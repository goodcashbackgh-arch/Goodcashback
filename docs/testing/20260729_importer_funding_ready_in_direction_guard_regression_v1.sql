-- IMPORTER FUNDING READY IN DIRECTION GUARD REGRESSION v1
-- READ ONLY
-- Safe to run directly in the Supabase SQL editor.
--
-- Purpose:
-- 1) prove the known target IN/OUT rows remain classified correctly;
-- 2) prove the shared worklist preserves those directions;
-- 3) prove no OUT row has been reconciled as order funding;
-- 4) prove all live funding RPCs retain their inbound direction guard.
--
-- Note: the UI source guard itself is covered by the companion .mjs repo regression.

DO $$
DECLARE
  v_target_in_count integer;
  v_target_out_count integer;
  v_worklist_in_count integer;
  v_worklist_out_count integer;
  v_out_funding_reconciliations integer;
  v_rpc_count integer;
  v_guarded_rpc_count integer;
BEGIN
  SELECT count(*) FILTER (WHERE direction = 'in'),
         count(*) FILTER (WHERE direction = 'out')
    INTO v_target_in_count, v_target_out_count
  FROM public.dva_statement_lines
  WHERE id IN (
    'e43b0cf6-5d79-45ff-a6c3-d6c42c15e6ad'::uuid,
    '63eb0078-e088-45a6-9287-45d4b1b5ab33'::uuid
  );

  IF v_target_in_count <> 1 OR v_target_out_count <> 1 THEN
    RAISE EXCEPTION
      'FAIL: expected target statement lines to remain exactly one IN and one OUT; got IN %, OUT %',
      v_target_in_count, v_target_out_count;
  END IF;

  SELECT count(*) FILTER (WHERE direction = 'in'),
         count(*) FILTER (WHERE direction = 'out')
    INTO v_worklist_in_count, v_worklist_out_count
  FROM public.day2_dva_review_worklist_vw
  WHERE dva_statement_line_id IN (
    'e43b0cf6-5d79-45ff-a6c3-d6c42c15e6ad'::uuid,
    '63eb0078-e088-45a6-9287-45d4b1b5ab33'::uuid
  );

  IF v_worklist_in_count <> 1 OR v_worklist_out_count <> 1 THEN
    RAISE EXCEPTION
      'FAIL: funding worklist must preserve the target directions; got IN %, OUT %',
      v_worklist_in_count, v_worklist_out_count;
  END IF;

  SELECT count(*)
    INTO v_out_funding_reconciliations
  FROM public.dva_reconciliation dr
  JOIN public.dva_statement_lines dsl
    ON dsl.id = dr.dva_statement_line_id
  WHERE dsl.direction = 'out'
    AND dr.reconciliation_type = 'order_funding';

  IF v_out_funding_reconciliations <> 0 THEN
    RAISE EXCEPTION
      'FAIL: found % OUT statement line(s) reconciled as order funding',
      v_out_funding_reconciliations;
  END IF;

  SELECT count(*),
         count(*) FILTER (
           WHERE lower(pg_get_functiondef(p.oid)) LIKE '%direction%'
             AND lower(pg_get_functiondef(p.oid)) LIKE '%<> ''in''%'
         )
    INTO v_rpc_count, v_guarded_rpc_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'staff_reconcile_dva_line_to_order',
      'staff_reconcile_dva_line_to_order_pending_surplus_v1',
      'staff_reconcile_dva_line_to_order_customer_fx_gain_v1'
    );

  IF v_rpc_count <> 3 THEN
    RAISE EXCEPTION 'FAIL: expected 3 funding RPCs, found %', v_rpc_count;
  END IF;

  IF v_guarded_rpc_count <> 3 THEN
    RAISE EXCEPTION
      'FAIL: expected all 3 funding RPCs to retain inbound direction guards; guarded % of %',
      v_guarded_rpc_count, v_rpc_count;
  END IF;
END
$$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'target statement lines remain one IN and one OUT; worklist preserves both directions; zero OUT rows are reconciled as order funding; all three live funding RPCs retain inbound direction guards'
) AS regression_result;
