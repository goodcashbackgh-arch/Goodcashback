-- Rollback-only behavioral regression for grouped physical outcome evidence linking.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $fixture$
DECLARE
  s record;
  v_lane_id uuid:=gen_random_uuid();
  v_replacement_lane_id uuid:=gen_random_uuid();
  v_clone_line_id uuid:=gen_random_uuid();
  v_clone_allocation_id uuid:=gen_random_uuid();
  v_other_dispute_id uuid;
  v_refund_submission_id uuid:=gen_random_uuid();
  v_return_submission_id uuid:=gen_random_uuid();
BEGIN
  SELECT r.*,pr.order_id,pr.importer_id,dl.dispute_id,dl.supplier_invoice_line_id,
         op.id AS operator_id,op.auth_user_id AS operator_auth_user_id
  INTO s
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
  JOIN public.operator_importers oi ON oi.importer_id=pr.importer_id AND oi.revoked_at IS NULL
  JOIN public.operators op ON op.id=oi.operator_id AND COALESCE(op.active,true) AND op.auth_user_id IS NOT NULL
  ORDER BY r.created_at,r.id
  LIMIT 1;

  IF s.id IS NULL THEN RAISE EXCEPTION 'FAIL: no structural fixture source'; END IF;

  SELECT d.id INTO v_other_dispute_id
  FROM public.disputes d
  WHERE d.id<>s.dispute_id
  ORDER BY d.id
  LIMIT 1;
  IF v_other_dispute_id IS NULL THEN RAISE EXCEPTION 'FAIL: no second dispute available for mixed-dispute rejection'; END IF;

  PERFORM set_config('app.test.lane_id',v_lane_id::text,true);
  PERFORM set_config('app.test.replacement_lane_id',v_replacement_lane_id::text,true);
  PERFORM set_config('app.test.source_allocation_id',s.id::text,true);
  PERFORM set_config('app.test.clone_allocation_id',v_clone_allocation_id::text,true);
  PERFORM set_config('app.test.refund_submission_id',v_refund_submission_id::text,true);
  PERFORM set_config('app.test.return_submission_id',v_return_submission_id::text,true);
  PERFORM set_config('app.test.operator_auth_user_id',s.operator_auth_user_id::text,true);

  SET LOCAL session_replication_role=replica;

  UPDATE public.dispute_lines
  SET resolved_at=NULL,physical_remedy_allocation_id=s.id
  WHERE id=s.dispute_line_id;

  INSERT INTO public.dispute_lines(
    id,dispute_id,supplier_invoice_line_id,qty_impact,amount_impact_gbp,line_status,
    resolution_method,resolved_at,resolved_via_child_order_id,created_at,
    conversation_status,intended_remedy,physical_remedy_allocation_id
  )
  SELECT v_clone_line_id,dispute_id,NULL,GREATEST(1,qty_impact),GREATEST(0.01,amount_impact_gbp),
         'affected',NULL,NULL,NULL,now(),'remedy_selected','refund',v_clone_allocation_id
  FROM public.dispute_lines WHERE id=s.dispute_line_id;

  INSERT INTO public.physical_exception_remedy_allocations(
    id,physical_receipt_review_id,receipt_line_disposition_id,tracking_line_allocation_id,supplier_invoice_line_id,
    proposed_remedy_type,proposed_remedy_qty,proposed_by_operator_id,proposed_at,
    approved_remedy_type,approved_remedy_qty,approved_by_staff_id,approved_at,
    dispute_line_id,supplier_claim_amount_gbp,customer_commercial_value_gbp,supplier_cost_mode,
    replacement_child_order_id,replacement_child_tracking_allocation_id,status,rerouted_to_remedy_allocation_id,created_at,updated_at
  )
  SELECT v_clone_allocation_id,physical_receipt_review_id,receipt_line_disposition_id,tracking_line_allocation_id,NULL,
         'refund',GREATEST(1,trunc(COALESCE(proposed_remedy_qty,1))),proposed_by_operator_id,now(),
         'refund',GREATEST(1,trunc(COALESCE(approved_remedy_qty,proposed_remedy_qty,1))),
         COALESCE(approved_by_staff_id,(SELECT id FROM public.staff WHERE COALESCE(active,true) ORDER BY id LIMIT 1)),now(),
         v_clone_line_id,supplier_claim_amount_gbp,customer_commercial_value_gbp,NULL,NULL,NULL,
         'linked_to_exception',NULL,now(),now()
  FROM public.physical_exception_remedy_allocations WHERE id=s.id;

  INSERT INTO public.physical_receipt_outcome_lanes(id,order_id,physical_receipt_review_id,outcome_type,lane_status)
  VALUES
    (v_lane_id,s.order_id,s.physical_receipt_review_id,'refund','open'),
    (v_replacement_lane_id,s.order_id,s.physical_receipt_review_id,'replacement','open');

  INSERT INTO public.physical_receipt_outcome_lane_items(lane_id,physical_remedy_allocation_id,dispute_id,dispute_line_id)
  VALUES
    (v_lane_id,s.id,s.dispute_id,s.dispute_line_id),
    (v_lane_id,v_clone_allocation_id,s.dispute_id,v_clone_line_id);

  INSERT INTO public.dispute_refund_evidence_submissions(
    id,dispute_id,original_order_id,submitted_by_operator_id,document_mode,message_type,raw_body
  ) VALUES(
    v_refund_submission_id,s.dispute_id,s.order_id,s.operator_id,'no_document','refund_evidence','Rollback grouped refund evidence regression.'
  );

  INSERT INTO public.dispute_return_tracking_submissions(
    id,dispute_id,tracking_ref,submitted_by_operator_id,note
  ) VALUES(
    v_return_submission_id,s.dispute_id,'ROLLBACK-GROUPED-RETURN',s.operator_id,'Rollback grouped return tracking regression.'
  );

  -- Temporarily point clone item to another dispute for the fail-closed assertion later.
  PERFORM set_config('app.test.other_dispute_id',v_other_dispute_id::text,true);

  SET LOCAL session_replication_role=origin;
END
$fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('app.test.operator_auth_user_id'),'role','authenticated')::text,true);

DO $exercise$
DECLARE
  l uuid:=current_setting('app.test.lane_id')::uuid;
  rl uuid:=current_setting('app.test.replacement_lane_id')::uuid;
  a1 uuid:=current_setting('app.test.source_allocation_id')::uuid;
  a2 uuid:=current_setting('app.test.clone_allocation_id')::uuid;
  re uuid:=current_setting('app.test.refund_submission_id')::uuid;
  rt uuid:=current_setting('app.test.return_submission_id')::uuid;
  r jsonb;
  e text;
BEGIN
  r:=public.link_physical_outcome_refund_evidence_v1(l,ARRAY[a1,a2],re,'refund_proof');
  IF (r->>'new_links')::integer<>2 OR (r->>'idempotent_existing_links')::integer<>0 THEN
    RAISE EXCEPTION 'FAIL: refund evidence did not create two exact links: %',r;
  END IF;

  r:=public.link_physical_outcome_refund_evidence_v1(l,ARRAY[a1,a2],re,'refund_proof');
  IF (r->>'new_links')::integer<>0 OR (r->>'idempotent_existing_links')::integer<>2 THEN
    RAISE EXCEPTION 'FAIL: refund evidence replay was not idempotent: %',r;
  END IF;

  r:=public.link_physical_outcome_return_tracking_v1(l,ARRAY[a1,a2],rt,'return');
  IF (r->>'new_links')::integer<>2 THEN RAISE EXCEPTION 'FAIL: return tracking did not create two exact links: %',r; END IF;

  e:=NULL;
  BEGIN
    PERFORM public.link_physical_outcome_refund_evidence_v1(rl,ARRAY[a1],re,'refund_document');
  EXCEPTION WHEN OTHERS THEN e:=SQLERRM; END;
  IF e IS NULL OR e NOT ILIKE '%only be linked to a refund lane%' THEN
    RAISE EXCEPTION 'FAIL: refund evidence lane-type boundary did not fail closed: %',e;
  END IF;

  SET LOCAL ROLE postgres;
  SET LOCAL session_replication_role=replica;
  UPDATE public.physical_receipt_outcome_lane_items
  SET dispute_id=current_setting('app.test.other_dispute_id')::uuid
  WHERE lane_id=l AND physical_remedy_allocation_id=a2;
  SET LOCAL session_replication_role=origin;
  SET LOCAL ROLE authenticated;

  e:=NULL;
  BEGIN
    PERFORM public.link_physical_outcome_return_tracking_v1(l,ARRAY[a1,a2],rt,'collection');
  EXCEPTION WHEN OTHERS THEN e:=SQLERRM; END;
  IF e IS NULL OR e NOT ILIKE '%does not match every selected lane item%' THEN
    RAISE EXCEPTION 'FAIL: mixed-dispute selection did not fail closed: %',e;
  END IF;
END
$exercise$;

RESET ROLE;

SELECT jsonb_build_object(
  'result','PASS',
  'regression','physical_outcome_lane_grouped_evidence_linking_rollback_v1',
  'refund_exact_links',2,
  'return_tracking_exact_links',2,
  'idempotent_replay_proven',true,
  'mixed_dispute_failed_closed',true,
  'refund_lane_type_failed_closed',true,
  'rolled_back',true
) AS result;

ROLLBACK;
