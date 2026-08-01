BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $catalog$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure('public.shipper_physical_receipt_entry_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: shipper_physical_receipt_entry_v1(uuid) is missing';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.shipper_physical_receipt_entry_v1(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated execute grant is missing';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.shipper_physical_receipt_entry_v1(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute the shipper entry read RPC';
  END IF;

  SELECT pg_get_functiondef(
    'public.shipper_physical_receipt_entry_v1(uuid)'::regprocedure
  ) INTO v_definition;

  IF v_definition NOT ILIKE '%security definer%'
     OR v_definition NOT ILIKE '%auth.uid()%'
     OR v_definition NOT ILIKE '%shipper_users%'
     OR v_definition NOT ILIKE '%orders%'
     OR v_definition NOT ILIKE '%order_tracking_line_allocations%'
     OR v_definition NOT ILIKE '%supplier_invoice_lines%'
     OR v_definition NOT ILIKE '%physical_receipt_reviews%'
  THEN
    RAISE EXCEPTION 'FAIL: shipper entry read source contract is incomplete';
  END IF;

  IF v_definition ~* '\m(insert|update|delete|merge|truncate)\M' THEN
    RAISE EXCEPTION 'FAIL: shipper entry read RPC contains a write statement';
  END IF;

  IF v_definition ILIKE '%service_role%'
     OR v_definition ILIKE '%set role%'
     OR v_definition ILIKE '%disable row level security%'
  THEN
    RAISE EXCEPTION 'FAIL: shipper entry read RPC contains an elevated bypass';
  END IF;
END
$catalog$;

DO $shape$
DECLARE
  v_expected text[] := ARRAY[
    'tracking_line_allocation_id:uuid',
    'supplier_invoice_line_id:uuid',
    'item_description:text',
    'qty_allocated:numeric',
    'latest_receipt_id:uuid',
    'latest_receipt_model_version:smallint',
    'latest_receipt_state:text',
    'latest_review_status:text',
    'correction_allowed:boolean'
  ];
  v_actual text[];
BEGIN
  SELECT array_agg(
    parameter_name || ':' || data_type
    ORDER BY ordinal_position
  )
  INTO v_actual
  FROM information_schema.parameters
  WHERE specific_schema = 'public'
    AND specific_name = (
      SELECT p.proname || '_' || p.oid
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.oid = 'public.shipper_physical_receipt_entry_v1(uuid)'::regprocedure
    )
    AND parameter_mode = 'OUT';

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'FAIL: return shape changed. Expected %, got %', v_expected, v_actual;
  END IF;
END
$shape$;

DO $unauthenticated$
DECLARE
  v_failed boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', 'anon', true);

  BEGIN
    PERFORM * FROM public.shipper_physical_receipt_entry_v1(gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL: unauthenticated call did not fail closed';
  END IF;
END
$unauthenticated$;

SELECT 'PASS — shipper receipt entry read catalog, privilege, shape, read-only and unauthenticated gates passed' AS result;

ROLLBACK;