BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
  v_existing_supplier_total numeric(12,2) := 0;
  v_statement_remaining numeric(12,2) := 0;
  v_existing_order_count integer := 0;
  v_existing_importer_count integer := 0;
  v_existing_retailer_count integer := 0;
  v_existing_source_count integer := 0;
  v_existing_order_id uuid;
  v_existing_importer_id uuid;
  v_existing_retailer_id uuid;
  v_source_mapping text;
  v_source_wallet text;
  v_source_reason text;
  v_inserted_count integer;
  v_inserted_ids uuid[];
  v_bad record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff allocation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid() AND s.active = true
  LIMIT 1;

  IF v_staff.id IS NULL OR COALESCE(v_staff.role_type, '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can allocate a supplier-payment bundle.';
  END IF;

  IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'p_allocations must be a non-empty JSON array';
  END IF;

  CREATE TEMP TABLE pg_temp.supplier_payment_bundle_input (
    supplier_invoice_id uuid PRIMARY KEY,
    allocated_gbp_amount numeric(12,2) NOT NULL
  ) ON COMMIT DROP;

  BEGIN
    INSERT INTO pg_temp.supplier_payment_bundle_input(supplier_invoice_id, allocated_gbp_amount)
    SELECT x.supplier_invoice_id, ROUND(x.allocated_gbp_amount::numeric, 2)
    FROM jsonb_to_recordset(p_allocations) AS x(supplier_invoice_id uuid, allocated_gbp_amount numeric);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Each supplier invoice may appear only once in the allocation bundle.';
  END;

  SELECT COUNT(*)::integer, COUNT(DISTINCT supplier_invoice_id)::integer,
         ROUND(SUM(allocated_gbp_amount)::numeric, 2)
  INTO v_input_count, v_distinct_invoice_count, v_requested_total
  FROM pg_temp.supplier_payment_bundle_input;

  IF v_input_count = 0 OR v_input_count <> v_distinct_invoice_count THEN
    RAISE EXCEPTION 'Supplier-payment bundle contains no usable or duplicate invoice entries.';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_temp.supplier_payment_bundle_input WHERE allocated_gbp_amount <= 0) THEN
    RAISE EXCEPTION 'Every supplier invoice allocation amount must be greater than zero.';
  END IF;

  SELECT dsl.id, dsl.direction, dsl.amount_gbp_equivalent,
         dsl.fx_rate_applied, dsl.card_markup_pct_applied, ds.importer_id
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL OR v_line.direction IS DISTINCT FROM 'out' THEN
    RAISE EXCEPTION 'A valid OUT statement line is required.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.allocation_status IN ('draft', 'held')
  ) THEN
    RAISE EXCEPTION 'Resolve draft/held allocations before adding a supplier bundle.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.allocation_status <> 'reversed'
      AND a.allocation_type <> 'supplier_invoice'
  ) THEN
    RAISE EXCEPTION 'Statement OUT has an incompatible active non-supplier allocation.';
  END IF;

  v_statement_total := ROUND(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2);

  SELECT
    ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2),
    COUNT(DISTINCT si.order_id)::integer,
    COUNT(DISTINCT o.importer_id)::integer,
    COUNT(DISTINCT o.retailer_id)::integer,
    COUNT(DISTINCT concat_ws('|', NULLIF(btrim(a.source_bank_account_mapping_code), ''), NULLIF(btrim(a.source_wallet_code), '')))::integer,
    (array_agg(DISTINCT si.order_id) FILTER (WHERE si.order_id IS NOT NULL))[1],
    (array_agg(DISTINCT o.importer_id) FILTER (WHERE o.importer_id IS NOT NULL))[1],
    (array_agg(DISTINCT o.retailer_id) FILTER (WHERE o.retailer_id IS NOT NULL))[1],
    (array_agg(DISTINCT NULLIF(btrim(a.source_bank_account_mapping_code), '')) FILTER (WHERE NULLIF(btrim(a.source_bank_account_mapping_code), '') IS NOT NULL))[1],
    (array_agg(DISTINCT NULLIF(btrim(a.source_wallet_code), '')) FILTER (WHERE NULLIF(btrim(a.source_wallet_code), '') IS NOT NULL))[1]
  INTO v_existing_supplier_total, v_existing_order_count, v_existing_importer_count,
       v_existing_retailer_count, v_existing_source_count, v_existing_order_id,
       v_existing_importer_id, v_existing_retailer_id, v_source_mapping, v_source_wallet
  FROM public.dva_statement_line_allocations a
  JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
  JOIN public.orders o ON o.id = si.order_id
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  v_statement_remaining := ROUND(GREATEST(v_statement_total - v_existing_supplier_total, 0)::numeric, 2);
  IF v_statement_total <= 0 OR v_statement_remaining <= 0.01 THEN
    RAISE EXCEPTION 'Physical statement OUT has no remaining supplier-allocation balance.';
  END IF;
  IF v_requested_total > v_statement_remaining + 0.005 THEN
    RAISE EXCEPTION 'Supplier-payment bundle would exceed the remaining physical OUT. Remaining GBP %, bundle GBP %',
      v_statement_remaining, v_requested_total;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.supplier_payment_bundle_input i
    JOIN public.dva_statement_line_allocations a
      ON a.supplier_invoice_id = i.supplier_invoice_id
     AND a.dva_statement_line_id = p_dva_statement_line_id
     AND a.allocation_type = 'supplier_invoice'
     AND a.allocation_status <> 'reversed'
  ) THEN
    RAISE EXCEPTION 'One or more selected supplier invoices are already allocated on this statement OUT.';
  END IF;

  SELECT (ARRAY_AGG(si.order_id ORDER BY si.order_id))[1],
         COUNT(DISTINCT si.order_id)::integer,
         COUNT(DISTINCT o.importer_id)::integer,
         COUNT(DISTINCT o.retailer_id)::integer
  INTO v_order_id, v_distinct_order_count, v_distinct_importer_count, v_distinct_retailer_count
  FROM pg_temp.supplier_payment_bundle_input i
  JOIN public.supplier_invoices si ON si.id = i.supplier_invoice_id
  JOIN public.orders o ON o.id = si.order_id;

  IF v_order_id IS NULL OR v_distinct_order_count <> 1 OR v_distinct_importer_count <> 1 OR v_distinct_retailer_count <> 1 THEN
    RAISE EXCEPTION 'All supplier invoices in one bundle must belong to the same order, importer and retailer.';
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, o.retailer_id, o.status INTO v_order
  FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Statement importer does not match the bundled supplier-invoice order.';
  END IF;
  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot allocate supplier payment to an archived or cancelled order.';
  END IF;

  IF v_existing_order_count > 0 THEN
    IF v_existing_order_count <> 1 OR v_existing_importer_count <> 1 OR v_existing_retailer_count <> 1 THEN
      RAISE EXCEPTION 'Existing supplier allocations do not resolve to one order/importer/retailer.';
    END IF;
    IF v_existing_order_id IS DISTINCT FROM v_order.id
       OR v_existing_importer_id IS DISTINCT FROM v_order.importer_id
       OR v_existing_retailer_id IS DISTINCT FROM v_order.retailer_id THEN
      RAISE EXCEPTION 'Atomic additions must remain on the same order, importer and retailer as earlier supplier allocations.';
    END IF;
    IF v_existing_source_count <> 1 OR v_source_mapping IS NULL THEN
      RAISE EXCEPTION 'Existing supplier allocation source mapping is missing or inconsistent.';
    END IF;
    v_source_reason := 'inherited_from_existing_statement_line_supplier_allocations';
  ELSE
    SELECT * INTO v_source
    FROM public.internal_supplier_payment_bundle_source_v1(v_order.id, v_requested_total)
    LIMIT 1;
    v_source_mapping := v_source.source_bank_account_mapping_code;
    v_source_wallet := v_source.source_wallet_code;
    v_source_reason := v_source.source_resolution_reason;
    IF NULLIF(btrim(COALESCE(v_source_mapping, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Supplier-payment source mapping could not be resolved for order % and bundle amount %.', v_order.id, v_requested_total;
    END IF;
  END IF;

  SELECT si.id, si.review_status INTO v_bad
  FROM pg_temp.supplier_payment_bundle_input i
  LEFT JOIN public.supplier_invoices si ON si.id = i.supplier_invoice_id
  WHERE si.id IS NULL OR si.order_id IS DISTINCT FROM v_order_id
     OR COALESCE(si.review_status, '') NOT IN ('approved_current', 'ref_corrected_approved')
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Every bundled invoice must exist on the selected order and be approved. Invoice %, status %', v_bad.id, v_bad.review_status;
  END IF;

  SELECT i.supplier_invoice_id, i.allocated_gbp_amount,
         totals.invoice_total_gbp, totals.confirmed_gbp INTO v_bad
  FROM pg_temp.supplier_payment_bundle_input i
  JOIN LATERAL (
    SELECT ROUND(COALESCE(si.ocr_invoice_total_gbp, si.reconciliation_gbp_total,
      (SELECT fs.invoice_total_gbp FROM public.supplier_invoice_financial_summary fs
       WHERE fs.supplier_invoice_id = si.id ORDER BY fs.created_at DESC LIMIT 1),
      (SELECT SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0))
       FROM public.supplier_invoice_lines sil WHERE sil.supplier_invoice_id = si.id), 0)::numeric, 2) AS invoice_total_gbp,
      ROUND(COALESCE((SELECT SUM(a.allocated_gbp_amount)
        FROM public.dva_statement_line_allocations a
        WHERE a.supplier_invoice_id = si.id
          AND a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'), 0)::numeric, 2) AS confirmed_gbp
    FROM public.supplier_invoices si WHERE si.id = i.supplier_invoice_id
  ) totals ON true
  WHERE totals.invoice_total_gbp <= 0
     OR totals.confirmed_gbp + i.allocated_gbp_amount > totals.invoice_total_gbp + 0.01
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Bundle would over-allocate invoice %. Total %, already confirmed %, proposed %',
      v_bad.supplier_invoice_id, v_bad.invoice_total_gbp, v_bad.confirmed_gbp, v_bad.allocated_gbp_amount;
  END IF;

  WITH inserted AS (
    INSERT INTO public.dva_statement_line_allocations(
      dva_statement_line_id, allocation_type, supplier_invoice_id, dispute_id, order_id,
      allocated_gbp_amount, allocation_status, fx_rate_applied, card_markup_pct_applied,
      source_bank_account_mapping_code, source_wallet_code, notes,
      created_by_staff_id, created_at, confirmed_by_staff_id, confirmed_at
    )
    SELECT p_dva_statement_line_id, 'supplier_invoice', i.supplier_invoice_id, NULL, v_order_id,
      i.allocated_gbp_amount, 'confirmed', v_line.fx_rate_applied, v_line.card_markup_pct_applied,
      v_source_mapping, v_source_wallet,
      CONCAT_WS(' | ', NULLIF(TRIM(p_notes), ''), 'atomic supplier addition: ' || v_source_reason),
      v_staff.id, now(), v_staff.id, now()
    FROM pg_temp.supplier_payment_bundle_input i
    ORDER BY i.supplier_invoice_id
    RETURNING id
  )
  SELECT COUNT(*)::integer, ARRAY_AGG(id ORDER BY id)
  INTO v_inserted_count, v_inserted_ids FROM inserted;

  IF v_inserted_count <> v_input_count THEN
    RAISE EXCEPTION 'Supplier-payment bundle insert count mismatch. Expected %, inserted %', v_input_count, v_inserted_count;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', v_order_id,
    'order_ref', v_order.order_ref,
    'statement_gbp_amount', v_statement_total,
    'statement_remaining_before_gbp', v_statement_remaining,
    'previous_supplier_allocated_gbp', v_existing_supplier_total,
    'allocated_gbp_amount', v_requested_total,
    'statement_remaining_after_gbp', ROUND(v_statement_remaining - v_requested_total, 2),
    'allocation_count', v_inserted_count,
    'allocation_ids', to_jsonb(v_inserted_ids),
    'source_bank_account_mapping_code', v_source_mapping,
    'source_wallet_code', v_source_wallet,
    'source_resolution_reason', v_source_reason,
    'balanced_yn', ABS(v_statement_remaining - v_requested_total) < 0.01
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) IS
'Mixed sequential/atomic supplier allocator. Adds one atomic batch to the remaining balance of a physical OUT, including after earlier confirmed supplier allocations, while preserving one order/importer/retailer/source identity and preventing duplicates or over-allocation.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
