BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid := 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure;
  v_before text;
  v_after text;
  v_block text := E'  -- PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V3\n  IF v_decision = ''approve_existing_exception'' THEN\n    UPDATE public.physical_receipt_reviews\n    SET status = ''approved_to_existing_exception'',\n        supervisor_decided_by_staff_id = v_staff.id,\n        supervisor_decided_at = v_now,\n        approved_liable_party = p_liable_party,\n        decision_note = v_note,\n        updated_at = v_now\n    WHERE id = v_review.id;\n  END IF;\n\n';
  v_count integer;
BEGIN
  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_before;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'Supervisor decision v1 authority is missing.';
  END IF;

  v_count := (length(v_before) - length(replace(v_before, v_block, ''))) / length(v_block);

  IF v_count = 0 THEN
    IF position('PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V3' IN v_before) = 0 THEN
      RAISE NOTICE 'Obsolete preapproval block is already absent.';
      RETURN;
    END IF;
    RAISE EXCEPTION 'Obsolete preapproval marker exists but exact block shape differs; refusing unsafe patch.';
  END IF;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected obsolete preapproval block exactly once, found %; refusing unsafe patch.', v_count;
  END IF;

  v_after := replace(v_before, v_block, '');
  EXECUTE v_after;

  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_after;

  IF position('PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V3' IN v_after) > 0 THEN
    RAISE EXCEPTION 'Obsolete preapproval block still exists after patch.';
  END IF;

  IF position('SET approved_remedy_type = payload.approved_remedy_type' IN v_after) = 0
     OR position('linked_dispute_id = v_primary_dispute_id' IN v_after) = 0
     OR position('LINK_SHAPE_SEQUENCE_V1' IN v_after) = 0 THEN
    RAISE EXCEPTION 'Required supervisor decision sequence was altered or is missing.';
  END IF;
END
$patch$;

DO $postflight$
DECLARE
  v_def text;
BEGIN
  SELECT replace(replace(pg_get_functiondef(
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure
  ), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_def;

  IF position('PREAUTHORISE_EXISTING_EXCEPTION_ROUTE_V3' IN v_def) > 0 THEN
    RAISE EXCEPTION 'Postflight failed: obsolete preapproval marker remains.';
  END IF;

  IF position('SET approved_remedy_type = payload.approved_remedy_type' IN v_def)
     >= position('linked_dispute_id = v_primary_dispute_id' IN v_def) THEN
    RAISE EXCEPTION 'Postflight failed: allocation approval is not before final linked review approval.';
  END IF;

  IF has_function_privilege('anon', 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon unexpectedly gained execute on supervisor decision v1.';
  END IF;

  IF has_function_privilege('authenticated', 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated unexpectedly gained execute on supervisor decision v1.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
