BEGIN TRANSACTION READ ONLY;

DO $$
DECLARE
  v_candidate uuid;
  v_staff_uid uuid;
  v_target_id uuid;
  v_new_action text;
  v_old_action text;
  v_new_status text;
  v_old_status text;
  v_non_action_drift_count integer;
  v_action text;
  v_decision regprocedure := 'public.internal_importer_reconciled_action_decision_v1(text,text,text,numeric,text,text,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer)'::regprocedure;
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_importer_reconciled_action_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_importer_reconciled_next_action_v1(uuid,text,text,text,numeric,text,text)') IS NULL
     OR to_regprocedure('public.internal_importer_reconciled_action_decision_v1(text,text,text,numeric,text,text,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer)') IS NULL
  THEN
    RAISE EXCEPTION 'Importer reconciled pending-approval action patch is not installed.';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.order_audience_status_pre_importer_reconciled_action_v1(uuid)'::regprocedure,
       'EXECUTE'
     )
     OR has_function_privilege('authenticated', v_decision, 'EXECUTE')
     OR has_function_privilege(
       'authenticated',
       'public.internal_importer_reconciled_next_action_v1(uuid,text,text,text,numeric,text,text)'::regprocedure,
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'Scope/security drift: preserved predecessor or internal helper is directly executable by authenticated.';
  END IF;

  FOR v_candidate IN
    SELECT u.id
    FROM auth.users u
    ORDER BY u.created_at NULLS LAST, u.id
  LOOP
    PERFORM set_config('request.jwt.claim.sub', v_candidate::text, true);
    BEGIN
      IF public.is_active_staff() THEN
        v_staff_uid := v_candidate;
        EXIT;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  IF v_staff_uid IS NULL THEN
    RAISE EXCEPTION 'No active staff auth user found for regression.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_staff_uid::text, true);

  -- Contract invariant: every audience field other than importer_next_action must be
  -- exactly equivalent as jsonb to the preserved predecessor for every current row.
  WITH old_rows AS (
    SELECT *
    FROM public.order_audience_status_pre_importer_reconciled_action_v1(NULL)
  ), new_rows AS (
    SELECT *
    FROM public.order_audience_status_v1(NULL)
  )
  SELECT COUNT(*)::integer
  INTO v_non_action_drift_count
  FROM old_rows o
  FULL JOIN new_rows n USING (order_id)
  WHERE o.order_id IS NULL
     OR n.order_id IS NULL
     OR (to_jsonb(o) - 'importer_next_action')
        IS DISTINCT FROM
        (to_jsonb(n) - 'importer_next_action');

  IF v_non_action_drift_count <> 0 THEN
    RAISE EXCEPTION 'Scope drift: % audience row(s) changed outside importer_next_action.', v_non_action_drift_count;
  END IF;

  -- Synthetic pure-decision regression: no business-data fixture writes are required.
  -- Baseline defect boundary + fully assigned tracking -> no importer action required.
  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'No importer action required' THEN
    RAISE EXCEPTION 'Decision regression failed: fully assigned reconciled pending-approval case returned %.', v_action;
  END IF;

  -- Partially assigned tracking -> Assign tracking.
  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 1
  );
  IF v_action IS DISTINCT FROM 'Assign tracking' THEN
    RAISE EXCEPTION 'Decision regression failed: partial tracking case returned %.', v_action;
  END IF;

  -- No active tracking -> Add tracking.
  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 0, 4
  );
  IF v_action IS DISTINCT FROM 'Add tracking' THEN
    RAISE EXCEPTION 'Decision regression failed: missing tracking case returned %.', v_action;
  END IF;

  -- Exact-boundary guards: any mismatch must preserve predecessor action.
  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'approved_current', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Boundary regression failed: supplier_state mismatch changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'incomplete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Boundary regression failed: reconciliation_state mismatch changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Some existing action', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Some existing action' THEN
    RAISE EXCEPTION 'Boundary regression failed: non-target predecessor action changed to %.', v_action;
  END IF;

  -- Genuine importer blockers must preserve predecessor action.
  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 1.00, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: positive balance changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'exception_or_hold_open', 'missing',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: exception/hold changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 1, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: resubmission changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 1, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: unknown review state changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 1, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: open evidence query changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 1, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: open/under-review invoice flag changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 1, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: missing confirmation changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 4, 0, 1, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: unresolved line changed action to %.', v_action;
  END IF;

  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'missing',
    3, 0, 0, 0, 0, 0, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Blocker regression failed: no progressed physical lines changed action to %.', v_action;
  END IF;

  -- Accepted POD remains complete inside the exact target boundary.
  v_action := public.internal_importer_reconciled_action_decision_v1(
    'Resolve evidence issue', 'review_needed', 'complete', 0, 'funding_incomplete', 'accepted_current',
    3, 0, 0, 0, 0, 4, 0, 0, 2, 0
  );
  IF v_action IS DISTINCT FROM 'Order complete' THEN
    RAISE EXCEPTION 'Decision regression failed: accepted POD returned %.', v_action;
  END IF;

  -- Production proof for the diagnosed target, if still present.
  SELECT o.id
  INTO v_target_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785414534454'
  LIMIT 1;

  IF v_target_id IS NOT NULL THEN
    SELECT a.importer_next_action, a.importer_status_label
    INTO v_new_action, v_new_status
    FROM public.order_audience_status_v1(v_target_id) a;

    SELECT a.importer_next_action, a.importer_status_label
    INTO v_old_action, v_old_status
    FROM public.order_audience_status_pre_importer_reconciled_action_v1(v_target_id) a;

    IF v_old_action IS DISTINCT FROM 'Resolve evidence issue' THEN
      RAISE EXCEPTION 'Target baseline drifted before regression: predecessor action is %, expected Resolve evidence issue.', v_old_action;
    END IF;

    IF v_new_action IS DISTINCT FROM 'No importer action required' THEN
      RAISE EXCEPTION 'Target projection failed: new action is %, expected No importer action required.', v_new_action;
    END IF;

    IF v_new_status IS DISTINCT FROM v_old_status THEN
      RAISE EXCEPTION 'Status-label scope drift: new %, old %.', v_new_status, v_old_status;
    END IF;
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'exact defect boundary enforced; every listed importer blocker fails closed; missing/partial/full tracking decisions proven without business-data fixture writes; predecessor and internal helpers are not executable by authenticated; only importer_next_action may differ from preserved predecessor; diagnosed target moves from Resolve evidence issue to No importer action required while every other audience field remains unchanged'
) AS regression_result;

ROLLBACK;
