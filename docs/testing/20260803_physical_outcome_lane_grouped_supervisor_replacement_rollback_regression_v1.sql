-- Rollback-only behavioral regression for grouped supervisor replacement decisions.
-- Proves two exact remedies on two disputes are accepted atomically into one resolved lane.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $fixture$
DECLARE
  s record;
  v_lane_id uuid:=gen_random_uuid();
  v_clone_dispute_id uuid:=gen_random_uuid();
  v_clone_line_id uuid:=gen_random_uuid();
  v_clone_allocation_id uuid:=gen_random_uuid();
  v_clone_supplier_invoice_line_id uuid;
  v_generated_by text;
BEGIN
  SELECT r.*,pr.order_id,pr.importer_id,dl.dispute_id,dl.supplier_invoice_line_id,
         d.raised_by_operator_id,op.auth_user_id AS operator_auth_user_id,
         st.id AS staff_id,st.auth_user_id AS staff_auth_user_id
  INTO s
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
  JOIN public.disputes d ON d.id=dl.dispute_id
  JOIN public.operator_importers oi ON oi.importer_id=pr.importer_id AND oi.revoked_at IS NULL
  JOIN public.operators op ON op.id=oi.operator_id AND COALESCE(op.active,true) AND op.auth_user_id IS NOT NULL
  CROSS JOIN LATERAL (
    SELECT st.* FROM public.staff st
    WHERE COALESCE(st.active,true) AND st.role_type IN ('admin','supervisor') AND st.auth_user_id IS NOT NULL
    ORDER BY st.id LIMIT 1
  ) st
  WHERE r.approved_remedy_type='replacement'
  ORDER BY r.created_at,r.id
  LIMIT 1;

  IF s.id IS NULL THEN RAISE EXCEPTION 'FAIL: no replacement structural fixture source'; END IF;

  SELECT dm.generated_by INTO v_generated_by
  FROM public.dispute_messages dm
  WHERE dm.generated_by IS NOT NULL
  ORDER BY dm.created_at,dm.id
  LIMIT 1;
  IF v_generated_by IS NULL THEN
    RAISE EXCEPTION 'FAIL: no valid dispute_messages.generated_by provenance value is available';
  END IF;

  SELECT sil.id INTO v_clone_supplier_invoice_line_id
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id=sil.supplier_invoice_id AND si.order_id=s.order_id
  WHERE sil.id<>s.supplier_invoice_line_id
  ORDER BY sil.id LIMIT 1;
  IF v_clone_supplier_invoice_line_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: no second supplier invoice line on the order for grouped replacement fixture';
  END IF;

  PERFORM set_config('app.test.lane_id',v_lane_id::text,true);
  PERFORM set_config('app.test.source_allocation_id',s.id::text,true);
  PERFORM set_config('app.test.clone_allocation_id',v_clone_allocation_id::text,true);
  PERFORM set_config('app.test.staff_id',s.staff_id::text,true);
  PERFORM set_config('app.test.staff_auth_user_id',s.staff_auth_user_id::text,true);
  PERFORM set_config('app.test.order_id',s.order_id::text,true);

  SET LOCAL session_replication_role=replica;

  UPDATE public.disputes
  SET desired_outcome='replacement',status='raised',resolved_at=NULL,replacement_child_order_id=NULL
  WHERE id=s.dispute_id;

  UPDATE public.dispute_lines
  SET line_status='affected',resolution_method=NULL,resolved_at=NULL,resolved_via_child_order_id=NULL,
      conversation_status='retailer_response_received',intended_remedy='replacement',physical_remedy_allocation_id=s.id
  WHERE id=s.dispute_line_id;

  UPDATE public.physical_exception_remedy_allocations
  SET approved_remedy_type='replacement',approved_remedy_qty=GREATEST(1,trunc(COALESCE(approved_remedy_qty,proposed_remedy_qty,1))),
      approved_by_staff_id=s.staff_id,approved_at=COALESCE(approved_at,now()),status='linked_to_exception',
      supplier_cost_mode='free_replacement',replacement_child_order_id=NULL,
      replacement_child_tracking_allocation_id=NULL,rerouted_to_remedy_allocation_id=NULL
  WHERE id=s.id;

  INSERT INTO public.disputes(
    id,order_id,raised_at,raised_by_operator_id,issue_type,desired_outcome,refund_settlement_mode,
    liable_party,stage_detected,amount_impact_gbp,comments_initial,status,reviewed_by_staff_id,
    reviewed_at,refund_approved_by_staff_id,refund_approved_at,customer_credit_note_sales_invoice_id,
    replacement_child_order_id,resolved_at,sop_version
  )
  SELECT v_clone_dispute_id,order_id,now(),raised_by_operator_id,issue_type,'replacement',NULL,
         liable_party,stage_detected,amount_impact_gbp,'Rollback grouped supervisor replacement fixture.',
         'raised',NULL,NULL,NULL,NULL,NULL,NULL,NULL,sop_version
  FROM public.disputes WHERE id=s.dispute_id;

  INSERT INTO public.dispute_lines(
    id,dispute_id,supplier_invoice_line_id,qty_impact,amount_impact_gbp,line_status,
    resolution_method,resolved_at,resolved_via_child_order_id,created_at,
    conversation_status,intended_remedy,physical_remedy_allocation_id
  )
  SELECT v_clone_line_id,v_clone_dispute_id,v_clone_supplier_invoice_line_id,
         GREATEST(1,qty_impact),GREATEST(0.01,amount_impact_gbp),'affected',NULL,NULL,NULL,now(),
         'retailer_response_received','replacement',v_clone_allocation_id
  FROM public.dispute_lines WHERE id=s.dispute_line_id;

  INSERT INTO public.physical_exception_remedy_allocations(
    id,physical_receipt_review_id,receipt_line_disposition_id,tracking_line_allocation_id,supplier_invoice_line_id,
    proposed_remedy_type,proposed_remedy_qty,proposed_by_operator_id,proposed_at,
    approved_remedy_type,approved_remedy_qty,approved_by_staff_id,approved_at,
    dispute_line_id,supplier_claim_amount_gbp,customer_commercial_value_gbp,supplier_cost_mode,
    replacement_child_order_id,replacement_child_tracking_allocation_id,status,rerouted_to_remedy_allocation_id,created_at,updated_at
  )
  SELECT v_clone_allocation_id,physical_receipt_review_id,receipt_line_disposition_id,tracking_line_allocation_id,
         v_clone_supplier_invoice_line_id,'replacement',GREATEST(1,trunc(COALESCE(proposed_remedy_qty,1))),proposed_by_operator_id,now(),
         'replacement',GREATEST(1,trunc(COALESCE(approved_remedy_qty,proposed_remedy_qty,1))),s.staff_id,now(),
         v_clone_line_id,supplier_claim_amount_gbp,customer_commercial_value_gbp,'free_replacement',NULL,NULL,
         'linked_to_exception',NULL,now(),now()
  FROM public.physical_exception_remedy_allocations WHERE id=s.id;

  INSERT INTO public.dispute_messages(dispute_id,message_type,counterparty,body,generated_by)
  VALUES
    (s.dispute_id,'retailer_reply','retailer','Rollback retailer accepted replacement.',v_generated_by),
    (v_clone_dispute_id,'retailer_reply','retailer','Rollback retailer accepted replacement.',v_generated_by);

  INSERT INTO public.physical_receipt_outcome_lanes(id,order_id,physical_receipt_review_id,outcome_type,lane_status)
  VALUES(v_lane_id,s.order_id,s.physical_receipt_review_id,'replacement','awaiting_supervisor_decision');

  INSERT INTO public.physical_receipt_outcome_lane_items(lane_id,physical_remedy_allocation_id,dispute_id,dispute_line_id)
  VALUES
    (v_lane_id,s.id,s.dispute_id,s.dispute_line_id),
    (v_lane_id,v_clone_allocation_id,v_clone_dispute_id,v_clone_line_id);

  SET LOCAL session_replication_role=origin;
END
$fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',current_setting('app.test.staff_auth_user_id'),'role','authenticated'
)::text,true);

DO $exercise$
DECLARE
  l uuid:=current_setting('app.test.lane_id')::uuid;
  a1 uuid:=current_setting('app.test.source_allocation_id')::uuid;
  a2 uuid:=current_setting('app.test.clone_allocation_id')::uuid;
  st uuid:=current_setting('app.test.staff_id')::uuid;
  o uuid:=current_setting('app.test.order_id')::uuid;
  payload jsonb;
  r1 jsonb;
  r2 jsonb;
  route_count integer;
  child_count integer;
BEGIN
  payload:=jsonb_build_array(
    jsonb_build_object('physical_remedy_allocation_id',a1,'decision','replacement_accept'),
    jsonb_build_object('physical_remedy_allocation_id',a2,'decision','replacement_accept')
  );

  SELECT COUNT(*) INTO child_count FROM public.orders WHERE parent_order_id=o;

  r1:=public.staff_decide_physical_outcome_lane_v1(l,st,payload,'Rollback grouped replacement acceptance.');
  IF (r1->>'selected_items')::integer<>2 OR (r1->>'resolved_items')::integer<>2 OR r1->>'lane_status'<>'resolved' THEN
    RAISE EXCEPTION 'FAIL: grouped replacement decision result incorrect: %',r1;
  END IF;

  SELECT COUNT(*) INTO route_count
  FROM public.physical_replacement_same_order_routes
  WHERE physical_remedy_allocation_id IN (a1,a2) AND route_status<>'cancelled';
  IF route_count<>2 THEN RAISE EXCEPTION 'FAIL: expected two exact same-order routes, got %',route_count; END IF;

  IF (SELECT COUNT(*) FROM public.orders WHERE parent_order_id=o)<>child_count THEN
    RAISE EXCEPTION 'FAIL: replacement child-order count changed';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.disputes d
    JOIN public.physical_receipt_outcome_lane_items li ON li.dispute_id=d.id
    WHERE li.lane_id=l AND d.replacement_child_order_id IS NOT NULL
  ) THEN RAISE EXCEPTION 'FAIL: replacement child-order link was created'; END IF;

  r2:=public.staff_decide_physical_outcome_lane_v1(l,st,payload,'Rollback grouped replacement acceptance.');
  IF r2 IS DISTINCT FROM r1 THEN RAISE EXCEPTION 'FAIL: identical replay did not return stored result'; END IF;
  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_decisions WHERE lane_id=l)<>1 THEN
    RAISE EXCEPTION 'FAIL: identical replay created another lane decision';
  END IF;
END
$exercise$;

RESET ROLE;

SELECT jsonb_build_object(
  'result','PASS',
  'regression','physical_outcome_lane_grouped_supervisor_replacement_rollback_v1',
  'selected_items',2,
  'same_order_routes_created',2,
  'lane_resolved',true,
  'idempotent_replay_proven',true,
  'replacement_child_orders_created',0,
  'rolled_back',true
) AS result;

ROLLBACK;
