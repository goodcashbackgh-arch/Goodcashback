-- Narrow correction: preserve the unchanged Mini Build remedy guard.
-- The same-order sidecar route owns progress; the legacy remedy row remains in its existing guard-compatible state.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $migration$
DECLARE
  v_oid oid := to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)');
  v_definition text;
  v_guard_before text;
  v_old text := 'SET supplier_cost_mode=''free_replacement'',status=''in_progress'',updated_at=v_now';
  v_new text := 'SET supplier_cost_mode=''free_replacement'',updated_at=v_now';
  v_old_count integer;
  v_new_count integer;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'Same-order acceptance authority is missing.';
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_definition;
  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure))
    INTO v_guard_before;

  IF v_guard_before <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN
    RAISE EXCEPTION 'Protected Mini Build remedy guard drifted. Stop.';
  END IF;

  v_old_count := (length(v_definition)-length(replace(v_definition,v_old,''))) / NULLIF(length(v_old),0);
  v_new_count := (length(v_definition)-length(replace(v_definition,v_new,''))) / NULLIF(length(v_new),0);

  IF v_old_count = 1 THEN
    v_definition := replace(v_definition,v_old,v_new);
    EXECUTE v_definition;
  ELSIF v_old_count = 0 AND v_new_count = 1 THEN
    NULL; -- already corrected
  ELSIF v_old_count > 1 THEN
    RAISE EXCEPTION 'Expected same-order assignment was not unique.';
  ELSE
    RAISE EXCEPTION 'Neither the old nor corrected same-order assignment was found; inspect before changing.';
  END IF;

  IF position('status=''in_progress''' in pg_get_functiondef(v_oid))>0 THEN
    RAISE EXCEPTION 'Same-order acceptance still attempts the legacy child-only in_progress state.';
  END IF;

  IF md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure))
       <> v_guard_before THEN
    RAISE EXCEPTION 'Protected Mini Build remedy guard changed.';
  END IF;
END
$migration$;

COMMENT ON FUNCTION public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) IS
'Supervisor/admin acceptance for a child-free same-order free replacement. Progress is held only by physical_replacement_same_order_routes; the protected legacy remedy remains in its existing guard-compatible state.';

COMMIT;
