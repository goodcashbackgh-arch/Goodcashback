-- Read-only probe for the exact structural anchor used by the grouped refund regression.
-- Returns every dispute line counted by the live exact-coverage guard.

WITH anchor AS (
  SELECT
    r.id AS physical_remedy_allocation_id,
    r.physical_receipt_review_id,
    r.dispute_line_id,
    dl.dispute_id,
    pr.order_id,
    r.receipt_line_disposition_id,
    r.tracking_line_allocation_id,
    r.supplier_invoice_line_id
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr
    ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl
    ON dl.id=r.dispute_line_id
  JOIN public.disputes d
    ON d.id=dl.dispute_id
   AND d.order_id=pr.order_id
  JOIN public.physical_receipt_review_dispute_links l
    ON l.physical_receipt_review_id=pr.id
   AND l.dispute_id=d.id
  WHERE r.dispute_line_id IS NOT NULL
    AND r.receipt_line_disposition_id IS NOT NULL
    AND r.tracking_line_allocation_id IS NOT NULL
    AND r.supplier_invoice_line_id IS NOT NULL
  ORDER BY r.created_at,r.id
  LIMIT 1
), counted_lines AS (
  SELECT
    dl.id AS dispute_line_id,
    dl.dispute_id,
    dl.physical_remedy_allocation_id,
    dl.resolved_at,
    dl.line_status,
    dl.resolution_method,
    dl.conversation_status,
    (dl.resolved_at IS NULL AND dl.physical_remedy_allocation_id IS NOT NULL) AS counted_by_guard,
    EXISTS (
      SELECT 1
      FROM public.physical_receipt_outcome_lane_items li
      WHERE li.dispute_line_id=dl.id
    ) AS currently_in_any_lane
  FROM public.dispute_lines dl
  JOIN anchor a ON a.dispute_id=dl.dispute_id
)
SELECT jsonb_build_object(
  'probe','grouped_refund_anchor_dispute_coverage_v1',
  'result',CASE WHEN EXISTS(SELECT 1 FROM anchor) THEN 'READY' ELSE 'BLOCKED' END,
  'anchor',(SELECT to_jsonb(anchor) FROM anchor),
  'guard_count',(SELECT COUNT(*) FROM counted_lines WHERE counted_by_guard),
  'counted_lines',(
    SELECT COALESCE(jsonb_agg(to_jsonb(counted_lines) ORDER BY dispute_line_id),'[]'::jsonb)
    FROM counted_lines
    WHERE counted_by_guard
  ),
  'all_dispute_lines',(
    SELECT COALESCE(jsonb_agg(to_jsonb(counted_lines) ORDER BY dispute_line_id),'[]'::jsonb)
    FROM counted_lines
  )
) AS result;
