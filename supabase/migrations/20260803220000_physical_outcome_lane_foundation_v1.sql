-- Governed by HYBRID_PHYSICAL_RECEIPT_OUTCOME_LANE_GROUPING_ADDENDUM_v1.
-- Additive grouping only. Existing disputes, refund evidence, same-order routes and Mini Builds remain unchanged.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $preflight$
BEGIN
  IF to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.dispute_messages') IS NULL
     OR to_regclass('public.dispute_refund_evidence_submissions') IS NULL
     OR to_regclass('public.dispute_return_tracking_submissions') IS NULL
  THEN RAISE EXCEPTION 'Outcome-lane prerequisites are missing.'; END IF;

  IF md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738'
     OR md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233'
     OR md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679'
  THEN RAISE EXCEPTION 'Protected Mini Build fingerprint drift.'; END IF;
END
$preflight$;

CREATE TABLE public.physical_receipt_outcome_lanes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  physical_receipt_review_id uuid NOT NULL REFERENCES public.physical_receipt_reviews(id) ON DELETE RESTRICT,
  outcome_type text NOT NULL CHECK (outcome_type IN ('refund','replacement')),
  lane_status text NOT NULL DEFAULT 'open' CHECK (lane_status IN (
    'open','retailer_contacted','retailer_response_partial','retailer_response_complete',
    'awaiting_supervisor_decision','partially_resolved','resolved','cancelled'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (physical_receipt_review_id, outcome_type)
);

CREATE TABLE public.physical_receipt_outcome_lane_items (
  lane_id uuid NOT NULL REFERENCES public.physical_receipt_outcome_lanes(id) ON DELETE RESTRICT,
  physical_remedy_allocation_id uuid NOT NULL UNIQUE REFERENCES public.physical_exception_remedy_allocations(id) ON DELETE RESTRICT,
  dispute_id uuid REFERENCES public.disputes(id) ON DELETE RESTRICT,
  dispute_line_id uuid UNIQUE REFERENCES public.dispute_lines(id) ON DELETE RESTRICT,
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lane_id, physical_remedy_allocation_id)
);

CREATE TABLE public.physical_receipt_outcome_lane_updates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lane_id uuid NOT NULL REFERENCES public.physical_receipt_outcome_lanes(id) ON DELETE RESTRICT,
  retailer_outcome text NOT NULL CHECK (retailer_outcome IN ('still_waiting','retailer_accepted','retailer_disputed','more_info_requested')),
  update_text text,
  note text,
  submitted_by_operator_id uuid NOT NULL REFERENCES public.operators(id) ON DELETE RESTRICT,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  idempotency_key uuid,
  UNIQUE (lane_id, idempotency_key)
);

CREATE TABLE public.physical_receipt_outcome_lane_update_items (
  lane_update_id uuid NOT NULL REFERENCES public.physical_receipt_outcome_lane_updates(id) ON DELETE RESTRICT,
  physical_remedy_allocation_id uuid NOT NULL REFERENCES public.physical_exception_remedy_allocations(id) ON DELETE RESTRICT,
  dispute_message_id uuid REFERENCES public.dispute_messages(id) ON DELETE RESTRICT,
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lane_update_id, physical_remedy_allocation_id)
);

CREATE TABLE public.physical_receipt_outcome_refund_evidence_links (
  refund_evidence_submission_id uuid NOT NULL REFERENCES public.dispute_refund_evidence_submissions(id) ON DELETE RESTRICT,
  lane_id uuid NOT NULL REFERENCES public.physical_receipt_outcome_lanes(id) ON DELETE RESTRICT,
  physical_remedy_allocation_id uuid NOT NULL REFERENCES public.physical_exception_remedy_allocations(id) ON DELETE RESTRICT,
  evidence_role text NOT NULL DEFAULT 'refund_document' CHECK (evidence_role IN ('refund_document','credit_note','refund_proof')),
  linked_by_operator_id uuid REFERENCES public.operators(id) ON DELETE RESTRICT,
  linked_by_staff_id uuid REFERENCES public.staff(id) ON DELETE RESTRICT,
  linked_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(linked_by_operator_id,linked_by_staff_id)=1),
  PRIMARY KEY (refund_evidence_submission_id, physical_remedy_allocation_id, evidence_role)
);

CREATE TABLE public.physical_receipt_outcome_return_tracking_links (
  return_tracking_submission_id uuid NOT NULL REFERENCES public.dispute_return_tracking_submissions(id) ON DELETE RESTRICT,
  lane_id uuid NOT NULL REFERENCES public.physical_receipt_outcome_lanes(id) ON DELETE RESTRICT,
  physical_remedy_allocation_id uuid NOT NULL REFERENCES public.physical_exception_remedy_allocations(id) ON DELETE RESTRICT,
  evidence_role text NOT NULL DEFAULT 'collection_or_return' CHECK (evidence_role IN ('collection','return','collection_or_return')),
  linked_by_operator_id uuid REFERENCES public.operators(id) ON DELETE RESTRICT,
  linked_by_staff_id uuid REFERENCES public.staff(id) ON DELETE RESTRICT,
  linked_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(linked_by_operator_id,linked_by_staff_id)=1),
  PRIMARY KEY (return_tracking_submission_id, physical_remedy_allocation_id, evidence_role)
);

CREATE INDEX physical_receipt_outcome_lane_items_lane_idx ON public.physical_receipt_outcome_lane_items(lane_id);
CREATE INDEX physical_receipt_outcome_lane_updates_lane_idx ON public.physical_receipt_outcome_lane_updates(lane_id,submitted_at DESC);

ALTER TABLE public.physical_receipt_outcome_lanes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_receipt_outcome_lane_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_receipt_outcome_lane_updates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_receipt_outcome_lane_update_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_receipt_outcome_refund_evidence_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_receipt_outcome_return_tracking_links ENABLE ROW LEVEL SECURITY;

CREATE POLICY outcome_lanes_read_v1 ON public.physical_receipt_outcome_lanes FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.staff s WHERE s.auth_user_id=auth.uid() AND COALESCE(s.active,true))
  OR EXISTS (
    SELECT 1 FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id=op.id AND oi.revoked_at IS NULL
    JOIN public.orders o ON o.id=physical_receipt_outcome_lanes.order_id AND o.importer_id=oi.importer_id
    WHERE op.auth_user_id=auth.uid() AND COALESCE(op.active,true)
  )
);

CREATE POLICY outcome_lane_items_read_v1 ON public.physical_receipt_outcome_lane_items FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.physical_receipt_outcome_lanes l WHERE l.id=lane_id)
);
CREATE POLICY outcome_lane_updates_read_v1 ON public.physical_receipt_outcome_lane_updates FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.physical_receipt_outcome_lanes l WHERE l.id=lane_id)
);
CREATE POLICY outcome_lane_update_items_read_v1 ON public.physical_receipt_outcome_lane_update_items FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM public.physical_receipt_outcome_lane_updates u
    JOIN public.physical_receipt_outcome_lanes l ON l.id=u.lane_id
    WHERE u.id=lane_update_id
  )
);
CREATE POLICY outcome_lane_refund_evidence_read_v1 ON public.physical_receipt_outcome_refund_evidence_links FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.physical_receipt_outcome_lanes l WHERE l.id=lane_id)
);
CREATE POLICY outcome_lane_return_tracking_read_v1 ON public.physical_receipt_outcome_return_tracking_links FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.physical_receipt_outcome_lanes l WHERE l.id=lane_id)
);

CREATE FUNCTION public.materialize_physical_receipt_outcome_lanes_v1(p_review_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_lane_id uuid;
  v_type text;
  v_count integer;
  v_result jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_review FROM public.physical_receipt_reviews WHERE id=p_review_id FOR UPDATE;
  IF v_review.id IS NULL THEN RAISE EXCEPTION 'Physical receipt review not found.'; END IF;

  FOR v_type IN
    SELECT DISTINCT r.approved_remedy_type
    FROM public.physical_exception_remedy_allocations r
    WHERE r.physical_receipt_review_id=p_review_id
      AND r.approved_remedy_type IN ('refund','replacement')
      AND r.status IN ('approved','linked_to_exception','in_progress','completed')
    ORDER BY 1
  LOOP
    INSERT INTO public.physical_receipt_outcome_lanes(order_id,physical_receipt_review_id,outcome_type)
    VALUES(v_review.order_id,v_review.id,v_type)
    ON CONFLICT(physical_receipt_review_id,outcome_type)
    DO UPDATE SET updated_at=now()
    RETURNING id INTO v_lane_id;

    INSERT INTO public.physical_receipt_outcome_lane_items(
      lane_id,physical_remedy_allocation_id,dispute_id,dispute_line_id
    )
    SELECT v_lane_id,r.id,dl.dispute_id,r.dispute_line_id
    FROM public.physical_exception_remedy_allocations r
    LEFT JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
    WHERE r.physical_receipt_review_id=p_review_id
      AND r.approved_remedy_type=v_type
      AND r.status IN ('approved','linked_to_exception','in_progress','completed')
    ON CONFLICT(physical_remedy_allocation_id)
    DO UPDATE SET lane_id=EXCLUDED.lane_id,dispute_id=EXCLUDED.dispute_id,dispute_line_id=EXCLUDED.dispute_line_id;

    GET DIAGNOSTICS v_count=ROW_COUNT;
    v_result := v_result || jsonb_build_array(jsonb_build_object('lane_id',v_lane_id,'outcome_type',v_type,'items_touched',v_count));
  END LOOP;

  RETURN jsonb_build_object('ok',true,'review_id',p_review_id,'lanes',v_result);
END;
$function$;

CREATE FUNCTION public.operator_record_physical_outcome_lane_update_v1(
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
      INSERT INTO public.dispute_messages(dispute_id,message_type,counterparty,generated_by,body)
      VALUES(v_dispute_id,'retailer_reply','retailer','retailer_paste',btrim(p_update_text))
      RETURNING id INTO v_message_id;
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

  UPDATE public.physical_receipt_outcome_lanes
  SET lane_status=CASE
      WHEN p_retailer_outcome='still_waiting' THEN 'retailer_contacted'
      WHEN p_retailer_outcome='retailer_accepted' AND v_updated=(SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_items WHERE lane_id=p_lane_id)
        THEN 'retailer_response_complete'
      WHEN p_retailer_outcome='retailer_accepted' THEN 'retailer_response_partial'
      ELSE 'retailer_response_partial'
    END,
    updated_at=now()
  WHERE id=p_lane_id;

  RETURN jsonb_build_object(
    'ok',true,'lane_id',p_lane_id,'lane_update_id',v_update_id,
    'retailer_outcome',p_retailer_outcome,'updated_items',v_updated
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.materialize_physical_receipt_outcome_lanes_v1(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.materialize_physical_receipt_outcome_lanes_v1(uuid) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid) TO authenticated,service_role;

COMMENT ON TABLE public.physical_receipt_outcome_lanes IS 'Operational refund/replacement grouping by one physical receipt review and exact outcome. Exact remedy/dispute records remain authoritative underneath.';
COMMENT ON FUNCTION public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid) IS 'One grouped importer retailer update for explicitly selected exact items in one refund or replacement lane. Writes exact compatibility messages and item links atomically.';

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
