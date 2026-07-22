BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Treasury statement control corrective pack — Phase 3.
-- Read-only hard eligibility and suggested ranking for the next supplier invoice.
-- Ranking never allocates money and never overrides the existing allocation RPC guards.

DO $$
BEGIN
  IF to_regclass('public.statement_line_effective_interpretation_v1') IS NULL
     OR to_regprocedure('public.internal_statement_line_control_resolver_v2(uuid)') IS NULL
     OR to_regclass('public.supplier_payment_candidate_status_vw') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.retailers') IS NULL
  THEN
    RAISE EXCEPTION 'Treasury supplier-payment eligibility/ranking prerequisite is missing.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(
  p_dva_statement_line_id uuid
)
RETURNS TABLE (
  dva_statement_line_id uuid,
  supplier_invoice_id uuid,
  order_id uuid,
  order_ref text,
  importer_id uuid,
  retailer_id uuid,
  retailer_name text,
  invoice_ref text,
  invoice_uploaded_date date,
  review_status text,
  statement_date date,
  effective_display_description text,
  auth_id_ref text,
  retailer_name_ref text,
  statement_gbp_amount numeric,
  statement_confirmed_allocated_gbp numeric,
  statement_remaining_gbp numeric,
  invoice_total_gbp numeric,
  invoice_confirmed_matched_gbp numeric,
  invoice_remaining_gbp numeric,
  recommended_allocation_gbp numeric,
  confirmed_supplier_allocation_count bigint,
  locked_order_id uuid,
  locked_importer_id uuid,
  locked_retailer_id uuid,
  locked_source_bank_account_mapping_code text,
  locked_source_wallet_code text,
  sequence_locked_yn boolean,
  hard_eligible_yn boolean,
  hard_blocker text,
  amount_variance_gbp numeric,
  date_variance_days integer,
  reference_fit_yn boolean,
  retailer_fit_yn boolean,
  amount_fit_score integer,
  date_fit_score integer,
  reference_fit_score integer,
  retailer_fit_score integer,
  ranking_score integer,
  ranking_band text,
  suggested_rank bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for supplier-payment candidate ranking.';
  END IF;

  RETURN QUERY
  WITH line_scope AS (
    SELECT
      e.dva_statement_line_id,
      e.importer_id,
      e.statement_date,
      e.raw_description,
      e.effective_display_description,
      e.auth_id_ref,
      e.retailer_name_ref,
      e.statement_account_context,
      e.effective_direction,
      e.effective_economic_classification,
      ROUND(COALESCE(e.amount_gbp_equivalent, 0)::numeric, 2) AS statement_gbp_amount,
      r.active_consumed_gbp,
      r.active_reserved_gbp,
      r.remaining_unconsumed_gbp,
      r.overconsumed_gbp,
      r.incompatible_principal_lanes_yn,
      r.control_status,
      r.blocker AS resolver_blocker
    FROM public.statement_line_effective_interpretation_v1 e
    JOIN LATERAL public.internal_statement_line_control_resolver_v2(e.dva_statement_line_id) r ON true
    WHERE e.dva_statement_line_id = p_dva_statement_line_id
  ), allocation_integrity AS (
    SELECT
      COUNT(*) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
      )::bigint AS confirmed_supplier_allocation_count,
      COUNT(*) FILTER (WHERE a.allocation_status IN ('draft', 'held'))::bigint AS draft_or_held_count,
      COUNT(*) FILTER (
        WHERE a.allocation_status <> 'reversed'
          AND a.allocation_type <> 'supplier_invoice'
      )::bigint AS active_non_supplier_count,
      COUNT(DISTINCT si.order_id) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
      )::integer AS confirmed_order_count,
      COUNT(DISTINCT o.importer_id) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
      )::integer AS confirmed_importer_count,
      COUNT(DISTINCT o.retailer_id) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
      )::integer AS confirmed_retailer_count,
      COUNT(DISTINCT concat_ws('|',
        NULLIF(btrim(a.source_bank_account_mapping_code), ''),
        NULLIF(btrim(a.source_wallet_code), '')
      )) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND NULLIF(btrim(a.source_bank_account_mapping_code), '') IS NOT NULL
      )::integer AS confirmed_source_count,
      (array_agg(DISTINCT si.order_id) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND si.order_id IS NOT NULL
      ))[1] AS locked_order_id,
      (array_agg(DISTINCT o.importer_id) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND o.importer_id IS NOT NULL
      ))[1] AS locked_importer_id,
      (array_agg(DISTINCT o.retailer_id) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND o.retailer_id IS NOT NULL
      ))[1] AS locked_retailer_id,
      (array_agg(DISTINCT NULLIF(btrim(a.source_bank_account_mapping_code), '')) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND NULLIF(btrim(a.source_bank_account_mapping_code), '') IS NOT NULL
      ))[1] AS locked_source_mapping,
      (array_agg(DISTINCT NULLIF(btrim(a.source_wallet_code), '')) FILTER (
        WHERE a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND NULLIF(btrim(a.source_wallet_code), '') IS NOT NULL
      ))[1] AS locked_source_wallet
    FROM public.dva_statement_line_allocations a
    LEFT JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
    LEFT JOIN public.orders o ON o.id = si.order_id
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
  ), candidate_base AS (
    SELECT
      ls.*,
      ai.*,
      c.supplier_invoice_id,
      c.order_id,
      c.order_ref::text,
      c.importer_id AS candidate_importer_id,
      c.retailer_id AS candidate_retailer_id,
      r.name::text AS retailer_name,
      c.invoice_ref::text,
      si.uploaded_at::date AS invoice_uploaded_date,
      c.review_status::text,
      c.invoice_total_gbp,
      c.confirmed_matched_gbp,
      c.remaining_unmatched_gbp,
      c.supplier_payment_ready_yn,
      c.blocker AS candidate_blocker,
      c.selectable_yn,
      EXISTS (
        SELECT 1
        FROM public.dva_statement_line_allocations existing
        WHERE existing.dva_statement_line_id = p_dva_statement_line_id
          AND existing.supplier_invoice_id = c.supplier_invoice_id
          AND existing.allocation_type = 'supplier_invoice'
          AND existing.allocation_status <> 'reversed'
      ) AS invoice_already_on_line_yn,
      regexp_replace(
        lower(concat_ws(' ', ls.effective_display_description, ls.raw_description, ls.auth_id_ref, ls.retailer_name_ref)),
        '[^a-z0-9]+', '', 'g'
      ) AS statement_search_key,
      regexp_replace(lower(COALESCE(c.invoice_ref, '')), '[^a-z0-9]+', '', 'g') AS invoice_ref_key,
      regexp_replace(lower(COALESCE(c.order_ref, '')), '[^a-z0-9]+', '', 'g') AS order_ref_key,
      regexp_replace(lower(COALESCE(r.name, '')), '[^a-z0-9]+', '', 'g') AS retailer_key,
      regexp_replace(lower(COALESCE(ls.retailer_name_ref, '')), '[^a-z0-9]+', '', 'g') AS statement_retailer_key
    FROM line_scope ls
    CROSS JOIN allocation_integrity ai
    JOIN public.supplier_payment_candidate_status_vw c
      ON c.importer_id = ls.importer_id
    JOIN public.supplier_invoices si ON si.id = c.supplier_invoice_id
    JOIN public.orders o ON o.id = c.order_id
    LEFT JOIN public.retailers r ON r.id = c.retailer_id
  ), assessed AS (
    SELECT
      cb.*,
      ROUND(ABS(COALESCE(cb.remaining_unconsumed_gbp, 0) - COALESCE(cb.remaining_unmatched_gbp, 0))::numeric, 2) AS amount_variance_gbp,
      CASE
        WHEN cb.statement_date IS NULL OR cb.invoice_uploaded_date IS NULL THEN NULL::integer
        ELSE ABS(cb.statement_date - cb.invoice_uploaded_date)::integer
      END AS date_variance_days,
      (
        (length(cb.invoice_ref_key) >= 3 AND cb.statement_search_key LIKE '%' || cb.invoice_ref_key || '%')
        OR (length(cb.order_ref_key) >= 3 AND cb.statement_search_key LIKE '%' || cb.order_ref_key || '%')
      ) AS reference_fit_yn,
      (
        (length(cb.retailer_key) >= 3 AND cb.statement_search_key LIKE '%' || left(cb.retailer_key, 5) || '%')
        OR (
          length(cb.statement_retailer_key) >= 3
          AND cb.retailer_key LIKE '%' || left(cb.statement_retailer_key, 5) || '%'
        )
      ) AS retailer_fit_yn,
      CASE
        WHEN cb.statement_account_context <> 'importer_dva_card_account' THEN 'statement_line_not_importer_dva_card_account'
        WHEN cb.effective_direction <> 'out' THEN 'statement_line_not_effective_out'
        WHEN cb.effective_economic_classification NOT IN ('unclassified', 'supplier_payment') THEN 'statement_line_not_supplier_payment_classification'
        WHEN cb.control_status = 'blocked' OR cb.overconsumed_gbp > 0.01 OR cb.incompatible_principal_lanes_yn THEN COALESCE(cb.resolver_blocker, 'statement_line_control_blocked')
        WHEN cb.remaining_unconsumed_gbp <= 0.01 THEN 'statement_line_no_remaining_amount'
        WHEN cb.draft_or_held_count > 0 THEN 'statement_line_has_draft_or_held_allocation'
        WHEN cb.active_non_supplier_count > 0 THEN 'statement_line_has_active_non_supplier_allocation'
        WHEN cb.confirmed_supplier_allocation_count > 0
          AND (
            cb.confirmed_order_count <> 1
            OR cb.confirmed_importer_count <> 1
            OR cb.confirmed_retailer_count <> 1
          ) THEN 'existing_sequential_allocation_identity_inconsistent'
        WHEN cb.confirmed_supplier_allocation_count > 0 AND cb.confirmed_source_count <> 1 THEN 'existing_sequential_source_mapping_inconsistent'
        WHEN cb.candidate_importer_id IS DISTINCT FROM cb.importer_id THEN 'candidate_importer_mismatch'
        WHEN cb.confirmed_supplier_allocation_count > 0 AND cb.order_id IS DISTINCT FROM cb.locked_order_id THEN 'candidate_not_same_locked_order'
        WHEN cb.confirmed_supplier_allocation_count > 0 AND cb.candidate_retailer_id IS DISTINCT FROM cb.locked_retailer_id THEN 'candidate_not_same_locked_retailer'
        WHEN cb.invoice_already_on_line_yn THEN 'candidate_invoice_already_allocated_on_statement_line'
        WHEN cb.selectable_yn IS DISTINCT FROM true THEN COALESCE(cb.candidate_blocker, 'candidate_not_selectable')
        WHEN cb.remaining_unmatched_gbp <= 0.01 THEN 'candidate_invoice_no_remaining_amount'
        ELSE NULL::text
      END AS hard_blocker
    FROM candidate_base cb
  ), scored AS (
    SELECT
      a.*,
      CASE
        WHEN a.amount_variance_gbp <= 0.01 THEN 40
        WHEN a.amount_variance_gbp <= 1.00 THEN 35
        WHEN a.amount_variance_gbp <= 5.00 THEN 25
        WHEN a.amount_variance_gbp <= 10.00 THEN 15
        WHEN a.amount_variance_gbp <= 25.00 THEN 5
        ELSE 0
      END::integer AS amount_fit_score,
      CASE
        WHEN a.date_variance_days IS NULL THEN 0
        WHEN a.date_variance_days <= 3 THEN 15
        WHEN a.date_variance_days <= 7 THEN 10
        WHEN a.date_variance_days <= 14 THEN 5
        ELSE 0
      END::integer AS date_fit_score,
      CASE WHEN a.reference_fit_yn THEN 20 ELSE 0 END::integer AS reference_fit_score,
      CASE WHEN a.retailer_fit_yn THEN 25 ELSE 0 END::integer AS retailer_fit_score
    FROM assessed a
  ), ranked AS (
    SELECT
      s.*,
      (s.amount_fit_score + s.date_fit_score + s.reference_fit_score + s.retailer_fit_score)::integer AS ranking_score,
      ROW_NUMBER() OVER (
        ORDER BY
          (s.hard_blocker IS NULL) DESC,
          (s.amount_fit_score + s.date_fit_score + s.reference_fit_score + s.retailer_fit_score) DESC,
          s.amount_variance_gbp ASC,
          s.date_variance_days ASC NULLS LAST,
          s.supplier_invoice_id
      ) AS suggested_rank
    FROM scored s
  )
  SELECT
    r.dva_statement_line_id,
    r.supplier_invoice_id,
    r.order_id,
    r.order_ref,
    r.candidate_importer_id,
    r.candidate_retailer_id,
    r.retailer_name,
    r.invoice_ref,
    r.invoice_uploaded_date,
    r.review_status,
    r.statement_date,
    r.effective_display_description,
    r.auth_id_ref,
    r.retailer_name_ref,
    r.statement_gbp_amount,
    ROUND(GREATEST(r.statement_gbp_amount - r.remaining_unconsumed_gbp, 0)::numeric, 2),
    r.remaining_unconsumed_gbp,
    r.invoice_total_gbp,
    r.confirmed_matched_gbp,
    r.remaining_unmatched_gbp,
    ROUND(LEAST(r.remaining_unconsumed_gbp, r.remaining_unmatched_gbp)::numeric, 2),
    r.confirmed_supplier_allocation_count,
    r.locked_order_id,
    r.locked_importer_id,
    r.locked_retailer_id,
    r.locked_source_mapping,
    r.locked_source_wallet,
    (r.confirmed_supplier_allocation_count > 0),
    (r.hard_blocker IS NULL),
    r.hard_blocker,
    r.amount_variance_gbp,
    r.date_variance_days,
    r.reference_fit_yn,
    r.retailer_fit_yn,
    r.amount_fit_score,
    r.date_fit_score,
    r.reference_fit_score,
    r.retailer_fit_score,
    r.ranking_score,
    CASE
      WHEN r.ranking_score >= 80 THEN 'high'
      WHEN r.ranking_score >= 60 THEN 'medium'
      WHEN r.ranking_score >= 35 THEN 'low'
      ELSE 'weak'
    END::text,
    r.suggested_rank
  FROM ranked r
  ORDER BY r.suggested_rank;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) IS
'Read-only supplier-payment candidate contract for one physical importer DVA/card OUT. Returns every same-importer candidate with hard eligibility, explicit blocker, remaining amounts, sequence lock identity and a non-binding 100-point ranking based on amount, date, retailer and statement reference/auth text. Ranking never bypasses hard eligibility and never writes an allocation.';

NOTIFY pgrst, 'reload schema';
COMMIT;
