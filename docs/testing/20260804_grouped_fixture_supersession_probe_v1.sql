-- READ-ONLY probe for grouped fixture review supersession and linked workflow state.
-- No DML. Safe to run repeatedly.
-- Uses only proven identifier/order columns; application rows are returned via to_jsonb(...).

WITH target_review AS (
  SELECT to_jsonb(r) AS row
  FROM public.physical_receipt_reviews r
  WHERE r.id='23e51455-9186-4207-81ff-3e502bbe9f4c'::uuid
), replacement_receipt AS (
  SELECT to_jsonb(p) AS row
  FROM public.shipper_package_receipts p
  WHERE p.id=(
    SELECT r.superseded_by_receipt_id
    FROM public.physical_receipt_reviews r
    WHERE r.id='23e51455-9186-4207-81ff-3e502bbe9f4c'::uuid
  )
), replacement_review AS (
  SELECT to_jsonb(r) AS row
  FROM public.physical_receipt_reviews r
  WHERE r.receipt_id=(
    SELECT r0.superseded_by_receipt_id
    FROM public.physical_receipt_reviews r0
    WHERE r0.id='23e51455-9186-4207-81ff-3e502bbe9f4c'::uuid
  )
), order_reviews AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) AS rows
  FROM public.physical_receipt_reviews r
  WHERE r.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
), receipts AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.id),'[]'::jsonb) AS rows
  FROM public.shipper_package_receipts p
  WHERE p.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
), disputes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.id),'[]'::jsonb) AS rows
  FROM public.disputes d
  WHERE d.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
), allocations AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id),'[]'::jsonb) AS rows
  FROM public.physical_remedy_allocations a
  WHERE a.physical_receipt_review_id='23e51455-9186-4207-81ff-3e502bbe9f4c'::uuid
     OR a.dispute_id IN (
       SELECT d.id FROM public.disputes d
       WHERE d.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
     )
), lanes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.id),'[]'::jsonb) AS rows
  FROM public.physical_outcome_lanes l
  WHERE l.physical_receipt_review_id='23e51455-9186-4207-81ff-3e502bbe9f4c'::uuid
), lane_items AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.id),'[]'::jsonb) AS rows
  FROM public.physical_outcome_lane_items i
  WHERE i.physical_outcome_lane_id IN (
    SELECT l.id FROM public.physical_outcome_lanes l
    WHERE l.physical_receipt_review_id='23e51455-9186-4207-81ff-3e502bbe9f4c'::uuid
  )
), child_orders AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.id),'[]'::jsonb) AS rows
  FROM public.orders o
  WHERE o.parent_order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
), same_order_routes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) AS rows
  FROM public.same_order_free_replacement_routes r
  WHERE r.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
)
SELECT jsonb_build_object(
  'probe','grouped_fixture_supersession_probe_v2',
  'result','READY',
  'target_review',(SELECT row FROM target_review),
  'superseding_receipt',(SELECT row FROM replacement_receipt),
  'superseding_review',(SELECT row FROM replacement_review),
  'all_order_reviews',(SELECT rows FROM order_reviews),
  'all_order_receipts',(SELECT rows FROM receipts),
  'disputes',(SELECT rows FROM disputes),
  'physical_remedy_allocations',(SELECT rows FROM allocations),
  'outcome_lanes',(SELECT rows FROM lanes),
  'outcome_lane_items',(SELECT rows FROM lane_items),
  'child_orders',(SELECT rows FROM child_orders),
  'same_order_routes',(SELECT rows FROM same_order_routes)
) AS result;
