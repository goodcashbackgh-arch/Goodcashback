-- Read-only diagnostic for the rollback regression fixture gate.
-- Shows why existing replacement disputes do or do not qualify.

WITH candidate_base AS (
  SELECT
    d.id AS dispute_id,
    d.order_id,
    d.status AS dispute_status,
    d.desired_outcome,
    d.resolved_at AS dispute_resolved_at,
    d.replacement_child_order_id AS dispute_child_order_id,
    dl.id AS dispute_line_id,
    dl.resolved_at AS line_resolved_at,
    dl.conversation_status,
    dl.resolved_via_child_order_id,
    dl.physical_remedy_allocation_id,
    r.id AS remedy_id,
    r.approved_remedy_type,
    r.approved_remedy_qty,
    r.status AS remedy_status,
    r.replacement_child_order_id AS remedy_child_order_id,
    r.replacement_child_tracking_allocation_id AS remedy_child_tracking_id,
    r.tracking_line_allocation_id AS source_allocation_id,
    src.tracking_submission_id AS source_tracking_submission_id,
    (SELECT COUNT(*) FROM public.dispute_lines x WHERE x.dispute_id=d.id AND x.resolved_at IS NULL) AS active_line_count,
    EXISTS (
      SELECT 1 FROM public.dispute_messages dm
      WHERE dm.dispute_id=d.id
        AND dm.message_type='retailer_reply'
        AND dm.counterparty='retailer'
    ) AS has_retailer_reply,
    EXISTS (
      SELECT 1 FROM public.physical_replacement_same_order_routes sr
      WHERE sr.physical_remedy_allocation_id=r.id OR sr.dispute_line_id=dl.id
    ) AS already_routed,
    EXISTS (
      SELECT 1
      FROM public.order_tracking_submissions ots
      WHERE ots.order_id=d.order_id
        AND ots.superseded_at IS NULL
        AND ots.id IS DISTINCT FROM src.tracking_submission_id
    ) AS has_different_active_successor_tracking,
    EXISTS (
      SELECT 1
      FROM public.orders o
      JOIN public.operator_importers oi ON oi.importer_id=o.importer_id AND oi.revoked_at IS NULL
      JOIN public.operators op ON op.id=oi.operator_id AND COALESCE(op.active,true)
      WHERE o.id=d.order_id
    ) AS has_active_authorised_operator,
    EXISTS (
      SELECT 1 FROM public.staff s
      WHERE COALESCE(s.active,true)
        AND s.role_type IN ('admin','supervisor')
    ) AS has_active_supervisor
  FROM public.disputes d
  LEFT JOIN public.dispute_lines dl ON dl.dispute_id=d.id
  LEFT JOIN public.physical_exception_remedy_allocations r ON r.id=dl.physical_remedy_allocation_id
  LEFT JOIN public.order_tracking_line_allocations src ON src.id=r.tracking_line_allocation_id
  WHERE d.desired_outcome='replacement'
)
SELECT
  *,
  array_remove(ARRAY[
    CASE WHEN dispute_status NOT IN ('raised','under_review') THEN 'dispute_not_open' END,
    CASE WHEN dispute_resolved_at IS NOT NULL THEN 'dispute_already_resolved' END,
    CASE WHEN dispute_child_order_id IS NOT NULL THEN 'legacy_child_already_linked' END,
    CASE WHEN dispute_line_id IS NULL THEN 'no_dispute_line' END,
    CASE WHEN line_resolved_at IS NOT NULL THEN 'line_already_resolved' END,
    CASE WHEN conversation_status IS DISTINCT FROM 'retailer_response_received' THEN 'retailer_response_not_received' END,
    CASE WHEN physical_remedy_allocation_id IS NULL THEN 'no_physical_remedy_link' END,
    CASE WHEN approved_remedy_type IS DISTINCT FROM 'replacement' THEN 'remedy_not_replacement' END,
    CASE WHEN remedy_status NOT IN ('approved','linked_to_exception') THEN 'remedy_not_acceptance_ready' END,
    CASE WHEN remedy_child_order_id IS NOT NULL OR remedy_child_tracking_id IS NOT NULL THEN 'legacy_child_remedy_link_exists' END,
    CASE WHEN source_allocation_id IS NULL THEN 'no_source_tracking_allocation' END,
    CASE WHEN active_line_count <> 1 THEN 'not_exactly_one_active_line' END,
    CASE WHEN NOT has_retailer_reply THEN 'no_retailer_reply_message' END,
    CASE WHEN already_routed THEN 'same_order_route_already_exists' END,
    CASE WHEN NOT has_different_active_successor_tracking THEN 'no_different_active_successor_tracking' END,
    CASE WHEN NOT has_active_authorised_operator THEN 'no_active_authorised_operator' END,
    CASE WHEN NOT has_active_supervisor THEN 'no_active_supervisor' END
  ], NULL) AS blockers,
  (
    dispute_status IN ('raised','under_review')
    AND dispute_resolved_at IS NULL
    AND dispute_child_order_id IS NULL
    AND dispute_line_id IS NOT NULL
    AND line_resolved_at IS NULL
    AND conversation_status='retailer_response_received'
    AND physical_remedy_allocation_id IS NOT NULL
    AND approved_remedy_type='replacement'
    AND remedy_status IN ('approved','linked_to_exception')
    AND remedy_child_order_id IS NULL
    AND remedy_child_tracking_id IS NULL
    AND source_allocation_id IS NOT NULL
    AND active_line_count=1
    AND has_retailer_reply
    AND NOT already_routed
    AND has_different_active_successor_tracking
    AND has_active_authorised_operator
    AND has_active_supervisor
  ) AS qualifies
FROM candidate_base
ORDER BY qualifies DESC, dispute_id, dispute_line_id;
