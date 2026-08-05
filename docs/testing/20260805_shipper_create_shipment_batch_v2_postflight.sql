WITH function_check AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    p.prosecdef AS security_definer,
    p.proconfig AS function_config,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid = 'public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
), protected AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  WHERE p.oid IN (
    'public.shipper_shipment_batch_candidates_v1()'::regprocedure,
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure,
    'public.shipper_package_contents_preview_v1(uuid)'::regprocedure,
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::regprocedure,
    'public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'::regprocedure
  )
)
SELECT jsonb_build_object(
  'function', COALESCE((
    SELECT to_jsonb(function_check) - 'definition'
    FROM function_check
  ), '{}'::jsonb),
  'wiring', jsonb_build_object(
    'uses_exact_candidate_source', EXISTS (
      SELECT 1 FROM function_check
      WHERE position('internal_shipper_shipment_batch_candidates_v2' in definition) > 0
    ),
    'uses_exact_routing_position', EXISTS (
      SELECT 1 FROM function_check
      WHERE position('internal_tracking_allocation_fulfilment_routing_position_v2' in definition) > 0
    ),
    'writes_existing_package_table', EXISTS (
      SELECT 1 FROM function_check
      WHERE position('shipper_shipment_batch_packages' in definition) > 0
    ),
    'writes_existing_membership_table', EXISTS (
      SELECT 1 FROM function_check
      WHERE position('shipper_shipment_batch_line_memberships' in definition) > 0
    )
  ),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb),
  'postflight_passed',
    EXISTS (SELECT 1 FROM function_check)
    AND (SELECT security_definer FROM function_check)
    AND NOT (SELECT anon_execute FROM function_check)
    AND (SELECT authenticated_execute FROM function_check)
    AND NOT (SELECT service_role_execute FROM function_check)
    AND EXISTS (
      SELECT 1 FROM function_check
      WHERE position('internal_shipper_shipment_batch_candidates_v2' in definition) > 0
        AND position('internal_tracking_allocation_fulfilment_routing_position_v2' in definition) > 0
        AND position('shipper_shipment_batch_packages' in definition) > 0
        AND position('shipper_shipment_batch_line_memberships' in definition) > 0
    )
    AND (SELECT COUNT(*) FROM protected) = 5
    AND NOT EXISTS (
      SELECT 1
      FROM protected
      WHERE (identity = 'shipper_shipment_batch_candidates_v1()' AND definition_md5 <> '952f24084fed0dffcdebbfae988e7400')
         OR (identity = 'shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamp with time zone,timestamp with time zone,integer,text,text,text)' AND definition_md5 <> '4e4b86b0121a85523fe95c1530a41658')
         OR (identity = 'shipper_package_contents_preview_v1(uuid)' AND definition_md5 <> 'a312af874648f50547270c2fcb7f7c6d')
         OR (identity = 'internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)' AND definition_md5 <> 'ae13557433f5e8500985b00266347807')
         OR (identity = 'tracking_allocation_effective_entitlement_v1(uuid,uuid)' AND definition_md5 <> '00d5450bb95b75d2bd2150914689250f')
    )
) AS shipper_create_shipment_batch_v2_postflight;
