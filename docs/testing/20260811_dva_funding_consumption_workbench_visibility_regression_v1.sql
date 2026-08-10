BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_def text;
  v_line_1 uuid := '28acc326-dd04-4ea8-b2b4-4d429e8ec5b7'::uuid;
  v_line_2 uuid := '0791dd47-43b3-4c16-bcb3-185d5de964da'::uuid;
  v_remaining numeric;
  v_balanced boolean;
BEGIN
  SELECT pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)
  INTO v_def;

  IF v_def NOT ILIKE '%dva_reconciliation%' THEN
    RAISE EXCEPTION 'FAIL: allocation summary does not consume dva_reconciliation';
  END IF;
  IF v_def NOT ILIKE '%order_funding%' THEN
    RAISE EXCEPTION 'FAIL: allocation summary does not narrow funding consumption to order_funding';
  END IF;
  IF v_def NOT ILIKE '%dva_statement_line_allocations%' THEN
    RAISE EXCEPTION 'FAIL: existing allocation family missing';
  END IF;
  IF v_def NOT ILIKE '%main_bank_completion_loyalty_funding_matches%' THEN
    RAISE EXCEPTION 'FAIL: existing loyalty family missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname IN (
      'staff_reconcile_dva_line_to_order',
      'allocate_statement_line_to_supplier_invoice',
      'allocate_statement_line_to_fx_card_or_fee'
    )
      AND pg_get_functiondef(oid) ILIKE '%20260811_dva_funding_consumption_workbench_visibility_v1%'
  ) THEN
    RAISE EXCEPTION 'FAIL: read-model patch unexpectedly modified write functions';
  END IF;

  IF EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_line_1) THEN
    SELECT confirmed_unallocated_gbp, confirmed_balanced_yn
    INTO v_remaining, v_balanced
    FROM public.dva_statement_line_allocation_summary_vw
    WHERE dva_statement_line_id = v_line_1;

    IF ABS(COALESCE(v_remaining, 999999)) >= 0.01 OR COALESCE(v_balanced, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: known £726.40 funding+FX line is not balanced; remaining=% balanced=%', v_remaining, v_balanced;
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_line_2) THEN
    SELECT confirmed_unallocated_gbp, confirmed_balanced_yn
    INTO v_remaining, v_balanced
    FROM public.dva_statement_line_allocation_summary_vw
    WHERE dva_statement_line_id = v_line_2;

    IF ABS(COALESCE(v_remaining, 999999)) >= 0.01 OR COALESCE(v_balanced, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: known £20.18 funding+FX line is not balanced; remaining=% balanced=%', v_remaining, v_balanced;
    END IF;
  END IF;
END $$;

SELECT
  'PASS'::text AS regression_result,
  'Allocation summary counts accepted-estimate order funding plus existing allocation/loyalty consumption; known live funding+FX lines are balanced when present.'::text AS details;

ROLLBACK;
