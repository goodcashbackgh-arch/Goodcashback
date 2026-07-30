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
  v_blocker_change_count integer;
  v_target_open_query_count integer;
  v_target_open_flag_count integer;
  v_target_unresolved_line_count integer;
  v_target_missing_confirmation_count integer;
  v_target_evidence_action_invoice_count integer;
  v_target_exception_or_hold boolean;
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_importer_reconciled_action_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_importer_pending_approval_action_v1(uuid,text,text,text,numeric,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Importer reconciled pending-approval action patch is not installed.';
  END IF;

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

  -- Every field except importer_next_action must be identical to the preserved predecessor.
  WITH old_rows AS (
    SELECT * FROM public.order_audience_status_pre_importer_reconciled_action_v1(NULL)
  ), new_rows AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
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

  -- Any changed importer action must be inside the exact agreed predecessor boundary.
  WITH old_rows AS (
    SELECT * FROM public.order_audience_status_pre_importer_reconciled_action_v1(NULL)
  ), new_rows AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
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

  -- Explicit fail-closed proof against the real wrapper. No changed row may have any
  -- blocker named by the addendum: exception/hold, open query, open review flag,
  -- needs_action/current genuine resubmission, unresolved line, or missing confirmation.
  WITH old_rows AS (
    SELECT * FROM public.order_audience_status_pre_importer_reconciled_action_v1(NULL)
  ), new_rows AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
  ), changed AS (
    SELECT o.*
    FROM old_rows o
    JOIN new_rows n USING (order_id)
    WHERE n.importer_next_action IS DISTINCT FROM o.importer_next_action
  )
  SELECT COUNT(*)::integer
  INTO v_blocker_change_count
  FROM changed c
  WHERE COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open'
     OR EXISTS (
       SELECT 1
       FROM public.order_evidence_queries q
       WHERE q.order_id = c.order_id
         AND q.status = 'open'
     )
     OR EXISTS (
       SELECT 1
       FROM public.supplier_invoice_review_flags f
       JOIN public.supplier_invoices si ON si.id = f.supplier_invoice_id
       WHERE si.order_id = c.order_id
         AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
         AND f.status IN ('open', 'under_review')
     )
     OR EXISTS (
       SELECT 1
       FROM public.supplier_invoices si
       WHERE si.order_id = c.order_id
         AND (
           si.review_status = 'needs_action'
           OR (
             si.review_status = 'rejected_resubmit_required'
             AND COALESCE(si.is_current_for_order, true) = true
             AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
           )
         )
     )
     OR EXISTS (
       SELECT 1
       FROM public.supplier_invoices si
       JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
       WHERE si.order_id = c.order_id
         AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
         AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y', 'yes', 'true', '1')
         AND NOT EXISTS (
           SELECT 1
           FROM public.supplier_invoice_line_resolutions r
           WHERE r.supplier_invoice_line_id = sil.id
             AND r.supplier_invoice_id = si.id
             AND r.resolution_type = 'non_physical_financial'
             AND r.active = true
         )
         AND NOT EXISTS (
           SELECT 1
           FROM public.dispute_lines dl
           JOIN public.disputes d ON d.id = dl.dispute_id
           WHERE dl.supplier_invoice_line_id = sil.id
             AND dl.resolved_at IS NULL
             AND d.resolved_at IS NULL
         )
     )
     OR EXISTS (
       SELECT 1
       FROM public.supplier_invoices si
       JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
       WHERE si.order_id = c.order_id
         AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
         AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
         AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL)
     );

  IF v_blocker_change_count <> 0 THEN
    RAISE EXCEPTION 'Blocker regression failed: % changed audience row(s) still have an addendum-defined importer blocker.', v_blocker_change_count;
  END IF;

  -- Production acceptance fixture.
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

  -- Explicit acceptance proof for the diagnosed fixture.
  SELECT COUNT(*)::integer
  INTO v_target_open_query_count
  FROM public.order_evidence_queries q
  WHERE q.order_id = v_target_id
    AND q.status = 'open';

  SELECT COUNT(*)::integer
  INTO v_target_open_flag_count
  FROM public.supplier_invoice_review_flags f
  JOIN public.supplier_invoices si ON si.id = f.supplier_invoice_id
  WHERE si.order_id = v_target_id
    AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
    AND f.status IN ('open', 'under_review');

  SELECT COUNT(*)::integer
  INTO v_target_evidence_action_invoice_count
  FROM public.supplier_invoices si
  WHERE si.order_id = v_target_id
    AND (
      si.review_status = 'needs_action'
      OR (
        si.review_status = 'rejected_resubmit_required'
        AND COALESCE(si.is_current_for_order, true) = true
        AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
      )
    );

  SELECT COUNT(*)::integer
  INTO v_target_unresolved_line_count
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE si.order_id = v_target_id
    AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
    AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y', 'yes', 'true', '1')
    AND NOT EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_line_id = sil.id
        AND r.supplier_invoice_id = si.id
        AND r.resolution_type = 'non_physical_financial'
        AND r.active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.dispute_lines dl
      JOIN public.disputes d ON d.id = dl.dispute_id
      WHERE dl.supplier_invoice_line_id = sil.id
        AND dl.resolved_at IS NULL
        AND d.resolved_at IS NULL
    );

  SELECT COUNT(*)::integer
  INTO v_target_missing_confirmation_count
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE si.order_id = v_target_id
    AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
    AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
    AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL);

  SELECT COALESCE(a.internal_current_stage, '') = 'exception_or_hold_open'
  INTO v_target_exception_or_hold
  FROM public.order_audience_status_pre_importer_reconciled_action_v1(v_target_id) a;

  IF v_target_open_query_count <> 0 THEN
    RAISE EXCEPTION 'Blocker regression failed: target has % open evidence query/queryies.', v_target_open_query_count;
  END IF;
  IF v_target_open_flag_count <> 0 THEN
    RAISE EXCEPTION 'Blocker regression failed: target has % open/under-review invoice flag(s).', v_target_open_flag_count;
  END IF;
  IF v_target_evidence_action_invoice_count <> 0 THEN
    RAISE EXCEPTION 'Blocker regression failed: target has % genuine evidence-action invoice(s).', v_target_evidence_action_invoice_count;
  END IF;
  IF v_target_unresolved_line_count <> 0 THEN
    RAISE EXCEPTION 'Blocker regression failed: target has % unresolved invoice line(s).', v_target_unresolved_line_count;
  END IF;
  IF v_target_missing_confirmation_count <> 0 THEN
    RAISE EXCEPTION 'Blocker regression failed: target has % progressed physical line(s) missing confirmed qty/value.', v_target_missing_confirmation_count;
  END IF;
  IF v_target_exception_or_hold THEN
    RAISE EXCEPTION 'Blocker regression failed: target predecessor is in exception/hold.';
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'read-only regression; all non-action audience fields unchanged; every changed importer action constrained to exact predecessor boundary; real wrapper proves addendum blockers fail closed; diagnosed target has no blocker and changes only importer_next_action from Resolve evidence issue to No importer action required'
) AS regression_result;

ROLLBACK;
