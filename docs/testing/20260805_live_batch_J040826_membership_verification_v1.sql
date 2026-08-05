WITH target_batch AS (
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
), result AS (
  SELECT jsonb_build_object(
    'probe', 'live_batch_J040826_membership_verification_v1',
    'batch_found', EXISTS (SELECT 1 FROM target_batch),
    'batch', COALESCE((SELECT to_jsonb(b) FROM target_batch b), '{}'::jsonb),
    'active_package_count', (SELECT COUNT(*) FROM package_rows),
    'membership_count', (SELECT COUNT(*) FROM membership_rows),
    'membership_qty', (SELECT COALESCE(SUM(qty_in_shipment), 0) FROM membership_rows),
    'clean_allocation_count', (
      SELECT COUNT(*)
      FROM membership_rows
      WHERE tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
    ),
    'diverted_allocation_count', (
      SELECT COUNT(*)
      FROM membership_rows
      WHERE tracking_line_allocation_id <> '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
    ),
    'tracking_submission_ids', COALESCE((
      SELECT jsonb_agg(tracking_submission_id ORDER BY tracking_submission_id)
      FROM package_rows
    ), '[]'::jsonb),
    'memberships', COALESCE((
      SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id)
      FROM membership_rows m
    ), '[]'::jsonb),
    'passed',
      EXISTS (SELECT 1 FROM target_batch)
      AND (SELECT COUNT(*) FROM package_rows) = 1
      AND (SELECT COUNT(*) FROM membership_rows) = 1
      AND (SELECT COALESCE(SUM(qty_in_shipment), 0) FROM membership_rows) = 1
      AND (
        SELECT COUNT(*)
        FROM membership_rows
        WHERE tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      ) = 1
      AND (
        SELECT COUNT(*)
        FROM membership_rows
        WHERE tracking_line_allocation_id <> '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      ) = 0
  ) AS result
)
SELECT result FROM result;
