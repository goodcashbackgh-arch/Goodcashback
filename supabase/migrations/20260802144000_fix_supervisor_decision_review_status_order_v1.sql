BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid := 'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure;
  v_before text;
  v_after text;
  v_anchor text := E'  WITH payload AS (\n    SELECT *\n    FROM jsonb_to_recordset(p_allocations) AS x(\n      remedy_allocation_id uuid,\n      approved_remedy_type text,\n      approved_remedy_qty numeric,\n      supplier_cost_mode text\n    )\n  )\n  UPDATE public.physical_exception_remedy_allocations remedy_row';
  v_insert text := E'  -- The physical-remedy guard requires the review to already be approved\n  -- into the existing exception route before refund/replacement allocations\n  -- progress beyond proposed. This update occurs in the same transaction and\n  -- is rolled back automatically if any later dispute/link creation fails.\n  IF v_decision = ''approve_existing_exception'' THEN\n    UPDATE public.physical_receipt_reviews\n    SET status = ''approved_to_existing_exception'',\n        supervisor_decided_by_staff_id = v_staff.id,\n        supervisor_decided_at = v_now,\n        approved_liable_party = p_liable_party,\n        decision_note = v_note,\n        updated_at = v_now\n    WHERE id = v_review.id;\n  END IF;\n\n';
BEGIN
  SELECT pg_get_functiondef(v_oid) INTO v_before;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'Supervisor decision v1 authority is missing.';
  END IF;

  -- pg_get_functiondef can preserve CRLF from the installed body. Normalise
  -- line endings before applying the exact single-anchor patch.
  v_before := replace(v_before, E'\r\n', E'\n');
  v_before := replace(v_before, E'\r', E'\n');

  IF position(v_insert IN v_before) > 0 THEN
    RAISE NOTICE 'Supervisor decision review-status ordering patch is already installed.';
    RETURN;
  END IF;

  IF (length(v_before) - length(replace(v_before, v_anchor, ''))) / length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'Expected supervisor allocation-update anchor exactly once after line-ending normalisation; refusing unsafe patch.';
  END IF;

  v_after := replace(v_before, v_anchor, v_insert || v_anchor);

  IF v_after = v_before THEN
    RAISE EXCEPTION 'Supervisor decision function was not changed.';
  END IF;

  EXECUTE v_after;

  IF position(v_insert IN replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n')) = 0 THEN
    RAISE EXCEPTION 'Supervisor decision review-status ordering patch did not persist.';
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

  IF v_def NOT ILIKE '%IF v_decision = ''approve_existing_exception'' THEN%approved_to_existing_exception%' THEN
    RAISE EXCEPTION 'Supervisor decision v1 does not pre-authorise the review before remedy progression.';
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
