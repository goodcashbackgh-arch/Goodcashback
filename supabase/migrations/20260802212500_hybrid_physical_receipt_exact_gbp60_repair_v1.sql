-- Governed by HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md.
-- Exact one-record repair only. No broad historical backfill.
BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $repair$
DECLARE
  v_order_id constant uuid := '8c882f9d-aadc-4a6a-b50c-d013d1abffd7';
  v_review_id constant uuid := '1987393f-47ba-4460-96f6-598e0e52792d';
  v_remedy_id constant uuid := '9e7f6c25-e920-4c90-a16a-0ffb6381a3d6';
  v_tracking_allocation_id constant uuid := '5dbd95c5-c0d0-489d-973d-fab4c9083160';
  v_supplier_line_id constant uuid := '0985538e-e9bb-42f2-8e3c-8cf11063705e';
  v_dispute_line_id constant uuid := '126ed01a-09b4-47e4-a2db-c52e7480d814';
  v_dispute_id constant uuid := 'd7b32314-603e-49bf-83d1-1a01e2e4d29f';
  v_expected_value constant numeric(12,2) := 60.00;

  v_state_count integer;
  v_already_repaired boolean;
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.disputes') IS NULL
  THEN
    RAISE EXCEPTION 'Exact GBP 60 repair prerequisites are missing.';
  END IF;

  PERFORM 1 FROM public.orders WHERE id = v_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected order % is missing.', v_order_id; END IF;

  PERFORM 1 FROM public.physical_receipt_reviews WHERE id = v_review_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected physical review % is missing.', v_review_id; END IF;

  PERFORM 1 FROM public.physical_exception_remedy_allocations WHERE id = v_remedy_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected physical remedy % is missing.', v_remedy_id; END IF;

  PERFORM 1 FROM public.disputes WHERE id = v_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected dispute % is missing.', v_dispute_id; END IF;

  PERFORM 1 FROM public.dispute_lines WHERE id = v_dispute_line_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected dispute line % is missing.', v_dispute_line_id; END IF;

  SELECT COUNT(*)::integer
  INTO v_state_count
  FROM public.order_tracking_line_allocations tracking_row
  JOIN public.physical_exception_remedy_allocations remedy_row
    ON remedy_row.id = v_remedy_id
  JOIN public.physical_receipt_reviews review_row
    ON review_row.id = remedy_row.physical_receipt_review_id
  JOIN public.dispute_lines line_row
    ON line_row.id = remedy_row.dispute_line_id
  JOIN public.disputes dispute_row
    ON dispute_row.id = line_row.dispute_id
  WHERE tracking_row.id = v_tracking_allocation_id
    AND tracking_row.order_id = v_order_id
    AND tracking_row.supplier_invoice_line_id = v_supplier_line_id
    AND tracking_row.qty_allocated = 1
    AND ROUND(tracking_row.adjusted_net_value_gbp, 2) = v_expected_value
    AND review_row.id = v_review_id
    AND review_row.order_id = v_order_id
    AND review_row.status = 'approved_to_existing_exception'
    AND remedy_row.physical_receipt_review_id = v_review_id
    AND remedy_row.tracking_line_allocation_id = v_tracking_allocation_id
    AND remedy_row.supplier_invoice_line_id = v_supplier_line_id
    AND remedy_row.approved_remedy_type = 'replacement'
    AND remedy_row.approved_remedy_qty = 1
    AND remedy_row.dispute_line_id = v_dispute_line_id
    AND line_row.id = v_dispute_line_id
    AND line_row.dispute_id = v_dispute_id
    AND line_row.supplier_invoice_line_id = v_supplier_line_id
    AND line_row.physical_remedy_allocation_id = v_remedy_id
    AND line_row.intended_remedy = 'replacement'
    AND line_row.qty_impact = 1
    AND dispute_row.id = v_dispute_id
    AND dispute_row.order_id = v_order_id
    AND dispute_row.desired_outcome = 'replacement'
    AND dispute_row.replacement_child_order_id IS NULL
    AND dispute_row.resolved_at IS NULL;

  IF v_state_count <> 1 THEN
    RAISE EXCEPTION 'Exact GBP 60 provenance precondition failed; expected one complete matching chain, found %.', v_state_count;
  END IF;

  SELECT
    remedy_row.customer_commercial_value_gbp = v_expected_value
    AND line_row.amount_impact_gbp = v_expected_value
    AND dispute_row.amount_impact_gbp = v_expected_value
  INTO v_already_repaired
  FROM public.physical_exception_remedy_allocations remedy_row
  JOIN public.dispute_lines line_row ON line_row.id = v_dispute_line_id
  JOIN public.disputes dispute_row ON dispute_row.id = v_dispute_id
  WHERE remedy_row.id = v_remedy_id;

  IF COALESCE(v_already_repaired, false) THEN
    RAISE NOTICE 'Exact GBP 60 physical replacement record is already repaired.';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN public.dispute_lines line_row ON line_row.id = v_dispute_line_id
    JOIN public.disputes dispute_row ON dispute_row.id = v_dispute_id
    WHERE remedy_row.id = v_remedy_id
      AND remedy_row.customer_commercial_value_gbp IS NULL
      AND line_row.amount_impact_gbp = 0
      AND dispute_row.amount_impact_gbp = 0
  ) THEN
    RAISE EXCEPTION 'Exact GBP 60 record is neither in the reviewed broken state nor the exact repaired state.';
  END IF;

  UPDATE public.physical_exception_remedy_allocations
  SET customer_commercial_value_gbp = v_expected_value,
      updated_at = clock_timestamp()
  WHERE id = v_remedy_id
    AND customer_commercial_value_gbp IS NULL;

  IF NOT FOUND THEN RAISE EXCEPTION 'Physical remedy value repair did not update exactly as expected.'; END IF;

  UPDATE public.dispute_lines
  SET amount_impact_gbp = v_expected_value
  WHERE id = v_dispute_line_id
    AND amount_impact_gbp = 0;

  IF NOT FOUND THEN RAISE EXCEPTION 'Dispute-line value repair did not update exactly as expected.'; END IF;

  UPDATE public.disputes
  SET amount_impact_gbp = v_expected_value
  WHERE id = v_dispute_id
    AND amount_impact_gbp = 0;

  IF NOT FOUND THEN RAISE EXCEPTION 'Dispute-header value repair did not update exactly as expected.'; END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN public.dispute_lines line_row ON line_row.id = v_dispute_line_id
    JOIN public.disputes dispute_row ON dispute_row.id = v_dispute_id
    WHERE remedy_row.id = v_remedy_id
      AND remedy_row.customer_commercial_value_gbp = v_expected_value
      AND line_row.amount_impact_gbp = v_expected_value
      AND dispute_row.amount_impact_gbp = v_expected_value
  ) THEN
    RAISE EXCEPTION 'Exact GBP 60 repair postcondition failed.';
  END IF;
END
$repair$;

COMMIT;
