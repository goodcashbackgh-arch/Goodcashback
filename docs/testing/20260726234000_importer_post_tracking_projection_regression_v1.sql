-- READ ONLY regression proof for:
-- supabase/migrations/20260726234000_importer_post_tracking_projection_final_v1.sql
--
-- Expected target after tracking exists but allocation remains open:
--   reconciliation_state = complete
--   tracking_state = allocation_incomplete
--   importer_status_label = Tracking submitted
--   importer_next_action = Assign tracking
--
-- This script performs no durable writes and rolls back its auth context.

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

  IF to_regprocedure('public.internal_platform_order_status_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_platform_order_status_v1()';
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

-- Result 1: target facts and pass/fail assertions.
WITH target AS (
  SELECT *
  FROM public.order_audience_status_v1('abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid)
), rejection_scope AS (
  SELECT
    COUNT(*) FILTER (
      WHERE COALESCE(si.is_current_for_order, true) = true
        AND si.review_status = 'rejected_resubmit_required'
        AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
    )::integer AS genuine_resubmission_required_count
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
)
SELECT
  t.order_id,
  t.order_ref,
  t.canonical_balance_due_gbp,
  t.internal_current_stage,
  t.supplier_state,
  t.reconciliation_state,
  t.tracking_state,
  t.shipment_state,
  r.genuine_resubmission_required_count,
  t.importer_status_label,
  t.importer_next_action,
  (t.importer_status_label <> 'Evidence attention') AS evidence_status_cleared_yn,
  (t.importer_next_action <> 'Resolve evidence issue') AS evidence_action_cleared_yn,
  CASE
    WHEN COALESCE(t.canonical_balance_due_gbp, 0) > 0.01 THEN
      t.importer_status_label IS NOT NULL
    WHEN COALESCE(t.internal_current_stage, '') = 'exception_or_hold_open' THEN
      t.importer_status_label IS NOT NULL
    WHEN r.genuine_resubmission_required_count > 0 THEN
      t.importer_status_label IN ('Evidence attention', 'Supplier evidence rejected')
    WHEN t.reconciliation_state = 'incomplete' THEN
      t.importer_status_label = 'Invoice reconciliation open'
      AND t.importer_next_action = 'Continue invoice reconciliation'
    WHEN t.reconciliation_state = 'complete' AND t.tracking_state = 'missing' THEN
      t.importer_status_label = 'Invoice reconciled; tracking open'
      AND t.importer_next_action = 'Add tracking'
    WHEN t.reconciliation_state = 'complete' AND t.tracking_state = 'allocation_incomplete' THEN
      t.importer_status_label = 'Tracking submitted'
      AND t.importer_next_action = 'Assign tracking'
    WHEN t.reconciliation_state = 'complete' AND t.tracking_state = 'submitted' AND t.pod_delivery_state = 'accepted_current' THEN
      t.importer_status_label = 'Order complete'
      AND t.importer_next_action = 'Order complete'
    WHEN t.reconciliation_state = 'complete' AND t.tracking_state = 'submitted' THEN
      t.importer_status_label = 'No importer action required'
      AND t.importer_next_action = 'No importer action required'
    ELSE true
  END AS target_projection_pass_yn
FROM target t
CROSS JOIN rejection_scope r;

-- Result 2: all active orders that violate the governed importer projection.
WITH audience AS (
  SELECT *
  FROM public.order_audience_status_v1(NULL)
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
), evaluated AS (
  SELECT
    a.*,
    COALESCE(r.genuine_resubmission_required_count, 0) AS genuine_resubmission_required_count,
    CASE
      WHEN COALESCE(a.canonical_balance_due_gbp, 0) > 0.01 THEN true
      WHEN COALESCE(a.internal_current_stage, '') = 'exception_or_hold_open' THEN true
      WHEN COALESCE(r.genuine_resubmission_required_count, 0) > 0 THEN true
      WHEN a.reconciliation_state = 'incomplete' THEN
        a.importer_status_label = 'Invoice reconciliation open'
        AND a.importer_next_action = 'Continue invoice reconciliation'
      WHEN a.reconciliation_state = 'complete' AND a.tracking_state = 'missing' THEN
        a.importer_status_label = 'Invoice reconciled; tracking open'
        AND a.importer_next_action = 'Add tracking'
      WHEN a.reconciliation_state = 'complete' AND a.tracking_state = 'allocation_incomplete' THEN
        a.importer_status_label = 'Tracking submitted'
        AND a.importer_next_action = 'Assign tracking'
      WHEN a.reconciliation_state = 'complete' AND a.tracking_state = 'submitted' AND a.pod_delivery_state = 'accepted_current' THEN
        a.importer_status_label = 'Order complete'
        AND a.importer_next_action = 'Order complete'
      WHEN a.reconciliation_state = 'complete' AND a.tracking_state = 'submitted' THEN
        a.importer_status_label = 'No importer action required'
        AND a.importer_next_action = 'No importer action required'
      ELSE true
    END AS projection_pass_yn
  FROM audience a
  LEFT JOIN rejection_scope r ON r.order_id = a.order_id
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
  e.importer_status_label,
  e.importer_next_action
FROM evaluated e
WHERE NOT e.projection_pass_yn
ORDER BY e.order_ref;

-- Result 3: customer and shipper pass-through comparison against the preserved
-- audience-safe predecessor. Normal expected result: zero rows.
WITH current_rows AS (
  SELECT *
  FROM public.order_audience_status_v1(NULL)
), predecessor_rows AS (
  SELECT *
  FROM public.order_audience_status_pre_supplier_rejection_final_v1(NULL)
)
SELECT
  c.order_id,
  c.order_ref,
  p.customer_status_label AS predecessor_customer_status_label,
  c.customer_status_label AS current_customer_status_label,
  p.customer_next_action AS predecessor_customer_next_action,
  c.customer_next_action AS current_customer_next_action,
  p.shipper_status_label AS predecessor_shipper_status_label,
  c.shipper_status_label AS current_shipper_status_label,
  p.shipper_next_action AS predecessor_shipper_next_action,
  c.shipper_next_action AS current_shipper_next_action
FROM current_rows c
JOIN predecessor_rows p ON p.order_id = c.order_id
WHERE c.customer_status_label IS DISTINCT FROM p.customer_status_label
   OR c.customer_next_action IS DISTINCT FROM p.customer_next_action
   OR c.shipper_status_label IS DISTINCT FROM p.shipper_status_label
   OR c.shipper_next_action IS DISTINCT FROM p.shipper_next_action
ORDER BY c.order_ref;

ROLLBACK;
