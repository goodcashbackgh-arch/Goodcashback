BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid := 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure;
  v_before text;
  v_after text;
  v_remove_block text := E'  -- THREE_PHASE_EXISTING_EXCEPTION_SEQUENCE_V1\n  -- Phase 1 above: proposed allocations become supervisor-approved while the\n  -- review is still awaiting supervisor review. Phase 2 here: the review enters\n  -- the approved existing-exception route. Phase 3 below: disputes are created\n  -- and the approved allocations progress to linked_to_exception.\n  IF v_decision = ''approve_existing_exception'' THEN\n    UPDATE public.physical_receipt_reviews\n    SET status = ''approved_to_existing_exception'',\n        supervisor_decided_by_staff_id = v_staff.id,\n        supervisor_decided_at = v_now,\n        approved_liable_party = p_liable_party,\n        decision_note = v_note,\n        updated_at = v_now\n    WHERE id = v_review.id;\n  END IF;\n\n';
  v_link_update_old text := E'    UPDATE public.physical_exception_remedy_allocations\n    SET dispute_line_id = v_dispute_line_id,\n        status = ''linked_to_exception'',\n        updated_at = v_now\n    WHERE id = v_item.remedy_allocation_id;';
  v_link_update_new text := E'    UPDATE public.physical_exception_remedy_allocations\n    SET dispute_line_id = v_dispute_line_id,\n        updated_at = v_now\n    WHERE id = v_item.remedy_allocation_id;';
  v_final_update_old text := E'  UPDATE public.physical_receipt_reviews\n  SET status = ''approved_to_existing_exception'',\n      supervisor_decided_by_staff_id = v_staff.id,\n      supervisor_decided_at = v_now,\n      approved_liable_party = p_liable_party,\n      decision_note = v_note,\n      linked_dispute_id = v_primary_dispute_id,\n      updated_at = v_now\n  WHERE id = v_review.id;\n\n  RETURN jsonb_build_object(';
  v_final_update_new text := E'  UPDATE public.physical_receipt_reviews\n  SET status = ''approved_to_existing_exception'',\n      supervisor_decided_by_staff_id = v_staff.id,\n      supervisor_decided_at = v_now,\n      approved_liable_party = p_liable_party,\n      decision_note = v_note,\n      linked_dispute_id = v_primary_dispute_id,\n      updated_at = v_now\n  WHERE id = v_review.id;\n\n  -- LINK_SHAPE_SEQUENCE_V1: the review now has its required linked dispute, so\n  -- approved refund/replacement allocations may progress to linked_to_exception.\n  UPDATE public.physical_exception_remedy_allocations\n  SET status = ''linked_to_exception'',\n      updated_at = v_now\n  WHERE physical_receipt_review_id = v_review.id\n    AND status = ''approved''\n    AND approved_remedy_type IN (''refund'',''replacement'')\n    AND dispute_line_id IS NOT NULL;\n\n  RETURN jsonb_build_object(';
  v_count integer;
BEGIN
  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_before;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'Supervisor decision v1 authority is missing.';
  END IF;

  IF position('LINK_SHAPE_SEQUENCE_V1' IN v_before) > 0 THEN
    RAISE NOTICE 'Supervisor link-shape sequence patch is already installed.';
    RETURN;
  END IF;

  v_count := (length(v_before) - length(replace(v_before, v_remove_block, ''))) / length(v_remove_block);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected the installed three-phase pre-update block exactly once, found %; refusing unsafe patch.', v_count;
  END IF;
  v_after := replace(v_before, v_remove_block, '');

  v_count := (length(v_after) - length(replace(v_after, v_link_update_old, ''))) / length(v_link_update_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected the per-allocation link progression block exactly once, found %; refusing unsafe patch.', v_count;
  END IF;
  v_after := replace(v_after, v_link_update_old, v_link_update_new);

  v_count := (length(v_after) - length(replace(v_after, v_final_update_old, ''))) / length(v_final_update_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected the final linked-review update block exactly once, found %; refusing unsafe patch.', v_count;
  END IF;
  v_after := replace(v_after, v_final_update_old, v_final_update_new);

  EXECUTE v_after;

  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_after;

  IF position('LINK_SHAPE_SEQUENCE_V1' IN v_after) = 0
     OR position('THREE_PHASE_EXISTING_EXCEPTION_SEQUENCE_V1' IN v_after) > 0 THEN
    RAISE EXCEPTION 'Supervisor link-shape sequence patch did not persist cleanly.';
  END IF;
END
$patch$;

DO $postflight$
DECLARE
  v_def text;
  v_security_definer boolean;
BEGIN
  SELECT replace(replace(pg_get_functiondef(
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure
  ), E'\r\n', E'\n'), E'\r', E'\n')
  INTO v_def;

  IF position('SET dispute_line_id = v_dispute_line_id' IN v_def) = 0
     OR position('LINK_SHAPE_SEQUENCE_V1' IN v_def) = 0
     OR position('linked_dispute_id = v_primary_dispute_id' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Supervisor decision v1 does not contain the complete proven link-shape sequence.';
  END IF;

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
