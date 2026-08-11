-- Delivery allocation atomic bulk control postflight v1
-- Read-only. Run after applying 20260811190000_delivery_allocation_atomic_bulk_control_v1.sql.

DO $test$
DECLARE
  v_authenticated_has_allocate boolean;
  v_authenticated_has_clear boolean;
  v_authenticated_has_read boolean;
BEGIN
  IF to_regprocedure('public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'Missing delivery_allocate_tracking_lines_v1';
  END IF;
  IF to_regprocedure('public.delivery_clear_tracking_allocations_v1(uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing delivery_clear_tracking_allocations_v1';
  END IF;
  IF to_regprocedure('public.delivery_allocation_control_state_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing delivery_allocation_control_state_v1';
  END IF;

  SELECT has_function_privilege(
    'authenticated',
    'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)',
    'EXECUTE'
  ) INTO v_authenticated_has_allocate;
  SELECT has_function_privilege(
    'authenticated',
    'public.delivery_clear_tracking_allocations_v1(uuid,text,uuid)',
    'EXECUTE'
  ) INTO v_authenticated_has_clear;
  SELECT has_function_privilege(
    'authenticated',
    'public.delivery_allocation_control_state_v1(uuid,text)',
    'EXECUTE'
  ) INTO v_authenticated_has_read;

  IF NOT v_authenticated_has_allocate OR NOT v_authenticated_has_clear OR NOT v_authenticated_has_read THEN
    RAISE EXCEPTION 'Authenticated execution grants are incomplete';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)',
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    'public.delivery_clear_tracking_allocations_v1(uuid,text,uuid)',
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    'public.delivery_allocation_control_state_v1(uuid,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Anon unexpectedly has delivery allocation v1 execution';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid = 'public.order_tracking_line_allocations'::regclass
      AND NOT t.tgisinternal
      AND t.tgname ILIKE '%delivery%allocation%bulk%'
  ) THEN
    RAISE EXCEPTION 'Unexpected bulk allocation table trigger found';
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
    'successor_tracking_line_allocation_id = a.id'
    in pg_get_functiondef(
      'public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'Allocation authority no longer excludes replacement successor provenance from ordinary remaining quantity';
  END IF;

  RAISE NOTICE 'delivery allocation atomic bulk postflight passed';
END
$test$;
