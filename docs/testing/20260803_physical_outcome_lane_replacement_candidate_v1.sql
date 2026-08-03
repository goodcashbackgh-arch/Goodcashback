-- Read-only candidate finder for grouped replacement-lane regression.
-- Returns reviews with at least two approved replacement remedies, exact dispute lines,
-- and at least one active linked operator auth identity.

WITH candidates AS (
  SELECT
    r.physical_receipt_review_id,
    pr.order_id,
    pr.importer_id,
    COUNT(*) AS replacement_item_count,
    jsonb_agg(
      jsonb_build_object(
        'physical_remedy_allocation_id', r.id,
        'approved_remedy_qty', r.approved_remedy_qty,
        'status', r.status,
        'dispute_line_id', r.dispute_line_id,
        'dispute_id', dl.dispute_id,
        'supplier_invoice_line_id', r.supplier_invoice_line_id,
        'replacement_child_order_id', r.replacement_child_order_id
      )
      ORDER BY r.id
    ) AS items
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr
    ON pr.id = r.physical_receipt_review_id
  JOIN public.dispute_lines dl
    ON dl.id = r.dispute_line_id
  WHERE r.approved_remedy_type = 'replacement'
    AND r.status IN ('approved','linked_to_exception','in_progress','completed')
    AND dl.resolved_at IS NULL
  GROUP BY r.physical_receipt_review_id, pr.order_id, pr.importer_id
  HAVING COUNT(*) >= 2
), linked_operators AS (
  SELECT
    c.*,
    op.id AS operator_id,
    op.auth_user_id AS operator_auth_user_id,
    row_number() OVER (
      PARTITION BY c.physical_receipt_review_id
      ORDER BY op.id
    ) AS operator_rank
  FROM candidates c
  JOIN public.operator_importers oi
    ON oi.importer_id = c.importer_id
   AND oi.revoked_at IS NULL
  JOIN public.operators op
    ON op.id = oi.operator_id
   AND COALESCE(op.active,true)
   AND op.auth_user_id IS NOT NULL
)
SELECT jsonb_build_object(
  'candidate_finder','physical_outcome_lane_replacement_v1',
  'candidate_count',COUNT(*),
  'candidates',COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'physical_receipt_review_id',physical_receipt_review_id,
        'order_id',order_id,
        'importer_id',importer_id,
        'replacement_item_count',replacement_item_count,
        'operator_id',operator_id,
        'operator_auth_user_id',operator_auth_user_id,
        'items',items
      )
      ORDER BY physical_receipt_review_id
    ) FILTER (WHERE operator_rank=1),
    '[]'::jsonb
  )
) AS result
FROM linked_operators
WHERE operator_rank=1;
