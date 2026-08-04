-- Rollback-only diagnostic: reproduce only the regression's lane/line fixture
-- and return the exact counts used by the live grouped-refund coverage guard.
-- Does not call any production authority function.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $fixture$
DECLARE
  s record;
  v_lane_id uuid:=gen_random_uuid();
BEGIN
  SELECT r.*,pr.order_id,dl.dispute_id
  INTO s
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
  JOIN public.disputes d ON d.id=dl.dispute_id AND d.order_id=pr.order_id
  JOIN public.physical_receipt_review_dispute_links l
    ON l.physical_receipt_review_id=pr.id AND l.dispute_id=d.id
  WHERE r.dispute_line_id IS NOT NULL
    AND r.receipt_line_disposition_id IS NOT NULL
    AND r.tracking_line_allocation_id IS NOT NULL
    AND r.supplier_invoice_line_id IS NOT NULL
  ORDER BY r.created_at,r.id
  LIMIT 1;

  IF s.id IS NULL THEN RAISE EXCEPTION 'BLOCKED: no structural anchor'; END IF;

  PERFORM set_config('app.test.guard_lane_id',v_lane_id::text,true);
  PERFORM set_config('app.test.guard_allocation_id',s.id::text,true);
  PERFORM set_config('app.test.guard_dispute_id',s.dispute_id::text,true);
  PERFORM set_config('app.test.guard_dispute_line_id',s.dispute_line_id::text,true);

  SET LOCAL session_replication_role=replica;

  UPDATE public.dispute_lines
  SET line_status='resolved',resolution_method='refund',resolved_at=COALESCE(resolved_at,now()),
      conversation_status='resolved_credit'
  WHERE dispute_id=s.dispute_id
    AND id<>s.dispute_line_id
    AND resolved_at IS NULL;

  UPDATE public.dispute_lines
  SET supplier_invoice_line_id=s.supplier_invoice_line_id,
      qty_impact=1,amount_impact_gbp=60,
      line_status='affected',resolution_method=NULL,resolved_at=NULL,
      resolved_via_child_order_id=NULL,conversation_status='retailer_response_received',
      intended_remedy='refund',physical_remedy_allocation_id=s.id
  WHERE id=s.dispute_line_id;

  UPDATE public.physical_exception_remedy_allocations
  SET proposed_remedy_type='refund',proposed_remedy_qty=1,
      approved_remedy_type='refund',approved_remedy_qty=1,
      dispute_line_id=s.dispute_line_id,
      customer_commercial_value_gbp=60,
      supplier_cost_mode='not_applicable',
      replacement_child_order_id=NULL,
      replacement_child_tracking_allocation_id=NULL,
      rerouted_to_remedy_allocation_id=NULL,
      status='linked_to_exception',updated_at=now()
  WHERE id=s.id;

  INSERT INTO public.physical_receipt_outcome_lanes(
    id,order_id,physical_receipt_review_id,outcome_type,lane_status
  ) VALUES(v_lane_id,s.order_id,s.physical_receipt_review_id,'refund','awaiting_supervisor_decision');

  INSERT INTO public.physical_receipt_outcome_lane_items(
    lane_id,physical_remedy_allocation_id,dispute_id,dispute_line_id
  ) VALUES(v_lane_id,s.id,s.dispute_id,s.dispute_line_id);

  SET LOCAL session_replication_role=origin;
END
$fixture$;

WITH inputs AS (
  SELECT
    current_setting('app.test.guard_lane_id')::uuid AS lane_id,
    current_setting('app.test.guard_allocation_id')::uuid AS allocation_id,
    current_setting('app.test.guard_dispute_id')::uuid AS dispute_id
), exact_guard AS (
  SELECT
    li.dispute_id,
    COUNT(*) FILTER (WHERE li.physical_remedy_allocation_id=(SELECT allocation_id FROM inputs)) AS selected_count,
    (
      SELECT COUNT(*)
      FROM public.dispute_lines dl2
      WHERE dl2.dispute_id=li.dispute_id
        AND dl2.resolved_at IS NULL
        AND dl2.physical_remedy_allocation_id IS NOT NULL
    ) AS unresolved_physical_count
  FROM public.physical_receipt_outcome_lane_items li
  WHERE li.lane_id=(SELECT lane_id FROM inputs)
    AND li.dispute_id=(SELECT dispute_id FROM inputs)
  GROUP BY li.dispute_id
), counted_lines AS (
  SELECT
    dl.id AS dispute_line_id,
    dl.physical_remedy_allocation_id,
    dl.resolved_at,
    dl.line_status,
    dl.resolution_method,
    dl.conversation_status
  FROM public.dispute_lines dl
  WHERE dl.dispute_id=(SELECT dispute_id FROM inputs)
    AND dl.resolved_at IS NULL
    AND dl.physical_remedy_allocation_id IS NOT NULL
)
SELECT jsonb_build_object(
  'probe','grouped_refund_fixture_guard_counts_v1',
  'result',CASE
    WHEN (SELECT selected_count FROM exact_guard)=(SELECT unresolved_physical_count FROM exact_guard)
    THEN 'MATCH'
    ELSE 'MISMATCH'
  END,
  'lane_id',(SELECT lane_id FROM inputs),
  'allocation_id',(SELECT allocation_id FROM inputs),
  'dispute_id',(SELECT dispute_id FROM inputs),
  'selected_count',(SELECT selected_count FROM exact_guard),
  'unresolved_physical_count',(SELECT unresolved_physical_count FROM exact_guard),
  'counted_lines',(SELECT COALESCE(jsonb_agg(to_jsonb(counted_lines) ORDER BY dispute_line_id),'[]'::jsonb) FROM counted_lines)
) AS result;

ROLLBACK;
