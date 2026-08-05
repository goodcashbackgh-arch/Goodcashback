WITH target_disputes AS (
  SELECT unnest(ARRAY[
    '47044cb5-7d24-416a-8359-d85e65d1c164'::uuid,
    '657f7cf9-af98-40e3-b981-b069a23e92c0'::uuid
  ]) AS dispute_id
), routes AS (
  SELECT
    r.id AS route_id,
    r.dispute_id,
    r.order_id,
    r.route_status,
    r.successor_tracking_submission_id,
    r.successor_tracking_line_allocation_id
  FROM public.physical_replacement_same_order_routes r
  JOIN target_disputes t ON t.dispute_id = r.dispute_id
), latest_receipts AS (
  SELECT DISTINCT ON (spr.tracking_submission_id)
    spr.tracking_submission_id,
    spr.receipt_status,
    spr.recorded_at,
    spr.created_at,
    spr.id AS receipt_id
  FROM public.shipper_package_receipts spr
  JOIN routes r ON r.successor_tracking_submission_id = spr.tracking_submission_id
  ORDER BY spr.tracking_submission_id, spr.created_at DESC, spr.id DESC
), memberships AS (
  SELECT
    m.tracking_line_allocation_id,
    m.active,
    m.shipment_batch_id,
    b.booking_ref,
    m.created_at,
    m.id AS membership_id
  FROM public.shipper_shipment_batch_line_memberships m
  JOIN public.shipper_shipment_batches b ON b.id = m.shipment_batch_id
  JOIN routes r ON r.successor_tracking_line_allocation_id = m.tracking_line_allocation_id
), installed AS (
  SELECT
    to_regprocedure('public.importer_same_order_replacement_progress_v1(uuid[])') IS NOT NULL AS function_exists,
    CASE
      WHEN to_regprocedure('public.importer_same_order_replacement_progress_v1(uuid[])') IS NULL THEN NULL
      ELSE md5(pg_get_functiondef('public.importer_same_order_replacement_progress_v1(uuid[])'::regprocedure))
    END AS function_md5
), order_identity AS (
  SELECT
    o.id AS order_id,
    o.operator_id,
    o.importer_id
  FROM public.orders o
  WHERE o.id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
)
SELECT jsonb_build_object(
  'probe', 'importer_replacement_progress_db_diagnostic_v1',
  'installed', (SELECT to_jsonb(installed) FROM installed),
  'order_identity', (SELECT to_jsonb(order_identity) FROM order_identity),
  'routes', COALESCE((SELECT jsonb_agg(to_jsonb(routes) ORDER BY dispute_id) FROM routes), '[]'::jsonb),
  'latest_receipts', COALESCE((SELECT jsonb_agg(to_jsonb(latest_receipts) ORDER BY tracking_submission_id) FROM latest_receipts), '[]'::jsonb),
  'memberships', COALESCE((SELECT jsonb_agg(to_jsonb(memberships) ORDER BY tracking_line_allocation_id) FROM memberships), '[]'::jsonb),
  'expected_progress', COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'dispute_id', r.dispute_id,
        'route_status', r.route_status,
        'latest_receipt_status', lr.receipt_status,
        'active_booking_ref', m.booking_ref,
        'expected_status', CASE
          WHEN r.route_status <> 'tracking_allocated'
            OR r.successor_tracking_submission_id IS NULL
            OR r.successor_tracking_line_allocation_id IS NULL
            THEN 'awaiting_successor_tracking'
          WHEN m.booking_ref IS NOT NULL AND m.active = true
            THEN 'added_to_shipment'
          WHEN lr.receipt_status = 'received_clean'
            THEN 'shipment_eligible'
          ELSE 'awaiting_replacement_receipt'
        END
      ) ORDER BY r.dispute_id
    )
    FROM routes r
    LEFT JOIN latest_receipts lr ON lr.tracking_submission_id = r.successor_tracking_submission_id
    LEFT JOIN memberships m ON m.tracking_line_allocation_id = r.successor_tracking_line_allocation_id AND m.active = true
  ), '[]'::jsonb)
) AS result;
