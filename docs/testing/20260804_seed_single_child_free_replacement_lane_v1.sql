-- Controlled persistent seed for one browser acceptance case under
-- HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.
--
-- This script does NOT create or modify a replacement child order.
-- It reuses one already-approved, still-open, child-free physical replacement
-- authority and creates only the missing replacement outcome lane/item.
-- It is idempotent for the selected physical receipt review.

DO $$
DECLARE
  v_review_id uuid;
  v_order_id uuid;
  v_remedy_id uuid;
  v_dispute_id uuid;
  v_dispute_line_id uuid;
  v_lane_id uuid;
BEGIN
  SELECT
    r.physical_receipt_review_id,
    pr.order_id,
    r.id,
    d.id,
    dl.id
  INTO
    v_review_id,
    v_order_id,
    v_remedy_id,
    v_dispute_id,
    v_dispute_line_id
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr
    ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl
    ON dl.id=r.dispute_line_id
   AND dl.physical_remedy_allocation_id=r.id
  JOIN public.disputes d
    ON d.id=dl.dispute_id
   AND d.order_id=pr.order_id
  WHERE r.approved_remedy_type='replacement'
    AND r.status IN ('approved','linked_to_exception')
    AND r.replacement_child_order_id IS NULL
    AND r.replacement_child_tracking_allocation_id IS NULL
    AND d.desired_outcome='replacement'
    AND d.status IN ('raised','under_review')
    AND d.resolved_at IS NULL
    AND d.replacement_child_order_id IS NULL
    AND dl.resolved_at IS NULL
    AND dl.resolved_via_child_order_id IS NULL
    AND dl.conversation_status='retailer_response_received'
    AND EXISTS (
      SELECT 1
      FROM public.dispute_messages dm
      WHERE dm.dispute_id=d.id
        AND dm.message_type='retailer_reply'
        AND dm.counterparty='retailer'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.physical_replacement_same_order_routes sr
      WHERE sr.physical_remedy_allocation_id=r.id
        AND sr.route_status<>'cancelled'
    )
  ORDER BY pr.created_at DESC,r.id
  LIMIT 1
  FOR UPDATE OF r,pr,dl,d;

  IF v_remedy_id IS NULL THEN
    RAISE EXCEPTION
      'No eligible child-free replacement authority exists. Refusing to seed from a legacy child-order or resolved record.';
  END IF;

  INSERT INTO public.physical_receipt_outcome_lanes(
    order_id,
    physical_receipt_review_id,
    outcome_type,
    lane_status,
    created_at,
    updated_at
  ) VALUES (
    v_order_id,
    v_review_id,
    'replacement',
    'awaiting_supervisor_decision',
    now(),
    now()
  )
  ON CONFLICT(physical_receipt_review_id,outcome_type)
  DO UPDATE SET
    lane_status=CASE
      WHEN public.physical_receipt_outcome_lanes.lane_status='resolved'
        THEN public.physical_receipt_outcome_lanes.lane_status
      ELSE 'awaiting_supervisor_decision'
    END,
    updated_at=now()
  RETURNING id INTO v_lane_id;

  INSERT INTO public.physical_receipt_outcome_lane_items(
    lane_id,
    physical_remedy_allocation_id,
    dispute_id,
    dispute_line_id,
    created_at
  ) VALUES (
    v_lane_id,
    v_remedy_id,
    v_dispute_id,
    v_dispute_line_id,
    now()
  )
  ON CONFLICT(physical_remedy_allocation_id)
  DO UPDATE SET
    lane_id=EXCLUDED.lane_id,
    dispute_id=EXCLUDED.dispute_id,
    dispute_line_id=EXCLUDED.dispute_line_id;

  RAISE NOTICE 'SEEDED review_id=%, lane_id=%, remedy_id=%, dispute_id=%, dispute_line_id=%',
    v_review_id,v_lane_id,v_remedy_id,v_dispute_id,v_dispute_line_id;
END;
$$;

SELECT jsonb_build_object(
  'result','SEEDED',
  'review_id',lane.physical_receipt_review_id,
  'lane_id',lane.id,
  'order_id',lane.order_id,
  'lane_status',lane.lane_status,
  'outcome_type',lane.outcome_type,
  'items',jsonb_agg(jsonb_build_object(
    'physical_remedy_allocation_id',li.physical_remedy_allocation_id,
    'dispute_id',li.dispute_id,
    'dispute_line_id',li.dispute_line_id,
    'replacement_child_order_id',r.replacement_child_order_id,
    'replacement_child_tracking_allocation_id',r.replacement_child_tracking_allocation_id,
    'allocation_status',r.status,
    'conversation_status',dl.conversation_status,
    'dispute_status',d.status
  ) ORDER BY li.physical_remedy_allocation_id)
) AS result
FROM public.physical_receipt_outcome_lanes lane
JOIN public.physical_receipt_outcome_lane_items li ON li.lane_id=lane.id
JOIN public.physical_exception_remedy_allocations r ON r.id=li.physical_remedy_allocation_id
JOIN public.dispute_lines dl ON dl.id=li.dispute_line_id
JOIN public.disputes d ON d.id=li.dispute_id
WHERE lane.outcome_type='replacement'
  AND lane.lane_status='awaiting_supervisor_decision'
  AND r.replacement_child_order_id IS NULL
  AND d.replacement_child_order_id IS NULL
GROUP BY lane.id,lane.physical_receipt_review_id,lane.order_id,lane.lane_status,lane.outcome_type
ORDER BY lane.updated_at DESC
LIMIT 1;
