BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Multi-supplier-invoice order control — Mini-build 2.
-- One physical OUT stays one bank event. Its child supplier-invoice allocations
-- are validated and inserted together, and all inherit one source resolution.

DO $$
BEGIN
  IF to_regclass('public.dva_statement_lines') IS NULL
     OR to_regclass('public.dva_statements') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_financial_summary') IS NULL
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

CREATE OR REPLACE FUNCTION public.internal_supplier_payment_bundle_source_v1(
  p_order_id uuid,
  p_physical_out_gbp numeric
)
RETURNS TABLE (
  source_bank_account_mapping_code text,
  source_wallet_code text,
  source_resolution_reason text,
  remaining_order_cash_funding_gbp numeric,
  remaining_released_loyalty_funding_gbp numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order record;
  v_amount numeric(12,2) := ROUND(COALESCE(p_physical_out_gbp, 0)::numeric, 2);
  v_funding_required boolean;
  v_ready boolean;
  v_blocker text;
  v_has_credit boolean := false;
  v_exact_count integer := 0;
  v_loyalty_remaining numeric(12,2) := 0;
  v_cash_remaining numeric(12,2) := 0;
  v_wallet text;
  v_mapping text;
BEGIN
  SELECT o.id, o.importer_id, COALESCE(o.order_type, 'original') AS order_type
    INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_order.id IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'A valid order and positive physical OUT amount are required.';
  END IF;

  SELECT r.supplier_payment_ready_yn, r.blocker, r.funding_required_yn
    INTO v_ready, v_blocker, v_funding_required
  FROM public.internal_supplier_payment_readiness_v1(p_order_id) r
  LIMIT 1;

  IF v_ready IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'source_funding_required_for_supplier_payment_bank_resolution: order %, blocker %',
      p_order_id, COALESCE(v_blocker, 'readiness_row_missing');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'credit_applied'
      AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
  ) INTO v_has_credit;

  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      resolver.resolved_wallet_code::text AS wallet_code
    FROM public.order_funding_events ofe
    JOIN public.importer_credit_ledger debit
      ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN debit.source_table = 'importer_credit_ledger' THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger' THEN debit.source_entity_id
        ELSE NULL::uuid
      END
     AND lm.importer_id = v_order.importer_id
     AND lm.match_status = 'released_available_dashboard_credit'
     AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
     AND lm.destination_in_statement_line_id IS NOT NULL
    JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(
      lm.destination_in_statement_line_id
    ) resolver ON resolver.blocker IS NULL
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
    ORDER BY ofe.id, lm.id
  ), loyalty_by_wallet AS (
    SELECT wallet_code, ROUND(SUM(amount_gbp)::numeric, 2) AS applied_gbp
    FROM loyalty_applied
    GROUP BY wallet_code
  ), existing_source_allocations AS (
    SELECT
      NULLIF(TRIM(a.source_bank_account_mapping_code), '') AS mapping_code,
      NULLIF(TRIM(a.source_wallet_code), '') AS wallet_code,
      ROUND(SUM(COALESCE(a.allocated_gbp_amount, 0))::numeric, 2) AS allocated_gbp
    FROM public.dva_statement_line_allocations a
    JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
    WHERE si.order_id = p_order_id
      AND a.allocation_type = 'supplier_invoice'
      AND a.allocation_status = 'confirmed'
    GROUP BY 1, 2
  ), loyalty_remaining AS (
    SELECT
      lbw.wallet_code,
      CASE lbw.wallet_code
        WHEN 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
        WHEN 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
        ELSE NULL::text
      END AS mapping_code,
      ROUND(GREATEST(lbw.applied_gbp - COALESCE(esa.allocated_gbp, 0), 0)::numeric, 2) AS remaining_gbp
    FROM loyalty_by_wallet lbw
    LEFT JOIN existing_source_allocations esa ON esa.wallet_code = lbw.wallet_code
  ), cash_funding AS (
    SELECT ROUND(COALESCE(SUM(ABS(ofe.amount_gbp)), 0)::numeric, 2) AS funded_gbp
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'funding_contribution'
  ), cash_allocated AS (
    SELECT ROUND(COALESCE(SUM(allocated_gbp), 0)::numeric, 2) AS allocated_gbp
    FROM existing_source_allocations
    WHERE mapping_code = 'DVA_CASH_BANK_ACCOUNT'
  )
  SELECT
    COUNT(*) FILTER (
      WHERE ABS(lr.remaining_gbp - v_amount) < 0.01
        AND lr.mapping_code IS NOT NULL
    )::integer,
    ROUND(COALESCE(SUM(lr.remaining_gbp), 0)::numeric, 2),
    ROUND(GREATEST(
      (SELECT funded_gbp FROM cash_funding) - (SELECT allocated_gbp FROM cash_allocated),
      0
    )::numeric, 2),
    MAX(lr.wallet_code) FILTER (
      WHERE ABS(lr.remaining_gbp - v_amount) < 0.01
        AND lr.mapping_code IS NOT NULL
    ),
    MAX(lr.mapping_code) FILTER (
      WHERE ABS(lr.remaining_gbp - v_amount) < 0.01
        AND lr.mapping_code IS NOT NULL
    )
  INTO v_exact_count, v_loyalty_remaining, v_cash_remaining, v_wallet, v_mapping
  FROM loyalty_remaining lr;

  IF v_exact_count > 1
     OR (v_exact_count = 1 AND v_cash_remaining + 0.01 >= v_amount) THEN
    RAISE EXCEPTION 'source_funding_ambiguous_for_supplier_payment_bank_resolution: order %, OUT %',
      p_order_id, v_amount;
  ELSIF v_exact_count = 1 THEN
    RETURN QUERY SELECT
      v_mapping,
      v_wallet,
      'exact_remaining_released_loyalty_source'::text,
      v_cash_remaining,
      v_loyalty_remaining;
  ELSIF v_cash_remaining + 0.01 >= v_amount THEN
    RETURN QUERY SELECT
      'DVA_CASH_BANK_ACCOUNT'::text,
      NULL::text,
      'proven_remaining_order_cash_funding'::text,
      v_cash_remaining,
      v_loyalty_remaining;
  ELSIF v_funding_required IS DISTINCT FROM true AND v_has_credit IS DISTINCT FROM true THEN
    RETURN QUERY SELECT
      'DVA_CASH_BANK_ACCOUNT'::text,
      NULL::text,
      'funding_not_required_physical_out_without_applied_credit_provenance'::text,
      v_cash_remaining,
      v_loyalty_remaining;
  ELSE
    RAISE EXCEPTION 'source_funding_required_for_supplier_payment_bank_resolution: order %, OUT %, loyalty remaining %, cash remaining %',
      p_order_id, v_amount, v_loyalty_remaining, v_cash_remaining;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_supplier_payment_bundle_source_v1(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supplier_payment_bundle_source_v1(uuid, numeric) TO authenticated;

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
  v_staff record;
  v_line record;
  v_order record;
  v_source record;
  v_order_id uuid;
  v_input_count integer;
  v_distinct_invoice_count integer;
  v_distinct_order_count integer;
  v_distinct_importer_count integer;
  v_distinct_retailer_count integer;
  v_requested_total numeric(12,2);
  v_statement_total numeric(12,2);
  v_inserted_count integer;
  v_inserted_ids uuid[];
  v_bad record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff allocation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff.id IS NULL OR COALESCE(v_staff.role_type, '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can allocate a supplier-payment bundle.';
  END IF;

  IF p_allocations IS NULL
     OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'p_allocations must be a non-empty JSON array';
  END IF;

  CREATE TEMP TABLE pg_temp.supplier_payment_bundle_input (
    supplier_invoice_id uuid PRIMARY KEY,
    allocated_gbp_amount numeric(12,2) NOT NULL
  ) ON COMMIT DROP;

  BEGIN
    INSERT INTO pg_temp.supplier_payment_bundle_input (
      supplier_invoice_id,
      allocated_gbp_amount
    )
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

  SELECT
    COUNT(*)::integer,
    COUNT(DISTINCT supplier_invoice_id)::integer,
    ROUND(SUM(allocated_gbp_amount)::numeric, 2)
  INTO v_input_count, v_distinct_invoice_count, v_requested_total
  FROM pg_temp.supplier_payment_bundle_input;

  IF v_input_count = 0 OR v_input_count <> v_distinct_invoice_count THEN
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
    dsl.fx_rate_applied,
    dsl.card_markup_pct_applied,
    ds.importer_id
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL OR v_line.direction IS DISTINCT FROM 'out' THEN
    RAISE EXCEPTION 'A valid OUT statement line is required.';
  END IF;

  v_statement_total := ROUND(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2);
  IF v_statement_total <= 0 OR ABS(v_requested_total - v_statement_total) > 0.01 THEN
    RAISE EXCEPTION 'One physical supplier-payment OUT must be allocated once for its full amount. Statement GBP %, bundle GBP %',
      v_statement_total, v_requested_total;
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
    COUNT(DISTINCT si.order_id)::integer,
    COUNT(DISTINCT o.importer_id)::integer,
    COUNT(DISTINCT o.retailer_id)::integer
  INTO
    v_order_id,
    v_distinct_order_count,
    v_distinct_importer_count,
    v_distinct_retailer_count
  FROM pg_temp.supplier_payment_bundle_input i
  JOIN public.supplier_invoices si ON si.id = i.supplier_invoice_id
  JOIN public.orders o ON o.id = si.order_id;

  IF v_order_id IS NULL
     OR v_distinct_order_count <> 1
     OR v_distinct_importer_count <> 1
     OR v_distinct_retailer_count <> 1 THEN
    RAISE EXCEPTION 'All supplier invoices in one physical OUT bundle must belong to the same order, importer and retailer.';
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, o.retailer_id, o.status
    INTO v_order
  FROM public.orders o
  WHERE o.id = v_order_id
  FOR UPDATE;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Statement importer does not match the bundled supplier-invoice order.';
  END IF;
  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot allocate supplier payment to an archived or cancelled order.';
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
      ROUND(COALESCE(
        si.ocr_invoice_total_gbp,
        si.reconciliation_gbp_total,
        (
          SELECT fs.invoice_total_gbp
          FROM public.supplier_invoice_financial_summary fs
          WHERE fs.supplier_invoice_id = si.id
          ORDER BY fs.created_at DESC
          LIMIT 1
        ),
        (
          SELECT SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0))
          FROM public.supplier_invoice_lines sil
          WHERE sil.supplier_invoice_id = si.id
        ),
        0
      )::numeric, 2) AS invoice_total_gbp,
      ROUND(COALESCE((
        SELECT SUM(a.allocated_gbp_amount)
        FROM public.dva_statement_line_allocations a
        WHERE a.supplier_invoice_id = si.id
          AND a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
      ), 0)::numeric, 2) AS confirmed_gbp
    FROM public.supplier_invoices si
    WHERE si.id = i.supplier_invoice_id
  ) totals ON true
  WHERE totals.invoice_total_gbp <= 0
     OR totals.confirmed_gbp + i.allocated_gbp_amount > totals.invoice_total_gbp + 0.01
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'Bundle would over-allocate invoice %. Total %, already confirmed %, proposed %',
      v_bad.supplier_invoice_id,
      v_bad.invoice_total_gbp,
      v_bad.confirmed_gbp,
      v_bad.allocated_gbp_amount;
  END IF;

  SELECT * INTO v_source
  FROM public.internal_supplier_payment_bundle_source_v1(v_order_id, v_statement_total)
  LIMIT 1;

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
      v_source.source_bank_account_mapping_code,
      v_source.source_wallet_code,
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

  IF v_inserted_count <> v_input_count THEN
    RAISE EXCEPTION 'Supplier-payment bundle insert count mismatch. Expected %, inserted %',
      v_input_count, v_inserted_count;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', v_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'retailer_id', v_order.retailer_id,
    'statement_gbp_amount', v_statement_total,
    'allocated_gbp_amount', v_requested_total,
    'allocation_count', v_inserted_count,
    'allocation_ids', to_jsonb(v_inserted_ids),
    'source_bank_account_mapping_code', v_source.source_bank_account_mapping_code,
    'source_wallet_code', v_source.source_wallet_code,
    'source_resolution_reason', v_source.source_resolution_reason,
    'balanced_yn', true
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) IS
'Atomic multi-invoice supplier-payment bundle. One physical OUT is allocated once across several approved supplier invoices from one order; bundle amounts must equal the full OUT; all rows share one proven source mapping; any failure rolls back every row.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) TO authenticated;

-- Corrected-reference approvals are approved documents for payment selection too.
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
    (
      SELECT fs.invoice_total_gbp
      FROM public.supplier_invoice_financial_summary fs
      WHERE fs.supplier_invoice_id = si.id
      ORDER BY fs.created_at DESC
      LIMIT 1
    ),
    (
      SELECT SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0))
      FROM public.supplier_invoice_lines sil
      WHERE sil.supplier_invoice_id = si.id
    ),
    0
  )::numeric, 2) AS invoice_total_gbp
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
