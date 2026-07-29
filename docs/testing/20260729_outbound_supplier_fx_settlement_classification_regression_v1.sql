BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_order_id uuid;
  v_out_fx numeric(12,2);
  v_supplier numeric(12,2);
  v_source_used numeric(12,2);
  v_position record;
  v_view_definition text;
BEGIN
  SELECT o.id INTO v_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled order ORD-1785274708774 is missing.';
  END IF;

  SELECT ROUND(COALESCE(SUM(ABS(COALESCE(NULLIF(a.fx_or_card_diff_gbp, 0), a.allocated_gbp_amount, 0))), 0)::numeric, 2)
  INTO v_out_fx
  FROM public.dva_statement_line_allocations a
  JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
  JOIN public.dva_statements s ON s.id = l.dva_statement_id
  WHERE a.order_id = v_order_id
    AND a.allocation_type = 'fx_card_difference'
    AND a.allocation_status = 'confirmed'
    AND l.direction = 'out'
    AND COALESCE(s.statement_account_context, 'importer_dva_card_account') = 'importer_dva_card_account';

  IF v_out_fx <> 0.93 THEN
    RAISE EXCEPTION 'FAIL: controlled confirmed outbound FX expected 0.93, got %.', v_out_fx;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
  INTO v_supplier
  FROM public.dva_statement_line_allocations a
  LEFT JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
  WHERE COALESCE(si.order_id, a.order_id) = v_order_id
    AND a.allocation_status = 'confirmed'
    AND a.allocation_type = 'supplier_invoice';

  IF v_supplier <> 701.83 THEN
    RAISE EXCEPTION 'FAIL: supplier-invoice allocation changed; expected 701.83, got %.', v_supplier;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
  INTO v_source_used
  FROM public.dva_statement_line_allocations a
  JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
  WHERE a.allocation_status = 'confirmed'
    AND l.direction = 'out'
    AND a.dva_statement_line_id IN (
      SELECT DISTINCT a2.dva_statement_line_id
      FROM public.dva_statement_line_allocations a2
      LEFT JOIN public.supplier_invoices si2 ON si2.id = a2.supplier_invoice_id
      WHERE COALESCE(si2.order_id, a2.order_id) = v_order_id
        AND a2.allocation_status = 'confirmed'
        AND a2.allocation_type IN ('supplier_invoice','fx_card_difference')
    );

  IF v_source_used <> 702.76 THEN
    RAISE EXCEPTION 'FAIL: bank OUT source consumption changed; expected 702.76, got %.', v_source_used;
  END IF;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1
  WHERE order_id = v_order_id;

  IF v_position.order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical settlement position missing.';
  END IF;

  IF ROUND(COALESCE(v_position.settlement_fx_card_difference_gbp, 0)::numeric, 2) < v_out_fx THEN
    RAISE EXCEPTION 'FAIL: canonical settlement does not include confirmed outbound FX; canonical %, outbound %.', v_position.settlement_fx_card_difference_gbp, v_out_fx;
  END IF;

  IF ROUND(COALESCE(v_position.order_attributed_receipt_gbp, 0)::numeric, 2)
     <> ROUND((COALESCE(v_position.funding_total_gbp, 0)
              + COALESCE(v_position.final_balance_payment_gbp, 0)
              + COALESCE(v_position.pending_receipt_residual_gbp, 0)
              + COALESCE(v_position.inbound_fx_receipt_residual_gbp, 0))::numeric, 2) THEN
    RAISE EXCEPTION 'FAIL: outbound FX leaked into order-attributed receipt.';
  END IF;

  SELECT pg_get_viewdef('public.order_settlement_resolution_position_v1'::regclass, true)
  INTO v_view_definition;

  IF position('dsl.direction = ''out''::text' IN v_view_definition) = 0
     OR position('dsa.allocation_type = ''fx_card_difference''::text' IN v_view_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: scoped outbound FX classification is absent from canonical view.';
  END IF;
END
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'ORD-1785274708774 keeps £701.83 supplier allocation and £702.76 OUT source consumption; £0.93 remains confirmed FX/payment variance, is included once in settlement classification, and is not added to order-attributed receipt'
) AS regression_result;

ROLLBACK;
