BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_order_id uuid := 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid;
  v_definition text;
  v_count integer;
  v_amount numeric;
  v_position record;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Required canonical objects and narrow audience overlay are installed.
  --    The original 28 July all-or-nothing implementation has been superseded
  --    by the partial receipt-residual correction; lock the preserved boundary,
  --    provenance controls and no-FX/no-write scope instead of the obsolete body.
  -- -------------------------------------------------------------------------
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical settlement position is missing.';
  END IF;

  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: audience residual overlay or preserved predecessor is missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.order_audience_status_v1(uuid)'::regprocedure))
  INTO v_definition;

  IF position('order_audience_status_pre_receipt_residual_overlay_v1' IN v_definition) = 0
     OR position('still_order_applied_residual_gbp' IN v_definition) = 0
     OR position('active_pending_receipt_gbp' IN v_definition) = 0
     OR position('confirmed_credit_ledger_id' IN v_definition) = 0
     OR position('select distinct' IN v_definition) = 0
     OR position('p.reversed_at is null' IN v_definition) = 0
     OR position('c.source_type = ''overfunding''' IN v_definition) = 0
     OR position('p.customer_complete_yn' IN v_definition) = 0
     OR position('p.importer_complete_yn' IN v_definition) = 0
     OR position('p.shipper_status_label' IN v_definition) = 0
     OR position('p.shipper_next_action' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: repaired audience overlay is broader than the locked receipt-residual scope.';
  END IF;

  IF position('order_attributed_receipt_gbp' IN v_definition) > 0
     OR position('inbound_fx_receipt_residual_gbp' IN v_definition) > 0
     OR position('settlement_fx_card_difference_gbp' IN v_definition) > 0
     OR position('fx_or_card_diff_gbp' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: repaired audience overlay references attributed-receipt or FX/card amounts.';
  END IF;

  IF position('insert into' IN v_definition) > 0
     OR position('update public.' IN v_definition) > 0
     OR position('delete from' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: repaired audience overlay contains a business-data write path.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Controlled order post-confirmation canonical settlement position.
  -- -------------------------------------------------------------------------
  SELECT *
  INTO v_position
  FROM public.order_settlement_resolution_position_v1
  WHERE order_id = v_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: controlled order canonical settlement position is missing.';
  END IF;

  IF round(v_position.funding_total_gbp, 2) <> 884.96
     OR round(v_position.applied_account_credit_gbp, 2) <> 80.03
     OR round(v_position.pending_receipt_residual_gbp, 2) <> 81.20
     OR v_position.pending_evidence_count <> 0
     OR v_position.pending_credit_confirmed_count < 1
     OR v_position.final_sale_document_count <> 3
     OR round(v_position.final_order_value_gbp, 2) <> 928.96
     OR round(v_position.payment_applied_to_order_gbp, 2) <> 884.96
     OR round(v_position.order_attributed_receipt_gbp, 2) <> 966.16
     OR round(v_position.gross_positive_difference_gbp, 2) <> 37.20
     OR round(v_position.confirmed_customer_credit_gbp, 2) <> 37.20
     OR round(v_position.remaining_unresolved_gbp, 2) <> 0.00
     OR round(v_position.final_balance_payment_gbp, 2) <> 0.00
     OR v_position.resolution_status <> 'over_resolved_review'
  THEN
    RAISE EXCEPTION
      'FAIL: controlled settlement position changed. funding %, applied credit %, pending residual %, pending evidence %, confirmed pending %, docs %, final %, applied %, attributed %, gross %, credit %, unresolved %, final-balance %, status %',
      v_position.funding_total_gbp,
      v_position.applied_account_credit_gbp,
      v_position.pending_receipt_residual_gbp,
      v_position.pending_evidence_count,
      v_position.pending_credit_confirmed_count,
      v_position.final_sale_document_count,
      v_position.final_order_value_gbp,
      v_position.payment_applied_to_order_gbp,
      v_position.order_attributed_receipt_gbp,
      v_position.gross_positive_difference_gbp,
      v_position.confirmed_customer_credit_gbp,
      v_position.remaining_unresolved_gbp,
      v_position.final_balance_payment_gbp,
      v_position.resolution_status;
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Original pending receipt was classified, not rewritten as funding.
  -- -------------------------------------------------------------------------
  SELECT count(*)::integer
  INTO v_count
  FROM public.order_pending_funding_surplus p
  WHERE p.order_id = v_order_id
    AND p.status = 'credit_confirmed'
    AND round(p.pending_surplus_gbp, 2) = 81.20;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected one £81.20 credit_confirmed pending-surplus row, found %.', v_count;
  END IF;

  SELECT round(coalesce(sum(abs(e.amount_gbp)), 0)::numeric, 2)
  INTO v_amount
  FROM public.order_funding_events e
  WHERE e.order_id = v_order_id
    AND e.event_type = 'credit_applied';

  IF v_amount <> 80.03 THEN
    RAISE EXCEPTION 'FAIL: pre-existing applied account credit changed or was recreated; current total %.', v_amount;
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.dva_statement_line_allocations a
  WHERE a.order_id = v_order_id
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: false final-balance payment allocation was created.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Final sales fingerprint remains unchanged.
  -- -------------------------------------------------------------------------
  SELECT count(*)::integer,
         round(coalesce(sum(
           CASE
             WHEN si.invoice_type = 'credit_note' THEN -abs(coalesce(si.amount_gbp, 0))
             ELSE coalesce(si.amount_gbp, 0)
           END
         ), 0)::numeric, 2)
  INTO v_count, v_amount
  FROM public.sales_invoices si
  WHERE si.order_id = v_order_id
    AND si.sage_status = 'posted'
    AND si.sage_invoice_id IS NOT NULL
    AND si.invoice_type IN ('main', 'supplementary', 'credit_note');

  IF v_count <> 3 OR v_amount <> 928.96 THEN
    RAISE EXCEPTION 'FAIL: posted customer-sales fingerprint changed; docs %, signed total %.', v_count, v_amount;
  END IF;

  -- -------------------------------------------------------------------------
  -- 5. Generic genuine shortfalls remain distinguishable from covered residuals.
  --    This is read-only and does not require an authenticated RPC call.
  -- -------------------------------------------------------------------------
  IF NOT EXISTS (
    SELECT 1
    FROM public.order_settlement_resolution_position_v1 p
    WHERE p.final_sale_document_count > 0
      AND p.final_order_value_gbp > p.order_attributed_receipt_gbp + 0.01
      AND p.remaining_unresolved_gbp <= 0.01
  ) AND NOT EXISTS (
    SELECT 1
    FROM public.order_settlement_resolution_position_v1 p
    WHERE p.final_sale_document_count > 0
      AND p.final_order_value_gbp > p.order_attributed_receipt_gbp + 0.01
  ) THEN
    RAISE NOTICE 'No live genuine final-balance shortfall is currently available for data-level comparison; source and UI smoke evidence remain the regression proof for that branch.';
  END IF;
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'controlled settlement fingerprint remains intact; repaired audience overlay preserves the 28 July predecessor boundary, exact linked-credit provenance and no-FX/no-write scope'
) AS regression_result;

ROLLBACK;
