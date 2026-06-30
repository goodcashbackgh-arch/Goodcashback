BEGIN;

-- Fix completion-loyalty internal-transfer candidates on Postgres installs without min(uuid).
-- The previous grouped CTE selected min(m.id) as an internal first_match_id, but UUID has no built-in min aggregate.
-- first_match_id is not returned or used downstream, so this replacement removes it without changing the RPC contract.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_internal_transfer_candidates_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  source_out_statement_line_id uuid,
  destination_in_statement_line_id uuid,
  importer_id uuid,
  importer_name text,
  source_out_date date,
  destination_in_date date,
  posting_date date,
  source_out_reference text,
  destination_in_reference text,
  source_amount_gbp numeric,
  destination_amount_gbp numeric,
  transfer_amount_gbp numeric,
  loyalty_released_amount_gbp numeric,
  excess_remaining_gbp numeric,
  destination_wallet_code text,
  source_mapping_code text,
  destination_mapping_code text,
  source_sage_ledger_account_id text,
  destination_sage_ledger_account_id text,
  materialisation_status text,
  blocker text,
  loyalty_match_ids jsonb,
  completed_order_ids jsonb,
  credit_ledger_ids jsonb,
  existing_posting_group_id uuid,
  existing_posting_group_ref text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: completion-loyalty internal-transfer candidates require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for completion-loyalty internal-transfer candidates.'; END IF;

  RETURN QUERY
  WITH grouped AS (
    SELECT
      m.dva_statement_line_id AS source_out_statement_line_id,
      m.destination_in_statement_line_id,
      m.importer_id,
      round(sum(COALESCE(m.matched_gbp_amount, 0))::numeric, 2) AS loyalty_released_amount_gbp,
      to_jsonb(array_agg(DISTINCT m.id)) AS loyalty_match_ids,
      to_jsonb(array_agg(DISTINCT m.completed_order_id)) AS completed_order_ids,
      to_jsonb(array_remove(array_agg(DISTINCT m.credit_ledger_id), NULL)) AS credit_ledger_ids
    FROM public.main_bank_completion_loyalty_funding_matches m
    WHERE m.transfer_pair_status = 'paired_released'
      AND m.match_status = 'released_available_dashboard_credit'
      AND m.destination_in_statement_line_id IS NOT NULL
    GROUP BY m.dva_statement_line_id, m.destination_in_statement_line_id, m.importer_id
  ), enriched AS (
    SELECT
      g.*,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      NULLIF(COALESCE(to_jsonb(src)->>'statement_date', to_jsonb(src)->>'transaction_date'), '')::date AS source_out_date,
      NULLIF(COALESCE(to_jsonb(dst)->>'statement_date', to_jsonb(dst)->>'transaction_date'), '')::date AS destination_in_date,
      COALESCE(NULLIF(to_jsonb(src)->>'reference_raw', ''), NULLIF(to_jsonb(src)->>'bank_reference', ''), src.id::text)::text AS source_out_reference,
      COALESCE(NULLIF(to_jsonb(dst)->>'reference_raw', ''), NULLIF(to_jsonb(dst)->>'bank_reference', ''), dst.id::text)::text AS destination_in_reference,
      round(abs(COALESCE(src.amount_gbp_equivalent, 0))::numeric, 2) AS source_amount_gbp,
      round(abs(COALESCE(dst.amount_gbp_equivalent, 0))::numeric, 2) AS destination_amount_gbp,
      COALESCE(to_jsonb(src)->>'direction', '')::text AS source_direction,
      COALESCE(to_jsonb(dst)->>'direction', '')::text AS destination_direction,
      sr.statement_account_context AS source_context,
      dr.statement_account_context AS destination_context,
      sr.resolved_mapping_code AS source_mapping_code,
      dr.resolved_mapping_code AS destination_mapping_code,
      sr.sage_ledger_account_id AS source_sage_ledger_account_id,
      dr.sage_ledger_account_id AS destination_sage_ledger_account_id,
      dr.resolved_wallet_code AS destination_wallet_code,
      sr.blocker AS source_mapping_blocker,
      dr.blocker AS destination_mapping_blocker,
      existing.id AS existing_posting_group_id,
      existing.posting_group_ref AS existing_posting_group_ref
    FROM grouped g
    JOIN public.dva_statement_lines src ON src.id = g.source_out_statement_line_id
    JOIN public.dva_statement_lines dst ON dst.id = g.destination_in_statement_line_id
    JOIN public.importers i ON i.id = g.importer_id
    LEFT JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(g.source_out_statement_line_id) sr ON true
    LEFT JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(g.destination_in_statement_line_id) dr ON true
    LEFT JOIN LATERAL (
      SELECT pg.id, pg.posting_group_ref
      FROM public.completion_loyalty_sage_posting_groups pg
      WHERE pg.posting_group_type = 'completion_loyalty_internal_transfer_journal'
        AND pg.active = true
        AND pg.status NOT IN ('cancelled','superseded','reversed')
        AND pg.request_context_json->>'source_out_statement_line_id' = g.source_out_statement_line_id::text
        AND pg.request_context_json->>'destination_in_statement_line_id' = g.destination_in_statement_line_id::text
        AND pg.importer_id = g.importer_id
      ORDER BY pg.created_at DESC
      LIMIT 1
    ) existing ON true
  ), finalised AS (
    SELECT
      e.*,
      e.source_amount_gbp AS transfer_amount_gbp,
      round(GREATEST(e.source_amount_gbp - e.loyalty_released_amount_gbp, 0)::numeric, 2) AS excess_remaining_gbp,
      CASE
        WHEN e.source_context <> 'main_company_bank_account' THEN 'source_out_not_main_company_bank_account'
        WHEN e.destination_context <> 'importer_dva_card_account' THEN 'destination_in_not_importer_wallet_account'
        WHEN e.source_direction <> 'out' THEN 'source_statement_line_not_out'
        WHEN e.destination_direction <> 'in' THEN 'destination_statement_line_not_in'
        WHEN e.source_amount_gbp <= 0 OR e.destination_amount_gbp <= 0 THEN 'invalid_statement_amount'
        WHEN abs(e.source_amount_gbp - e.destination_amount_gbp) > 0.01 THEN 'source_destination_amount_mismatch'
        WHEN e.source_mapping_blocker IS NOT NULL THEN e.source_mapping_blocker
        WHEN e.destination_mapping_blocker IS NOT NULL THEN e.destination_mapping_blocker
        WHEN e.existing_posting_group_id IS NOT NULL THEN 'already_materialised'
        ELSE NULL
      END AS blocker
    FROM enriched e
  ), filtered AS (
    SELECT f.*
    FROM finalised f
    WHERE v_search IS NULL
       OR lower(concat_ws(' ', f.importer_name, f.source_out_reference, f.destination_in_reference, f.destination_wallet_code, f.source_amount_gbp::text, f.loyalty_released_amount_gbp::text, f.existing_posting_group_ref)) LIKE '%' || v_search || '%'
  )
  SELECT
    f.source_out_statement_line_id,
    f.destination_in_statement_line_id,
    f.importer_id,
    f.importer_name,
    f.source_out_date,
    f.destination_in_date,
    f.destination_in_date AS posting_date,
    f.source_out_reference,
    f.destination_in_reference,
    f.source_amount_gbp,
    f.destination_amount_gbp,
    f.transfer_amount_gbp,
    f.loyalty_released_amount_gbp,
    f.excess_remaining_gbp,
    f.destination_wallet_code,
    f.source_mapping_code,
    f.destination_mapping_code,
    f.source_sage_ledger_account_id,
    f.destination_sage_ledger_account_id,
    CASE WHEN f.blocker IS NULL THEN 'ready_internal_transfer_journal_materialisation' ELSE 'blocked' END,
    f.blocker,
    f.loyalty_match_ids,
    f.completed_order_ids,
    f.credit_ledger_ids,
    f.existing_posting_group_id,
    f.existing_posting_group_ref,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.destination_in_date DESC NULLS LAST, f.source_out_date DESC NULLS LAST, f.importer_name ASC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

COMMIT;
