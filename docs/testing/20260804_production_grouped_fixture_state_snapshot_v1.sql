-- READ-ONLY production state snapshot for the grouped physical-receipt fixture.
-- Uses only live relations and columns proven by the catalog probe.
-- No DML. Safe to run repeatedly.

WITH params AS (
  SELECT
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid AS order_id,
    'cb0752b1-7e34-4f4c-8157-f2f7140f58cd'::uuid AS review_id
),
reviews AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_reviews r, params p
  WHERE r.order_id = p.order_id
),
receipts AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]'::jsonb) AS rows
  FROM public.shipper_package_receipts r, params p
  WHERE r.order_id = p.order_id
),
disputes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.id), '[]'::jsonb) AS rows
  FROM public.disputes d, params p
  WHERE d.order_id = p.order_id
),
review_links AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_review_dispute_links l, params p
  WHERE l.physical_receipt_review_id = p.review_id
),
allocations AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id), '[]'::jsonb) AS rows
  FROM public.physical_exception_remedy_allocations a, params p
  WHERE a.physical_receipt_review_id = p.review_id
),
lanes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_outcome_lanes l, params p
  WHERE l.physical_receipt_review_id = p.review_id
),
lane_items AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.lane_id, i.physical_remedy_allocation_id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_outcome_lane_items i
  JOIN public.physical_receipt_outcome_lanes l ON l.id = i.lane_id
  JOIN params p ON p.review_id = l.physical_receipt_review_id
),
lane_updates AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(u) ORDER BY u.id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_outcome_lane_updates u
  JOIN public.physical_receipt_outcome_lanes l ON l.id = u.lane_id
  JOIN params p ON p.review_id = l.physical_receipt_review_id
),
lane_update_items AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.lane_update_id, i.physical_remedy_allocation_id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_outcome_lane_update_items i
  JOIN public.physical_receipt_outcome_lane_updates u ON u.id = i.lane_update_id
  JOIN public.physical_receipt_outcome_lanes l ON l.id = u.lane_id
  JOIN params p ON p.review_id = l.physical_receipt_review_id
),
lane_decisions AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_outcome_lane_decisions d
  JOIN public.physical_receipt_outcome_lanes l ON l.id = d.lane_id
  JOIN params p ON p.review_id = l.physical_receipt_review_id
),
lane_decision_items AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.lane_decision_id, i.physical_remedy_allocation_id), '[]'::jsonb) AS rows
  FROM public.physical_receipt_outcome_lane_decision_items i
  JOIN public.physical_receipt_outcome_lane_decisions d ON d.id = i.lane_decision_id
  JOIN public.physical_receipt_outcome_lanes l ON l.id = d.lane_id
  JOIN params p ON p.review_id = l.physical_receipt_review_id
),
replacement_routes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]'::jsonb) AS rows
  FROM public.physical_replacement_same_order_routes r, params p
  WHERE r.physical_receipt_review_id = p.review_id
),
child_orders AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.id), '[]'::jsonb) AS rows
  FROM public.orders o, params p
  WHERE o.parent_order_id = p.order_id
)
SELECT jsonb_build_object(
  'probe', 'production_grouped_fixture_state_snapshot_v1',
  'result', 'READY',
  'order_id', (SELECT order_id FROM params),
  'review_id', (SELECT review_id FROM params),
  'reviews', (SELECT rows FROM reviews),
  'receipts', (SELECT rows FROM receipts),
  'disputes', (SELECT rows FROM disputes),
  'review_dispute_links', (SELECT rows FROM review_links),
  'remedy_allocations', (SELECT rows FROM allocations),
  'outcome_lanes', (SELECT rows FROM lanes),
  'outcome_lane_items', (SELECT rows FROM lane_items),
  'outcome_lane_updates', (SELECT rows FROM lane_updates),
  'outcome_lane_update_items', (SELECT rows FROM lane_update_items),
  'outcome_lane_decisions', (SELECT rows FROM lane_decisions),
  'outcome_lane_decision_items', (SELECT rows FROM lane_decision_items),
  'same_order_replacement_routes', (SELECT rows FROM replacement_routes),
  'child_orders', (SELECT rows FROM child_orders)
) AS result;
