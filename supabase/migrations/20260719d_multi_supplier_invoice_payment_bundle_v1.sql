BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Multi-supplier-invoice order control — Mini-build 2 payment bundle.
-- One physical OUT remains one statement event. Several allocation rows may sit
-- beneath it, but they must be written atomically, total exactly to the OUT, use
-- invoices from one order, and share one proven source mapping.

DO $$
BEGIN
  IF to_regclass('public.dva_statement_lines') IS NULL
     OR to_regclass('public.dva_statements') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.staff') IS NULL
     OR to_regclass('public.order_funding_events') IS NULL
     OR to_regclass('public.importer_credit_ledger') IS NULL
     OR to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL
  THEN
    RAISE EXCEPTION 'Mini-build 2 supplier-payment bundle prerequisite relation is missing.';
  END IF;

  IF to_regprocedure('public.internal_supplier_payment_readiness_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Mini-build 2 supplier-payment bundle prerequisite routine is missing.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(
  p_dva_statement_line_id uuid,
  p_allocations jsonb,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_line record;
  v_order record;
  v_order_id uuid;
  v_importer_id uuid;
  v_retailer_id uuid;
  v_statement_amount numeric(12,2);
  v_requested_total numeric(12,2);
  v_allocation_count integer;
  v_distinct_invoice_count integer;
  v_readiness_ready boolean;
  v_readiness_blocker text;
  v_funding_required_yn boolean;
  v_has_applied_credit_provenance boolean := false;
  v_loyalty_exact_count integer := 0;
  v_loyalty_total_remaining_gbp numeric(12,2) := 0;
  v_cash_funding_remaining_gbp numeric(12,2) := 0;
  v_exact_wallet_code text;
  v_exact_mapping_code text;
  v_source_bank_account_mapping_code text;
  v_source_wallet_code text;
  v_source_resolution_reason text;
  v_inserted_count integer := 0;
  v_inserted_ids uuid[] := ARRAY[]::uuid[];
  v_bad record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff allocation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND s.active = true
  LIMIT 1;

  IF v_staff.id IS NULL OR COALESCE(v_staff.role_type, '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can allocate a supplier-payment bundle.';
  END IF;

  IF p_dva_statement_line_id IS NULL THEN
    RAISE EXCEPTION 'dva_statement_line_id is required';
  END IF;

  IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'p_allocations must be a non-empty JSON array';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.supplier_payment_bundle_input (
    supplier_invoice_id uuid PRIMARY KEY,
    allocated_gbp_amount numeric(12,2) NOT NULL
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.supplier_payment_bundle_input;

  BEGIN
    INSERT INTO pg_temp.supplier_payment_bundle_input (supplier_invoice_id, allocated_gbp_amount)
    SELECT
      x.supplier_invoice_id,
      ROUND(x.allocated_gbp_amount::numeric, 2)
    FROM jsonb_to_recordset(p_allocations) AS x(
      supplier_invoice_id uuid,
      allocated_gbp_amount numeric
    );
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Each supplier invoice may appear only once in the allocation bundle.';
  END;

  SELECT COUNT(*), COUNT(DISTINCT supplier_invoice_id), ROUND(SUM(allocated_gbp_amount)::numeric, 2)
    INTO v_allocation_count, v_distinct_invoice_count, v_requested_total
  FROM pg_temp.supplier_payment_bundle_input;

  IF v_allocation_count = 0 OR v_allocation_count <> v_distinct_invoice_count THEN
    RAISE EXCEPTION 'Supplier-payment bundle contains no usable or duplicate invoice entries.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_temp.supplier_payment_bundle_input WHERE allocated_gbp_amount <= 0
  ) THEN
    RAISE EXCEPTION 'Every supplier invoice allocation amount must be greater than zero.';
  END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.match_status,
    dsl.fx_rate_applied,
    dsl.card_markup_pct_applied,
    dsl.local_ccy,
    ds.importer_id,
    ds.statement_account_context
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'DVA/card statement line not found: %', p_dva_statement_line_id;
  END IF;
  IF v_line.direction IS DISTINCT FROM 'out' THEN
    RAISE EXCEPTION 'Supplier-payment bundle requires an OUT statement line.';
  END IF;

  v_statement_amount := ROUND(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2);
  IF v_statement_amount <= 0 THEN
    RAISE EXCEPTION 'Statement line has no positive GBP amount.';
  END IF;
  IF ABS(v_requested_total - v_statement_amount) > 0.01 THEN
    RAISE EXCEPTION 'One physical supplier-payment OUT must be allocated once for its full amount. Statement GBP %, bundle GBP %',
      v_statement_amount, v_requested_total;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.allocation_status <> 'reversed'
  ) THEN
    RAISE EXCEPTION 'Physical statement OUT % already has an active allocation.', p_dva_statement_line_id;
  END IF;

  SELECT
    MIN(si.order_id),
    COUNT(DISTINCT si.order_id),
    COUNT(DISTINCT o.importer_id),
    COUNT(DISTINCT o.retailer_id)
  INTO v_order_id, v_allocation_count, v_distinct_invoice_count, v_inserted_count
  FROM pg_temp.supplier_payment_bundle_input i
  JOIN public.supplier_invoices si ON si.id = i.supplier_invoice_id
  JOIN public.orders o ON o.id = si.order_id;

  IF v_order_id IS NULL OR v_allocation_count <> 1 THEN
    RAISE EXCEPTION 'All supplier invoices in one physical OUT bundle must belong to the same order.';
  END IF;
  IF v_distinct_invoice_count <> 1 OR v_inserted_count <> 1 THEN
    RAISE EXCEPTION 'Supplier-payment bundle importer or retailer identity is inconsistent.';
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, o.retailer_id, o.status, COALESCE(o.order_type, 'original') AS order_type
    INTO v_order
  FROM public.orders o
  WHERE o.id = v_order_id
  FOR UPDATE;

  v_importer_id := v_order.importer_id;
  v_retailer_id := v_order.retailer_id;

  IF v_importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Statement importer % does not match order importer %.', v_line.importer_id, v_importer_id;
  END IF;
  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot allocate supplier payment to order % with status %.', v_order.order_ref, v_order.status;
  END IF;

  SELECT
    r.supplier_payment_ready_yn,
    r.blocker,
    r.funding_required_yn
  INTO v_readiness_ready, v_readiness_blocker, v_funding_required_yn
  FROM public.internal_supplier_payment_readiness_v1(v_order_id) r
  LIMIT 1;

  IF v_readiness_ready IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'source_funding_required_for_supplier_payment_bank_resolution: order %, blocker %',
      v_order_id, COALESCE(v_readiness_blocker, 'readiness_row_missing');
  END IF;

  SELECT si.id, si.review_status
    INTO v_bad
  FROM pg_temp.supplier_payment_bundle_input i
  LEFT JOIN public.supplier_invoices si ON si.id = i.supplier_invoice_id
  WHERE si.id IS NULL
     OR si.order_id IS DISTINCT FROM v_order_id
     OR COALESCE(si.review_status, '') NOT IN ('approved_current', 'ref_corrected_approved')
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'Every bundled invoice must exist on the selected order and be approved. Invoice %, status %',
      v_bad.id, v_bad.review_status;
  END IF;

  SELECT
    i.supplier_invoice_id,
    i.allocated_gbp_amount,
    totals.invoice_total_gbp,
    totals.confirmed_gbp
  INTO v_bad
  FROM pg_temp.supplier_payment_bundle_input i
  JOIN LATERAL (
    SELECT
      ROUND(COALESCE(si.ocr_invoice_total_gbp, si.reconciliation_gbp_total, fs.invoice_total_gbp,
        (SELECT SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)) FROM public.supplier_invoice_lines sil WHERE sil.supplier_invoice_id = si.id), 0)::numeric, 2) AS invoice_total_gbp,
      ROUND(COALESCE((SELECT SUM(a.allocated_gbp_amount) FROM public.dva_statement_line_allocations a WHERE a.supplier_invoice_id = si.id AND a.allocation_type = 'supplier_invoice' AND a.allocation_status = 'confirmed'), 0)::numeric, 2) AS confirmed_gbp
    FROM public.supplier_invoices si
    LEFT JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id
    WHERE si.id = i.supplier_invoice_id
    ORDER BY fs.created_at DESC NULLS LAST
    LIMIT 1
  ) totals ON true
  WHERE totals.invoice_total_gbp <= 0
     OR totals.confirmed_gbp + i.allocated_gbp_amount > totals.invoice_total_gbp + 0.01
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'Bundle would over-allocate invoice %. Total %, already confirmed %, proposed %',
      v_bad.supplier_invoice_id, v_bad.invoice_total_gbp, v_bad.confirmed_gbp, v_bad.allocated_gbp_amount;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
    WHERE si.order_id = v_order_id
      AND a.allocation_type = 'supplier_invoice'
      AND a.allocation_status = 'confirmed'
      AND (
        NULLIF(TRIM(a.source_bank_account_mapping_code), '') IS NULL
        OR a.source_bank_account_mapping_code NOT IN (
          'DVA_CASH_BANK_ACCOUNT',
          'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT',
          'LOYALTY_DVA_GHS_BANK_ACCOUNT'
        )
      )
  ) THEN
    RAISE EXCEPTION 'source_funding_required_for_supplier_payment_bank_resolution: existing order allocation source unresolved';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.order_funding_events ofe
    WHERE ofe.order_id = v_order_id
      AND ofe.event_type = 'credit_applied'
      AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
  ) INTO v_has_applied_credit_provenance;

  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      resolver.resolved_wallet_code::text AS source_wallet_code
    FROM public.order_funding_events ofe
    JOIN public.importer_credit_ledger debit ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN debit.source_table = 'importer_credit_ledger' THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger' THEN debit.source_entity_id
        ELSE NULL::uuid
      END
     AND lm.importer_id = v_importer_id
     AND lm.match_status = 'released_available_dashboard_credit'
     AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
     AND lm.destination_in_statement_line_id IS NOT NULL
    JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(lm.destination_in_statement_line_id) resolver
      ON resolver.blocker IS NULL
    WHERE ofe.order_id = v_order_id
      AND ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
    ORDER BY ofe.id, lm.id
  ), loyalty_by_wallet AS (
    SELECT source_wallet_code, ROUND(SUM(amount_gbp)::numeric, 2) AS applied_gbp
    FROM loyalty_applied GROUP BY source_wallet_code
  ), existing_source_allocations AS (
    SELECT
      NULLIF(TRIM(a.source_bank_account_mapping_code), '') AS mapping_code,
      NULLIF(TRIM(a.source_wallet_code), '') AS wallet_code,
      ROUND(SUM(COALESCE(a.allocated_gbp_amount, 0))::numeric, 2) AS allocated_gbp
    FROM public.dva_statement_line_allocations a
    JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
    WHERE si.order_id = v_order_id
      AND a.allocation_type = 'supplier_invoice'
      AND a.allocation_status = 'confirmed'
    GROUP BY 1, 2
  ), loyalty_remaining AS (
    SELECT
      lbw.source_wallet_code,
      CASE lbw.source_wallet_code
        WHEN 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
        WHEN 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
      END AS mapping_code,
      ROUND(GREATEST(lbw.applied_gbp - COALESCE(esa.allocated_gbp, 0), 0)::numeric, 2) AS remaining_gbp
    FROM loyalty_by_wallet lbw
    LEFT JOIN existing_source_allocations esa ON esa.wallet_code = lbw.source_wallet_code
  ), cash_funding AS (
    SELECT ROUND(COALESCE(SUM(ABS(ofe.amount_gbp)), 0)::numeric, 2) AS funded_gbp
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = v_order_id AND ofe.event_type = 'funding_contribution'
  ), cash_allocated AS (
    SELECT ROUND(COALESCE(SUM(allocated_gbp), 0)::numeric, 2) AS allocated_gbp
    FROM existing_source_allocations WHERE mapping_code = 'DVA_CASH_BANK_ACCOUNT'
  )
  SELECT
    COUNT(*) FILTER (WHERE ABS(lr.remaining_gbp - v_statement_amount) < 0.01 AND lr.mapping_code IS NOT NULL)::integer,
    ROUND(COALESCE(SUM(lr.remaining_gbp), 0)::numeric, 2),
    ROUND(GREATEST((SELECT funded_gbp FROM cash_funding) - (SELECT allocated_gbp FROM cash_allocated), 0)::numeric, 2),
    MAX(lr.source_wallet_code) FILTER (WHERE ABS(lr.remaining_gbp - v_statement_amount) < 0.01 AND lr.mapping_code IS NOT NULL),
    MAX(lr.mapping_code) FILTER (WHERE ABS(lr.remaining_gbp - v_statement_amount) < 0.01 AND lr.mapping_code IS NOT NULL)
  INTO v_loyalty_exact_count, v_loyalty_total_remaining_gbp, v_cash_funding_remaining_gbp, v_exact_wallet_code, v_exact_mapping_code
  FROM loyalty_remaining lr;

  IF v_loyalty_exact_count > 1
     OR (v_loyalty_exact_count = 1 AND v_cash_funding_remaining_gbp + 0.01 >= v_statement_amount) THEN
    RAISE EXCEPTION 'source_funding_ambiguous_for_supplier_payment_bank_resolution: order %, OUT %', v_order_id, v_statement_amount;
  ELSIF v_loyalty_exact_count = 1 THEN
    v_source_wallet_code := v_exact_wallet_code;
    v_source_bank_account_mapping_code := v_exact_mapping_code;
    v_source_resolution_reason := 'exact_remaining_released_loyalty_source';
  ELSIF v_cash_funding_remaining_gbp + 0.01 >= v_statement_amount THEN
    v_source_wallet_code := NULL;
    v_source_bank_account_mapping_code := 'DVA_CASH_BANK_ACCOUNT';
    v_source_resolution_reason := 'proven_remaining_order_cash_funding';
  ELSIF v_funding_required_yn IS DISTINCT FROM true
        AND v_has_applied_credit_provenance IS DISTINCT FROM true THEN
    v_source_wallet_code := NULL;
    v_source_bank_account_mapping_code := 'DVA_CASH_BANK_ACCOUNT';
    v_source_resolution_reason := 'funding_not_required_physical_out_without_applied_credit_provenance';
  ELSE
    RAISE EXCEPTION 'source_funding_required_for_supplier_payment_bank_resolution: order %, OUT %, loyalty remaining %, cash remaining %',
      v_order_id, v_statement_amount, v_loyalty_total_remaining_gbp, v_cash_funding_remaining_gbp;
  END IF;

  WITH inserted AS (
    INSERT INTO public.dva_statement_line_allocations (
      dva_statement_line_id,
      allocation_type,
      supplier_invoice_id,
      dispute_id,
      order_id,
      allocated_gbp_amount,
      allocation_status,
      fx_rate_applied,
      card_markup_pct_applied,
      source_bank_account_mapping_code,
      source_wallet_code,
      notes,
      created_by_staff_id,
      created_at,
      confirmed_by_staff_id,
      confirmed_at
    )
    SELECT
      p_dva_statement_line_id,
      'supplier_invoice',
      i.supplier_invoice_id,
      NULL,
      v_order_id,
      i.allocated_gbp_amount,
      'confirmed',
      v_line.fx_rate_applied,
      v_line.card_markup_pct_applied,
      v_source_bank_account_mapping_code,
      v_source_wallet_code,
      CONCAT_WS(' | ', NULLIF(TRIM(p_notes), ''), 'atomic multi-invoice supplier-payment bundle'),
      v_staff.id,
      now(),
      v_staff.id,
      now()
    FROM pg_temp.supplier_payment_bundle_input i
    ORDER BY i.supplier_invoice_id
    RETURNING id
  )
  SELECT COUNT(*)::integer, ARRAY_AGG(id ORDER BY id)
    INTO v_inserted_count, v_inserted_ids
  FROM inserted;

  IF v_inserted_count <> v_allocation_count THEN
    RAISE EXCEPTION 'Supplier-payment bundle insert count mismatch. Expected %, inserted %', v_allocation_count, v_inserted_count;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', v_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_importer_id,
    'retailer_id', v_retailer_id,
    'statement_gbp_amount', v_statement_amount,
    'allocated_gbp_amount', v_requested_total,
    'allocation_count', v_inserted_count,
    'allocation_ids', to_jsonb(v_inserted_ids),
    'source_bank_account_mapping_code', v_source_bank_account_mapping_code,
    'source_wallet_code', v_source_wallet_code,
    'source_resolution_reason', v_source_resolution_reason,
    'balanced_yn', true
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) IS
'Atomic Mini-build 2 supplier-payment bundle. One physical OUT is allocated once across several approved supplier invoices from one order; bundle amounts must equal the full OUT; all rows share one proven source mapping; any validation failure rolls back the whole bundle.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) TO authenticated;

-- Corrected-reference approvals are equally approved for supplier-payment use.
CREATE OR REPLACE VIEW public.supplier_payment_candidate_status_vw AS
SELECT
  si.id AS supplier_invoice_id,
  si.order_id,
  o.order_ref,
  o.importer_id,
  o.retailer_id,
  COALESCE(o.order_type, 'original')::text AS order_type,
  COALESCE(si.ocr_invoice_ref, si.invoice_ref)::text AS invoice_ref,
  si.review_status::text AS review_status,
  totals.invoice_total_gbp,
  allocations.confirmed_matched_gbp,
  ROUND(GREATEST(totals.invoice_total_gbp - allocations.confirmed_matched_gbp, 0)::numeric, 2) AS remaining_unmatched_gbp,
  readiness.funding_required_yn,
  readiness.threshold_met_yn,
  readiness.funding_provenance_ready_yn,
  readiness.supplier_payment_ready_yn,
  CASE
    WHEN COALESCE(si.review_status, '') NOT IN ('approved_current', 'ref_corrected_approved') THEN 'supplier_invoice_not_approved_current'
    WHEN totals.invoice_total_gbp <= 0 THEN 'supplier_invoice_total_missing_or_non_positive'
    WHEN ROUND(GREATEST(totals.invoice_total_gbp - allocations.confirmed_matched_gbp, 0)::numeric, 2) <= 0 THEN 'supplier_invoice_fully_matched'
    ELSE readiness.blocker
  END AS blocker,
  (
    COALESCE(si.review_status, '') IN ('approved_current', 'ref_corrected_approved')
    AND totals.invoice_total_gbp > 0
    AND ROUND(GREATEST(totals.invoice_total_gbp - allocations.confirmed_matched_gbp, 0)::numeric, 2) > 0
    AND readiness.supplier_payment_ready_yn
  ) AS selectable_yn
FROM public.supplier_invoices si
JOIN public.orders o ON o.id = si.order_id
JOIN LATERAL (
  SELECT ROUND(COALESCE(
    si.ocr_invoice_total_gbp,
    si.reconciliation_gbp_total,
    fs.invoice_total_gbp,
    SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)),
    0
  )::numeric, 2) AS invoice_total_gbp
  FROM public.supplier_invoice_lines sil
  LEFT JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id
  WHERE sil.supplier_invoice_id = si.id
  GROUP BY fs.invoice_total_gbp, fs.created_at
  ORDER BY fs.created_at DESC NULLS LAST
  LIMIT 1
) totals ON true
JOIN LATERAL (
  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) AS confirmed_matched_gbp
  FROM public.dva_statement_line_allocations a
  WHERE a.supplier_invoice_id = si.id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed'
) allocations ON true
JOIN LATERAL public.internal_supplier_payment_readiness_v1(si.order_id) readiness ON true
WHERE public.is_active_staff();

REVOKE ALL ON public.supplier_payment_candidate_status_vw FROM PUBLIC;
GRANT SELECT ON public.supplier_payment_candidate_status_vw TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
