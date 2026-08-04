-- READ-ONLY diagnostic for the failed grouped-lane backfill postflight.
-- No DML. Safe to run after the migration rollback.

WITH eligible AS (
  SELECT
    review_row.id AS review_id,
    review_row.order_id,
    review_row.status AS review_status,
    remedy_row.id AS remedy_allocation_id,
    remedy_row.approved_remedy_type::text AS outcome_type,
    remedy_row.status AS remedy_status,
    remedy_row.dispute_line_id,
    dispute_line.dispute_id,
    matching_lane.id AS matching_lane_id,
    matching_item.lane_id AS matching_item_lane_id,
    any_item.lane_id AS existing_item_lane_id,
    any_lane.physical_receipt_review_id AS existing_item_review_id,
    any_lane.outcome_type::text AS existing_item_outcome_type
  FROM public.physical_receipt_reviews review_row
  JOIN public.physical_exception_remedy_allocations remedy_row
    ON remedy_row.physical_receipt_review_id = review_row.id
  LEFT JOIN public.dispute_lines dispute_line
    ON dispute_line.id = remedy_row.dispute_line_id
  LEFT JOIN public.physical_receipt_outcome_lanes matching_lane
    ON matching_lane.physical_receipt_review_id = review_row.id
   AND matching_lane.outcome_type = remedy_row.approved_remedy_type
  LEFT JOIN public.physical_receipt_outcome_lane_items matching_item
    ON matching_item.lane_id = matching_lane.id
   AND matching_item.physical_remedy_allocation_id = remedy_row.id
  LEFT JOIN public.physical_receipt_outcome_lane_items any_item
    ON any_item.physical_remedy_allocation_id = remedy_row.id
  LEFT JOIN public.physical_receipt_outcome_lanes any_lane
    ON any_lane.id = any_item.lane_id
  WHERE review_row.status = 'approved_to_existing_exception'
    AND remedy_row.approved_remedy_type IN ('refund', 'replacement')
    AND remedy_row.status IN ('approved', 'linked_to_exception', 'in_progress', 'completed')
), classified AS (
  SELECT *,
    CASE
      WHEN dispute_line_id IS NULL THEN 'missing_dispute_line'
      WHEN dispute_id IS NULL THEN 'dispute_line_has_no_dispute'
      WHEN matching_lane_id IS NULL THEN 'matching_lane_missing'
      WHEN matching_item_lane_id IS NULL AND existing_item_lane_id IS NOT NULL THEN 'item_linked_to_different_lane'
      WHEN matching_item_lane_id IS NULL THEN 'matching_lane_item_missing'
      ELSE 'complete'
    END AS diagnostic
  FROM eligible
)
SELECT jsonb_build_object(
  'probe', 'grouped_lane_backfill_postflight_failure_probe_v1',
  'result', 'READY',
  'eligible_count', COUNT(*),
  'complete_count', COUNT(*) FILTER (WHERE diagnostic = 'complete'),
  'incomplete_count', COUNT(*) FILTER (WHERE diagnostic <> 'complete'),
  'fixture_rows', COALESCE(jsonb_agg(to_jsonb(classified) ORDER BY outcome_type, remedy_allocation_id)
    FILTER (WHERE review_id = 'cb0752b1-7e34-4f4c-8157-f2f7140f58cd'::uuid), '[]'::jsonb),
  'incomplete_rows', COALESCE(jsonb_agg(to_jsonb(classified) ORDER BY review_id, outcome_type, remedy_allocation_id)
    FILTER (WHERE diagnostic <> 'complete'), '[]'::jsonb)
) AS result
FROM classified;
