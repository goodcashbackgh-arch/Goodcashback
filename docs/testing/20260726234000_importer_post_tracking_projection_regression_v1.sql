-- READ-ONLY platform regression gate for:
-- supabase/migrations/20260726234000_importer_post_tracking_projection_final_v1.sql
--
-- Validates canonical supplier truth and importer projection for every active
-- order. No order-specific branch and no durable writes.

BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_auth_uid uuid;
BEGIN
  IF to_regprocedure('public.internal_platform_order_status_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_platform_order_status_v1()';
  END IF;

  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_supplier_rejection_final_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_pre_supplier_rejection_final_v1(uuid)';
  END IF;

  IF to_regclass('public.order_evidence_queries') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_evidence_queries';
  END IF;

  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY
    CASE
      WHEN s.role_type::text = 'admin' THEN 0
      WHEN s.role_type::text = 'supervisor' THEN 1
      ELSE 2
    END,
    s.created_at
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No active staff auth user available for status proof';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );
END $$;

-- Diagnostic 1: canonical supplier/reconciliation violations.
-- Normal expected result: zero rows.
WITH internal_rows AS (
  SELECT *
  FROM public.internal_platform_order_status_v1()
), invoice_counts AS (
  SELECT
    si.order_id,
    COUNT(*) FILTER (
      WHERE COALESCE(si.is_current_for_order, true) = true
        AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
        AND NOT (
          si.review_status = 'rejected_resubmit_required'
          AND si.rejection_requires_resubmission_yn = false
        )
    )::integer AS active_invoice_count,
    COUNT(*) FILTER (
      WHERE COALESCE(si.is_current_for_order, true) = true
        AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
        AND NOT (
          si.review_status = 'rejected_resubmit_required'
          AND si.rejection_requires_resubmission_yn = false
        )
        AND si.review_status IN ('approved_current', 'ref_corrected_approved')
        AND COALESCE(si.blocked_from_sage_yn, false) = false
    )::integer AS approved_invoice_count,
    COUNT(*) FILTER (
      WHERE COALESCE(si.is_current_for_order, true) = true
        AND si.review_status = 'rejected_resubmit_required'
        AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
    )::integer AS genuine_rejected_count
  FROM public.supplier_invoices si
  GROUP BY si.order_id
), line_counts AS (
  SELECT
    si.order_id,
    COUNT(sil.id)::integer AS active_line_count,
    COUNT(sil.id) FILTER (
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
    )::integer AS unresolved_active_line_count
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE COALESCE(si.is_current_for_order, true) = true
    AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
    AND NOT (
      si.review_status = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn = false
    )
  GROUP BY si.order_id
), expected AS (
  SELECT
    i.*,
    COALESCE(ic.active_invoice_count, 0) AS active_invoice_count,
    COALESCE(ic.approved_invoice_count, 0) AS approved_invoice_count,
    COALESCE(ic.genuine_rejected_count, 0) AS genuine_rejected_count,
    COALESCE(lc.active_line_count, 0) AS active_line_count,
    COALESCE(lc.unresolved_active_line_count, 0) AS unresolved_active_line_count,
    CASE
      WHEN COALESCE(ic.active_invoice_count, 0) = 0 THEN 'missing'
      WHEN COALESCE(ic.genuine_rejected_count, 0) > 0 THEN 'rejected_resubmit_required'
      WHEN COALESCE(ic.approved_invoice_count, 0) = COALESCE(ic.active_invoice_count, 0) THEN 'approved_current'
      ELSE 'review_needed'
    END::text AS expected_supplier_state,
    CASE
      WHEN COALESCE(lc.active_line_count, 0) = 0 THEN 'not_started'
      WHEN COALESCE(lc.unresolved_active_line_count, 0) = 0 THEN 'complete'
      ELSE 'incomplete'
    END::text AS expected_reconciliation_state
  FROM internal_rows i
  LEFT JOIN invoice_counts ic ON ic.order_id = i.order_id
  LEFT JOIN line_counts lc ON lc.order_id = i.order_id
)
SELECT
  e.order_id,
  e.order_ref,
  e.active_invoice_count,
  e.approved_invoice_count,
  e.genuine_rejected_count,
  e.supplier_state,
  e.expected_supplier_state,
  e.active_line_count,
  e.unresolved_active_line_count,
  e.reconciliation_state,
  e.expected_reconciliation_state
FROM expected e
WHERE e.supplier_state IS DISTINCT FROM e.expected_supplier_state
   OR e.reconciliation_state IS DISTINCT FROM e.expected_reconciliation_state
ORDER BY e.order_ref;

-- Diagnostic 2: importer projection violations.
-- Normal expected result: zero rows.
WITH current_rows AS (
  SELECT *
  FROM public.order_audience_status_v1(NULL)
), predecessor_rows AS (
  SELECT *
  FROM public.order_audience_status_pre_supplier_rejection_final_v1(NULL)
), rejection_scope AS (
  SELECT
    si.order_id,
    COUNT(*) FILTER (
      WHERE COALESCE(si.is_current_for_order, true) = true
        AND si.review_status = 'rejected_resubmit_required'
        AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
    )::integer AS genuine_resubmission_required_count
  FROM public.supplier_invoices si
  GROUP BY si.order_id
), query_scope AS (
  SELECT
    q.order_id,
    COUNT(*) FILTER (WHERE q.status = 'open')::integer AS open_query_count
  FROM public.order_evidence_queries q
  GROUP BY q.order_id
), expected AS (
  SELECT
    c.*,
    COALESCE(r.genuine_resubmission_required_count, 0) AS genuine_resubmission_required_count,
    COALESCE(q.open_query_count, 0) AS open_query_count,
    CASE
      WHEN COALESCE(c.canonical_balance_due_gbp, 0) > 0.01 THEN p.importer_status_label
      WHEN COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open' THEN p.importer_status_label
      WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0 THEN 'Evidence attention'
      WHEN COALESCE(q.open_query_count, 0) > 0 THEN 'Evidence query open'
      WHEN c.reconciliation_state = 'incomplete' THEN 'Invoice reconciliation open'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'missing' THEN 'Invoice reconciled; tracking open'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'allocation_incomplete' THEN 'Tracking submitted'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' AND c.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' THEN 'No importer action required'
      ELSE p.importer_status_label
    END::text AS expected_status,
    CASE
      WHEN COALESCE(c.canonical_balance_due_gbp, 0) > 0.01 THEN p.importer_next_action
      WHEN COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open' THEN p.importer_next_action
      WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0 THEN 'Resolve evidence issue'
      WHEN COALESCE(q.open_query_count, 0) > 0 THEN 'Answer query'
      WHEN c.reconciliation_state = 'incomplete' THEN 'Continue invoice reconciliation'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'missing' THEN 'Add tracking'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'allocation_incomplete' THEN 'Assign tracking'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' AND c.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' THEN 'No importer action required'
      ELSE p.importer_next_action
    END::text AS expected_action
  FROM current_rows c
  JOIN predecessor_rows p ON p.order_id = c.order_id
  LEFT JOIN rejection_scope r ON r.order_id = c.order_id
  LEFT JOIN query_scope q ON q.order_id = c.order_id
)
SELECT
  e.order_id,
  e.order_ref,
  e.canonical_balance_due_gbp,
  e.internal_current_stage,
  e.supplier_state,
  e.reconciliation_state,
  e.tracking_state,
  e.pod_delivery_state,
  e.genuine_resubmission_required_count,
  e.open_query_count,
  e.importer_status_label,
  e.expected_status,
  e.importer_next_action,
  e.expected_action,
  e.importer_complete_yn,
  COALESCE(e.expected_action IN ('No importer action required', 'Order complete'), false) AS expected_importer_complete_yn
FROM expected e
WHERE e.importer_status_label IS DISTINCT FROM e.expected_status
   OR e.importer_next_action IS DISTINCT FROM e.expected_action
   OR e.importer_complete_yn IS DISTINCT FROM COALESCE(e.expected_action IN ('No importer action required', 'Order complete'), false)
ORDER BY e.order_ref;

DO $$
DECLARE
  v_supplier_drift integer;
  v_row_identity_drift integer;
  v_projection_drift integer;
  v_passthrough_drift integer;
BEGIN
  WITH internal_rows AS (
    SELECT * FROM public.internal_platform_order_status_v1()
  ), invoice_counts AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
          AND NOT (si.review_status = 'rejected_resubmit_required' AND si.rejection_requires_resubmission_yn = false)
      )::integer AS active_invoice_count,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
          AND NOT (si.review_status = 'rejected_resubmit_required' AND si.rejection_requires_resubmission_yn = false)
          AND si.review_status IN ('approved_current', 'ref_corrected_approved')
          AND COALESCE(si.blocked_from_sage_yn, false) = false
      )::integer AS approved_invoice_count,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND si.review_status = 'rejected_resubmit_required'
          AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
      )::integer AS genuine_rejected_count
    FROM public.supplier_invoices si
    GROUP BY si.order_id
  ), line_counts AS (
    SELECT
      si.order_id,
      COUNT(sil.id)::integer AS active_line_count,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y', 'yes', 'true', '1')
          AND NOT EXISTS (
            SELECT 1 FROM public.supplier_invoice_line_resolutions r
            WHERE r.supplier_invoice_line_id = sil.id
              AND r.supplier_invoice_id = si.id
              AND r.resolution_type = 'non_physical_financial'
              AND r.active = true
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.dispute_lines dl
            JOIN public.disputes d ON d.id = dl.dispute_id
            WHERE dl.supplier_invoice_line_id = sil.id
              AND dl.resolved_at IS NULL
              AND d.resolved_at IS NULL
          )
      )::integer AS unresolved_active_line_count
    FROM public.supplier_invoices si
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    WHERE COALESCE(si.is_current_for_order, true) = true
      AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
      AND NOT (si.review_status = 'rejected_resubmit_required' AND si.rejection_requires_resubmission_yn = false)
    GROUP BY si.order_id
  ), expected AS (
    SELECT
      i.*,
      CASE
        WHEN COALESCE(ic.active_invoice_count, 0) = 0 THEN 'missing'
        WHEN COALESCE(ic.genuine_rejected_count, 0) > 0 THEN 'rejected_resubmit_required'
        WHEN COALESCE(ic.approved_invoice_count, 0) = COALESCE(ic.active_invoice_count, 0) THEN 'approved_current'
        ELSE 'review_needed'
      END::text AS expected_supplier_state,
      CASE
        WHEN COALESCE(lc.active_line_count, 0) = 0 THEN 'not_started'
        WHEN COALESCE(lc.unresolved_active_line_count, 0) = 0 THEN 'complete'
        ELSE 'incomplete'
      END::text AS expected_reconciliation_state
    FROM internal_rows i
    LEFT JOIN invoice_counts ic ON ic.order_id = i.order_id
    LEFT JOIN line_counts lc ON lc.order_id = i.order_id
  )
  SELECT COUNT(*)::integer
  INTO v_supplier_drift
  FROM expected e
  WHERE e.supplier_state IS DISTINCT FROM e.expected_supplier_state
     OR e.reconciliation_state IS DISTINCT FROM e.expected_reconciliation_state;

  IF v_supplier_drift <> 0 THEN
    RAISE EXCEPTION 'Canonical supplier/reconciliation drift detected for % active order(s)', v_supplier_drift;
  END IF;

  WITH current_rows AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
  ), predecessor_rows AS (
    SELECT * FROM public.order_audience_status_pre_supplier_rejection_final_v1(NULL)
  )
  SELECT COUNT(*)::integer
  INTO v_row_identity_drift
  FROM current_rows c
  FULL OUTER JOIN predecessor_rows p ON p.order_id = c.order_id
  WHERE c.order_id IS NULL OR p.order_id IS NULL;

  IF v_row_identity_drift <> 0 THEN
    RAISE EXCEPTION 'Importer projection changed the audience row identity set for % order(s)', v_row_identity_drift;
  END IF;

  WITH current_rows AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
  ), predecessor_rows AS (
    SELECT * FROM public.order_audience_status_pre_supplier_rejection_final_v1(NULL)
  ), rejection_scope AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND si.review_status = 'rejected_resubmit_required'
          AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
      )::integer AS genuine_resubmission_required_count
    FROM public.supplier_invoices si
    GROUP BY si.order_id
  ), query_scope AS (
    SELECT q.order_id, COUNT(*) FILTER (WHERE q.status = 'open')::integer AS open_query_count
    FROM public.order_evidence_queries q
    GROUP BY q.order_id
  ), expected AS (
    SELECT
      c.*,
      CASE
        WHEN COALESCE(c.canonical_balance_due_gbp, 0) > 0.01 THEN p.importer_status_label
        WHEN COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open' THEN p.importer_status_label
        WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0 THEN 'Evidence attention'
        WHEN COALESCE(q.open_query_count, 0) > 0 THEN 'Evidence query open'
        WHEN c.reconciliation_state = 'incomplete' THEN 'Invoice reconciliation open'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'missing' THEN 'Invoice reconciled; tracking open'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'allocation_incomplete' THEN 'Tracking submitted'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' AND c.pod_delivery_state = 'accepted_current' THEN 'Order complete'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' THEN 'No importer action required'
        ELSE p.importer_status_label
      END::text AS expected_status,
      CASE
        WHEN COALESCE(c.canonical_balance_due_gbp, 0) > 0.01 THEN p.importer_next_action
        WHEN COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open' THEN p.importer_next_action
        WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0 THEN 'Resolve evidence issue'
        WHEN COALESCE(q.open_query_count, 0) > 0 THEN 'Answer query'
        WHEN c.reconciliation_state = 'incomplete' THEN 'Continue invoice reconciliation'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'missing' THEN 'Add tracking'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'allocation_incomplete' THEN 'Assign tracking'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' AND c.pod_delivery_state = 'accepted_current' THEN 'Order complete'
        WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' THEN 'No importer action required'
        ELSE p.importer_next_action
      END::text AS expected_action
    FROM current_rows c
    JOIN predecessor_rows p ON p.order_id = c.order_id
    LEFT JOIN rejection_scope r ON r.order_id = c.order_id
    LEFT JOIN query_scope q ON q.order_id = c.order_id
  )
  SELECT COUNT(*)::integer
  INTO v_projection_drift
  FROM expected e
  WHERE e.importer_status_label IS DISTINCT FROM e.expected_status
     OR e.importer_next_action IS DISTINCT FROM e.expected_action
     OR e.importer_complete_yn IS DISTINCT FROM COALESCE(e.expected_action IN ('No importer action required', 'Order complete'), false);

  IF v_projection_drift <> 0 THEN
    RAISE EXCEPTION 'Importer projection drift detected for % active order(s)', v_projection_drift;
  END IF;

  WITH current_rows AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
  ), predecessor_rows AS (
    SELECT * FROM public.order_audience_status_pre_supplier_rejection_final_v1(NULL)
  )
  SELECT COUNT(*)::integer
  INTO v_passthrough_drift
  FROM current_rows c
  JOIN predecessor_rows p ON p.order_id = c.order_id
  WHERE c.customer_complete_yn IS DISTINCT FROM p.customer_complete_yn
     OR c.customer_status_label IS DISTINCT FROM p.customer_status_label
     OR c.customer_next_action IS DISTINCT FROM p.customer_next_action
     OR c.shipper_complete_yn IS DISTINCT FROM p.shipper_complete_yn
     OR c.shipper_status_label IS DISTINCT FROM p.shipper_status_label
     OR c.shipper_next_action IS DISTINCT FROM p.shipper_next_action;

  IF v_passthrough_drift <> 0 THEN
    RAISE EXCEPTION 'Customer/shipper pass-through drift detected for % active order(s)', v_passthrough_drift;
  END IF;
END $$;

SELECT
  COUNT(*)::integer AS active_order_count,
  COUNT(*) FILTER (WHERE supplier_state = 'rejected_resubmit_required')::integer AS genuine_rejection_state_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Answer query')::integer AS open_query_action_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Continue invoice reconciliation')::integer AS reconciliation_action_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Add tracking')::integer AS add_tracking_action_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Assign tracking')::integer AS assign_tracking_action_count,
  COUNT(*) FILTER (WHERE importer_complete_yn)::integer AS importer_complete_count
FROM public.order_audience_status_v1(NULL);

ROLLBACK;
