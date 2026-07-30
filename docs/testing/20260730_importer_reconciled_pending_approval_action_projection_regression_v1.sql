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
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_importer_reconciled_action_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_importer_reconciled_next_action_v1(uuid,text,numeric,text,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Importer reconciled pending-approval action patch is not installed.';
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
  -- byte-for-byte equivalent as jsonb to the preserved predecessor.
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
  'proof', 'only importer_next_action may differ from preserved predecessor; target reconciled pending-approval order moves from Resolve evidence issue to No importer action required while importer status and every other audience field remain unchanged; no business-data writes'
) AS regression_result;

ROLLBACK;
