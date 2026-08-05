-- Read-only postflight for internal_tracking_allocation_review_state_v2.
-- No writes.

WITH contract AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.provolatile AS volatility,
    p.proconfig,
    p.proacl AS acl
  FROM pg_proc p
  WHERE p.oid = 'public.internal_tracking_allocation_review_state_v2(uuid,uuid,uuid)'::regprocedure
), fixture AS (
  SELECT s.*
  FROM public.internal_tracking_allocation_review_state_v2(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid,
    NULL
  ) s
), protected AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.proacl AS acl
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
  'review_state_present', EXISTS (SELECT 1 FROM contract),
  'contract', (SELECT to_jsonb(contract) FROM contract),
  'fixture_rows', COALESCE((
    SELECT jsonb_agg(to_jsonb(fixture) ORDER BY tracking_line_allocation_id)
    FROM fixture
  ), '[]'::jsonb),
  'fixture_summary', jsonb_build_object(
    'row_count', (SELECT COUNT(*) FROM fixture),
    'not_enrolled_count', (SELECT COUNT(*) FROM fixture WHERE review_state = 'not_enrolled'),
    'not_applicable_count', (SELECT COUNT(*) FROM fixture WHERE review_state = 'not_applicable'),
    'active_count', (SELECT COUNT(*) FROM fixture WHERE review_state = 'active'),
    'completed_count', (SELECT COUNT(*) FROM fixture WHERE review_state = 'completed'),
    'blocked_count', (SELECT COUNT(*) FROM fixture WHERE review_state = 'blocked'),
    'clean_allocation_state', (
      SELECT review_state
      FROM fixture
      WHERE tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
    ),
    'clean_review_available_qty', (
      SELECT review_available_qty
      FROM fixture
      WHERE tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
    )
  ),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb)
) AS exact_allocation_review_state_v2_postflight;
