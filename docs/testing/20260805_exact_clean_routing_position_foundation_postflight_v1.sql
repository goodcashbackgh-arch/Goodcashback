-- Read-only postflight for the additive exact clean routing position foundation.
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
  WHERE p.oid = 'public.internal_tracking_allocation_fulfilment_routing_position_v2(uuid,uuid,uuid)'::regprocedure
), fixture AS (
  SELECT r.*
  FROM public.internal_tracking_allocation_fulfilment_routing_position_v2(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid,
    NULL
  ) r
), protected AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.proacl AS acl
  FROM pg_proc p
  WHERE p.oid IN (
    'public.customer_review_cycle_component_guard_v1()'::regprocedure,
    'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure,
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure,
    'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure,
    'public.customer_review_cycle_candidates_v1(uuid)'::regprocedure,
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure,
    'public.shipper_shipment_batch_candidates_v1()'::regprocedure,
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  )
)
SELECT jsonb_build_object(
  'foundation_present', EXISTS (SELECT 1 FROM contract),
  'contract', (SELECT to_jsonb(contract) FROM contract),
  'fixture_rows', COALESCE((
    SELECT jsonb_agg(to_jsonb(fixture) ORDER BY tracking_line_allocation_id)
    FROM fixture
  ), '[]'::jsonb),
  'fixture_summary', jsonb_build_object(
    'row_count', (SELECT COUNT(*) FROM fixture),
    'valid_row_count', (SELECT COUNT(*) FROM fixture WHERE position_valid_yn),
    'clean_qty', (SELECT COALESCE(SUM(effective_clean_qty),0) FROM fixture),
    'exception_qty', (SELECT COALESCE(SUM(effective_exception_qty),0) FROM fixture),
    'review_available_qty', (SELECT COALESCE(SUM(review_available_qty),0) FROM fixture),
    'shipment_ready_qty', (SELECT COALESCE(SUM(shipment_ready_qty),0) FROM fixture),
    'diverted_qty', (SELECT COALESCE(SUM(diverted_qty),0) FROM fixture),
    'position_balance_ok', (
      SELECT COALESCE(bool_and(
        effective_clean_qty + effective_exception_qty <= effective_allocated_qty + 0.0005
      ), false)
      FROM fixture
    )
  ),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb)
) AS exact_clean_routing_position_foundation_postflight;
