WITH protected_functions(identity, expected_md5) AS (
  VALUES
    ('public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::text, 'ae13557433f5e8500985b00266347807'::text),
    ('public.shipper_shipment_batch_candidates_v1()'::text, '952f24084fed0dffcdebbfae988e7400'::text),
    ('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::text, '4e4b86b0121a85523fe95c1530a41658'::text),
    ('public.shipper_package_contents_preview_v1(uuid)'::text, 'a312af874648f50547270c2fcb7f7c6d'::text)
), protected_results AS (
  SELECT
    identity,
    expected_md5,
    to_regprocedure(identity) IS NOT NULL AS exists,
    CASE
      WHEN to_regprocedure(identity) IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(to_regprocedure(identity)))
    END AS actual_md5
  FROM protected_functions
), target_batch AS (
  SELECT b.id, b.booking_ref, b.importer_id, b.status, b.created_at
  FROM public.shipper_shipment_batches b
  WHERE b.booking_ref = 'J040826'
  ORDER BY b.created_at DESC, b.id DESC
  LIMIT 1
), package_rows AS (
  SELECT p.id AS shipment_batch_package_id, p.tracking_submission_id
  FROM public.shipper_shipment_batch_packages p
  JOIN target_batch b ON b.id = p.shipment_batch_id
  WHERE p.active = true
), membership_rows AS (
  SELECT
    m.id,
    m.shipment_batch_id,
    m.shipment_batch_package_id,
    m.tracking_line_allocation_id,
    m.qty_in_shipment
  FROM public.shipper_shipment_batch_line_memberships m
  JOIN target_batch b ON b.id = m.shipment_batch_id
), exact_candidate_after AS (
  SELECT COUNT(*)::integer AS candidate_count
  FROM public.internal_shipper_shipment_batch_candidates_v2(
    NULL,
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid
  )
), final_result AS (
  SELECT jsonb_build_object(
    'probe', 'exact_clean_shipment_addendum_closure_postflight_v1',
    'governing_addendum', 'HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1',
    'protected_authorities', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'identity', identity,
          'expected_md5', expected_md5,
          'actual_md5', actual_md5,
          'passed', exists AND actual_md5 = expected_md5
        ) ORDER BY identity
      )
      FROM protected_results
    ),
    'protected_authorities_passed', NOT EXISTS (
      SELECT 1 FROM protected_results
      WHERE NOT exists OR actual_md5 IS DISTINCT FROM expected_md5
    ),
    'effective_entitlement_view_exists', to_regclass('public.tracking_allocation_effective_entitlement_v1') IS NOT NULL,
    'effective_entitlement_view_definition_md5', CASE
      WHEN to_regclass('public.tracking_allocation_effective_entitlement_v1') IS NULL THEN NULL
      ELSE md5(pg_get_viewdef('public.tracking_allocation_effective_entitlement_v1'::regclass, true))
    END,
    'same_order_route_table_exists', to_regclass('public.physical_replacement_same_order_routes') IS NOT NULL,
    'same_order_route_count_for_order', CASE
      WHEN to_regclass('public.physical_replacement_same_order_routes') IS NULL THEN NULL
      ELSE (
        SELECT COUNT(*)
        FROM public.physical_replacement_same_order_routes r
        WHERE r.order_id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
      )
    END,
    'live_batch', COALESCE((SELECT to_jsonb(b) FROM target_batch b), '{}'::jsonb),
    'active_package_count', (SELECT COUNT(*) FROM package_rows),
    'membership_count', (SELECT COUNT(*) FROM membership_rows),
    'membership_qty', (SELECT COALESCE(SUM(qty_in_shipment), 0) FROM membership_rows),
    'clean_allocation_count', (
      SELECT COUNT(*) FROM membership_rows
      WHERE tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
    ),
    'diverted_allocation_count', (
      SELECT COUNT(*) FROM membership_rows
      WHERE tracking_line_allocation_id <> '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
    ),
    'candidate_count_after_creation', (SELECT candidate_count FROM exact_candidate_after),
    'v2_uses_pre_link_snapshot', position(
      'v_membership_snapshot' IN pg_get_functiondef(
        'public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
      )
    ) > 0,
    'passed',
      NOT EXISTS (
        SELECT 1 FROM protected_results
        WHERE NOT exists OR actual_md5 IS DISTINCT FROM expected_md5
      )
      AND to_regclass('public.tracking_allocation_effective_entitlement_v1') IS NOT NULL
      AND to_regclass('public.physical_replacement_same_order_routes') IS NOT NULL
      AND EXISTS (SELECT 1 FROM target_batch)
      AND (SELECT COUNT(*) FROM package_rows) = 1
      AND (SELECT COUNT(*) FROM membership_rows) = 1
      AND (SELECT COALESCE(SUM(qty_in_shipment), 0) FROM membership_rows) = 1
      AND (
        SELECT COUNT(*) FROM membership_rows
        WHERE tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      ) = 1
      AND (
        SELECT COUNT(*) FROM membership_rows
        WHERE tracking_line_allocation_id <> '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      ) = 0
      AND (SELECT candidate_count FROM exact_candidate_after) = 0
      AND position(
        'v_membership_snapshot' IN pg_get_functiondef(
          'public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
        )
      ) > 0
  ) AS result
)
SELECT result FROM final_result;
