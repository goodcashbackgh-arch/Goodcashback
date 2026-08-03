-- Read-only probe for the exact replacement case shown in the live UI.
-- Confirms whether the item is terminal in the legacy child-order route,
-- whether any unresolved physical allocation remains, and whether a governed
-- same-order replacement route already exists.

WITH target AS (
  SELECT
    'd7b32314-603e-49bf-83d1-1a01e2e4d29f'::uuid AS dispute_id,
    '83a2a969-56b2-4b33-99f9-aa3d68bc89d9'::uuid AS displayed_child_order_id
), dispute_state AS (
  SELECT jsonb_build_object(
    'id',d.id,
    'order_id',d.order_id,
    'desired_outcome',d.desired_outcome,
    'status',d.status,
    'replacement_child_order_id',d.replacement_child_order_id,
    'resolved_at',d.resolved_at,
    'displayed_child_matches_dispute',d.replacement_child_order_id=t.displayed_child_order_id
  ) AS value
  FROM target t
  LEFT JOIN public.disputes d ON d.id=t.dispute_id
), lines AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',dl.id,
    'supplier_invoice_line_id',dl.supplier_invoice_line_id,
    'qty_impact',dl.qty_impact,
    'line_status',dl.line_status,
    'resolution_method',dl.resolution_method,
    'conversation_status',dl.conversation_status,
    'physical_remedy_allocation_id',dl.physical_remedy_allocation_id,
    'resolved_via_child_order_id',dl.resolved_via_child_order_id,
    'resolved_at',dl.resolved_at
  ) ORDER BY dl.id),'[]'::jsonb) AS value
  FROM target t
  JOIN public.dispute_lines dl ON dl.dispute_id=t.dispute_id
), allocations AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',r.id,
    'physical_receipt_review_id',r.physical_receipt_review_id,
    'approved_remedy_type',r.approved_remedy_type,
    'approved_remedy_qty',r.approved_remedy_qty,
    'supplier_cost_mode',r.supplier_cost_mode,
    'status',r.status,
    'dispute_line_id',r.dispute_line_id,
    'replacement_child_order_id',r.replacement_child_order_id,
    'replacement_child_tracking_allocation_id',r.replacement_child_tracking_allocation_id,
    'rerouted_to_remedy_allocation_id',r.rerouted_to_remedy_allocation_id,
    'updated_at',r.updated_at
  ) ORDER BY r.id),'[]'::jsonb) AS value,
  COUNT(*) FILTER (
    WHERE r.approved_remedy_type='replacement'
      AND r.status NOT IN ('completed','cancelled')
  ) AS unresolved_replacement_allocation_count
  FROM target t
  JOIN public.dispute_lines dl ON dl.dispute_id=t.dispute_id
  JOIN public.physical_exception_remedy_allocations r
    ON r.id=dl.physical_remedy_allocation_id
), lanes AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'lane_id',l.id,
    'physical_receipt_review_id',l.physical_receipt_review_id,
    'outcome_type',l.outcome_type,
    'lane_status',l.lane_status,
    'physical_remedy_allocation_id',li.physical_remedy_allocation_id,
    'dispute_line_id',li.dispute_line_id,
    'updated_at',l.updated_at
  ) ORDER BY l.id,li.physical_remedy_allocation_id),'[]'::jsonb) AS value
  FROM target t
  JOIN public.physical_receipt_outcome_lane_items li ON li.dispute_id=t.dispute_id
  JOIN public.physical_receipt_outcome_lanes l ON l.id=li.lane_id
), same_order_routes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at,r.id),'[]'::jsonb) AS value,
         COUNT(*) FILTER (WHERE r.route_status<>'cancelled') AS active_route_count
  FROM target t
  JOIN public.dispute_lines dl ON dl.dispute_id=t.dispute_id
  JOIN public.physical_replacement_same_order_routes r
    ON r.physical_remedy_allocation_id=dl.physical_remedy_allocation_id
), decisions AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'lane_decision_id',d.id,
    'lane_id',d.lane_id,
    'decision_type',d.decision_type,
    'result_json',d.result_json,
    'decided_at',d.decided_at,
    'physical_remedy_allocation_id',di.physical_remedy_allocation_id,
    'route_id',di.route_id,
    'authority_result',di.authority_result
  ) ORDER BY d.decided_at,d.id),'[]'::jsonb) AS value
  FROM target t
  JOIN public.physical_receipt_outcome_lane_items li ON li.dispute_id=t.dispute_id
  JOIN public.physical_receipt_outcome_lane_decisions d ON d.lane_id=li.lane_id
  LEFT JOIN public.physical_receipt_outcome_lane_decision_items di
    ON di.lane_decision_id=d.id
   AND di.physical_remedy_allocation_id=li.physical_remedy_allocation_id
)
SELECT jsonb_build_object(
  'probe','single_replacement_item_live_route_v1',
  'dispute_id',t.dispute_id,
  'displayed_child_order_id',t.displayed_child_order_id,
  'dispute',dispute_state.value,
  'dispute_lines',lines.value,
  'physical_allocations',allocations.value,
  'unresolved_replacement_allocation_count',allocations.unresolved_replacement_allocation_count,
  'outcome_lanes',lanes.value,
  'same_order_routes',same_order_routes.value,
  'active_same_order_route_count',same_order_routes.active_route_count,
  'grouped_lane_decisions',decisions.value,
  'classification',CASE
    WHEN same_order_routes.active_route_count>0 THEN 'SAME_ORDER_ROUTE_EXISTS'
    WHEN allocations.unresolved_replacement_allocation_count>0 THEN 'UNRESOLVED_PHYSICAL_REPLACEMENT_REMAINS'
    ELSE 'LEGACY_CHILD_ORDER_TERMINAL_OR_NO_ELIGIBLE_PHYSICAL_REPLACEMENT'
  END
) AS result
FROM target t
CROSS JOIN dispute_state
CROSS JOIN lines
CROSS JOIN allocations
CROSS JOIN lanes
CROSS JOIN same_order_routes
CROSS JOIN decisions;
