-- Hardens grouped physical outcome lane updates.
-- 1. Writes one compatibility dispute message per distinct dispute per lane update.
-- 2. Derives response completion cumulatively across accepted update items.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $preflight$
BEGIN
  IF to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing grouped outcome lane update function';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.operator_record_physical_outcome_lane_update_v1(
  p_lane_id uuid,
  p_remedy_allocation_ids uuid[],
  p_update_text text,
  p_retailer_outcome text,
  p_note text DEFAULT NULL,
  p_idempotency_key uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
  v_operator_id uuid;
  v_lane public.physical_receipt_outcome_lanes%ROWTYPE;
  v_status text;
  v_update_id uuid;
  v_remedy_id uuid;
  v_dispute_id uuid;
  v_message_id uuid;
  v_updated integer:=0;
  v_total_items integer;
  v_accepted_items integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF p_retailer_outcome NOT IN ('still_waiting','retailer_accepted','retailer_disputed','more_info_requested') THEN
    RAISE EXCEPTION 'Invalid retailer outcome.';
  END IF;
  IF p_remedy_allocation_ids IS NULL OR cardinality(p_remedy_allocation_ids)=0 THEN
    RAISE EXCEPTION 'At least one lane item is required.';
  END IF;
  IF cardinality(p_remedy_allocation_ids)<>(SELECT COUNT(DISTINCT x) FROM unnest(p_remedy_allocation_ids) x) THEN
    RAISE EXCEPTION 'Duplicate lane item IDs are not allowed.';
  END IF;
  IF p_retailer_outcome IN ('retailer_accepted','retailer_disputed') AND NULLIF(btrim(COALESCE(p_update_text,'')),'') IS NULL THEN
    RAISE EXCEPTION 'Retailer response text is required.';
  END IF;

  SELECT op.id INTO v_operator_id
  FROM public.operators op
  WHERE op.auth_user_id=auth.uid() AND COALESCE(op.active,true)
  LIMIT 1;
  IF v_operator_id IS NULL THEN RAISE EXCEPTION 'Active operator not found.'; END IF;

  SELECT * INTO v_lane FROM public.physical_receipt_outcome_lanes WHERE id=p_lane_id FOR UPDATE;
  IF v_lane.id IS NULL THEN RAISE EXCEPTION 'Outcome lane not found.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.operator_importers oi ON oi.importer_id=o.importer_id AND oi.operator_id=v_operator_id AND oi.revoked_at IS NULL
    WHERE o.id=v_lane.order_id
  ) THEN RAISE EXCEPTION 'Operator does not control this order importer.'; END IF;

  PERFORM 1
  FROM public.physical_receipt_outcome_lane_items li
  WHERE li.lane_id=p_lane_id AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids)
  ORDER BY li.physical_remedy_allocation_id
  FOR UPDATE;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_items li
      WHERE li.lane_id=p_lane_id AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids))
     <> cardinality(p_remedy_allocation_ids)
  THEN RAISE EXCEPTION 'One or more selected items do not belong to the lane.'; END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_update_id FROM public.physical_receipt_outcome_lane_updates
    WHERE lane_id=p_lane_id AND idempotency_key=p_idempotency_key;
    IF v_update_id IS NOT NULL THEN
      RETURN jsonb_build_object('ok',true,'idempotent_replay',true,'lane_update_id',v_update_id);
    END IF;
  END IF;

  INSERT INTO public.physical_receipt_outcome_lane_updates(
    lane_id,retailer_outcome,update_text,note,submitted_by_operator_id,idempotency_key
  ) VALUES(
    p_lane_id,p_retailer_outcome,NULLIF(btrim(COALESCE(p_update_text,'')),''),NULLIF(btrim(COALESCE(p_note,'')),''),v_operator_id,p_idempotency_key
  ) RETURNING id INTO v_update_id;

  v_status := CASE p_retailer_outcome
    WHEN 'still_waiting' THEN 'retailer_contacted'
    WHEN 'retailer_accepted' THEN 'retailer_response_received'
    WHEN 'retailer_disputed' THEN 'awaiting_retailer_resolution'
    WHEN 'more_info_requested' THEN 'retailer_draft_ready'
  END;

  FOR v_remedy_id,v_dispute_id IN
    SELECT li.physical_remedy_allocation_id,li.dispute_id
    FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id=p_lane_id AND li.physical_remedy_allocation_id=ANY(p_remedy_allocation_ids)
    ORDER BY li.physical_remedy_allocation_id
  LOOP
    IF v_dispute_id IS NULL THEN RAISE EXCEPTION 'Selected lane item has no dispute.'; END IF;

    v_message_id:=NULL;
    IF NULLIF(btrim(COALESCE(p_update_text,'')),'') IS NOT NULL THEN
      SELECT ui.dispute_message_id INTO v_message_id
      FROM public.physical_receipt_outcome_lane_update_items ui
      JOIN public.physical_receipt_outcome_lane_items li
        ON li.physical_remedy_allocation_id=ui.physical_remedy_allocation_id
       AND li.lane_id=p_lane_id
      WHERE ui.lane_update_id=v_update_id
        AND li.dispute_id=v_dispute_id
        AND ui.dispute_message_id IS NOT NULL
      LIMIT 1;

      IF v_message_id IS NULL THEN
        INSERT INTO public.dispute_messages(dispute_id,message_type,counterparty,generated_by,body)
        VALUES(v_dispute_id,'retailer_reply','retailer','retailer_paste',btrim(p_update_text))
        RETURNING id INTO v_message_id;
      END IF;
    END IF;

    UPDATE public.dispute_lines dl
    SET conversation_status=v_status
    FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id=p_lane_id
      AND li.physical_remedy_allocation_id=v_remedy_id
      AND dl.id=li.dispute_line_id
      AND dl.resolved_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selected lane item has no open dispute line.'; END IF;

    INSERT INTO public.physical_receipt_outcome_lane_update_items(
      lane_update_id,physical_remedy_allocation_id,dispute_message_id
    ) VALUES(v_update_id,v_remedy_id,v_message_id);
    v_updated:=v_updated+1;
  END LOOP;

  SELECT COUNT(*) INTO v_total_items
  FROM public.physical_receipt_outcome_lane_items
  WHERE lane_id=p_lane_id;

  SELECT COUNT(DISTINCT ui.physical_remedy_allocation_id) INTO v_accepted_items
  FROM public.physical_receipt_outcome_lane_update_items ui
  JOIN public.physical_receipt_outcome_lane_updates u ON u.id=ui.lane_update_id
  WHERE u.lane_id=p_lane_id
    AND u.retailer_outcome='retailer_accepted';

  UPDATE public.physical_receipt_outcome_lanes
  SET lane_status=CASE
      WHEN v_accepted_items=v_total_items AND v_total_items>0 THEN 'retailer_response_complete'
      WHEN v_accepted_items>0 THEN 'retailer_response_partial'
      WHEN p_retailer_outcome='still_waiting' THEN 'retailer_contacted'
      ELSE 'retailer_response_partial'
    END,
    updated_at=now()
  WHERE id=p_lane_id;

  RETURN jsonb_build_object(
    'ok',true,'lane_id',p_lane_id,'lane_update_id',v_update_id,
    'retailer_outcome',p_retailer_outcome,'updated_items',v_updated,
    'accepted_items_cumulative',v_accepted_items,'lane_item_count',v_total_items
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid) TO authenticated,service_role;

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
