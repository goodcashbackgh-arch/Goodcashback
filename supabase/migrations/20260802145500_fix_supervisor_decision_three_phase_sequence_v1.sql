BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid := 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure;
  v_before text;
  v_after text;
  v_anchor text := E'  FROM payload\n  WHERE remedy_row.id = payload.remedy_allocation_id;\n\n  IF v_decision = ''close_no_action'' THEN';
  v_insert text := E'  FROM payload\n  WHERE remedy_row.id = payload.remedy_allocation_id;\n\n  -- THREE_PHASE_EXISTING_EXCEPTION_SEQUENCE_V1\n  -- Phase 1 above: proposed allocations become supervisor-approved while the\n  -- review is still awaiting supervisor review. Phase 2 here: the review enters\n  -- the approved existing-exception route. Phase 3 below: disputes are created\n  -- and the approved allocations progress to linked_to_exception.\n  IF v_decision = ''approve_existing_exception'' THEN\n    UPDATE public.physical_receipt_reviews\n    SET status = ''approved_to_existing_exception'',\n        supervisor_decided_by_staff_id = v_staff.id,\n        supervisor_decided_at = v_now,\n        approved_liable_party = p_liable_party,\n        decision_note = v_note,\n        updated_at = v_now\n    WHERE id = v_review.id;\n  END IF;\n\n  IF v_decision = ''close_no_action'' THEN';
  v_count integer;
BEGIN
  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_before;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'Supervisor decision v1 authority is missing.';
  END IF;

  IF position('THREE_PHASE_EXISTING_EXCEPTION_SEQUENCE_V1' IN v_before) > 0 THEN
    RAISE NOTICE 'Supervisor three-phase sequence patch is already installed.';
    RETURN;
  END IF;

  v_count := (length(v_before) - length(replace(v_before, v_anchor, ''))) / length(v_anchor);

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected exact post-approval allocation anchor once, found %; refusing unsafe patch.', v_count;
  END IF;

  v_after := replace(v_before, v_anchor, v_insert);

  IF v_after = v_before THEN
    RAISE EXCEPTION 'Supervisor decision function was not changed.';
  END IF;

  EXECUTE v_after;

  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_after;

  IF position('THREE_PHASE_EXISTING_EXCEPTION_SEQUENCE_V1' IN v_after) = 0 THEN
    RAISE EXCEPTION 'Supervisor three-phase sequence patch did not persist.';
  END IF;

  IF position('THREE_PHASE_EXISTING_EXCEPTION_SEQUENCE_V1' IN v_after)
     < position('SET approved_remedy_type = payload.approved_remedy_type' IN v_after) THEN
    RAISE EXCEPTION 'Review approval was inserted before allocation approval; refusing unsafe ordering.';
  END IF;

  IF position('THREE_PHASE_EXISTING_EXCEPTION_SEQUENCE_V1' IN v_after)
     > position('INSERT INTO public.disputes' IN v_after) THEN
    RAISE EXCEPTION 'Review approval was inserted after dispute progression; refusing unsafe ordering.';
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
