-- Governed read-model extension for grouped physical outcome lanes.
-- Adds later supervisor lane actions to the existing staff queue/detail RPC.
-- Does not change review decisions, lane decisions, replacement routing,
-- refund settlement, money movement, or audit authorities.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $preflight$
BEGIN
  IF md5(pg_get_functiondef('public.staff_physical_receipt_reviews_v1(uuid)'::regprocedure))
       <> 'c137cb73655d614c91b40261df365bae'
  THEN
    RAISE EXCEPTION 'Unexpected live staff physical receipt read definition; inspect before replacement.';
  END IF;

  IF to_regclass('public.physical_receipt_outcome_lanes') IS NULL
     OR to_regclass('public.physical_receipt_outcome_lane_items') IS NULL
     OR to_regclass('public.physical_receipt_outcome_lane_decisions') IS NULL
     OR to_regclass('public.physical_receipt_outcome_lane_decision_items') IS NULL
  THEN
    RAISE EXCEPTION 'Grouped physical outcome lane read prerequisites are missing.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.staff_physical_receipt_reviews_v1(
  p_review_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
  WITH caller AS (
    SELECT s.id
    FROM public.staff s
    WHERE s.auth_user_id=auth.uid()
      AND COALESCE(s.active,true)=true
      AND s.role_type IN ('admin','supervisor')
    ORDER BY s.id
    LIMIT 1
  ), allowed AS (
    SELECT review.*,c.id AS caller_staff_id
    FROM public.physical_receipt_reviews review
    JOIN caller c ON true
    WHERE (
      p_review_id IS NULL
      AND (
        review.status='awaiting_supervisor_review'
        OR EXISTS (
          SELECT 1
          FROM public.physical_receipt_outcome_lanes lane
          WHERE lane.physical_receipt_review_id=review.id
            AND lane.lane_status='awaiting_supervisor_decision'
        )
      )
    ) OR review.id=p_review_id
  ), rows AS (
    SELECT jsonb_build_object(
      'id',review.id,
      'status',review.status,
      'created_at',review.created_at,
      'updated_at',review.updated_at,
      'order_id',review.order_id,
      'order_ref',o.order_ref,
      'retailer_name',retailer.name,
      'tracking_submission_id',review.tracking_submission_id,
      'tracking_ref',tracking.tracking_ref,
      'receipt_id',review.receipt_id,
      'caller_staff_id',review.caller_staff_id,
      'importer_proposal_note',review.importer_proposal_note,
      'decision_note',review.decision_note,
      'affected_quantity',COALESCE((
        SELECT SUM(d.quantity)
        FROM public.shipper_package_receipt_line_dispositions d
        WHERE d.receipt_id=review.receipt_id
          AND d.disposition_type<>'clean'
      ),0),
      'dispositions',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id',d.id,
          'supplier_invoice_line_id',d.supplier_invoice_line_id,
          'item_description',sil.description,
          'disposition_type',d.disposition_type,
          'quantity',d.quantity,
          'condition_note',d.condition_note
        ) ORDER BY sil.line_order NULLS LAST,d.id)
        FROM public.shipper_package_receipt_line_dispositions d
        JOIN public.supplier_invoice_lines sil ON sil.id=d.supplier_invoice_line_id
        WHERE d.receipt_id=review.receipt_id
      ),'[]'::jsonb),
      'evidence',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id',e.id,
          'storage_object_path',e.storage_object_path,
          'original_filename',e.original_filename,
          'content_type',e.content_type,
          'display_order',e.display_order
        ) ORDER BY e.display_order,e.created_at,e.id)
        FROM public.shipper_package_receipt_evidence e
        WHERE e.receipt_id=review.receipt_id
      ),'[]'::jsonb),
      'proposals',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id',remedy.id,
          'receipt_line_disposition_id',remedy.receipt_line_disposition_id,
          'proposed_remedy_type',remedy.proposed_remedy_type,
          'proposed_remedy_qty',remedy.proposed_remedy_qty,
          'status',remedy.status,
          'approved_remedy_type',remedy.approved_remedy_type,
          'approved_remedy_qty',remedy.approved_remedy_qty,
          'supplier_cost_mode',remedy.supplier_cost_mode
        ) ORDER BY remedy.proposed_at,remedy.id)
        FROM public.physical_exception_remedy_allocations remedy
        WHERE remedy.physical_receipt_review_id=review.id
          AND remedy.status<>'cancelled'
      ),'[]'::jsonb),
      'linked_disputes',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'dispute_id',link.dispute_id,
          'remedy_type',link.desired_outcome
        ) ORDER BY link.created_at,link.dispute_id)
        FROM public.physical_receipt_review_dispute_links link
        WHERE link.physical_receipt_review_id=review.id
      ),'[]'::jsonb),
      'outcome_lanes',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id',lane.id,
          'outcome_type',lane.outcome_type,
          'lane_status',lane.lane_status,
          'created_at',lane.created_at,
          'updated_at',lane.updated_at,
          'can_decide',lane.lane_status='awaiting_supervisor_decision',
          'items',COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'physical_remedy_allocation_id',li.physical_remedy_allocation_id,
              'dispute_id',li.dispute_id,
              'dispute_line_id',li.dispute_line_id,
              'approved_remedy_type',remedy.approved_remedy_type,
              'approved_remedy_qty',remedy.approved_remedy_qty,
              'allocation_status',remedy.status,
              'customer_commercial_value_gbp',remedy.customer_commercial_value_gbp,
              'dispute_status',dispute.status,
              'refund_settlement_mode',dispute.refund_settlement_mode,
              'line_status',dl.line_status,
              'resolution_method',dl.resolution_method,
              'conversation_status',dl.conversation_status,
              'resolved_at',dl.resolved_at
            ) ORDER BY li.physical_remedy_allocation_id)
            FROM public.physical_receipt_outcome_lane_items li
            JOIN public.physical_exception_remedy_allocations remedy
              ON remedy.id=li.physical_remedy_allocation_id
            LEFT JOIN public.disputes dispute ON dispute.id=li.dispute_id
            LEFT JOIN public.dispute_lines dl ON dl.id=li.dispute_line_id
            WHERE li.lane_id=lane.id
          ),'[]'::jsonb),
          'latest_decision',(
            SELECT jsonb_build_object(
              'id',decision.id,
              'staff_id',decision.staff_id,
              'decision_type',decision.decision_type,
              'note',decision.note,
              'result_json',decision.result_json,
              'decided_at',decision.decided_at,
              'items',COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                  'physical_remedy_allocation_id',di.physical_remedy_allocation_id,
                  'dispute_id',di.dispute_id,
                  'decision_type',di.decision_type,
                  'route_id',di.route_id,
                  'authority_result',di.authority_result,
                  'decided_at',di.decided_at
                ) ORDER BY di.physical_remedy_allocation_id)
                FROM public.physical_receipt_outcome_lane_decision_items di
                WHERE di.lane_decision_id=decision.id
              ),'[]'::jsonb)
            )
            FROM public.physical_receipt_outcome_lane_decisions decision
            WHERE decision.lane_id=lane.id
            ORDER BY decision.decided_at DESC,decision.id DESC
            LIMIT 1
          )
        ) ORDER BY lane.outcome_type,lane.id)
        FROM public.physical_receipt_outcome_lanes lane
        WHERE lane.physical_receipt_review_id=review.id
      ),'[]'::jsonb)
    ) AS row_json
    FROM allowed review
    JOIN public.orders o ON o.id=review.order_id
    LEFT JOIN public.retailers retailer ON retailer.id=o.retailer_id
    JOIN public.order_tracking_submissions tracking ON tracking.id=review.tracking_submission_id
    ORDER BY review.created_at DESC,review.id DESC
  )
  SELECT jsonb_build_object(
    'action_count',(SELECT COUNT(*) FROM allowed),
    'initial_review_action_count',(
      SELECT COUNT(*) FROM allowed WHERE status='awaiting_supervisor_review'
    ),
    'outcome_lane_action_count',(
      SELECT COUNT(*)
      FROM public.physical_receipt_outcome_lanes lane
      JOIN allowed review ON review.id=lane.physical_receipt_review_id
      WHERE lane.lane_status='awaiting_supervisor_decision'
    ),
    'reviews',COALESCE((SELECT jsonb_agg(row_json) FROM rows),'[]'::jsonb)
  );
$function$;

REVOKE ALL ON FUNCTION public.staff_physical_receipt_reviews_v1(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.staff_physical_receipt_reviews_v1(uuid)
TO authenticated;

COMMENT ON FUNCTION public.staff_physical_receipt_reviews_v1(uuid) IS
'Active supervisor/admin queue and exact detail read for both initial physical receipt review decisions and later grouped refund/replacement outcome-lane decisions. Read-only and auth.uid()-bound.';

DO $postflight$
DECLARE
  v_def text:=pg_get_functiondef('public.staff_physical_receipt_reviews_v1(uuid)'::regprocedure);
BEGIN
  IF v_def NOT ILIKE '%outcome_lanes%'
     OR v_def NOT ILIKE '%caller_staff_id%'
     OR v_def NOT ILIKE '%lane_status=''awaiting_supervisor_decision''%'
     OR v_def NOT ILIKE '%physical_receipt_outcome_lane_decision_items%'
     OR v_def NOT ILIKE '%outcome_lane_action_count%'
     OR v_def NOT ILIKE '%review.status=''awaiting_supervisor_review''%'
  THEN
    RAISE EXCEPTION 'Staff grouped outcome-lane read extension did not install completely.';
  END IF;
END
$postflight$;

NOTIFY pgrst,'reload schema';
COMMIT;
