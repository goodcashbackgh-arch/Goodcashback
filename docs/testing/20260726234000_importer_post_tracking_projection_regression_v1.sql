-- READ-ONLY platform regression gate for:
-- supabase/migrations/20260726234000_importer_post_tracking_projection_final_v1.sql
--
-- This test validates every row returned by order_audience_status_v1(NULL).
-- It contains no order-specific branch and performs no durable writes.

BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_auth_uid uuid;
BEGIN
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

-- Diagnostic result: normal expected result is zero rows.
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
    p.importer_status_label AS predecessor_importer_status_label,
    p.importer_next_action AS predecessor_importer_next_action,
    COALESCE(r.genuine_resubmission_required_count, 0) AS genuine_resubmission_required_count,
    COALESCE(q.open_query_count, 0) AS open_query_count,
    CASE
      WHEN COALESCE(c.canonical_balance_due_gbp, 0) > 0.01
        THEN p.importer_status_label
      WHEN COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open'
        THEN p.importer_status_label
      WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0
        THEN p.importer_status_label
      WHEN COALESCE(q.open_query_count, 0) > 0
        THEN 'Evidence query open'
      WHEN c.reconciliation_state = 'incomplete'
        THEN 'Invoice reconciliation open'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'missing'
        THEN 'Invoice reconciled; tracking open'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'allocation_incomplete'
        THEN 'Tracking submitted'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' AND c.pod_delivery_state = 'accepted_current'
        THEN 'Order complete'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted'
        THEN 'No importer action required'
      ELSE p.importer_status_label
    END::text AS expected_importer_status_label,
    CASE
      WHEN COALESCE(c.canonical_balance_due_gbp, 0) > 0.01
        THEN p.importer_next_action
      WHEN COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open'
        THEN p.importer_next_action
      WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0
        THEN p.importer_next_action
      WHEN COALESCE(q.open_query_count, 0) > 0
        THEN 'Answer query'
      WHEN c.reconciliation_state = 'incomplete'
        THEN 'Continue invoice reconciliation'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'missing'
        THEN 'Add tracking'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'allocation_incomplete'
        THEN 'Assign tracking'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted' AND c.pod_delivery_state = 'accepted_current'
        THEN 'Order complete'
      WHEN c.reconciliation_state = 'complete' AND c.tracking_state = 'submitted'
        THEN 'No importer action required'
      ELSE p.importer_next_action
    END::text AS expected_importer_next_action
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
  e.expected_importer_status_label,
  e.importer_next_action,
  e.expected_importer_next_action,
  e.importer_complete_yn,
  e.expected_importer_next_action IN ('No importer action required', 'Order complete') AS expected_importer_complete_yn
FROM expected e
WHERE e.importer_status_label IS DISTINCT FROM e.expected_importer_status_label
   OR e.importer_next_action IS DISTINCT FROM e.expected_importer_next_action
   OR e.importer_complete_yn IS DISTINCT FROM (e.expected_importer_next_action IN ('No importer action required', 'Order complete'))
ORDER BY e.order_ref;

DO $$
DECLARE
  v_row_count_drift integer;
  v_projection_drift integer;
  v_audience_passthrough_drift integer;
BEGIN
  SELECT ABS(
    (SELECT COUNT(*) FROM public.order_audience_status_v1(NULL))
    -
    (SELECT COUNT(*) FROM public.order_audience_status_pre_supplier_rejection_final_v1(NULL))
  )::integer
  INTO v_row_count_drift;

  IF v_row_count_drift <> 0 THEN
    RAISE EXCEPTION 'Importer projection changed the audience row count';
  END IF;

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
      CASE
        WHEN COALESCE(c.canonical_balance_due_gbp, 0) > 0.01 THEN p.importer_status_label
        WHEN COALESCE(c.internal_current_stage, '') = 'exception_or_hold_open' THEN p.importer_status_label
        WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0 THEN p.importer_status_label
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
        WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0 THEN p.importer_next_action
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
     OR e.importer_complete_yn IS DISTINCT FROM (e.expected_action IN ('No importer action required', 'Order complete'));

  IF v_projection_drift <> 0 THEN
    RAISE EXCEPTION 'Importer projection drift detected for % active order(s)', v_projection_drift;
  END IF;

  WITH current_rows AS (
    SELECT *
    FROM public.order_audience_status_v1(NULL)
  ), predecessor_rows AS (
    SELECT *
    FROM public.order_audience_status_pre_supplier_rejection_final_v1(NULL)
  )
  SELECT COUNT(*)::integer
  INTO v_audience_passthrough_drift
  FROM current_rows c
  JOIN predecessor_rows p ON p.order_id = c.order_id
  WHERE c.customer_status_label IS DISTINCT FROM p.customer_status_label
     OR c.customer_next_action IS DISTINCT FROM p.customer_next_action
     OR c.shipper_status_label IS DISTINCT FROM p.shipper_status_label
     OR c.shipper_next_action IS DISTINCT FROM p.shipper_next_action;

  IF v_audience_passthrough_drift <> 0 THEN
    RAISE EXCEPTION 'Customer/shipper pass-through drift detected for % active order(s)', v_audience_passthrough_drift;
  END IF;
END $$;

SELECT
  COUNT(*)::integer AS active_order_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Answer query')::integer AS open_query_action_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Continue invoice reconciliation')::integer AS reconciliation_action_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Add tracking')::integer AS add_tracking_action_count,
  COUNT(*) FILTER (WHERE importer_next_action = 'Assign tracking')::integer AS assign_tracking_action_count,
  COUNT(*) FILTER (WHERE importer_next_action IN ('No importer action required', 'Order complete'))::integer AS importer_complete_count
FROM public.order_audience_status_v1(NULL);

ROLLBACK;
