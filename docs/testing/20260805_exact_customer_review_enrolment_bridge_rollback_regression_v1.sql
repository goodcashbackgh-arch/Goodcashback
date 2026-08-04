BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Rollback-only regression for the exact customer-review enrolment bridge.
-- Proves the clean allocation is enrolled exactly once into the existing Mini Build 4 tables.
-- All writes are rolled back.

WITH before_state AS (
  SELECT
    COUNT(*)::integer AS membership_count,
    COALESCE(SUM(m.review_qty),0)::numeric AS review_qty
  FROM public.customer_review_cycle_memberships m
  WHERE m.order_id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
    AND m.tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
), bridge_call AS (
  SELECT public.internal_bridge_exact_customer_review_candidates_v1(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    NULL
  ) AS inserted_count
), bridge_call_again AS (
  SELECT public.internal_bridge_exact_customer_review_candidates_v1(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    NULL
  ) AS inserted_count
), after_state AS (
  SELECT
    COUNT(*)::integer AS membership_count,
    COALESCE(SUM(m.review_qty),0)::numeric AS review_qty,
    COUNT(DISTINCT m.tracking_line_allocation_id)::integer AS distinct_allocation_count,
    BOOL_AND(m.tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid) AS clean_allocation_only,
    BOOL_AND(m.review_qty = 1) AS exact_qty_only,
    BOOL_AND(m.receipt_recorded_at = '2026-08-04T01:02:36.449728+00:00'::timestamptz) AS exact_receipt_anchor
  FROM public.customer_review_cycle_memberships m
  WHERE m.order_id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
    AND m.tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
), review_state_after AS (
  SELECT s.*
  FROM public.internal_tracking_allocation_review_state_v2(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid,
    '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
  ) s
), protected AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  WHERE p.oid IN (
    'public.customer_review_cycle_candidates_v1(uuid)'::regprocedure,
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure,
    'public.customer_review_cycle_component_guard_v1()'::regprocedure,
    'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure,
    'public.shipper_shipment_batch_candidates_v1()'::regprocedure,
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  )
)
SELECT jsonb_build_object(
  'before_state', (SELECT to_jsonb(before_state) FROM before_state),
  'first_bridge_inserted_count', (SELECT inserted_count FROM bridge_call),
  'second_bridge_inserted_count', (SELECT inserted_count FROM bridge_call_again),
  'after_state', (SELECT to_jsonb(after_state) FROM after_state),
  'review_state_after', (SELECT to_jsonb(review_state_after) FROM review_state_after),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb),
  'regression_passed', (
    SELECT
      (SELECT inserted_count FROM bridge_call) = 1
      AND (SELECT inserted_count FROM bridge_call_again) = 0
      AND after_state.membership_count = before_state.membership_count + 1
      AND after_state.review_qty = before_state.review_qty + 1
      AND after_state.distinct_allocation_count = 1
      AND after_state.clean_allocation_only
      AND after_state.exact_qty_only
      AND after_state.exact_receipt_anchor
      AND review_state_after.review_state IN ('active','completed')
      AND review_state_after.review_enrolled_qty = 1
      AND review_state_after.review_available_qty = 0
    FROM before_state, after_state, review_state_after
  )
) AS exact_customer_review_enrolment_bridge_rollback_regression;

ROLLBACK;
