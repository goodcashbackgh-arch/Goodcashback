-- Grouped supervisor decisions for physical outcome lanes.
-- Delegates to existing child-free replacement and refund settlement-credit authorities.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

CREATE TABLE public.physical_receipt_outcome_lane_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lane_id uuid NOT NULL REFERENCES public.physical_receipt_outcome_lanes(id) ON DELETE RESTRICT,
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  outcome_type text NOT NULL CHECK (outcome_type IN ('refund','replacement')),
  decision_type text NOT NULL CHECK (decision_type IN ('refund_settlement_credit','replacement_accept')),
  request_hash text NOT NULL,
  note text,
  result_json jsonb,
  decided_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(lane_id,request_hash)
);

CREATE TABLE public.physical_receipt_outcome_lane_decision_items (
  lane_decision_id uuid NOT NULL REFERENCES public.physical_receipt_outcome_lane_decisions(id) ON DELETE RESTRICT,
  physical_remedy_allocation_id uuid NOT NULL REFERENCES public.physical_exception_remedy_allocations(id) ON DELETE RESTRICT,
  dispute_id uuid NOT NULL REFERENCES public.disputes(id) ON DELETE RESTRICT,
  decision_type text NOT NULL CHECK (decision_type IN ('refund_settlement_credit','replacement_accept')),
  route_id uuid REFERENCES public.physical_replacement_same_order_routes(id) ON DELETE RESTRICT,
  authority_result jsonb,
  decided_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(lane_decision_id,physical_remedy_allocation_id)
);

CREATE INDEX physical_outcome_lane_decisions_lane_idx
  ON public.physical_receipt_outcome_lane_decisions(lane_id,decided_at DESC);

ALTER TABLE public.physical_receipt_outcome_lane_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_receipt_outcome_lane_decision_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY physical_outcome_lane_decisions_read_v1
ON public.physical_receipt_outcome_lane_decisions
FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.physical_receipt_outcome_lanes l WHERE l.id=lane_id));

CREATE POLICY physical_outcome_lane_decision_items_read_v1
ON public.physical_receipt_outcome_lane_decision_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.physical_receipt_outcome_lane_decisions d
    JOIN public.physical_receipt_outcome_lanes l ON l.id=d.lane_id
    WHERE d.id=lane_decision_id
  )
);

CREATE OR REPLACE FUNCTION public.staff_decide_physical_outcome_lane_v1(
  p_lane_id uuid,
  p_staff_id uuid,
  p_item_decisions jsonb,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
  v_lane public.physical_receipt_outcome_lanes%ROWTYPE;
  v_staff public.staff%ROWTYPE;
  v_decision_type text;
  v_count integer;
  v_request_hash text;
  v_decision_id uuid;
  v_existing_result jsonb;
  v_item record;
  v_route_id uuid;
  v_authority_result jsonb;
  v_results jsonb:='[]'::jsonb;
  v_resolved_count integer;
  v_total_count integer;
  v_lane_status text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF p_item_decisions IS NULL OR jsonb_typeof(p_item_decisions)<>'array' OR jsonb_array_length(p_item_decisions)=0 THEN
    RAISE EXCEPTION 'At least one item decision is required.';
  END IF;

  SELECT * INTO v_staff
  FROM public.staff
  WHERE id=p_staff_id AND auth_user_id=auth.uid() AND COALESCE(active,true)
    AND role_type IN ('admin','supervisor')
  FOR UPDATE;
  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active supervisor/admin authority not found.'; END IF;

  SELECT * INTO v_lane FROM public.physical_receipt_outcome_lanes WHERE id=p_lane_id FOR UPDATE;
  IF v_lane.id IS NULL THEN RAISE EXCEPTION 'Outcome lane not found.'; END IF;
  IF v_lane.lane_status='cancelled' THEN RAISE EXCEPTION 'Cancelled outcome lane cannot be decided.'; END IF;

  SELECT COUNT(*),MIN(x->>'decision'),MAX(x->>'decision')
  INTO v_count,v_decision_type,v_lane_status
  FROM jsonb_array_elements(p_item_decisions) x;

  IF v_count<>(
    SELECT COUNT(DISTINCT (x->>'physical_remedy_allocation_id'))
    FROM jsonb_array_elements(p_item_decisions) x
  ) THEN RAISE EXCEPTION 'Duplicate remedy allocation IDs are not allowed.'; END IF;

  IF v_decision_type IS NULL OR v_decision_type<>v_lane_status THEN
    RAISE EXCEPTION 'Mixed decisions are not allowed in one grouped call.';
  END IF;

  IF (v_lane.outcome_type='replacement' AND v_decision_type<>'replacement_accept')
     OR (v_lane.outcome_type='refund' AND v_decision_type<>'refund_settlement_credit')
  THEN RAISE EXCEPTION 'Decision type does not match the outcome lane.'; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_item_decisions) x
    WHERE COALESCE(x->>'physical_remedy_allocation_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) THEN RAISE EXCEPTION 'Every item decision requires a valid physical_remedy_allocation_id.'; END IF;

  PERFORM 1
  FROM public.physical_receipt_outcome_lane_items li
  JOIN public.physical_exception_remedy_allocations r ON r.id=li.physical_remedy_allocation_id
  JOIN public.dispute_lines dl ON dl.id=li.dispute_line_id
  JOIN public.disputes d ON d.id=li.dispute_id
  WHERE li.lane_id=p_lane_id
    AND li.physical_remedy_allocation_id IN (
      SELECT (x->>'physical_remedy_allocation_id')::uuid FROM jsonb_array_elements(p_item_decisions) x
    )
  ORDER BY li.physical_remedy_allocation_id
  FOR UPDATE OF li,r,dl,d;

  IF (
    SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id=p_lane_id
      AND li.physical_remedy_allocation_id IN (
        SELECT (x->>'physical_remedy_allocation_id')::uuid FROM jsonb_array_elements(p_item_decisions) x
      )
  )<>v_count THEN RAISE EXCEPTION 'One or more selected items do not belong to the lane.'; END IF;

  IF EXISTS (
    SELECT 1
    FROM public.physical_receipt_outcome_lane_items li
    JOIN public.physical_exception_remedy_allocations r ON r.id=li.physical_remedy_allocation_id
    WHERE li.lane_id=p_lane_id
      AND li.physical_remedy_allocation_id IN (
        SELECT (x->>'physical_remedy_allocation_id')::uuid FROM jsonb_array_elements(p_item_decisions) x
      )
      AND r.approved_remedy_type IS DISTINCT FROM v_lane.outcome_type
  ) THEN RAISE EXCEPTION 'Selected remedy type does not match the lane outcome.'; END IF;

  -- The refund authority resolves every unresolved line in a dispute. Require exact selected coverage.
  IF v_decision_type='refund_settlement_credit' AND EXISTS (
    SELECT 1
    FROM (
      SELECT li.dispute_id,
             COUNT(*) FILTER (WHERE li.physical_remedy_allocation_id IN (
               SELECT (x->>'physical_remedy_allocation_id')::uuid FROM jsonb_array_elements(p_item_decisions) x
             )) AS selected_count,
             (
               SELECT COUNT(*)
               FROM public.dispute_lines dl2
               WHERE dl2.dispute_id=li.dispute_id
                 AND dl2.resolved_at IS NULL
                 AND dl2.physical_remedy_allocation_id IS NOT NULL
             ) AS unresolved_physical_count
      FROM public.physical_receipt_outcome_lane_items li
      WHERE li.lane_id=p_lane_id
        AND li.dispute_id IN (
          SELECT li2.dispute_id
          FROM public.physical_receipt_outcome_lane_items li2
          WHERE li2.lane_id=p_lane_id
            AND li2.physical_remedy_allocation_id IN (
              SELECT (x->>'physical_remedy_allocation_id')::uuid FROM jsonb_array_elements(p_item_decisions) x
            )
        )
      GROUP BY li.dispute_id
    ) q
    WHERE q.selected_count<>q.unresolved_physical_count
  ) THEN RAISE EXCEPTION 'Refund decision must select every unresolved physical item in each affected dispute.'; END IF;

  SELECT md5(
    p_lane_id::text||'|'||p_staff_id::text||'|'||v_decision_type||'|'||
    COALESCE((
      SELECT string_agg((x->>'physical_remedy_allocation_id'),',' ORDER BY (x->>'physical_remedy_allocation_id'))
      FROM jsonb_array_elements(p_item_decisions) x
    ),'')||'|'||COALESCE(BTRIM(p_note),'')
  ) INTO v_request_hash;

  SELECT result_json INTO v_existing_result
  FROM public.physical_receipt_outcome_lane_decisions
  WHERE lane_id=p_lane_id AND request_hash=v_request_hash;
  IF v_existing_result IS NOT NULL THEN RETURN v_existing_result; END IF;

  INSERT INTO public.physical_receipt_outcome_lane_decisions(
    lane_id,staff_id,outcome_type,decision_type,request_hash,note
  ) VALUES(p_lane_id,p_staff_id,v_lane.outcome_type,v_decision_type,v_request_hash,NULLIF(BTRIM(COALESCE(p_note,'')),''))
  RETURNING id INTO v_decision_id;

  IF v_decision_type='replacement_accept' THEN
    FOR v_item IN
      SELECT li.physical_remedy_allocation_id,li.dispute_id
      FROM public.physical_receipt_outcome_lane_items li
      WHERE li.lane_id=p_lane_id
        AND li.physical_remedy_allocation_id IN (
          SELECT (x->>'physical_remedy_allocation_id')::uuid FROM jsonb_array_elements(p_item_decisions) x
        )
      ORDER BY li.physical_remedy_allocation_id
    LOOP
      v_route_id:=public.staff_accept_same_order_free_replacement_v1(
        v_item.dispute_id,p_staff_id,'free_replacement',p_note
      );
      v_authority_result:=jsonb_build_object('route_id',v_route_id);

      INSERT INTO public.physical_receipt_outcome_lane_decision_items(
        lane_decision_id,physical_remedy_allocation_id,dispute_id,decision_type,route_id,authority_result
      ) VALUES(v_decision_id,v_item.physical_remedy_allocation_id,v_item.dispute_id,v_decision_type,v_route_id,v_authority_result);

      v_results:=v_results||jsonb_build_array(jsonb_build_object(
        'physical_remedy_allocation_id',v_item.physical_remedy_allocation_id,
        'dispute_id',v_item.dispute_id,'decision',v_decision_type,'route_id',v_route_id
      ));
    END LOOP;
  ELSE
    FOR v_item IN
      SELECT li.dispute_id,
             array_agg(li.physical_remedy_allocation_id ORDER BY li.physical_remedy_allocation_id) AS allocation_ids
      FROM public.physical_receipt_outcome_lane_items li
      WHERE li.lane_id=p_lane_id
        AND li.physical_remedy_allocation_id IN (
          SELECT (x->>'physical_remedy_allocation_id')::uuid FROM jsonb_array_elements(p_item_decisions) x
        )
      GROUP BY li.dispute_id
      ORDER BY li.dispute_id
    LOOP
      v_authority_result:=public.staff_close_refund_exception_as_settlement_credit_v1(
        v_item.dispute_id,
        COALESCE((
          SELECT NULLIF(BTRIM(x->>'reason'),'')
          FROM jsonb_array_elements(p_item_decisions) x
          JOIN public.physical_receipt_outcome_lane_items li
            ON li.physical_remedy_allocation_id=(x->>'physical_remedy_allocation_id')::uuid
          WHERE li.dispute_id=v_item.dispute_id
          LIMIT 1
        ),'supervisor_confirmed_credit'),
        p_note
      );

      INSERT INTO public.physical_receipt_outcome_lane_decision_items(
        lane_decision_id,physical_remedy_allocation_id,dispute_id,decision_type,authority_result
      )
      SELECT v_decision_id,x,v_item.dispute_id,v_decision_type,v_authority_result
      FROM unnest(v_item.allocation_ids) x;

      SELECT v_results||jsonb_agg(jsonb_build_object(
        'physical_remedy_allocation_id',x,'dispute_id',v_item.dispute_id,
        'decision',v_decision_type,'authority_result',v_authority_result
      )) INTO v_results
      FROM unnest(v_item.allocation_ids) x;
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_total_count
  FROM public.physical_receipt_outcome_lane_items WHERE lane_id=p_lane_id;

  IF v_lane.outcome_type='replacement' THEN
    SELECT COUNT(*) INTO v_resolved_count
    FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id=p_lane_id
      AND EXISTS (
        SELECT 1 FROM public.physical_replacement_same_order_routes r
        WHERE r.physical_remedy_allocation_id=li.physical_remedy_allocation_id
          AND r.route_status<>'cancelled'
      );
  ELSE
    SELECT COUNT(*) INTO v_resolved_count
    FROM public.physical_receipt_outcome_lane_items li
    JOIN public.disputes d ON d.id=li.dispute_id
    WHERE li.lane_id=p_lane_id AND d.resolved_at IS NOT NULL;
  END IF;

  v_lane_status:=CASE WHEN v_resolved_count=v_total_count AND v_total_count>0 THEN 'resolved' ELSE 'partially_resolved' END;
  UPDATE public.physical_receipt_outcome_lanes
  SET lane_status=v_lane_status,updated_at=now()
  WHERE id=p_lane_id;

  v_existing_result:=jsonb_build_object(
    'ok',true,'lane_decision_id',v_decision_id,'lane_id',p_lane_id,
    'outcome_type',v_lane.outcome_type,'decision_type',v_decision_type,
    'selected_items',v_count,'resolved_items',v_resolved_count,
    'lane_item_count',v_total_count,'lane_status',v_lane_status,'items',v_results
  );

  UPDATE public.physical_receipt_outcome_lane_decisions
  SET result_json=v_existing_result WHERE id=v_decision_id;

  RETURN v_existing_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text) TO authenticated,service_role;

DO $postflight$
BEGIN
  IF md5(pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure)) <> '78e94d6d76bf1c160068a3fd97ae4a87'
     OR md5(pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure)) <> '0698d2ab2e7301881dac862a18284f52'
  THEN RAISE EXCEPTION 'Delegated supervisor authority fingerprint changed.'; END IF;

  IF md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738'
     OR md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233'
     OR md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679'
  THEN RAISE EXCEPTION 'Protected Mini Build definition changed.'; END IF;
END
$postflight$;

NOTIFY pgrst,'reload schema';
COMMIT;
