-- Read-only preflight for the exact clean shipment-continuation build.
-- Governed by HYBRID_PHYSICAL_RECEIPT_EXACT_ROUTING_AND_SHIPMENT_CONTINUATION_CORRECTION_ADDENDUM_v1 and v1.1.
-- No DDL, DML, temporary objects or persistent changes.

WITH target_functions(identity) AS (
  VALUES
    ('public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::text),
    ('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'::text),
    ('public.shipper_shipment_batch_candidates_v1()'::text),
    ('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::text),
    ('public.shipper_package_contents_preview_v1(uuid)'::text),
    ('public.customer_review_cycle_candidates_v1(uuid)'::text),
    ('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::text)
), function_contracts AS (
  SELECT
    tf.identity,
    to_regprocedure(tf.identity) IS NOT NULL AS present,
    CASE WHEN p.oid IS NOT NULL THEN pg_get_userbyid(p.proowner) END AS owner,
    CASE WHEN p.oid IS NOT NULL THEN p.prosecdef END AS security_definer,
    CASE WHEN p.oid IS NOT NULL THEN p.provolatile END AS volatility,
    CASE WHEN p.oid IS NOT NULL THEN p.proconfig END AS proconfig,
    CASE WHEN p.oid IS NOT NULL THEN p.proacl END AS acl,
    CASE WHEN p.oid IS NOT NULL THEN md5(pg_get_functiondef(p.oid)) END AS definition_md5,
    CASE WHEN p.oid IS NOT NULL THEN pg_get_functiondef(p.oid) END AS definition
  FROM target_functions tf
  LEFT JOIN pg_proc p ON p.oid = to_regprocedure(tf.identity)
), protected_functions AS (
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
    'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
  )
), grouped_fixture AS (
  SELECT
    o.id AS order_id,
    o.order_ref,
    ots.id AS tracking_submission_id,
    ots.tracking_ref,
    otla.id AS tracking_line_allocation_id,
    otla.qty_allocated,
    otla.base_value_gbp,
    otla.retailer_delivery_share_gbp,
    otla.discount_share_gbp
  FROM public.orders o
  JOIN public.order_tracking_submissions ots
    ON ots.order_id = o.id
   AND ots.superseded_at IS NULL
  JOIN public.order_tracking_line_allocations otla
    ON otla.tracking_submission_id = ots.id
   AND otla.order_id = o.id
  WHERE o.id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
     OR o.order_ref LIKE 'PW-GROUPED-%'
), current_candidates AS (
  SELECT c.*
  FROM public.shipper_shipment_batch_candidates_v1() c
  WHERE c.order_id IN (SELECT DISTINCT order_id FROM grouped_fixture)
), current_positions AS (
  SELECT p.*
  FROM grouped_fixture gf
  CROSS JOIN LATERAL public.internal_tracking_allocation_fulfilment_position_v1(
    gf.order_id,
    gf.tracking_submission_id,
    gf.tracking_line_allocation_id
  ) p
), membership_table AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'shipment_batch_line_memberships'
  ORDER BY c.ordinal_position
)
SELECT jsonb_build_object(
  'all_required_functions_present', NOT EXISTS (
    SELECT 1 FROM function_contracts WHERE NOT present
  ),
  'function_contracts', COALESCE((
    SELECT jsonb_agg(to_jsonb(function_contracts) ORDER BY identity)
    FROM function_contracts
  ), '[]'::jsonb),
  'protected_function_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected_functions) ORDER BY identity)
    FROM protected_functions
  ), '[]'::jsonb),
  'grouped_fixture_allocations', COALESCE((
    SELECT jsonb_agg(to_jsonb(grouped_fixture) ORDER BY tracking_submission_id, tracking_line_allocation_id)
    FROM grouped_fixture
  ), '[]'::jsonb),
  'current_shipment_candidates', COALESCE((
    SELECT jsonb_agg(to_jsonb(current_candidates))
    FROM current_candidates
  ), '[]'::jsonb),
  'current_exact_positions', COALESCE((
    SELECT jsonb_agg(to_jsonb(current_positions))
    FROM current_positions
  ), '[]'::jsonb),
  'shipment_membership_columns', COALESCE((
    SELECT jsonb_agg(to_jsonb(membership_table) ORDER BY ordinal_position)
    FROM membership_table
  ), '[]'::jsonb)
) AS exact_clean_shipment_continuation_live_preflight;
