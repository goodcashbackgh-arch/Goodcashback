BEGIN;

-- Completion loyalty internal-transfer journal lane v1.
-- Additive integration into the existing /internal/accounting-command-centre/loyalty-controls Sage lifecycle.
-- No new workbench. No in-transit MVP. No VAT rows. No applied-loyalty settlement rewrite.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_groups') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_groups'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_steps') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_steps'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_batches') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_batches'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_batch_items') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_batch_items'; END IF;
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_mapping_settings'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing public.staff'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_staff_id_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_completion_loyalty_staff_id_v1()'; END IF;
END $$;

INSERT INTO public.sage_mapping_settings (mapping_code, mapping_group, display_name, description, value_kind, required_for)
VALUES
  ('LOYALTY_MAIN_GBP_BANK_LEDGER','completion_loyalty','Main GBP bank ledger','Sage long ledger account id for the existing mapped main GBP bank account used on completion-loyalty internal-transfer journals. Do not use the GL/display number.','ledger_account_id',ARRAY['completion_loyalty_internal_transfer_journal']::text[]),
  ('LOYALTY_DVA_GHS_BANK_LEDGER','completion_loyalty','DVA GHS wallet ledger','Sage long ledger account id for the company-controlled DVA GHS wallet/control account. Posted in GBP equivalent. Do not use the GL/display number.','ledger_account_id',ARRAY['completion_loyalty_internal_transfer_journal']::text[]),
  ('LOYALTY_VIRTUAL_GBP_BANK_LEDGER','completion_loyalty','Virtual GBP wallet ledger','Sage long ledger account id for the company-controlled Virtual GBP wallet/control account. Do not use the GL/display number.','ledger_account_id',ARRAY['completion_loyalty_internal_transfer_journal']::text[])
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    updated_at = now();

ALTER TABLE public.completion_loyalty_sage_posting_batches
  DROP CONSTRAINT IF EXISTS completion_loyalty_sage_batch_type_chk;

ALTER TABLE public.completion_loyalty_sage_posting_batches
  ADD CONSTRAINT completion_loyalty_sage_batch_type_chk
  CHECK (batch_type IN ('completion_loyalty_applied_settlement','completion_loyalty_internal_transfer_journal'));

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_statement_ledger_resolver_v1(
  p_statement_line_id uuid
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_account_context text,
  local_ccy text,
  resolved_wallet_code text,
  resolved_mapping_code text,
  sage_ledger_account_id text,
  blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_line record;
  v_context text;
  v_ccy text;
  v_wallet_code text;
  v_mapping_codes text[];
  v_mapping record;
  v_blocker text;
BEGIN
  SELECT
    dsl.id,
    ds.statement_account_context::text AS statement_account_context,
    upper(COALESCE(NULLIF(to_jsonb(dsl)->>'local_ccy', ''), NULLIF(to_jsonb(dsl)->>'currency', ''), ''))::text AS local_ccy
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_statement_line_id;

  IF v_line.id IS NULL THEN
    RETURN QUERY SELECT p_statement_line_id, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, 'statement_line_not_found'::text;
    RETURN;
  END IF;

  v_context := v_line.statement_account_context;
  v_ccy := v_line.local_ccy;

  IF v_context = 'main_company_bank_account' THEN
    v_wallet_code := 'main_gbp_bank';
    v_mapping_codes := ARRAY['LOYALTY_MAIN_GBP_BANK_LEDGER','LOYALTY_MAIN_BANK_LEDGER','MAIN_GBP_BANK_LEDGER','MAIN_BANK_LEDGER','MAIN_COMPANY_BANK_LEDGER'];
  ELSIF v_context = 'importer_dva_card_account' AND v_ccy = 'GBP' THEN
    v_wallet_code := 'virtual_gbp_wallet';
    v_mapping_codes := ARRAY['LOYALTY_VIRTUAL_GBP_BANK_LEDGER','VIRTUAL_GBP_BANK_LEDGER','VIRTUAL_GBP_BANK_ACCOUNT'];
  ELSIF v_context = 'importer_dva_card_account' AND v_ccy = 'GHS' THEN
    v_wallet_code := 'dva_ghs_wallet';
    v_mapping_codes := ARRAY['LOYALTY_DVA_GHS_BANK_LEDGER','DVA_GHS_BANK_LEDGER','DVA_CASH_BANK_LEDGER','DVA_CASH_BANK_LEDGER_ACCOUNT','DVA_CASH_CLEARING_LEDGER'];
  ELSIF v_context = 'importer_dva_card_account' THEN
    v_wallet_code := 'unsupported_importer_wallet_currency';
    v_mapping_codes := ARRAY[]::text[];
    v_blocker := 'unsupported_importer_wallet_currency_' || COALESCE(NULLIF(v_ccy, ''), 'missing');
  ELSE
    v_wallet_code := 'unsupported_statement_account_context';
    v_mapping_codes := ARRAY[]::text[];
    v_blocker := 'unsupported_statement_account_context_' || COALESCE(NULLIF(v_context, ''), 'missing');
  END IF;

  IF v_blocker IS NULL THEN
    SELECT sms.mapping_code, sms.sage_external_id
    INTO v_mapping
    FROM public.sage_mapping_settings sms
    WHERE sms.mapping_code = ANY(v_mapping_codes)
      AND sms.is_active = true
      AND NULLIF(trim(COALESCE(sms.sage_external_id, '')), '') IS NOT NULL
    ORDER BY array_position(v_mapping_codes, sms.mapping_code), sms.updated_at DESC NULLS LAST
    LIMIT 1;

    IF NULLIF(trim(COALESCE(v_mapping.sage_external_id, '')), '') IS NULL THEN
      v_blocker := 'missing_' || v_wallet_code || '_sage_ledger_mapping';
    END IF;
  END IF;

  RETURN QUERY SELECT
    v_line.id::uuid,
    v_context::text,
    v_ccy::text,
    v_wallet_code::text,
    v_mapping.mapping_code::text,
    v_mapping.sage_external_id::text,
    v_blocker::text;
END;
$$;

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
      to_jsonb(array_remove(array_agg(DISTINCT m.credit_ledger_id), NULL)) AS credit_ledger_ids,
      min(m.id) AS first_match_id
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

CREATE OR REPLACE FUNCTION public.staff_materialise_completion_loyalty_internal_transfer_journal_v1(
  p_source_out_statement_line_id uuid,
  p_destination_in_statement_line_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_candidate record;
  v_group_id uuid;
  v_group_ref text;
  v_journal_payload jsonb;
  v_status text := 'locally_validated';
  v_validation_status text := 'ok_to_post';
  v_payload_fp text;
  v_mapping_fp text;
  v_source_fp text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: materialise internal transfer requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required to materialise internal transfer journals.'; END IF;
  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;

  SELECT * INTO v_candidate
  FROM public.internal_completion_loyalty_internal_transfer_candidates_v1(NULL, 300, 0) c
  WHERE c.source_out_statement_line_id = p_source_out_statement_line_id
    AND c.destination_in_statement_line_id = p_destination_in_statement_line_id
  LIMIT 1;

  IF v_candidate.source_out_statement_line_id IS NULL THEN
    RAISE EXCEPTION 'No paired released completion-loyalty transfer candidate found for source % and destination %.', p_source_out_statement_line_id, p_destination_in_statement_line_id;
  END IF;

  IF v_candidate.existing_posting_group_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'already_materialised', true, 'posting_group_id', v_candidate.existing_posting_group_id, 'posting_group_ref', v_candidate.existing_posting_group_ref, 'status', 'existing');
  END IF;

  IF v_candidate.blocker IS NOT NULL THEN
    v_status := 'blocked';
    v_validation_status := CASE WHEN v_candidate.blocker LIKE '%mapping%' THEN 'blocked_mapping_missing' ELSE 'blocked_source_not_ready' END;
  END IF;

  v_group_ref := 'CLIT-' || left(p_source_out_statement_line_id::text, 6) || '-' || left(p_destination_in_statement_line_id::text, 6) || '-' || floor(extract(epoch from clock_timestamp()))::bigint::text;
  v_source_fp := md5(concat_ws('|', p_source_out_statement_line_id::text, p_destination_in_statement_line_id::text, v_candidate.importer_id::text, v_candidate.transfer_amount_gbp::text, v_candidate.loyalty_match_ids::text));
  v_mapping_fp := md5(concat_ws('|', v_candidate.source_sage_ledger_account_id, v_candidate.destination_sage_ledger_account_id, v_candidate.source_mapping_code, v_candidate.destination_mapping_code));
  v_payload_fp := md5(concat_ws('|', v_source_fp, v_mapping_fp, v_candidate.posting_date::text, v_candidate.transfer_amount_gbp::text));

  INSERT INTO public.completion_loyalty_sage_posting_groups (
    posting_group_ref,
    posting_group_type,
    order_id,
    order_ref,
    importer_id,
    order_funding_event_id,
    loyalty_match_id,
    source_credit_ledger_id,
    debit_ledger_id,
    target_sage_invoice_snapshot_ids,
    target_sage_invoice_ids,
    target_allocation_json,
    amount_gbp,
    posting_date,
    status,
    validation_status,
    validated_at,
    validation_error_json,
    blocker,
    source_payload_fingerprint,
    mapping_fingerprint,
    payload_fingerprint,
    current_resolver_version,
    request_context_json,
    created_by_staff_id
  ) VALUES (
    v_group_ref,
    'completion_loyalty_internal_transfer_journal',
    NULL,
    'Internal transfer',
    v_candidate.importer_id,
    NULL,
    NULL,
    NULL,
    NULL,
    '[]'::jsonb,
    '[]'::jsonb,
    '[]'::jsonb,
    v_candidate.transfer_amount_gbp,
    v_candidate.posting_date,
    v_status,
    v_validation_status,
    now(),
    jsonb_build_object('blocker', v_candidate.blocker),
    v_candidate.blocker,
    v_source_fp,
    v_mapping_fp,
    v_payload_fp,
    'completion_loyalty_internal_transfer_resolver_v1',
    jsonb_build_object(
      'source_out_statement_line_id', v_candidate.source_out_statement_line_id,
      'destination_in_statement_line_id', v_candidate.destination_in_statement_line_id,
      'source_out_date', v_candidate.source_out_date,
      'destination_in_date', v_candidate.destination_in_date,
      'source_out_reference', v_candidate.source_out_reference,
      'destination_in_reference', v_candidate.destination_in_reference,
      'source_amount_gbp', v_candidate.source_amount_gbp,
      'destination_amount_gbp', v_candidate.destination_amount_gbp,
      'transfer_amount_gbp', v_candidate.transfer_amount_gbp,
      'loyalty_released_amount_gbp', v_candidate.loyalty_released_amount_gbp,
      'excess_remaining_gbp', v_candidate.excess_remaining_gbp,
      'destination_wallet_code', v_candidate.destination_wallet_code,
      'source_mapping_code', v_candidate.source_mapping_code,
      'destination_mapping_code', v_candidate.destination_mapping_code,
      'source_sage_ledger_account_id', v_candidate.source_sage_ledger_account_id,
      'destination_sage_ledger_account_id', v_candidate.destination_sage_ledger_account_id,
      'loyalty_match_ids', v_candidate.loyalty_match_ids,
      'completed_order_ids', v_candidate.completed_order_ids,
      'credit_ledger_ids', v_candidate.credit_ledger_ids,
      'notes', p_notes
    ),
    v_staff_id
  ) RETURNING id INTO v_group_id;

  IF v_status = 'locally_validated' THEN
    v_journal_payload := jsonb_build_object(
      'journal', jsonb_build_object(
        'date', v_candidate.posting_date::text,
        'reference', 'LT-' || left(v_group_id::text, 6),
        'description', 'Completion loyalty internal transfer',
        'show_payments_allocations', false,
        'journal_lines', jsonb_build_array(
          jsonb_build_object('ledger_account_id', v_candidate.destination_sage_ledger_account_id, 'details', 'Completion loyalty transfer to ' || replace(v_candidate.destination_wallet_code, '_', ' '), 'debit', v_candidate.transfer_amount_gbp, 'credit', 0, 'tax_rate_id', NULL, 'include_on_tax_return', false),
          jsonb_build_object('ledger_account_id', v_candidate.source_sage_ledger_account_id, 'details', 'Completion loyalty transfer from main GBP bank', 'debit', 0, 'credit', v_candidate.transfer_amount_gbp, 'tax_rate_id', NULL, 'include_on_tax_return', false)
        )
      )
    );

    INSERT INTO public.completion_loyalty_sage_posting_steps (posting_group_id, step_type, source_table, source_id, endpoint_path, method, idempotency_key, request_payload, request_payload_hash, sage_object_type, sage_reference, status)
    VALUES (v_group_id, 'loyalty_internal_transfer_journal', 'main_bank_completion_loyalty_funding_matches', NULL, '/journals', 'POST', 'completion-loyalty-internal-transfer:' || p_source_out_statement_line_id::text || ':' || p_destination_in_statement_line_id::text, v_journal_payload, md5(v_journal_payload::text), 'journal', ('LT-' || left(v_group_id::text, 6)), 'locally_validated')
    ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (posting_group_id, log_type, message, payload, created_by_staff_id)
  VALUES (v_group_id, 'materialisation', 'Completion-loyalty internal-transfer journal group materialised/frozen locally.', jsonb_build_object('status', v_status, 'validation_status', v_validation_status, 'blocker', v_candidate.blocker), v_staff_id);

  RETURN jsonb_build_object('ok', true, 'posting_group_id', v_group_id, 'posting_group_ref', v_group_ref, 'status', v_status, 'validation_status', v_validation_status, 'blocker', v_candidate.blocker);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_validate_completion_loyalty_sage_group_v1(p_posting_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_group record;
  v_staff_id uuid;
  v_current_total numeric(18,2) := 0;
  v_current_targets jsonb := '[]'::jsonb;
  v_new_validation text := 'ok_to_post';
  v_new_status text;
  v_new_blocker text;
  v_candidate record;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: validation requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for validation.'; END IF;
  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;
  SELECT * INTO v_group FROM public.completion_loyalty_sage_posting_groups WHERE id = p_posting_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN RAISE EXCEPTION 'Posting group not found: %', p_posting_group_id; END IF;
  IF NOT v_group.active OR v_group.status IN ('cancelled','superseded','reversed') THEN RAISE EXCEPTION 'Cannot validate inactive or closed posting group %.', v_group.posting_group_ref; END IF;
  IF EXISTS (SELECT 1 FROM public.completion_loyalty_sage_posting_steps s WHERE s.posting_group_id = v_group.id AND (s.status = 'posted_to_sage' OR s.sage_object_id IS NOT NULL OR s.posted_at IS NOT NULL)) THEN
    RAISE EXCEPTION 'Cannot revalidate %. At least one step has already posted to Sage.', v_group.posting_group_ref;
  END IF;

  IF v_group.posting_group_type = 'completion_loyalty_internal_transfer_journal' THEN
    SELECT * INTO v_candidate
    FROM public.internal_completion_loyalty_internal_transfer_candidates_v1(NULL, 300, 0) c
    WHERE c.source_out_statement_line_id = (v_group.request_context_json->>'source_out_statement_line_id')::uuid
      AND c.destination_in_statement_line_id = (v_group.request_context_json->>'destination_in_statement_line_id')::uuid
    LIMIT 1;

    IF v_candidate.source_out_statement_line_id IS NULL THEN
      v_new_status := 'blocked';
      v_new_validation := 'blocked_source_not_ready';
      v_new_blocker := 'paired_released_internal_transfer_source_not_found';
    ELSIF v_candidate.blocker IS NOT NULL AND v_candidate.blocker <> 'already_materialised' THEN
      v_new_status := 'blocked';
      v_new_validation := CASE WHEN v_candidate.blocker LIKE '%mapping%' THEN 'blocked_mapping_missing' ELSE 'blocked_source_not_ready' END;
      v_new_blocker := v_candidate.blocker;
    ELSE
      v_new_status := CASE WHEN v_group.status = 'admin_approved' THEN 'admin_approved' ELSE 'locally_validated' END;
      v_new_validation := 'ok_to_post';
      v_new_blocker := NULL;
    END IF;

    UPDATE public.completion_loyalty_sage_posting_groups
    SET status = v_new_status,
        validation_status = v_new_validation,
        validated_at = now(),
        blocker = v_new_blocker,
        validation_error_json = jsonb_build_object('blocker', v_new_blocker, 'validated_by_staff_id', v_staff_id),
        approval_status = CASE WHEN v_new_validation IN ('ok_to_post','warning_only') THEN approval_status ELSE 'invalidated' END,
        updated_at = now()
    WHERE id = v_group.id;

    UPDATE public.completion_loyalty_sage_posting_steps
    SET status = CASE WHEN v_new_validation = 'ok_to_post' AND status IN ('blocked','draft','locally_validated') THEN 'locally_validated' ELSE status END,
        updated_at = now()
    WHERE posting_group_id = v_group.id AND active = true;

    INSERT INTO public.completion_loyalty_sage_posting_step_logs (posting_group_id, log_type, message, payload, created_by_staff_id)
    VALUES (v_group.id, 'validation', 'Completion-loyalty internal-transfer posting group revalidated.', jsonb_build_object('status', v_new_status, 'validation_status', v_new_validation, 'blocker', v_new_blocker), v_staff_id);

    RETURN jsonb_build_object('ok', true, 'posting_group_id', v_group.id, 'status', v_new_status, 'validation_status', v_new_validation, 'blocker', v_new_blocker);
  END IF;

  IF v_group.status = 'blocked' THEN
    v_new_status := 'blocked';
    v_new_validation := v_group.validation_status;
    v_new_blocker := v_group.blocker;
  ELSE
    SELECT COALESCE(jsonb_agg(to_jsonb(t.target_sage_invoice_id) ORDER BY t.sort_key, t.target_sage_invoice_snapshot_id), '[]'::jsonb), round(COALESCE(sum(t.allocation_amount_gbp),0)::numeric,2)
    INTO v_current_targets, v_current_total
    FROM public.internal_completion_loyalty_open_customer_sales_targets_v1((v_group.order_id)::uuid, v_group.request_context_json->>'sage_contact_id', v_group.amount_gbp) t;

    IF v_current_total + 0.01 < v_group.amount_gbp THEN
      v_new_status := 'blocked';
      v_new_validation := 'blocked_target_not_ready';
      v_new_blocker := 'current_open_customer_receivable_below_loyalty_amount';
    ELSIF v_current_targets::text <> v_group.target_sage_invoice_ids::text THEN
      v_new_status := 'blocked';
      v_new_validation := 'stale_reapproval_required';
      v_new_blocker := 'current_target_list_differs_from_frozen_group_supersede_and_rematerialise';
    ELSE
      v_new_status := CASE WHEN v_group.status = 'admin_approved' THEN 'admin_approved' ELSE 'locally_validated' END;
      v_new_validation := 'ok_to_post';
      v_new_blocker := NULL;
    END IF;
  END IF;

  UPDATE public.completion_loyalty_sage_posting_groups
  SET status = v_new_status,
      validation_status = v_new_validation,
      validated_at = now(),
      blocker = v_new_blocker,
      validation_error_json = jsonb_build_object('blocker', v_new_blocker, 'validated_by_staff_id', v_staff_id),
      approval_status = CASE WHEN v_new_validation IN ('ok_to_post','warning_only') THEN approval_status ELSE 'invalidated' END,
      updated_at = now()
  WHERE id = v_group.id;

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (posting_group_id, log_type, message, payload, created_by_staff_id)
  VALUES (v_group.id, 'validation', 'Completion-loyalty posting group revalidated.', jsonb_build_object('status', v_new_status, 'validation_status', v_new_validation, 'blocker', v_new_blocker), v_staff_id);

  RETURN jsonb_build_object('ok', true, 'posting_group_id', v_group.id, 'status', v_new_status, 'validation_status', v_new_validation, 'blocker', v_new_blocker);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_create_completion_loyalty_sage_batch_v1(
  p_posting_group_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_group_ids uuid[];
  v_group_count integer := 0;
  v_found_count integer := 0;
  v_distinct_type_count integer := 0;
  v_batch_type text;
  v_bad_ref text;
  v_existing_batch_ref text;
  v_staff_id uuid;
  v_batch_id uuid;
  v_batch_ref text;
  v_total_amount numeric(18,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: create loyalty Sage batch requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required to create loyalty Sage batch.'; END IF;

  SELECT array_agg(DISTINCT item) INTO v_group_ids
  FROM unnest(COALESCE(p_posting_group_ids, ARRAY[]::uuid[])) AS item
  WHERE item IS NOT NULL;

  v_group_count := COALESCE(array_length(v_group_ids, 1), 0);
  IF v_group_count = 0 THEN RAISE EXCEPTION 'Select at least one locally validated loyalty Sage posting group to batch.'; END IF;

  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'Active staff record required to create loyalty Sage batch.'; END IF;

  SELECT count(*)::integer, count(DISTINCT g.posting_group_type)::integer, min(g.posting_group_type)
  INTO v_found_count, v_distinct_type_count, v_batch_type
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids);

  IF v_found_count <> v_group_count THEN RAISE EXCEPTION 'One or more selected loyalty Sage posting groups could not be found.'; END IF;
  IF v_distinct_type_count <> 1 THEN RAISE EXCEPTION 'Do not mix applied-loyalty settlement and internal-transfer journal groups in the same Sage batch.'; END IF;
  IF v_batch_type NOT IN ('completion_loyalty_applied_settlement','completion_loyalty_internal_transfer_journal') THEN RAISE EXCEPTION 'Unsupported loyalty Sage batch type: %', v_batch_type; END IF;

  PERFORM 1 FROM public.completion_loyalty_sage_posting_groups g WHERE g.id = ANY(v_group_ids) FOR UPDATE;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids)
    AND NOT (g.active = true AND g.posting_group_type = v_batch_type AND g.status IN ('locally_validated','admin_approved') AND g.validation_status IN ('ok_to_post','warning_only') AND g.blocker IS NULL AND g.posted_at IS NULL)
  ORDER BY g.created_at DESC
  LIMIT 1;
  IF v_bad_ref IS NOT NULL THEN RAISE EXCEPTION 'Selected loyalty Sage group % is not eligible for batching. It must be active, locally validated, unposted and blocker-free.', v_bad_ref; END IF;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids)
    AND EXISTS (SELECT 1 FROM public.completion_loyalty_sage_posting_steps s WHERE s.posting_group_id = g.id AND s.active = true AND (s.status = 'posted_to_sage' OR s.sage_object_id IS NOT NULL OR s.posted_at IS NOT NULL))
  LIMIT 1;
  IF v_bad_ref IS NOT NULL THEN RAISE EXCEPTION 'Selected loyalty Sage group % already has a posted Sage step and cannot be batched as unposted.', v_bad_ref; END IF;

  SELECT b.batch_ref INTO v_existing_batch_ref
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_batches b ON b.id = bi.batch_id
  WHERE bi.posting_group_id = ANY(v_group_ids)
    AND bi.active = true
    AND bi.item_status NOT IN ('cancelled','superseded')
    AND b.active = true
    AND b.status NOT IN ('cancelled','superseded')
  ORDER BY b.created_at DESC
  LIMIT 1;
  IF v_existing_batch_ref IS NOT NULL THEN RAISE EXCEPTION 'One or more selected loyalty Sage groups already sit in active batch %.', v_existing_batch_ref; END IF;

  SELECT round(COALESCE(sum(g.amount_gbp), 0)::numeric, 2) INTO v_total_amount FROM public.completion_loyalty_sage_posting_groups g WHERE g.id = ANY(v_group_ids);
  v_batch_ref := CASE WHEN v_batch_type = 'completion_loyalty_internal_transfer_journal' THEN 'CLITB-' ELSE 'CLASB-' END || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || substr(md5(gen_random_uuid()::text), 1, 6);

  INSERT INTO public.completion_loyalty_sage_posting_batches (batch_ref, batch_type, status, validation_status, approval_status, row_count, total_amount_gbp, notes, created_by_staff_id)
  VALUES (v_batch_ref, v_batch_type, 'validated', 'ok_to_post', 'not_approved', v_group_count, v_total_amount, NULLIF(p_notes, ''), v_staff_id)
  RETURNING id, batch_ref INTO v_batch_id, v_batch_ref;

  INSERT INTO public.completion_loyalty_sage_posting_batch_items (batch_id, posting_group_id, order_funding_event_id, amount_gbp, item_status, validation_status, posting_status)
  SELECT v_batch_id, g.id, g.order_funding_event_id, g.amount_gbp, 'batched_validated', g.validation_status, 'not_posted'
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids);

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (posting_group_id, log_type, message, payload, created_by_staff_id)
  SELECT g.id, 'batch_create', 'Completion-loyalty Sage posting group added to batch.', jsonb_build_object('batch_id', v_batch_id, 'batch_ref', v_batch_ref, 'batch_type', v_batch_type, 'notes', p_notes), v_staff_id
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids);

  RETURN jsonb_build_object('ok', true, 'batch_id', v_batch_id, 'batch_ref', v_batch_ref, 'batch_type', v_batch_type, 'row_count', v_group_count, 'total_amount_gbp', v_total_amount);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_approve_completion_loyalty_sage_batch_v1(
  p_batch_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch record;
  v_staff_id uuid;
  v_bad_ref text;
  v_payload_hash text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: approve loyalty Sage batch requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required to approve loyalty Sage batch.'; END IF;
  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'Active staff record required to approve loyalty Sage batch.'; END IF;

  SELECT * INTO v_batch FROM public.completion_loyalty_sage_posting_batches b WHERE b.id = p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Loyalty Sage batch not found: %', p_batch_id; END IF;
  IF v_batch.active IS NOT TRUE OR v_batch.status IN ('cancelled','superseded','posted_to_sage','posting_to_sage') THEN RAISE EXCEPTION 'Loyalty Sage batch % cannot be approved from status %.', v_batch.batch_ref, v_batch.status; END IF;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_groups g ON g.id = bi.posting_group_id
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true
    AND NOT (g.active = true AND g.posting_group_type = v_batch.batch_type AND g.status IN ('locally_validated','admin_approved') AND g.validation_status IN ('ok_to_post','warning_only') AND g.blocker IS NULL AND g.posted_at IS NULL)
  ORDER BY g.created_at DESC
  LIMIT 1;
  IF v_bad_ref IS NOT NULL THEN RAISE EXCEPTION 'Loyalty Sage batch % cannot be approved because group % is no longer eligible.', v_batch.batch_ref, v_bad_ref; END IF;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_groups g ON g.id = bi.posting_group_id
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true
    AND EXISTS (SELECT 1 FROM public.completion_loyalty_sage_posting_steps s WHERE s.posting_group_id = g.id AND s.active = true AND (s.status = 'posted_to_sage' OR s.sage_object_id IS NOT NULL OR s.posted_at IS NOT NULL))
  LIMIT 1;
  IF v_bad_ref IS NOT NULL THEN RAISE EXCEPTION 'Loyalty Sage batch % cannot be approved because group % already has a posted Sage step.', v_batch.batch_ref, v_bad_ref; END IF;

  SELECT md5(COALESCE(string_agg(concat_ws(':', g.id::text, g.payload_fingerprint, g.mapping_fingerprint, g.source_payload_fingerprint), ',' ORDER BY g.id::text), 'empty'))
  INTO v_payload_hash
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_groups g ON g.id = bi.posting_group_id
  WHERE bi.batch_id = p_batch_id AND bi.active = true;

  UPDATE public.completion_loyalty_sage_posting_batches
  SET status = 'approved', approval_status = 'approved', approved_by_staff_id = v_staff_id, approved_at = now(), approved_payload_hash = v_payload_hash, notes = COALESCE(NULLIF(p_notes, ''), notes), updated_at = now()
  WHERE id = p_batch_id;

  UPDATE public.completion_loyalty_sage_posting_batch_items SET item_status = 'approved', updated_at = now() WHERE batch_id = p_batch_id AND active = true AND item_status = 'batched_validated';

  UPDATE public.completion_loyalty_sage_posting_groups g
  SET status = 'admin_approved', approval_status = 'approved', approved_by_staff_id = v_staff_id, approved_at = now(), approved_payload_hash = COALESCE(g.payload_fingerprint, v_payload_hash), updated_at = now()
  WHERE g.id IN (SELECT bi.posting_group_id FROM public.completion_loyalty_sage_posting_batch_items bi WHERE bi.batch_id = p_batch_id AND bi.active = true)
    AND g.status = 'locally_validated';

  UPDATE public.completion_loyalty_sage_posting_steps s
  SET status = CASE WHEN s.status = 'locally_validated' THEN 'admin_approved' ELSE s.status END, updated_at = now()
  WHERE s.posting_group_id IN (SELECT bi.posting_group_id FROM public.completion_loyalty_sage_posting_batch_items bi WHERE bi.batch_id = p_batch_id AND bi.active = true)
    AND s.active = true;

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (posting_group_id, log_type, message, payload, created_by_staff_id)
  SELECT bi.posting_group_id, 'batch_approval', 'Completion-loyalty Sage batch approved.', jsonb_build_object('batch_id', p_batch_id, 'batch_ref', v_batch.batch_ref, 'batch_type', v_batch.batch_type, 'notes', p_notes, 'approved_payload_hash', v_payload_hash), v_staff_id
  FROM public.completion_loyalty_sage_posting_batch_items bi
  WHERE bi.batch_id = p_batch_id AND bi.active = true;

  RETURN jsonb_build_object('ok', true, 'batch_id', p_batch_id, 'batch_ref', v_batch.batch_ref, 'batch_type', v_batch.batch_type, 'status', 'approved');
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.internal_completion_loyalty_internal_transfer_candidates_v1(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_internal_transfer_candidates_v1(text, integer, integer) TO authenticated;
REVOKE ALL ON FUNCTION public.staff_materialise_completion_loyalty_internal_transfer_journal_v1(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_materialise_completion_loyalty_internal_transfer_journal_v1(uuid, uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
