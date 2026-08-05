WITH function_check AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    p.prosecdef AS security_definer,
    p.proconfig AS function_config,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  WHERE p.oid = 'public.internal_shipper_shipment_batch_candidates_v2(uuid,uuid,uuid)'::regprocedure
), fixture_position AS (
  SELECT *
  FROM public.internal_tracking_allocation_fulfilment_routing_position_v2(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid,
    NULL
  )
), fixture_candidate AS (
  SELECT *
  FROM public.internal_shipper_shipment_batch_candidates_v2(
    NULL,
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid
  )
), protected AS (
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
  'function', COALESCE((SELECT to_jsonb(function_check) FROM function_check), '{}'::jsonb),
  'fixture_position', jsonb_build_object(
    'row_count', (SELECT COUNT(*) FROM fixture_position),
    'clean_qty', COALESCE((SELECT SUM(effective_clean_qty) FROM fixture_position), 0),
    'completed_review_qty', COALESCE((SELECT SUM(completed_review_qty) FROM fixture_position), 0),
    'active_hold_qty', COALESCE((SELECT SUM(active_hold_qty) FROM fixture_position), 0),
    'shipped_qty', COALESCE((SELECT SUM(shipped_qty) FROM fixture_position), 0),
    'shipment_ready_qty', COALESCE((SELECT SUM(shipment_ready_qty) FROM fixture_position), 0),
    'diverted_qty', COALESCE((SELECT SUM(diverted_qty) FROM fixture_position), 0),
    'invalid_row_count', (SELECT COUNT(*) FROM fixture_position WHERE NOT position_valid_yn)
  ),
  'fixture_candidate_rows', COALESCE((
    SELECT jsonb_agg(to_jsonb(fixture_candidate) ORDER BY order_id, tracking_submission_id)
    FROM fixture_candidate
  ), '[]'::jsonb),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb),
  'postflight_passed',
    EXISTS (SELECT 1 FROM function_check)
    AND (SELECT security_definer FROM function_check)
    AND NOT (SELECT anon_execute FROM function_check)
    AND NOT (SELECT authenticated_execute FROM function_check)
    AND (SELECT service_role_execute FROM function_check)
    AND (SELECT COUNT(*) FROM fixture_position) = 5
    AND (SELECT COUNT(*) FROM fixture_position WHERE NOT position_valid_yn) = 0
    AND (SELECT COUNT(*) FROM protected) = 4
    AND NOT EXISTS (
      SELECT 1
      FROM protected
      WHERE (identity = 'customer_review_cycle_candidates_v1(uuid)' AND definition_md5 <> '80c5ca83374ed2ddaedeadd3b88dd95d')
         OR (identity = 'internal_materialize_customer_review_cycles_v1(uuid,uuid)' AND definition_md5 <> '0293a94d4eb17daf9c7e48131cd75ca1')
         OR (identity = 'shipper_shipment_batch_candidates_v1()' AND definition_md5 <> '952f24084fed0dffcdebbfae988e7400')
         OR (identity = 'shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamp with time zone,timestamp with time zone,integer,text,text,text)' AND definition_md5 <> '4e4b86b0121a85523fe95c1530a41658')
    )
) AS exact_shipment_candidate_source_v2_postflight;
