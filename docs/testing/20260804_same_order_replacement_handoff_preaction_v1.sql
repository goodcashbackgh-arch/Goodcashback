-- Read-only pre-action diagnostic for the grouped replacement handoff.
-- Fixture: review cb0752b1-7e34-4f4c-8157-f2f7140f58cd
-- Expected before successor tracking allocation:
--   * exactly two same-order routes
--   * both approved_waiting_tracking
--   * no successor tracking allocation/submission
--   * no replacement child order
--   * source disputes are replaced

WITH constants AS (
  SELECT
    'cb0752b1-7e34-4f4c-8157-f2f7140f58cd'::uuid AS review_id,
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid AS order_id
), routes AS (
  SELECT r.*
  FROM public.physical_replacement_same_order_routes r
  JOIN constants c ON c.review_id = r.physical_receipt_review_id
), route_summary AS (
  SELECT
    count(*) AS route_count,
    count(*) FILTER (WHERE route_status = 'approved_waiting_tracking') AS waiting_tracking_count,
    count(*) FILTER (WHERE successor_tracking_submission_id IS NOT NULL) AS successor_submission_count,
    count(*) FILTER (WHERE successor_tracking_line_allocation_id IS NOT NULL) AS successor_allocation_count,
    count(*) FILTER (WHERE tracking_allocated_at IS NOT NULL) AS allocated_at_count,
    count(*) FILTER (WHERE cancelled_at IS NOT NULL OR route_status = 'cancelled') AS cancelled_count
  FROM routes
), child_orders AS (
  SELECT count(*) AS child_order_count
  FROM public.orders o
  JOIN constants c ON c.order_id = o.parent_order_id
  WHERE o.order_type = 'replacement_child'
), dispute_summary AS (
  SELECT
    count(*) AS dispute_count,
    count(*) FILTER (WHERE d.status = 'replaced') AS replaced_count,
    count(*) FILTER (WHERE d.replacement_child_order_id IS NOT NULL) AS dispute_child_order_link_count
  FROM public.disputes d
  WHERE d.id IN (SELECT dispute_id FROM routes)
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN (SELECT route_count FROM route_summary) <> 2 THEN 'expected_two_routes' END,
    CASE WHEN (SELECT waiting_tracking_count FROM route_summary) <> 2 THEN 'routes_not_waiting_tracking' END,
    CASE WHEN (SELECT successor_submission_count FROM route_summary) <> 0 THEN 'successor_submission_already_present' END,
    CASE WHEN (SELECT successor_allocation_count FROM route_summary) <> 0 THEN 'successor_allocation_already_present' END,
    CASE WHEN (SELECT allocated_at_count FROM route_summary) <> 0 THEN 'tracking_allocated_at_already_present' END,
    CASE WHEN (SELECT cancelled_count FROM route_summary) <> 0 THEN 'route_cancelled' END,
    CASE WHEN (SELECT child_order_count FROM child_orders) <> 0 THEN 'replacement_child_order_exists' END,
    CASE WHEN (SELECT dispute_count FROM dispute_summary) <> 2 THEN 'expected_two_route_disputes' END,
    CASE WHEN (SELECT replaced_count FROM dispute_summary) <> 2 THEN 'route_disputes_not_replaced' END,
    CASE WHEN (SELECT dispute_child_order_link_count FROM dispute_summary) <> 0 THEN 'dispute_links_child_order' END
  ], NULL) AS blockers
)
SELECT jsonb_build_object(
  'probe', 'same_order_replacement_handoff_preaction_v1',
  'result', CASE WHEN COALESCE(array_length(blockers, 1), 0) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'blockers', blockers,
  'review_id', (SELECT review_id FROM constants),
  'order_id', (SELECT order_id FROM constants),
  'route_summary', to_jsonb(route_summary),
  'dispute_summary', to_jsonb(dispute_summary),
  'child_orders', to_jsonb(child_orders),
  'routes', COALESCE((SELECT jsonb_agg(to_jsonb(routes) ORDER BY created_at) FROM routes), '[]'::jsonb)
) AS result
FROM blockers
CROSS JOIN route_summary
CROSS JOIN dispute_summary
CROSS JOIN child_orders;