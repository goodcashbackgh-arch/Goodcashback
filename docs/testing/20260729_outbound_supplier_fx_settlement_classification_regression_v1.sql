BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_order_id uuid;
  v_statement_line_id uuid;
  v_supplier_order_count integer;
  v_out_fx numeric(12,2);
  v_existing_action_fx numeric(12,2);
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

  -- Resolve the controlled supplier-payment OUT through its confirmed supplier
  -- allocations. The FX row itself is deliberately not required to carry order_id.
  SELECT a.dva_statement_line_id
  INTO v_statement_line_id
  FROM public.dva_statement_line_allocations a
  LEFT JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
  JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
  WHERE COALESCE(si.order_id, a.order_id) = v_order_id
    AND a.allocation_status = 'confirmed'
    AND a.allocation_type = 'supplier_invoice'
    AND l.direction = 'out'
  GROUP BY a.dva_statement_line_id
  HAVING ROUND(SUM(a.allocated_gbp_amount)::numeric, 2) = 701.83
  LIMIT 1;

  IF v_statement_line_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled supplier-payment OUT statement line is missing.';
  END IF;

  SELECT COUNT(DISTINCT COALESCE(si.order_id, a.order_id))::integer
  INTO v_supplier_order_count
  FROM public.dva_statement_line_allocations a
  LEFT JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
  WHERE a.dva_statement_line_id = v_statement_line_id
    AND a.allocation_status = 'confirmed'
    AND a.allocation_type = 'supplier_invoice'
    AND COALESCE(si.order_id, a.order_id) IS NOT NULL;

  IF v_supplier_order_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: controlled supplier-payment OUT must resolve to exactly one supplier order; got %.', v_supplier_order_count;
  END IF;

  SELECT ROUND(COALESCE(SUM(ABS(COALESCE(NULLIF(a.fx_or_card_diff_gbp, 0), a.allocated_gbp_amount, 0))), 0)::numeric, 2)
  INTO v_out_fx
  FROM public.dva_statement_line_allocations a
  JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
  JOIN public.dva_statements s ON s.id = l.dva_statement_id
  WHERE a.dva_statement_line_id = v_statement_line_id
    AND a.allocation_type = 'fx_card_difference'
    AND a.allocation_status = 'confirmed'
    AND l.direction = 'out'
    AND COALESCE(s.statement_account_context, 'importer_dva_card_account') = 'importer_dva_card_account';

  IF v_out_fx <> 0.93 THEN
    RAISE EXCEPTION 'FAIL: controlled confirmed outbound FX expected 0.93, got %.', v_out_fx;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.fx_card_difference_gbp) FILTER (WHERE a.status = 'active'), 0)::numeric, 2)
  INTO v_existing_action_fx
  FROM public.order_settlement_resolution_actions a
  WHERE a.order_id = v_order_id;

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
  WHERE a.dva_statement_line_id = v_statement_line_id
    AND a.allocation_status = 'confirmed';

  IF v_source_used <> 702.76 THEN
    RAISE EXCEPTION 'FAIL: bank OUT source consumption changed; expected 702.76, got %.', v_source_used;
  END IF;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1
  WHERE order_id = v_order_id;

  IF v_position.order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical settlement position missing.';
  END IF;

  IF ROUND(COALESCE(v_position.settlement_fx_card_difference_gbp, 0)::numeric, 2)
     <> ROUND((COALESCE(v_existing_action_fx, 0) + v_out_fx)::numeric, 2) THEN
    RAISE EXCEPTION 'FAIL: canonical settlement FX expected existing action FX % + outbound FX %, got %.', v_existing_action_fx, v_out_fx, v_position.settlement_fx_card_difference_gbp;
  END IF;

  -- OUT FX must remain classification only and must not change receipt attribution.
  IF ROUND(COALESCE(v_position.order_attributed_receipt_gbp, 0)::numeric, 2)
     <> ROUND((COALESCE(v_position.funding_total_gbp, 0)
              + COALESCE(v_position.final_balance_payment_gbp, 0)
              + COALESCE(v_position.pending_receipt_residual_gbp, 0)
              + COALESCE(v_position.inbound_fx_receipt_residual_gbp, 0))::numeric, 2) THEN
    RAISE EXCEPTION 'FAIL: outbound FX leaked into order-attributed receipt.';
  END IF;

  SELECT lower(pg_get_viewdef('public.order_settlement_resolution_position_v1'::regclass, true))
  INTO v_view_definition;

  IF position('dsl.direction = ''out''::text' IN v_view_definition) = 0
     OR position('fx.allocation_type = ''fx_card_difference''::text' IN v_view_definition) = 0
     OR position('supplier_alloc.allocation_type = ''supplier_invoice''::text' IN v_view_definition) = 0
     OR position('supplier_orders' IN v_view_definition) = 0
     OR position('select distinct coalesce(si.order_id, supplier_alloc.order_id)' IN v_view_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: fail-closed outbound supplier FX classification is absent from canonical view.';
  END IF;

  -- Existing inbound FX remains its separate receipt-attribution lane.
  IF position('ifx.inbound_fx_receipt_residual_gbp' IN v_view_definition) = 0
     OR position('b.inbound_fx_receipt_residual_gbp' IN v_view_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: existing inbound FX settlement path changed.';
  END IF;
END
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'ORD-1785274708774 supplier-payment OUT resolves to one order through supplier allocations; £701.83 supplier allocation and £702.76 source consumption remain intact; £0.93 null-order FX is classified once in addition to any existing active settlement-action FX and is not added to receipt attribution; inbound FX path remains present'
) AS regression_result;

ROLLBACK;
