-- Rollback-only behavioral regression for grouped update hardening.
-- Proves one message per distinct dispute and cumulative lane completion.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $fixture$
DECLARE
  s record;
  v_lane_id uuid:=gen_random_uuid();
  v_clone_line_id uuid:=gen_random_uuid();
  v_clone_allocation_id uuid:=gen_random_uuid();
BEGIN
  SELECT r.*,pr.order_id,pr.importer_id,dl.dispute_id,op.auth_user_id AS operator_auth_user_id
  INTO s
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
  JOIN public.operator_importers oi ON oi.importer_id=pr.importer_id AND oi.revoked_at IS NULL
  JOIN public.operators op ON op.id=oi.operator_id AND COALESCE(op.active,true) AND op.auth_user_id IS NOT NULL
  ORDER BY r.created_at,r.id
  LIMIT 1;

  IF s.id IS NULL THEN RAISE EXCEPTION 'FAIL: no structural fixture source'; END IF;

  PERFORM set_config('app.test.lane_id',v_lane_id::text,true);
  PERFORM set_config('app.test.source_allocation_id',s.id::text,true);
  PERFORM set_config('app.test.clone_allocation_id',v_clone_allocation_id::text,true);
  PERFORM set_config('app.test.dispute_id',s.dispute_id::text,true);
  PERFORM set_config('app.test.operator_auth_user_id',s.operator_auth_user_id::text,true);

  SET LOCAL session_replication_role=replica;

  UPDATE public.dispute_lines
  SET resolved_at=NULL,conversation_status='remedy_selected',intended_remedy='replacement',physical_remedy_allocation_id=s.id
  WHERE id=s.dispute_line_id;

  UPDATE public.physical_exception_remedy_allocations
  SET approved_remedy_type='replacement',approved_remedy_qty=GREATEST(1,trunc(COALESCE(approved_remedy_qty,proposed_remedy_qty,1))),
      approved_by_staff_id=COALESCE(approved_by_staff_id,(SELECT id FROM public.staff WHERE COALESCE(active,true) ORDER BY id LIMIT 1)),
      approved_at=COALESCE(approved_at,now()),status='linked_to_exception',supplier_cost_mode='free_replacement',
      replacement_child_order_id=NULL,replacement_child_tracking_allocation_id=NULL,rerouted_to_remedy_allocation_id=NULL
  WHERE id=s.id;

  INSERT INTO public.dispute_lines(
    id,dispute_id,supplier_invoice_line_id,qty_impact,amount_impact_gbp,line_status,
    resolution_method,resolved_at,resolved_via_child_order_id,created_at,
    conversation_status,intended_remedy,physical_remedy_allocation_id
  )
  SELECT v_clone_line_id,dispute_id,supplier_invoice_line_id,GREATEST(1,qty_impact),GREATEST(0.01,amount_impact_gbp),
         'affected',NULL,NULL,NULL,now(),'remedy_selected','replacement',v_clone_allocation_id
  FROM public.dispute_lines WHERE id=s.dispute_line_id;

  INSERT INTO public.physical_exception_remedy_allocations(
    id,physical_receipt_review_id,receipt_line_disposition_id,tracking_line_allocation_id,supplier_invoice_line_id,
    proposed_remedy_type,proposed_remedy_qty,proposed_by_operator_id,proposed_at,
    approved_remedy_type,approved_remedy_qty,approved_by_staff_id,approved_at,
    dispute_line_id,supplier_claim_amount_gbp,customer_commercial_value_gbp,supplier_cost_mode,
    replacement_child_order_id,replacement_child_tracking_allocation_id,status,rerouted_to_remedy_allocation_id,created_at,updated_at
  )
  SELECT v_clone_allocation_id,physical_receipt_review_id,receipt_line_disposition_id,tracking_line_allocation_id,supplier_invoice_line_id,
         'replacement',GREATEST(1,trunc(COALESCE(proposed_remedy_qty,1))),proposed_by_operator_id,now(),
         'replacement',GREATEST(1,trunc(COALESCE(approved_remedy_qty,proposed_remedy_qty,1))),approved_by_staff_id,now(),
         v_clone_line_id,supplier_claim_amount_gbp,customer_commercial_value_gbp,'free_replacement',NULL,NULL,
         'linked_to_exception',NULL,now(),now()
  FROM public.physical_exception_remedy_allocations WHERE id=s.id;

  INSERT INTO public.physical_receipt_outcome_lanes(id,order_id,physical_receipt_review_id,outcome_type,lane_status)
  VALUES(v_lane_id,s.order_id,s.physical_receipt_review_id,'replacement','open');

  INSERT INTO public.physical_receipt_outcome_lane_items(lane_id,physical_remedy_allocation_id,dispute_id,dispute_line_id)
  VALUES
    (v_lane_id,s.id,s.dispute_id,s.dispute_line_id),
    (v_lane_id,v_clone_allocation_id,s.dispute_id,v_clone_line_id);

  SET LOCAL session_replication_role=origin;
END
$fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('app.test.operator_auth_user_id'),'role','authenticated')::text,true);

DO $exercise$
DECLARE
  l uuid:=current_setting('app.test.lane_id')::uuid;
  a1 uuid:=current_setting('app.test.source_allocation_id')::uuid;
  a2 uuid:=current_setting('app.test.clone_allocation_id')::uuid;
  d uuid:=current_setting('app.test.dispute_id')::uuid;
  r1 jsonb;
  r2 jsonb;
  r3 jsonb;
  u3 uuid;
  mcount integer;
BEGIN
  r1:=public.operator_record_physical_outcome_lane_update_v1(l,ARRAY[a1],'Accepted first item.','retailer_accepted','partial 1',gen_random_uuid());
  IF (r1->>'accepted_items_cumulative')::integer<>1 OR (r1->>'lane_item_count')::integer<>2 THEN
    RAISE EXCEPTION 'FAIL: first partial cumulative counts wrong: %',r1;
  END IF;
  IF (SELECT lane_status FROM public.physical_receipt_outcome_lanes WHERE id=l)<>'retailer_response_partial' THEN
    RAISE EXCEPTION 'FAIL: lane was not partial after first accepted item';
  END IF;

  r2:=public.operator_record_physical_outcome_lane_update_v1(l,ARRAY[a2],'Accepted second item.','retailer_accepted','partial 2',gen_random_uuid());
  IF (r2->>'accepted_items_cumulative')::integer<>2 OR (r2->>'lane_item_count')::integer<>2 THEN
    RAISE EXCEPTION 'FAIL: second partial cumulative counts wrong: %',r2;
  END IF;
  IF (SELECT lane_status FROM public.physical_receipt_outcome_lanes WHERE id=l)<>'retailer_response_complete' THEN
    RAISE EXCEPTION 'FAIL: lane did not complete cumulatively';
  END IF;

  r3:=public.operator_record_physical_outcome_lane_update_v1(l,ARRAY[a1,a2],'Shared dispute response.','retailer_disputed','shared dispute message',gen_random_uuid());
  u3:=(r3->>'lane_update_id')::uuid;

  SELECT COUNT(DISTINCT ui.dispute_message_id) INTO mcount
  FROM public.physical_receipt_outcome_lane_update_items ui
  WHERE ui.lane_update_id=u3;

  IF mcount<>1 THEN RAISE EXCEPTION 'FAIL: same-dispute items did not reuse one message'; END IF;
  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_update_items WHERE lane_update_id=u3)<>2 THEN
    RAISE EXCEPTION 'FAIL: shared-dispute update did not link two items';
  END IF;
  IF (SELECT COUNT(*) FROM public.dispute_messages WHERE dispute_id=d AND body='Shared dispute response.')<>1 THEN
    RAISE EXCEPTION 'FAIL: shared-dispute update created duplicate messages';
  END IF;
END
$exercise$;

RESET ROLE;

SELECT jsonb_build_object(
  'result','PASS',
  'regression','physical_outcome_lane_grouped_update_hardening_rollback_v1',
  'partial_then_complete_cumulative',true,
  'same_dispute_items',2,
  'distinct_messages_for_shared_dispute',1,
  'rolled_back',true
) AS result;

ROLLBACK;
