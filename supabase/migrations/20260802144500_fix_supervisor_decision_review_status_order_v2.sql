BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid := 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure;
  v_before text;
  v_after text;
  v_match_count integer;
  v_marker text := E'  -- PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V2\n  IF v_decision = ''approve_existing_exception'' THEN\n    UPDATE public.physical_receipt_reviews\n    SET status = ''approved_to_existing_exception'',\n        supervisor_decided_by_staff_id = v_staff.id,\n        supervisor_decided_at = v_now,\n        approved_liable_party = p_liable_party,\n        decision_note = v_note,\n        updated_at = v_now\n    WHERE id = v_review.id;\n  END IF;\n\n';
  v_pattern text := '([[:space:]]+)UPDATE[[:space:]]+public\.physical_exception_remedy_allocations[[:space:]]+remedy_row[[:space:]]+SET[[:space:]]+approved_remedy_type[[:space:]]*=';
BEGIN
  SELECT pg_get_functiondef(v_oid) INTO v_before;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'Supervisor decision v1 authority is missing.';
  END IF;

  v_before := replace(replace(v_before, E'\r\n', E'\n'), E'\r', E'\n');

  IF position('PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V2' IN v_before) > 0 THEN
    RAISE NOTICE 'Supervisor decision ordering patch v2 is already installed.';
    RETURN;
  END IF;

  SELECT COUNT(*)
  INTO v_match_count
  FROM regexp_matches(v_before, v_pattern, 'g');

  IF v_match_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one remedy-allocation progression statement, found %; refusing unsafe patch.', v_match_count;
  END IF;

  v_after := regexp_replace(
    v_before,
    v_pattern,
    E'\n' || v_marker || E'  UPDATE public.physical_exception_remedy_allocations remedy_row\n  SET approved_remedy_type =',
    ''
  );

  IF v_after = v_before THEN
    RAISE EXCEPTION 'Supervisor decision function was not changed.';
  END IF;

  EXECUTE v_after;

  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_after;

  IF position('PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V2' IN v_after) = 0 THEN
    RAISE EXCEPTION 'Supervisor decision ordering patch v2 did not persist.';
  END IF;

  IF position('PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V2' IN v_after)
     > position('UPDATE public.physical_exception_remedy_allocations remedy_row' IN v_after) THEN
    RAISE EXCEPTION 'Review pre-authorisation was not installed before remedy progression.';
  END IF;
END
$patch$;

DO $postflight$
DECLARE
  v_security_definer boolean;
BEGIN
  IF has_function_privilege('anon', 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon unexpectedly gained direct supervisor decision v1 execute.';
  END IF;

  IF has_function_privilege('authenticated', 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated unexpectedly gained direct supervisor decision v1 execute.';
  END IF;

  SELECT p.prosecdef
  INTO v_security_definer
  FROM pg_proc p
  WHERE p.oid = 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure;

  IF v_security_definer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Supervisor decision v1 lost SECURITY DEFINER.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
