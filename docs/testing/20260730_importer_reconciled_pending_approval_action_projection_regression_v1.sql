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
  v_outside_boundary_change_count integer;
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_importer_reconciled_action_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_importer_pending_approval_action_v1(uuid,text,text,text,numeric,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Importer reconciled pending-approval action patch is not installed.';
  END IF;

  -- Internal implementation must not be directly callable by normal authenticated users.
  IF has_function_privilege(
       'authenticated',
       'public.order_audience_status_pre_importer_reconciled_action_v1(uuid)'::regprocedure,
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.internal_importer_pending_approval_action_v1(uuid,text,text,text,numeric,text)'::regprocedure,
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'Scope/security drift: predecessor or internal helper is directly executable by authenticated.';
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

  -- Scope invariant: every audience field except importer_next_action must be identical
  -- to the preserved predecessor for every current audience row.
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

  -- Wiring invariant: if the public wrapper changes importer_next_action at all, the
  -- predecessor row must be exactly the diagnosed defect boundary. This catches any
  -- accidental broadening in the real wrapper, not merely in an isolated helper test.
  WITH old_rows AS (
    SELECT *
    FROM public.order_audience_status_pre_importer_reconciled_action_v1(NULL)
  ), new_rows AS (
    SELECT *
    FROM public.order_audience_status_v1(NULL)
  )
  SELECT COUNT(*)::integer
  INTO v_outside_boundary_change_count
  FROM old_rows o
  JOIN new_rows n USING (order_id)
  WHERE n.importer_next_action IS DISTINCT FROM o.importer_next_action
    AND NOT (
      o.supplier_state = 'review_needed'
      AND o.reconciliation_state = 'complete'
      AND o.importer_next_action = 'Resolve evidence issue'
      AND COALESCE(o.canonical_balance_due_gbp, 0) <= 0.01
      AND COALESCE(o.internal_current_stage, '') <> 'exception_or_hold_open'
    );

  IF v_outside_boundary_change_count <> 0 THEN
    RAISE EXCEPTION 'Boundary drift: % audience row(s) changed importer action outside the agreed defect boundary.', v_outside_boundary_change_count;
  END IF;

  -- Production acceptance fixture for the diagnosed order.
  SELECT o.id
  INTO v_target_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785414534454'
  LIMIT 1;

  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'Acceptance fixture ORD-1785414534454 is missing.';
  END IF;

  SELECT a.importer_next_action, a.importer_status_label
  INTO v_new_action, v_new_status
  FROM public.order_audience_status_v1(v_target_id) a;

  SELECT a.importer_next_action, a.importer_status_label
  INTO v_old_action, v_old_status
  FROM public.order_audience_status_pre_importer_reconciled_action_v1(v_target_id) a;

  IF v_old_action IS DISTINCT FROM 'Resolve evidence issue' THEN
    RAISE EXCEPTION 'Target baseline drifted: predecessor action is %, expected Resolve evidence issue.', v_old_action;
  END IF;

  IF v_new_action IS DISTINCT FROM 'No importer action required' THEN
    RAISE EXCEPTION 'Target projection failed: new action is %, expected No importer action required.', v_new_action;
  END IF;

  IF v_new_status IS DISTINCT FROM v_old_status THEN
    RAISE EXCEPTION 'Status-label scope drift: new %, old %.', v_new_status, v_old_status;
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'read-only regression; all non-action audience fields unchanged; every changed importer action constrained to exact review_needed + reconciliation complete + Resolve evidence issue predecessor boundary; predecessor/helper private; diagnosed target changes only importer_next_action from Resolve evidence issue to No importer action required'
) AS regression_result;

ROLLBACK;
