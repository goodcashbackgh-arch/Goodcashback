-- Rollback-only grouped supervisor refund settlement-credit regression v2.
-- Executes the real RPC as authenticated, then resets role before inspecting
-- RLS-protected financial/audit rows.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $preflight$
DECLARE
  v_grouped_authority text:=pg_get_functiondef('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)'::regprocedure);
  v_refund_authority text:=pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure);
BEGIN
  IF md5(pg_get_functiondef('public.staff_confirm_order_settlement_credit_v1(uuid,text,text)'::regprocedure))<>'1919f05068406545d207adecafba362f'
     OR md5(pg_get_functiondef('public.order_funding_total_gbp(uuid)'::regprocedure))<>'7f71d968c6662c1df535a50428797fb4'
     OR v_grouped_authority NOT ILIKE '%Identical completed requests must replay before mutable-state guards.%'
     OR v_grouped_authority NOT ILIKE '%WHERE lane_id=p_lane_id AND request_hash=v_request_hash%'
     OR v_grouped_authority NOT ILIKE '%IF v_existing_result IS NOT NULL THEN RETURN v_existing_result; END IF;%'
     OR v_grouped_authority NOT ILIKE '%Refund decision must select every unresolved physical item in each affected dispute.%'
     OR v_grouped_authority NOT ILIKE '%staff_close_refund_exception_as_settlement_credit_v1%'
     OR v_grouped_authority NOT ILIKE '%staff_accept_same_order_free_replacement_v1%'
     OR v_refund_authority NOT ILIKE '%resolution_method=''refund''%'
     OR v_refund_authority NOT ILIKE '%status=''under_review''%'
     OR v_refund_authority NOT ILIKE '%status=''approved_refund''%'
     OR v_refund_authority NOT ILIKE '%status=''awaiting_refund_credit''%'
     OR v_refund_authority NOT ILIKE '%status=''refunded''%'
     OR v_refund_authority NOT ILIKE '%generated_by)%'
     OR v_refund_authority NOT ILIKE '%''manual''%'
  THEN
    RAISE EXCEPTION 'FAIL: corrected grouped refund authority contract is not installed';
  END IF;
END
$preflight$;

DO $fixture$
DECLARE
  s record;
  v_lane_id uuid:=gen_random_uuid();
  v_funding_event_id uuid:=gen_random_uuid();
  v_invoice_id uuid:=gen_random_uuid();
  v_credit_due numeric:=60;
  v_invoice_amount numeric:=50;
  v_existing_funding numeric;
  v_existing_posted numeric;
  v_required_adjustment numeric;
BEGIN
  SELECT r.*,pr.order_id,pr.importer_id,dl.dispute_id,
         st.id AS staff_id,st.auth_user_id AS staff_auth_user_id
  INTO s
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
  JOIN public.disputes d ON d.id=dl.dispute_id AND d.order_id=pr.order_id
  JOIN public.physical_receipt_review_dispute_links l
    ON l.physical_receipt_review_id=pr.id AND l.dispute_id=d.id
  CROSS JOIN LATERAL (
    SELECT st.* FROM public.staff st
    WHERE COALESCE(st.active,true)
      AND st.role_type IN ('admin','supervisor')
      AND st.auth_user_id IS NOT NULL
    ORDER BY st.id LIMIT 1
  ) st
  WHERE r.dispute_line_id IS NOT NULL
    AND r.receipt_line_disposition_id IS NOT NULL
    AND r.tracking_line_allocation_id IS NOT NULL
    AND r.supplier_invoice_line_id IS NOT NULL
  ORDER BY r.created_at,r.id
  LIMIT 1;

  IF s.id IS NULL THEN RAISE EXCEPTION 'FAIL: no structural physical remedy anchor'; END IF;

  SELECT COALESCE(public.order_funding_total_gbp(s.order_id),0) INTO v_existing_funding;
  SELECT COALESCE(SUM(si.amount_gbp),0) INTO v_existing_posted
  FROM public.sales_invoices si
  WHERE si.order_id=s.order_id
    AND si.invoice_type IN ('main','supplementary')
    AND si.sage_status='posted';

  v_required_adjustment:=v_existing_posted+v_invoice_amount+v_credit_due-v_existing_funding;
  IF v_required_adjustment=0 THEN v_required_adjustment:=v_credit_due; END IF;

  PERFORM set_config('app.test.refund_lane_id',v_lane_id::text,true);
  PERFORM set_config('app.test.refund_allocation_id',s.id::text,true);
  PERFORM set_config('app.test.refund_dispute_id',s.dispute_id::text,true);
  PERFORM set_config('app.test.refund_dispute_line_id',s.dispute_line_id::text,true);
  PERFORM set_config('app.test.refund_order_id',s.order_id::text,true);
  PERFORM set_config('app.test.refund_staff_id',s.staff_id::text,true);
  PERFORM set_config('app.test.refund_staff_auth_user_id',s.staff_auth_user_id::text,true);

  SET LOCAL session_replication_role=replica;

  DELETE FROM public.importer_credit_ledger
  WHERE source_type='settlement_credit'
    AND source_entity_type='order'
    AND source_entity_id=s.order_id;

  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NOT NULL THEN
    DELETE FROM public.customer_pre_shipment_hold_requests
    WHERE order_id=s.order_id AND status IN ('requested','supervisor_approved');
  END IF;

  UPDATE public.disputes
  SET status='closed',resolved_at=COALESCE(resolved_at,now())
  WHERE order_id=s.order_id AND id<>s.dispute_id AND resolved_at IS NULL;

  UPDATE public.dispute_lines
  SET line_status='resolved',resolution_method='refund',resolved_at=COALESCE(resolved_at,now()),
      conversation_status='resolved_credit'
  WHERE dispute_id=s.dispute_id AND id<>s.dispute_line_id AND resolved_at IS NULL;

  UPDATE public.disputes
  SET desired_outcome='refund',status='raised',amount_impact_gbp=v_credit_due,
      refund_settlement_mode=NULL,resolved_at=NULL,
      reviewed_by_staff_id=NULL,reviewed_at=NULL
  WHERE id=s.dispute_id;

  UPDATE public.dispute_lines
  SET supplier_invoice_line_id=s.supplier_invoice_line_id,
      qty_impact=1,amount_impact_gbp=v_credit_due,
      line_status='affected',resolution_method=NULL,resolved_at=NULL,
      resolved_via_child_order_id=NULL,conversation_status='retailer_response_received',
      intended_remedy='refund',physical_remedy_allocation_id=s.id
  WHERE id=s.dispute_line_id;

  DELETE FROM public.physical_receipt_review_dispute_links
  WHERE physical_receipt_review_id=s.physical_receipt_review_id AND dispute_id=s.dispute_id;

  INSERT INTO public.physical_receipt_review_dispute_links(
    physical_receipt_review_id,dispute_id,desired_outcome,created_by_staff_id
  ) VALUES(s.physical_receipt_review_id,s.dispute_id,'refund',s.staff_id);

  UPDATE public.physical_exception_remedy_allocations
  SET proposed_remedy_type='refund',proposed_remedy_qty=1,
      approved_remedy_type='refund',approved_remedy_qty=1,
      approved_by_staff_id=s.staff_id,approved_at=COALESCE(approved_at,now()),
      dispute_line_id=s.dispute_line_id,customer_commercial_value_gbp=v_credit_due,
      supplier_cost_mode='not_applicable',replacement_child_order_id=NULL,
      replacement_child_tracking_line_allocation_id=NULL,
      rerouted_to_remedy_allocation_id=NULL,status='linked_to_exception',updated_at=now()
  WHERE id=s.id;

  INSERT INTO public.order_funding_events(
    id,order_id,event_type,amount_gbp,source_table,source_id,
    resulting_funded_total_gbp,threshold_met,created_by_staff_id,created_at,notes,
    source_ref,source_entity_type,source_entity_id,legacy_event_type
  ) VALUES(
    v_funding_event_id,s.order_id,'manual_adjustment',v_required_adjustment,
    'physical_outcome_lane_refund_regression_v2',v_lane_id,
    NULL,false,s.staff_id,now(),'Rollback-only GBP 60 refund settlement-credit fixture.',
    'rollback:physical_outcome_lane_refund_v2','physical_outcome_lane',v_lane_id,NULL
  );

  INSERT INTO public.sales_invoices(
    id,order_id,invoice_type,linked_invoice_id,
    consideration_received_date,sage_invoice_date,tax_point_period,sage_invoice_period,
    vat_box6_reported_period,amount_gbp,vat_code,line_items_json,
    sage_invoice_id,sage_posted_at,sage_status,
    export_evidence_complete_date,zero_rating_deadline_date,zero_rating_status,
    vat_adjustment_posted_at,reversal_posted_at,raised_by_trigger,created_at,sage_reference
  ) VALUES(
    v_invoice_id,s.order_id,'main',NULL,
    current_date,current_date,to_char(current_date,'YYYY-MM'),to_char(current_date,'YYYY-MM'),
    NULL,v_invoice_amount,'T0',jsonb_build_array(jsonb_build_object('rollback_fixture',true,'amount_gbp',v_invoice_amount)),
    'ROLLBACK-REFUND-'||left(v_invoice_id::text,8),now(),'posted',
    NULL,current_date+90,'on_track',NULL,NULL,false,now(),
    'ROLLBACK-REFUND-'||left(v_invoice_id::text,8)
  );

  INSERT INTO public.physical_receipt_outcome_lanes(
    id,order_id,physical_receipt_review_id,outcome_type,lane_status
  ) VALUES(v_lane_id,s.order_id,s.physical_receipt_review_id,'refund','awaiting_supervisor_decision');

  INSERT INTO public.physical_receipt_outcome_lane_items(
    lane_id,physical_remedy_allocation_id,dispute_id,dispute_line_id
  ) VALUES(v_lane_id,s.id,s.dispute_id,s.dispute_line_id);

  SET LOCAL session_replication_role=origin;
END
$fixture$;

DO $fixture_assertions$
DECLARE
  o uuid:=current_setting('app.test.refund_order_id')::uuid;
  p record;
BEGIN
  SELECT * INTO p FROM public.order_settlement_credit_position_v1 WHERE order_id=o;
  IF p.settlement_status<>'credit_due' OR ABS(p.funding_less_posted_invoice_gbp-60)>0.01 THEN
    RAISE EXCEPTION 'FAIL: fixture did not produce exact GBP 60 credit_due position: %',to_jsonb(p);
  END IF;
END
$fixture_assertions$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',current_setting('app.test.refund_staff_auth_user_id'),
  'role','authenticated'
)::text,true);

DO $authenticated_exercise$
DECLARE
  l uuid:=current_setting('app.test.refund_lane_id')::uuid;
  a uuid:=current_setting('app.test.refund_allocation_id')::uuid;
  d uuid:=current_setting('app.test.refund_dispute_id')::uuid;
  dl uuid:=current_setting('app.test.refund_dispute_line_id')::uuid;
  st uuid:=current_setting('app.test.refund_staff_id')::uuid;
  payload jsonb;
  r1 jsonb;
  r2 jsonb;
BEGIN
  payload:=jsonb_build_array(jsonb_build_object(
    'physical_remedy_allocation_id',a,
    'decision','refund_settlement_credit',
    'reason','supervisor_confirmed_credit'
  ));

  r1:=public.staff_decide_physical_outcome_lane_v1(
    l,st,payload,'Rollback grouped supervisor refund settlement-credit acceptance.'
  );

  IF COALESCE((r1->>'ok')::boolean,false) IS DISTINCT FROM true
     OR (r1->>'selected_items')::integer<>1
     OR (r1->>'resolved_items')::integer<>1
     OR r1->>'lane_status'<>'resolved'
  THEN RAISE EXCEPTION 'FAIL: grouped refund decision result incorrect: %',r1; END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.disputes
    WHERE id=d AND status='closed' AND resolved_at IS NOT NULL
      AND refund_settlement_mode='credit_balance'
  ) THEN RAISE EXCEPTION 'FAIL: refund dispute was not closed through credit_balance'; END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.dispute_lines
    WHERE id=dl AND line_status='resolved' AND resolution_method='refund'
      AND conversation_status='resolved_credit' AND resolved_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'FAIL: refund dispute line was not resolved through refund'; END IF;

  r2:=public.staff_decide_physical_outcome_lane_v1(
    l,st,payload,'Rollback grouped supervisor refund settlement-credit acceptance.'
  );
  IF r2 IS DISTINCT FROM r1 THEN
    RAISE EXCEPTION 'FAIL: identical authenticated replay did not return stored result';
  END IF;
END
$authenticated_exercise$;

RESET ROLE;

DO $owner_assertions$
DECLARE
  l uuid:=current_setting('app.test.refund_lane_id')::uuid;
  a uuid:=current_setting('app.test.refund_allocation_id')::uuid;
  d uuid:=current_setting('app.test.refund_dispute_id')::uuid;
  o uuid:=current_setting('app.test.refund_order_id')::uuid;
  decision_count integer;
  decision_item_count integer;
  credit_count integer;
  message_count integer;
BEGIN
  SELECT COUNT(*) INTO decision_count
  FROM public.physical_receipt_outcome_lane_decisions
  WHERE lane_id=l AND decision_type='refund_settlement_credit';
  IF decision_count<>1 THEN RAISE EXCEPTION 'FAIL: expected one refund lane decision, got %',decision_count; END IF;

  SELECT COUNT(*) INTO decision_item_count
  FROM public.physical_receipt_outcome_lane_decision_items di
  JOIN public.physical_receipt_outcome_lane_decisions dd ON dd.id=di.lane_decision_id
  WHERE dd.lane_id=l AND di.physical_remedy_allocation_id=a
    AND di.decision_type='refund_settlement_credit'
    AND di.authority_result->>'ok'='true';
  IF decision_item_count<>1 THEN RAISE EXCEPTION 'FAIL: exact refund decision-item audit missing'; END IF;

  SELECT COUNT(*) INTO credit_count
  FROM public.importer_credit_ledger
  WHERE source_type='settlement_credit'
    AND source_entity_type='order'
    AND source_entity_id=o
    AND linked_order_id=o
    AND direction='credit'
    AND ABS(amount_gbp-60)<=0.01;
  IF credit_count<>1 THEN RAISE EXCEPTION 'FAIL: expected one exact GBP 60 settlement credit, got %',credit_count; END IF;

  IF (SELECT settlement_status FROM public.order_settlement_credit_position_v1 WHERE order_id=o)<>'credit_created' THEN
    RAISE EXCEPTION 'FAIL: settlement position did not become credit_created';
  END IF;

  SELECT COUNT(*) INTO message_count
  FROM public.dispute_messages
  WHERE dispute_id=d
    AND message_type='supervisor_note'
    AND generated_by='manual'
    AND body LIKE '[NO_REFUND_SETTLEMENT_CREDIT_V1]%';
  IF message_count<>1 THEN RAISE EXCEPTION 'FAIL: expected one settlement-credit supervisor note'; END IF;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_decisions WHERE lane_id=l)<>1
     OR (SELECT COUNT(*) FROM public.importer_credit_ledger
         WHERE source_type='settlement_credit' AND source_entity_type='order'
           AND source_entity_id=o AND linked_order_id=o)<>1
     OR (SELECT COUNT(*) FROM public.dispute_messages
         WHERE dispute_id=d AND message_type='supervisor_note'
           AND generated_by='manual'
           AND body LIKE '[NO_REFUND_SETTLEMENT_CREDIT_V1]%')<>1
  THEN RAISE EXCEPTION 'FAIL: refund replay duplicated financial or audit effects'; END IF;
END
$owner_assertions$;

SELECT jsonb_build_object(
  'result','PASS',
  'regression','physical_outcome_lane_grouped_supervisor_refund_rollback_v2',
  'credit_due_seeded_gbp',60,
  'selected_items',1,
  'refund_disputes_closed',1,
  'settlement_credit_created_gbp',60,
  'lane_resolved',true,
  'authenticated_execution_proven',true,
  'owner_financial_assertions_proven',true,
  'decision_audit_proven',true,
  'idempotent_replay_proven',true,
  'rolled_back',true
) AS result;

ROLLBACK;
