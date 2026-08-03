-- Grouped evidence linking for physical outcome lanes.
-- Links one dispute-scoped submission to explicitly selected exact lane items.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

CREATE OR REPLACE FUNCTION public.link_physical_outcome_refund_evidence_v1(
  p_lane_id uuid,
  p_remedy_allocation_ids uuid[],
  p_refund_evidence_submission_id uuid,
  p_evidence_role text DEFAULT 'refund_document'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
  v_lane public.physical_receipt_outcome_lanes%ROWTYPE;
  v_submission_dispute_id uuid;
  v_operator_id uuid;
  v_staff_id uuid;
  v_linked integer:=0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF p_evidence_role NOT IN ('refund_document','credit_note','refund_proof') THEN RAISE EXCEPTION 'Invalid refund evidence role.'; END IF;
  IF p_remedy_allocation_ids IS NULL OR cardinality(p_remedy_allocation_ids)=0 THEN RAISE EXCEPTION 'At least one lane item is required.'; END IF;
  IF cardinality(p_remedy_allocation_ids)<>(SELECT COUNT(DISTINCT x) FROM unnest(p_remedy_allocation_ids) x) THEN RAISE EXCEPTION 'Duplicate lane item IDs are not allowed.'; END IF;

  SELECT * INTO v_lane FROM public.physical_receipt_outcome_lanes WHERE id=p_lane_id FOR UPDATE;
  IF v_lane.id IS NULL THEN RAISE EXCEPTION 'Outcome lane not found.'; END IF;
  IF v_lane.outcome_type<>'refund' THEN RAISE EXCEPTION 'Refund evidence can only be linked to a refund lane.'; END IF;

  SELECT dispute_id INTO v_submission_dispute_id
  FROM public.dispute_refund_evidence_submissions
  WHERE id=p_refund_evidence_submission_id;
  IF v_submission_dispute_id IS NULL THEN RAISE EXCEPTION 'Refund evidence submission not found.'; END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id=auth.uid() AND COALESCE(s.active,true) AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    SELECT op.id INTO v_operator_id
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id=op.id AND oi.revoked_at IS NULL
    JOIN public.orders o ON o.id=v_lane.order_id AND o.importer_id=oi.importer_id
    WHERE op.auth_user_id=auth.uid() AND COALESCE(op.active,true)
    LIMIT 1;
    IF v_operator_id IS NULL THEN RAISE EXCEPTION 'User is not authorized for this lane.'; END IF;
  END IF;

  PERFORM 1 FROM public.physical_receipt_outcome_lane_items li
  WHERE li.lane_id=p_lane_id AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids)
  ORDER BY li.physical_remedy_allocation_id FOR UPDATE;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_items li
      WHERE li.lane_id=p_lane_id AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids))
     <> cardinality(p_remedy_allocation_ids)
  THEN RAISE EXCEPTION 'One or more selected items do not belong to the lane.'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id=p_lane_id
      AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids)
      AND li.dispute_id IS DISTINCT FROM v_submission_dispute_id
  ) THEN RAISE EXCEPTION 'Refund evidence submission dispute does not match every selected lane item.'; END IF;

  INSERT INTO public.physical_receipt_outcome_refund_evidence_links(
    refund_evidence_submission_id,lane_id,physical_remedy_allocation_id,evidence_role,
    linked_by_operator_id,linked_by_staff_id
  )
  SELECT p_refund_evidence_submission_id,p_lane_id,x,p_evidence_role,v_operator_id,v_staff_id
  FROM unnest(p_remedy_allocation_ids) x
  ON CONFLICT(refund_evidence_submission_id,physical_remedy_allocation_id,evidence_role) DO NOTHING;
  GET DIAGNOSTICS v_linked=ROW_COUNT;

  RETURN jsonb_build_object('ok',true,'lane_id',p_lane_id,'submission_id',p_refund_evidence_submission_id,
    'evidence_role',p_evidence_role,'selected_items',cardinality(p_remedy_allocation_ids),'new_links',v_linked,
    'idempotent_existing_links',cardinality(p_remedy_allocation_ids)-v_linked);
END;
$function$;

CREATE OR REPLACE FUNCTION public.link_physical_outcome_return_tracking_v1(
  p_lane_id uuid,
  p_remedy_allocation_ids uuid[],
  p_return_tracking_submission_id uuid,
  p_evidence_role text DEFAULT 'collection_or_return'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
  v_lane public.physical_receipt_outcome_lanes%ROWTYPE;
  v_submission_dispute_id uuid;
  v_operator_id uuid;
  v_staff_id uuid;
  v_linked integer:=0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF p_evidence_role NOT IN ('collection','return','collection_or_return') THEN RAISE EXCEPTION 'Invalid return tracking role.'; END IF;
  IF p_remedy_allocation_ids IS NULL OR cardinality(p_remedy_allocation_ids)=0 THEN RAISE EXCEPTION 'At least one lane item is required.'; END IF;
  IF cardinality(p_remedy_allocation_ids)<>(SELECT COUNT(DISTINCT x) FROM unnest(p_remedy_allocation_ids) x) THEN RAISE EXCEPTION 'Duplicate lane item IDs are not allowed.'; END IF;

  SELECT * INTO v_lane FROM public.physical_receipt_outcome_lanes WHERE id=p_lane_id FOR UPDATE;
  IF v_lane.id IS NULL THEN RAISE EXCEPTION 'Outcome lane not found.'; END IF;

  SELECT dispute_id INTO v_submission_dispute_id
  FROM public.dispute_return_tracking_submissions
  WHERE id=p_return_tracking_submission_id;
  IF v_submission_dispute_id IS NULL THEN RAISE EXCEPTION 'Return tracking submission not found.'; END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id=auth.uid() AND COALESCE(s.active,true) AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    SELECT op.id INTO v_operator_id
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id=op.id AND oi.revoked_at IS NULL
    JOIN public.orders o ON o.id=v_lane.order_id AND o.importer_id=oi.importer_id
    WHERE op.auth_user_id=auth.uid() AND COALESCE(op.active,true)
    LIMIT 1;
    IF v_operator_id IS NULL THEN RAISE EXCEPTION 'User is not authorized for this lane.'; END IF;
  END IF;

  PERFORM 1 FROM public.physical_receipt_outcome_lane_items li
  WHERE li.lane_id=p_lane_id AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids)
  ORDER BY li.physical_remedy_allocation_id FOR UPDATE;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_items li
      WHERE li.lane_id=p_lane_id AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids))
     <> cardinality(p_remedy_allocation_ids)
  THEN RAISE EXCEPTION 'One or more selected items do not belong to the lane.'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id=p_lane_id
      AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids)
      AND li.dispute_id IS DISTINCT FROM v_submission_dispute_id
  ) THEN RAISE EXCEPTION 'Return tracking submission dispute does not match every selected lane item.'; END IF;

  INSERT INTO public.physical_receipt_outcome_return_tracking_links(
    return_tracking_submission_id,lane_id,physical_remedy_allocation_id,evidence_role,
    linked_by_operator_id,linked_by_staff_id
  )
  SELECT p_return_tracking_submission_id,p_lane_id,x,p_evidence_role,v_operator_id,v_staff_id
  FROM unnest(p_remedy_allocation_ids) x
  ON CONFLICT(return_tracking_submission_id,physical_remedy_allocation_id,evidence_role) DO NOTHING;
  GET DIAGNOSTICS v_linked=ROW_COUNT;

  RETURN jsonb_build_object('ok',true,'lane_id',p_lane_id,'submission_id',p_return_tracking_submission_id,
    'evidence_role',p_evidence_role,'selected_items',cardinality(p_remedy_allocation_ids),'new_links',v_linked,
    'idempotent_existing_links',cardinality(p_remedy_allocation_ids)-v_linked);
END;
$function$;

REVOKE ALL ON FUNCTION public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text) TO authenticated,service_role;

DO $postflight$
BEGIN
  IF md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738'
     OR md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233'
     OR md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679'
  THEN RAISE EXCEPTION 'Protected Mini Build definition changed.'; END IF;
END
$postflight$;

NOTIFY pgrst,'reload schema';
COMMIT;
