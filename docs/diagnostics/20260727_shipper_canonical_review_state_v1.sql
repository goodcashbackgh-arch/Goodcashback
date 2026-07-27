-- SQL Editor-compatible, read-only diagnostic for the shipper canonical review gate.
WITH controlled_packages AS (
  SELECT o.id AS order_id, o.order_ref, ots.id AS tracking_submission_id, ots.tracking_ref
  FROM public.orders o
  JOIN public.order_tracking_submissions ots ON ots.order_id = o.id
  WHERE o.order_ref = 'ORD-1784976429191'
    AND ots.tracking_ref IN ('DPD240726', 'DHL240726A')
), canonical_state AS (
  SELECT
    package.*,
    link_row.id AS review_link_id,
    link_row.expires_at AS review_expires_at,
    EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = link_row.id
        AND membership.order_id = package.order_id
        AND membership.tracking_submission_id = package.tracking_submission_id
        AND membership.membership_status = 'active'
    ) AS has_active_exact_membership
  FROM controlled_packages package
  LEFT JOIN LATERAL (
    SELECT review_link.id, review_link.expires_at
    FROM public.customer_order_review_links review_link
    WHERE review_link.order_id = package.order_id
      AND review_link.is_active = true
      AND review_link.expires_at IS NOT NULL
      AND review_link.expires_at > now()
      AND EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships membership
        WHERE membership.review_link_id = review_link.id
          AND membership.order_id = package.order_id
          AND membership.tracking_submission_id = package.tracking_submission_id
          AND membership.membership_status = 'active'
      )
    ORDER BY review_link.expires_at, review_link.id
    LIMIT 1
  ) link_row ON true
)
SELECT
  state.order_ref,
  state.tracking_ref,
  (state.review_link_id IS NOT NULL) AS active_review_yn,
  state.review_link_id,
  state.review_expires_at,
  state.has_active_exact_membership,
  latest_receipt.receipt_status AS latest_receipt_status,
  latest_receipt.recorded_at AS latest_receipt_recorded_at,
  EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_packages package_membership
    WHERE package_membership.tracking_submission_id = state.tracking_submission_id
      AND package_membership.active = true
  ) AS in_active_shipment_yn,
  EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = state.order_id
      AND allocation.tracking_submission_id = state.tracking_submission_id
      AND allocation.qty_allocated > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        allocation.order_id,
        allocation.tracking_submission_id,
        allocation.supplier_invoice_line_id
      ) = true
  ) AS active_hold_conflict_yn
FROM canonical_state state
LEFT JOIN LATERAL (
  SELECT receipt.receipt_status, receipt.recorded_at
  FROM public.shipper_package_receipts receipt
  WHERE receipt.tracking_submission_id = state.tracking_submission_id
  ORDER BY receipt.created_at DESC, receipt.id DESC
  LIMIT 1
) latest_receipt ON true
ORDER BY state.tracking_ref;

-- Exact deployed definitions and grants; this result set makes drift visible.
SELECT
  procedure.oid::regprocedure::text AS function_identity,
  pg_get_functiondef(procedure.oid) AS function_definition,
  proacl AS grants
FROM pg_proc procedure
JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
WHERE namespace.nspname = 'public'
  AND procedure.proname IN (
    'shipper_tracking_review_state_v1',
    'shipper_dashboard_tracking_review_states_v1',
    'customer_tracking_review_deadline_v1',
    'shipper_shipment_batch_candidates_v1',
    'shipper_create_shipment_batch_v1',
    'shipper_package_receipt_dashboard_v1'
  )
ORDER BY procedure.proname, procedure.oid::regprocedure::text;
