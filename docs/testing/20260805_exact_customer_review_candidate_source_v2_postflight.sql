-- Read-only postflight for internal_customer_review_cycle_candidates_v2.
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
  WHERE p.oid = 'public.internal_customer_review_cycle_candidates_v2(uuid)'::regprocedure
), fixture AS (
  SELECT c.*
  FROM public.internal_customer_review_cycle_candidates_v2(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
  ) c
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
  'candidate_source_present', EXISTS (SELECT 1 FROM contract),
  'contract', (SELECT to_jsonb(contract) FROM contract),
  'fixture_candidates', COALESCE((
    SELECT jsonb_agg(to_jsonb(fixture) ORDER BY tracking_line_allocation_id)
    FROM fixture
  ), '[]'::jsonb),
  'fixture_summary', jsonb_build_object(
    'candidate_count', (SELECT COUNT(*) FROM fixture),
    'review_qty', (SELECT COALESCE(SUM(review_qty),0) FROM fixture),
    'distinct_allocation_count', (
      SELECT COUNT(DISTINCT tracking_line_allocation_id) FROM fixture
    ),
    'all_deadlines_24h', (
      SELECT COALESCE(bool_and(
        review_expires_at = review_eligible_at + interval '24 hours'
      ), false)
      FROM fixture
    ),
    'clean_allocation_only', (
      SELECT COALESCE(bool_and(
        tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      ), false)
      FROM fixture
    )
  ),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb)
) AS exact_customer_review_candidate_source_v2_postflight;
