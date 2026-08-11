-- Delivery allocation bulk wrapper postflight v1.3
-- Read-only. Run after applying 20260811190000_delivery_allocation_atomic_bulk_control_v1.sql.

DO $test$
DECLARE
  v_function_def text;
BEGIN
  IF to_regprocedure('public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)') IS NULL THEN
    RAISE EXCEPTION 'Missing delivery_allocate_tracking_lines_bulk_v1';
  END IF;

  IF to_regprocedure('public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected branch-only single/bulk replacement authority exists';
  END IF;

  IF to_regprocedure('public.delivery_clear_tracking_allocations_v1(uuid,text,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected clear/rework authority exists';
  END IF;

  IF to_regprocedure('public.delivery_allocation_control_state_v1(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected delivery-allocation control-state authority exists';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Authenticated execution grant is missing';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Anon unexpectedly has bulk delivery-allocation execution';
  END IF;

  v_function_def := pg_get_functiondef(
    'public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)'::regprocedure
  );

  IF position('pg_advisory_xact_lock(hashtext(p_order_id::text))' in v_function_def) = 0 THEN
    RAISE EXCEPTION 'Bulk authority is missing the order advisory transaction lock';
  END IF;

  IF position('SUM(a.qty_allocated)' in v_function_def) = 0 THEN
    RAISE EXCEPTION 'Bulk authority no longer mirrors the existing raw allocated-quantity basis';
  END IF;

  IF position('non_physical_financial' in v_function_def) = 0 THEN
    RAISE EXCEPTION 'Bulk authority no longer mirrors the existing non-physical write rejection';
  END IF;

  IF position('recalculate_invoice_adjustment_consumption_v1' in v_function_def) = 0 THEN
    RAISE EXCEPTION 'Bulk authority no longer refreshes the existing invoice-adjustment ledger';
  END IF;

  IF position('physical_replacement_same_order_routes' in v_function_def) > 0
     OR position('successor_tracking_line_allocation_id' in v_function_def) > 0
     OR position('tracking_allocation_effective_entitlement_v1' in v_function_def) > 0 THEN
    RAISE EXCEPTION 'Bulk authority has drifted into replacement-specific logic';
  END IF;

  RAISE NOTICE 'delivery allocation bulk wrapper v1.3 postflight passed';
END
$test$;
