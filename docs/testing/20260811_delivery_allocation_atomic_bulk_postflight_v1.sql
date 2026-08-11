-- Delivery allocation atomic bulk postflight v1.2
-- Read-only. Run after applying 20260811190000_delivery_allocation_atomic_bulk_control_v1.sql.

DO $test$
DECLARE
  v_authenticated_has_allocate boolean;
BEGIN
  IF to_regprocedure('public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'Missing delivery_allocate_tracking_lines_v1';
  END IF;

  IF to_regprocedure('public.delivery_clear_tracking_allocations_v1(uuid,text,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected delivery_clear_tracking_allocations_v1 exists; v1.2 bulk scope does not install a clear authority';
  END IF;

  IF to_regprocedure('public.delivery_allocation_control_state_v1(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected delivery_allocation_control_state_v1 exists; v1.2 bulk scope does not install a control-state authority';
  END IF;

  SELECT has_function_privilege(
    'authenticated',
    'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)',
    'EXECUTE'
  ) INTO v_authenticated_has_allocate;

  IF NOT v_authenticated_has_allocate THEN
    RAISE EXCEPTION 'Authenticated execution grant is missing';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Anon unexpectedly has delivery allocation execution';
  END IF;

  IF position(
    'pg_advisory_xact_lock(hashtext(p_order_id::text))'
    in pg_get_functiondef(
      'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'Allocation authority is missing the governed order advisory lock';
  END IF;

  IF position(
    'successor_tracking_line_allocation_id=a.id'
    in replace(pg_get_functiondef(
      'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)'::regprocedure
    ), ' ', '')
  ) = 0 THEN
    RAISE EXCEPTION 'Allocation authority no longer excludes committed replacement successor provenance from ordinary remaining quantity';
  END IF;

  IF position(
    'Single allocation requires exact quantity mode.'
    in pg_get_functiondef(
      'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'Single request no longer fails closed to exact quantity mode';
  END IF;

  RAISE NOTICE 'delivery allocation atomic bulk v1.2 postflight passed';
END
$test$;
