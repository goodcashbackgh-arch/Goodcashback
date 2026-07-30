BEGIN TRANSACTION READ ONLY;

DO $$
DECLARE
  v_definition text;
  v_candidate uuid;
  v_staff_uid uuid;
  v_target_id uuid;
  v_target_action text;
  v_target_status text;
  v_target_supplier_state text;
  v_target_reconciliation_state text;
  v_target_balance numeric;
  v_target_stage text;
  v_open_query_count integer;
  v_open_flag_count integer;
  v_genuine_resubmission_count integer;
  v_unresolved_line_count integer;
  v_missing_confirmation_count integer;
  v_physical_line_count integer;
  v_active_tracking_count integer;
  v_unassigned_physical_count integer;
  v_bad_live_assignment_count integer;
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  -- The clean implementation must not introduce the abandoned rename/helper architecture.
  IF to_regprocedure('public.order_audience_status_pre_importer_reconciled_action_v1(uuid)') IS NOT NULL
     OR to_regprocedure('public.internal_importer_pending_approval_action_v1(uuid,text,text,text,numeric,text)') IS NOT NULL
     OR to_regprocedure('public.internal_importer_reconciled_next_action_v1(uuid,text,numeric,text,text)') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Scope drift: abandoned predecessor/helper function still exists.';
  END IF;

  SELECT lower(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g'))
  INTO v_definition
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_v1(uuid)'::regprocedure;

  -- Existing 30 July projection mappings must remain present.
  IF position('from public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)' IN v_definition) = 0
     OR position('p.corrected_balance_due_gbp::numeric as canonical_balance_due_gbp' IN v_definition) = 0
     OR position('p.corrected_customer_status_label as customer_status_label' IN v_definition) = 0
     OR position('p.corrected_customer_next_action as customer_next_action' IN v_definition) = 0
     OR position('p.corrected_importer_status_label as importer_status_label' IN v_definition) = 0
     OR position('p.shipper_status_label' IN v_definition) = 0
     OR position('p.shipper_next_action' IN v_definition) = 0
     OR position('when p.tracking_assignment_needed then ''assign tracking''' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'Scope drift: an existing 30 July audience projection mapping is missing.';
  END IF;

  -- Exact correction boundary and addendum blockers must be encoded in the final action only.
  IF position('p.supplier_state = ''review_needed''' IN v_definition) = 0
     OR position('p.reconciliation_state = ''complete''' IN v_definition) = 0
     OR position('p.corrected_importer_next_action = ''resolve evidence issue''' IN v_definition) = 0
     OR position('coalesce(p.corrected_balance_due_gbp, 0) <= 0.01' IN v_definition) = 0
     OR position('coalesce(p.internal_current_stage, '''') <> ''exception_or_hold_open''' IN v_definition) = 0
     OR position('p.pod_delivery_state is distinct from ''accepted_current''' IN v_definition) = 0
     OR position('p.pending_review_invoice_count > 0' IN v_definition) = 0
     OR position('p.genuine_resubmission_count = 0' IN v_definition) = 0
     OR position('p.open_query_count = 0' IN v_definition) = 0
     OR position('p.open_review_flag_count = 0' IN v_definition) = 0
     OR position('p.importer_unresolved_line_count = 0' IN v_definition) = 0
     OR position('p.importer_missing_confirmation_count = 0' IN v_definition) = 0
     OR position('p.importer_progressed_physical_line_count > 0' IN v_definition) = 0
     OR position('when p.active_tracking_count = 0 then ''add tracking''' IN v_definition) = 0
     OR position('when p.importer_unassigned_physical_line_count > 0 then ''assign tracking''' IN v_definition) = 0
     OR position('else ''no importer action required''' IN v_definition) = 0
     OR position('else p.corrected_importer_next_action' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'Addendum contract drift: narrow importer-next-action gate or blocker guard is missing.';
  END IF;

  -- is_current_for_order may remain in the pre-existing approved-current tracking scope
  -- and in the genuine-resubmission test, but must not gate importer reconciliation lines.
  IF position('where si.review_status in (''pending_review'', ''approved_current'', ''ref_corrected_approved'') and lower(coalesce(sil.eligible_for_invoice_yn::text, ''''))' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Compatibility drift: pending-review importer line scope is missing or no longer independent of is_current_for_order.';
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

  SELECT o.id
  INTO v_target_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785414534454'
  LIMIT 1;

  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'Acceptance fixture ORD-1785414534454 is missing.';
  END IF;

  SELECT
    a.importer_next_action,
    a.importer_status_label,
    a.supplier_state,
    a.reconciliation_state,
    a.canonical_balance_due_gbp,
    a.internal_current_stage
  INTO
    v_target_action,
    v_target_status,
    v_target_supplier_state,
    v_target_reconciliation_state,
    v_target_balance,
    v_target_stage
  FROM public.order_audience_status_v1(v_target_id) a;

  IF v_target_supplier_state IS DISTINCT FROM 'review_needed'
     OR v_target_reconciliation_state IS DISTINCT FROM 'complete'
     OR COALESCE(v_target_balance, 0) > 0.01
     OR COALESCE(v_target_stage, '') = 'exception_or_hold_open'
  THEN
    RAISE EXCEPTION 'Acceptance fixture baseline facts drifted.';
  END IF;

  IF v_target_status IS DISTINCT FROM 'Tracking submitted' THEN
    RAISE EXCEPTION 'Scope drift: target importer status changed to %, expected Tracking submitted.', v_target_status;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_open_query_count
  FROM public.order_evidence_queries q
  WHERE q.order_id = v_target_id
    AND q.status = 'open';

  SELECT COUNT(*)::integer
  INTO v_open_flag_count
  FROM public.supplier_invoice_review_flags f
  JOIN public.supplier_invoices si ON si.id = f.supplier_invoice_id
  WHERE si.order_id = v_target_id
    AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
    AND f.status IN ('open', 'under_review');

  SELECT COUNT(*)::integer
  INTO v_genuine_resubmission_count
  FROM public.supplier_invoices si
  WHERE si.order_id = v_target_id
    AND si.review_status = 'rejected_resubmit_required'
    AND COALESCE(si.is_current_for_order, true) = true
    AND COALESCE(si.rejection_requires_resubmission_yn, true) = true;

  SELECT
    COUNT(*) FILTER (
      WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
    )::integer,
    COUNT(*) FILTER (
      WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
        AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL)
    )::integer,
    COUNT(*) FILTER (
      WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y', 'yes', 'true', '1')
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
    )::integer
  INTO v_physical_line_count, v_missing_confirmation_count, v_unresolved_line_count
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE si.order_id = v_target_id
    AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved');

  SELECT COUNT(*)::integer
  INTO v_active_tracking_count
  FROM public.order_tracking_submissions ots
  WHERE ots.order_id = v_target_id
    AND ots.superseded_at IS NULL;

  WITH physical_position AS (
    SELECT
      sil.id,
      GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0)::numeric AS required_qty,
      COALESCE(SUM(otla.qty_allocated) FILTER (WHERE ats.id IS NOT NULL), 0)::numeric AS active_tracking_allocated_qty
    FROM public.supplier_invoices si
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = si.order_id
     AND otla.supplier_invoice_line_id = sil.id
     AND otla.tracking_submission_id IS NOT NULL
    LEFT JOIN public.order_tracking_submissions ats
      ON ats.id = otla.tracking_submission_id
     AND ats.order_id = si.order_id
     AND ats.superseded_at IS NULL
    WHERE si.order_id = v_target_id
      AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
    GROUP BY sil.id, sil.qty_confirmed, sil.qty
  )
  SELECT COUNT(*) FILTER (
    WHERE required_qty > 0
      AND active_tracking_allocated_qty + 0.0005 < required_qty
  )::integer
  INTO v_unassigned_physical_count
  FROM physical_position;

  IF v_open_query_count <> 0
     OR v_open_flag_count <> 0
     OR v_genuine_resubmission_count <> 0
     OR v_unresolved_line_count <> 0
     OR v_missing_confirmation_count <> 0
     OR v_physical_line_count <> 4
     OR v_active_tracking_count <= 0
     OR v_unassigned_physical_count <> 0
  THEN
    RAISE EXCEPTION 'Acceptance fixture no longer matches the proven blocker-free, fully-assigned case.';
  END IF;

  IF v_target_action IS DISTINCT FROM 'No importer action required' THEN
    RAISE EXCEPTION 'Target projection failed: action is %, expected No importer action required.', v_target_action;
  END IF;

  -- For every live row that currently satisfies the addendum's partially-assigned case,
  -- the public action must be Assign tracking. If the environment has no such row, the
  -- structural branch assertion above still protects the shipped SQL path.
  WITH audience AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
  ), candidates AS (
    SELECT a.order_id
    FROM audience a
    WHERE a.supplier_state = 'review_needed'
      AND a.reconciliation_state = 'complete'
      AND COALESCE(a.canonical_balance_due_gbp, 0) <= 0.01
      AND COALESCE(a.internal_current_stage, '') <> 'exception_or_hold_open'
      AND a.pod_delivery_state IS DISTINCT FROM 'accepted_current'
      AND EXISTS (
        SELECT 1 FROM public.supplier_invoices si
        WHERE si.order_id = a.order_id AND si.review_status = 'pending_review'
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.order_evidence_queries q
        WHERE q.order_id = a.order_id AND q.status = 'open'
      )
      AND EXISTS (
        SELECT 1
        FROM public.order_tracking_submissions ots
        WHERE ots.order_id = a.order_id AND ots.superseded_at IS NULL
      )
      AND EXISTS (
        SELECT 1
        FROM public.supplier_invoices si
        JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
        LEFT JOIN public.order_tracking_line_allocations otla
          ON otla.order_id = si.order_id
         AND otla.supplier_invoice_line_id = sil.id
         AND otla.tracking_submission_id IS NOT NULL
        LEFT JOIN public.order_tracking_submissions ats
          ON ats.id = otla.tracking_submission_id
         AND ats.order_id = si.order_id
         AND ats.superseded_at IS NULL
        WHERE si.order_id = a.order_id
          AND si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
          AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
        GROUP BY sil.id, sil.qty_confirmed, sil.qty
        HAVING GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0) > 0
           AND COALESCE(SUM(otla.qty_allocated) FILTER (WHERE ats.id IS NOT NULL), 0) + 0.0005
               < GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0)
      )
  )
  SELECT COUNT(*)::integer
  INTO v_bad_live_assignment_count
  FROM candidates c
  JOIN audience a ON a.order_id = c.order_id
  WHERE a.importer_next_action IS DISTINCT FROM 'Assign tracking';

  IF v_bad_live_assignment_count <> 0 THEN
    RAISE EXCEPTION 'Live partial-assignment regression failed for % row(s).', v_bad_live_assignment_count;
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'in-place function only; no helper/predecessor; existing projection mappings preserved; exact addendum gate present; target stays Tracking submitted and changes only stale importer action to No importer action required; live partial-assignment rows, when present, resolve to Assign tracking'
) AS regression_result;

ROLLBACK;
