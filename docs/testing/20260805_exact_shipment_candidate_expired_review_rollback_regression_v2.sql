BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE exact_review_bridge_result_v2 (
  inserted_count integer NOT NULL
) ON COMMIT DROP;

INSERT INTO exact_review_bridge_result_v2(inserted_count)
SELECT public.internal_bridge_exact_customer_review_candidates_v1(
  '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
  NULL
);

CREATE TEMP TABLE exact_membership_snapshot_v2 ON COMMIT DROP AS
SELECT
  membership.id,
  membership.review_link_id,
  membership.tracking_line_allocation_id,
  membership.review_qty,
  membership.membership_status,
  membership.receipt_recorded_at,
  link_row.is_active,
  link_row.expires_at
FROM public.customer_review_cycle_memberships membership
JOIN public.customer_order_review_links link_row
  ON link_row.id = membership.review_link_id
WHERE membership.order_id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
  AND membership.tracking_submission_id = 'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid
  AND membership.tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid;

CREATE TEMP TABLE exact_position_snapshot_v2 ON COMMIT DROP AS
SELECT *
FROM public.internal_tracking_allocation_fulfilment_routing_position_v2(
  '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
  'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid,
  NULL
);

CREATE TEMP TABLE exact_candidate_snapshot_v2 ON COMMIT DROP AS
SELECT *
FROM public.internal_shipper_shipment_batch_candidates_v2(
  NULL,
  '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
  'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid
);

WITH protected AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  WHERE p.oid IN (
    'public.customer_review_cycle_candidates_v1(uuid)'::regprocedure,
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure,
    'public.shipper_shipment_batch_candidates_v1()'::regprocedure,
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  )
)
SELECT jsonb_build_object(
  'bridge_inserted_count', (SELECT inserted_count FROM exact_review_bridge_result_v2),
  'exact_membership_rows', COALESCE((
    SELECT jsonb_agg(to_jsonb(exact_membership_snapshot_v2) ORDER BY review_link_id, id)
    FROM exact_membership_snapshot_v2
  ), '[]'::jsonb),
  'position_after', jsonb_build_object(
    'row_count', (SELECT COUNT(*) FROM exact_position_snapshot_v2),
    'completed_review_qty', COALESCE((SELECT SUM(completed_review_qty) FROM exact_position_snapshot_v2), 0),
    'shipment_ready_qty', COALESCE((SELECT SUM(shipment_ready_qty) FROM exact_position_snapshot_v2), 0),
    'diverted_qty', COALESCE((SELECT SUM(diverted_qty) FROM exact_position_snapshot_v2), 0),
    'invalid_row_count', (SELECT COUNT(*) FROM exact_position_snapshot_v2 WHERE NOT position_valid_yn)
  ),
  'candidate_after', COALESCE((
    SELECT jsonb_agg(to_jsonb(exact_candidate_snapshot_v2) ORDER BY order_id, tracking_submission_id)
    FROM exact_candidate_snapshot_v2
  ), '[]'::jsonb),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb),
  'regression_passed',
    (SELECT inserted_count FROM exact_review_bridge_result_v2) = 1
    AND (SELECT COUNT(*) FROM exact_membership_snapshot_v2) = 1
    AND (SELECT COALESCE(SUM(review_qty), 0) FROM exact_membership_snapshot_v2) = 1
    AND (SELECT COUNT(*) FROM exact_membership_snapshot_v2 WHERE expires_at <= now()) = 1
    AND (SELECT COALESCE(SUM(completed_review_qty), 0) FROM exact_position_snapshot_v2) = 1
    AND (SELECT COALESCE(SUM(shipment_ready_qty), 0) FROM exact_position_snapshot_v2) = 1
    AND (SELECT COALESCE(SUM(diverted_qty), 0) FROM exact_position_snapshot_v2) = 4
    AND (SELECT COUNT(*) FROM exact_position_snapshot_v2 WHERE NOT position_valid_yn) = 0
    AND (SELECT COUNT(*) FROM exact_candidate_snapshot_v2) = 1
    AND (SELECT COALESCE(SUM(shipment_ready_qty), 0) FROM exact_candidate_snapshot_v2) = 1
    AND (SELECT COUNT(*) FROM protected) = 4
    AND NOT EXISTS (
      SELECT 1
      FROM protected
      WHERE (identity = 'customer_review_cycle_candidates_v1(uuid)' AND definition_md5 <> '80c5ca83374ed2ddaedeadd3b88dd95d')
         OR (identity = 'internal_materialize_customer_review_cycles_v1(uuid,uuid)' AND definition_md5 <> '0293a94d4eb17daf9c7e48131cd75ca1')
         OR (identity = 'shipper_shipment_batch_candidates_v1()' AND definition_md5 <> '952f24084fed0dffcdebbfae988e7400')
         OR (identity = 'shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamp with time zone,timestamp with time zone,integer,text,text,text)' AND definition_md5 <> '4e4b86b0121a85523fe95c1530a41658')
    )
) AS exact_shipment_candidate_expired_review_rollback_regression;

ROLLBACK;
