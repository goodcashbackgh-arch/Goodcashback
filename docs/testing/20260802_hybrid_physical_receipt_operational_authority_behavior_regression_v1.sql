\set ON_ERROR_STOP on

-- Required psql variables:
-- IMPORTER_A_AUTH_USER_ID IMPORTER_B_AUTH_USER_ID REVOKED_IMPORTER_AUTH_USER_ID
-- SUPERVISOR_AUTH_USER_ID ORDINARY_STAFF_AUTH_USER_ID
-- IMPORTER_ACTION_REVIEW_ID IMPORTER_ACTION_DISPOSITION_ID EVIDENCE_OBJECT_PATH
-- SUPERVISOR_EXISTING_REVIEW_ID SUPERVISOR_REFUND_ALLOCATION_ID SUPERVISOR_REPLACEMENT_ALLOCATION_ID
-- SUPERVISOR_HOLD_REVIEW_ID SUPERVISOR_HOLD_ALLOCATION_ID
-- SUPERVISOR_NO_ACTION_REVIEW_ID SUPERVISOR_NO_ACTION_ALLOCATION_ID

BEGIN;

SELECT set_config('app.test.importer_review_id', :'IMPORTER_ACTION_REVIEW_ID', true);
SELECT set_config('app.test.importer_disposition_id', :'IMPORTER_ACTION_DISPOSITION_ID', true);
SELECT set_config('app.test.evidence_path', :'EVIDENCE_OBJECT_PATH', true);
SELECT set_config('app.test.existing_review_id', :'SUPERVISOR_EXISTING_REVIEW_ID', true);
SELECT set_config('app.test.refund_allocation_id', :'SUPERVISOR_REFUND_ALLOCATION_ID', true);
SELECT set_config('app.test.replacement_allocation_id', :'SUPERVISOR_REPLACEMENT_ALLOCATION_ID', true);
SELECT set_config('app.test.hold_review_id', :'SUPERVISOR_HOLD_REVIEW_ID', true);
SELECT set_config('app.test.hold_allocation_id', :'SUPERVISOR_HOLD_ALLOCATION_ID', true);
SELECT set_config('app.test.no_action_review_id', :'SUPERVISOR_NO_ACTION_REVIEW_ID', true);
SELECT set_config('app.test.no_action_allocation_id', :'SUPERVISOR_NO_ACTION_ALLOCATION_ID', true);

DO $preflight$
DECLARE
  v_importer_status text;
  v_existing_status text;
  v_hold_status text;
  v_no_action_status text;
BEGIN
  IF to_regprocedure('public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)') IS NULL
     OR to_regprocedure('public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)') IS NULL
     OR to_regprocedure('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)') IS NULL
     OR to_regprocedure('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)') IS NULL
     OR to_regprocedure('public.importer_physical_receipt_reviews_v1(uuid)') IS NULL
     OR to_regprocedure('public.staff_physical_receipt_reviews_v1(uuid)') IS NULL
     OR to_regprocedure('public.can_read_physical_receipt_evidence_v1(text)') IS NULL
  THEN
    RAISE EXCEPTION 'Operational gateways and read authorities must be installed first.';
  END IF;

  IF has_function_privilege('authenticated','public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)','EXECUTE')
     OR has_function_privilege('authenticated','public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)','EXECUTE')
  THEN
    RAISE EXCEPTION 'Authenticated direct v1 execution remains available.';
  END IF;

  IF NOT has_function_privilege('authenticated','public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)','EXECUTE')
  THEN
    RAISE EXCEPTION 'Authenticated v2 execution is missing.';
  END IF;

  SELECT status INTO v_importer_status FROM public.physical_receipt_reviews
  WHERE id=current_setting('app.test.importer_review_id')::uuid;
  SELECT status INTO v_existing_status FROM public.physical_receipt_reviews
  WHERE id=current_setting('app.test.existing_review_id')::uuid;
  SELECT status INTO v_hold_status FROM public.physical_receipt_reviews
  WHERE id=current_setting('app.test.hold_review_id')::uuid;
  SELECT status INTO v_no_action_status FROM public.physical_receipt_reviews
  WHERE id=current_setting('app.test.no_action_review_id')::uuid;

  IF v_importer_status NOT IN ('awaiting_importer_proposal','returned_for_information') THEN
    RAISE EXCEPTION 'Importer fixture is not actionable: %', v_importer_status;
  END IF;
  IF v_existing_status <> 'awaiting_supervisor_review'
     OR v_hold_status <> 'awaiting_supervisor_review'
     OR v_no_action_status <> 'awaiting_supervisor_review'
  THEN
    RAISE EXCEPTION 'Supervisor fixtures must all await supervisor review.';
  END IF;
END
$preflight$;

SET LOCAL ROLE authenticated;

-- Runtime privilege denial, not ACL inspection only.
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_A_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $runtime_importer_v1_denial$
DECLARE v_denied boolean := false;
BEGIN
  BEGIN
    EXECUTE format(
      'SELECT public.operator_submit_physical_receipt_proposal_v1(%L::uuid,%L::jsonb,%L)',
      current_setting('app.test.importer_review_id'),
      jsonb_build_array(jsonb_build_object(
        'receipt_line_disposition_id', current_setting('app.test.importer_disposition_id')::uuid,
        'proposed_remedy_type', 'replacement',
        'proposed_remedy_qty', 1
      ))::text,
      'runtime v1 denial'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Authenticated importer executed v1 directly.'; END IF;
END
$runtime_importer_v1_denial$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'SUPERVISOR_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $runtime_supervisor_v1_denial$
DECLARE v_denied boolean := false;
BEGIN
  BEGIN
    EXECUTE format(
      'SELECT public.staff_decide_physical_receipt_review_v1(%L::uuid,%L,%L::jsonb,%L,%L)',
      current_setting('app.test.hold_review_id'),
      'return_for_information',
      '[]',
      'unknown',
      'runtime v1 denial'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Authenticated supervisor executed v1 directly.'; END IF;
END
$runtime_supervisor_v1_denial$;

-- Queue/detail/evidence behavioral matrix.
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_A_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $authorised_importer$
DECLARE v_detail jsonb; v_queue jsonb; v_count integer; v_bad integer; p text:=current_setting('app.test.evidence_path');
BEGIN
  v_detail:=public.importer_physical_receipt_reviews_v1(current_setting('app.test.importer_review_id')::uuid);
  IF jsonb_array_length(COALESCE(v_detail->'reviews','[]'::jsonb))<>1 THEN RAISE EXCEPTION 'Authorised importer detail failed.'; END IF;
  v_queue:=public.importer_physical_receipt_reviews_v1(NULL);
  SELECT count(*) INTO v_bad FROM jsonb_array_elements(COALESCE(v_queue->'reviews','[]'::jsonb)) row_json
  WHERE row_json->>'status' NOT IN ('awaiting_importer_proposal','returned_for_information');
  IF v_bad<>0 OR (v_queue->>'action_count')::integer<>jsonb_array_length(COALESCE(v_queue->'reviews','[]'::jsonb)) THEN
    RAISE EXCEPTION 'Importer queue is not action-only or count is inconsistent.';
  END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Authorised importer evidence helper failed.'; END IF;
  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF v_count<>1 THEN RAISE EXCEPTION 'Authorised importer storage RLS failed.'; END IF;
END
$authorised_importer$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_B_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $other_importer$
DECLARE v jsonb; c integer; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.importer_physical_receipt_reviews_v1(current_setting('app.test.importer_review_id')::uuid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>0 THEN RAISE EXCEPTION 'Cross-importer detail succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) THEN RAISE EXCEPTION 'Cross-importer evidence helper succeeded.'; END IF;
  SELECT count(*) INTO c FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF c<>0 THEN RAISE EXCEPTION 'Cross-importer storage RLS succeeded.'; END IF;
END
$other_importer$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'REVOKED_IMPORTER_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $revoked_importer$
DECLARE v jsonb; c integer; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.importer_physical_receipt_reviews_v1(current_setting('app.test.importer_review_id')::uuid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>0 THEN RAISE EXCEPTION 'Revoked importer detail succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) THEN RAISE EXCEPTION 'Revoked importer evidence succeeded.'; END IF;
  SELECT count(*) INTO c FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF c<>0 THEN RAISE EXCEPTION 'Revoked importer storage RLS succeeded.'; END IF;
END
$revoked_importer$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'SUPERVISOR_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $supervisor_access$
DECLARE v_detail jsonb; v_queue jsonb; v_count integer; v_bad integer; p text:=current_setting('app.test.evidence_path');
BEGIN
  v_detail:=public.staff_physical_receipt_reviews_v1(current_setting('app.test.existing_review_id')::uuid);
  IF jsonb_array_length(COALESCE(v_detail->'reviews','[]'::jsonb))<>1 THEN RAISE EXCEPTION 'Supervisor detail failed.'; END IF;
  v_queue:=public.staff_physical_receipt_reviews_v1(NULL);
  SELECT count(*) INTO v_bad FROM jsonb_array_elements(COALESCE(v_queue->'reviews','[]'::jsonb)) row_json
  WHERE row_json->>'status'<>'awaiting_supervisor_review';
  IF v_bad<>0 OR (v_queue->>'action_count')::integer<>jsonb_array_length(COALESCE(v_queue->'reviews','[]'::jsonb)) THEN
    RAISE EXCEPTION 'Supervisor queue is not action-only or count is inconsistent.';
  END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Supervisor evidence helper failed.'; END IF;
  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF v_count<>1 THEN RAISE EXCEPTION 'Supervisor storage RLS failed.'; END IF;
END
$supervisor_access$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'ORDINARY_STAFF_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $ordinary_staff$
DECLARE v jsonb; c integer; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.staff_physical_receipt_reviews_v1(current_setting('app.test.existing_review_id')::uuid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>0 THEN RAISE EXCEPTION 'Ordinary staff detail succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) THEN RAISE EXCEPTION 'Ordinary staff evidence succeeded.'; END IF;
  SELECT count(*) INTO c FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF c<>0 THEN RAISE EXCEPTION 'Ordinary staff storage RLS succeeded.'; END IF;
END
$ordinary_staff$;

-- Importer v2: every prohibited numeric and no-mutation invariants.
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_A_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $importer_invalid_quantities$
DECLARE
  rid uuid:=current_setting('app.test.importer_review_id')::uuid;
  did uuid:=current_setting('app.test.importer_disposition_id')::uuid;
  v_qty numeric;
  v_status text;
  v_note text;
  v_count integer;
  v_error text;
BEGIN
  SELECT status, importer_proposal_note INTO v_status, v_note FROM public.physical_receipt_reviews WHERE id=rid;
  SELECT count(*) INTO v_count FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid;

  FOREACH v_qty IN ARRAY ARRAY[0::numeric,-1::numeric,1.0004::numeric,1.5::numeric] LOOP
    v_error:=NULL;
    BEGIN
      PERFORM public.operator_submit_physical_receipt_proposal_v2(
        rid,
        jsonb_build_array(jsonb_build_object(
          'receipt_line_disposition_id',did,
          'proposed_remedy_type','replacement',
          'proposed_remedy_qty',v_qty
        )),
        'invalid quantity regression'
      );
    EXCEPTION WHEN OTHERS THEN v_error:=SQLERRM; END;
    IF v_error IS NULL OR v_error NOT ILIKE '%positive whole unit%' THEN
      RAISE EXCEPTION 'Importer v2 did not reject % at the gateway: %', v_qty, v_error;
    END IF;
    IF (SELECT status FROM public.physical_receipt_reviews WHERE id=rid) IS DISTINCT FROM v_status
       OR (SELECT importer_proposal_note FROM public.physical_receipt_reviews WHERE id=rid) IS DISTINCT FROM v_note
       OR (SELECT count(*) FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid)<>v_count
    THEN RAISE EXCEPTION 'Rejected importer quantity % mutated state.', v_qty; END IF;
  END LOOP;
END
$importer_invalid_quantities$;

-- Valid importer v2 call must reach and preserve v1 atomic behavior.
SAVEPOINT importer_valid;
DO $importer_valid$
DECLARE
  rid uuid:=current_setting('app.test.importer_review_id')::uuid;
  did uuid:=current_setting('app.test.importer_disposition_id')::uuid;
  v_before integer;
  v_result jsonb;
BEGIN
  SELECT count(*) INTO v_before FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid;
  v_result:=public.operator_submit_physical_receipt_proposal_v2(
    rid,
    jsonb_build_array(jsonb_build_object(
      'receipt_line_disposition_id',did,
      'proposed_remedy_type','replacement',
      'proposed_remedy_qty',1
    )),
    'valid integer regression'
  );
  IF COALESCE((v_result->>'ok')::boolean,false) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Importer v2 did not return v1 success.'; END IF;
  IF (SELECT status FROM public.physical_receipt_reviews WHERE id=rid)<>'awaiting_supervisor_review' THEN RAISE EXCEPTION 'Importer v2 did not preserve v1 status transition.'; END IF;
  IF (SELECT count(*) FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid)<>v_before+1 THEN RAISE EXCEPTION 'Importer v2 did not preserve atomic proposal insertion.'; END IF;
  IF EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid AND proposed_remedy_qty<>trunc(proposed_remedy_qty)) THEN RAISE EXCEPTION 'Importer valid call stored a fractional quantity.'; END IF;
END
$importer_valid$;
ROLLBACK TO SAVEPOINT importer_valid;

-- Supervisor v2: exact fractional rejection for every allocation route, no mutation.
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'SUPERVISOR_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $supervisor_invalid_quantities$
DECLARE
  rid uuid:=current_setting('app.test.hold_review_id')::uuid;
  aid uuid:=current_setting('app.test.hold_allocation_id')::uuid;
  v_decision text;
  v_remedy text;
  v_qty numeric;
  v_error text;
  v_status text;
  v_allocation record;
BEGIN
  SELECT status INTO v_status FROM public.physical_receipt_reviews WHERE id=rid;
  SELECT * INTO v_allocation FROM public.physical_exception_remedy_allocations WHERE id=aid;

  FOR v_decision,v_remedy IN
    VALUES ('approve_existing_exception','refund'),
           ('approve_existing_exception','replacement'),
           ('approve_investigation','hold_investigate'),
           ('close_no_action','no_action')
  LOOP
    FOREACH v_qty IN ARRAY ARRAY[0::numeric,-1::numeric,1.0004::numeric,1.5::numeric] LOOP
      v_error:=NULL;
      BEGIN
        PERFORM public.staff_decide_physical_receipt_review_v2(
          rid,
          v_decision,
          jsonb_build_array(jsonb_build_object(
            'remedy_allocation_id',aid,
            'approved_remedy_type',v_remedy,
            'approved_remedy_qty',v_qty,
            'supplier_cost_mode',CASE WHEN v_remedy='replacement' THEN 'pending_supplier_evidence' ELSE 'not_applicable' END
          )),
          CASE WHEN v_decision='close_no_action' THEN 'no_liability' ELSE 'unknown' END,
          'invalid supervisor quantity regression'
        );
      EXCEPTION WHEN OTHERS THEN v_error:=SQLERRM; END;
      IF v_error IS NULL OR v_error NOT ILIKE '%positive whole unit%' THEN
        RAISE EXCEPTION 'Supervisor v2 did not reject %/% at gateway: %', v_decision, v_qty, v_error;
      END IF;
      IF (SELECT status FROM public.physical_receipt_reviews WHERE id=rid) IS DISTINCT FROM v_status THEN
        RAISE EXCEPTION 'Rejected supervisor call changed review status.';
      END IF;
      IF EXISTS (
        SELECT 1 FROM public.physical_exception_remedy_allocations current_row
        WHERE current_row.id=aid
          AND (current_row.status IS DISTINCT FROM v_allocation.status
            OR current_row.approved_remedy_type IS DISTINCT FROM v_allocation.approved_remedy_type
            OR current_row.approved_remedy_qty IS DISTINCT FROM v_allocation.approved_remedy_qty
            OR current_row.dispute_line_id IS DISTINCT FROM v_allocation.dispute_line_id)
      ) THEN RAISE EXCEPTION 'Rejected supervisor call mutated allocation.'; END IF;
    END LOOP;
  END LOOP;
END
$supervisor_invalid_quantities$;

-- Return-for-information preserves the same review identity and creates no allocations/disputes.
SAVEPOINT supervisor_return;
DO $supervisor_return$
DECLARE rid uuid:=current_setting('app.test.hold_review_id')::uuid; v_result jsonb; v_before integer;
BEGIN
  SELECT count(*) INTO v_before FROM public.physical_receipt_review_dispute_links WHERE physical_receipt_review_id=rid;
  v_result:=public.staff_decide_physical_receipt_review_v2(rid,'return_for_information','[]'::jsonb,'unknown','Return for exact revised information');
  IF v_result->>'review_id'<>rid::text OR v_result->>'status'<>'returned_for_information' THEN RAISE EXCEPTION 'Return did not preserve same review identity.'; END IF;
  IF (SELECT status FROM public.physical_receipt_reviews WHERE id=rid)<>'returned_for_information' THEN RAISE EXCEPTION 'Return status not persisted.'; END IF;
  IF (SELECT count(*) FROM public.physical_receipt_review_dispute_links WHERE physical_receipt_review_id=rid)<>v_before THEN RAISE EXCEPTION 'Return created a dispute link.'; END IF;
END
$supervisor_return$;
ROLLBACK TO SAVEPOINT supervisor_return;

-- Reject route.
SAVEPOINT supervisor_reject;
DO $supervisor_reject$
DECLARE rid uuid:=current_setting('app.test.hold_review_id')::uuid; v_result jsonb;
BEGIN
  v_result:=public.staff_decide_physical_receipt_review_v2(rid,'reject','[]'::jsonb,'unknown','Reject regression');
  IF v_result->>'status'<>'rejected' OR (SELECT status FROM public.physical_receipt_reviews WHERE id=rid)<>'rejected' THEN RAISE EXCEPTION 'Reject route failed.'; END IF;
  IF EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid AND status='proposed') THEN RAISE EXCEPTION 'Reject left active proposals.'; END IF;
END
$supervisor_reject$;
ROLLBACK TO SAVEPOINT supervisor_reject;

-- Investigation route.
SAVEPOINT supervisor_investigation;
DO $supervisor_investigation$
DECLARE rid uuid:=current_setting('app.test.hold_review_id')::uuid; aid uuid:=current_setting('app.test.hold_allocation_id')::uuid; v_result jsonb;
BEGIN
  v_result:=public.staff_decide_physical_receipt_review_v2(rid,'approve_investigation',jsonb_build_array(jsonb_build_object('remedy_allocation_id',aid,'approved_remedy_type','hold_investigate','approved_remedy_qty',1,'supplier_cost_mode','not_applicable')),'unknown','Investigation regression');
  IF v_result->>'status'<>'approved_for_investigation' THEN RAISE EXCEPTION 'Investigation route failed.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations WHERE id=aid AND status='in_progress' AND approved_remedy_type='hold_investigate' AND approved_remedy_qty=1) THEN RAISE EXCEPTION 'Investigation allocation state failed.'; END IF;
END
$supervisor_investigation$;
ROLLBACK TO SAVEPOINT supervisor_investigation;

-- Close-no-action route.
SAVEPOINT supervisor_no_action;
DO $supervisor_no_action$
DECLARE rid uuid:=current_setting('app.test.no_action_review_id')::uuid; aid uuid:=current_setting('app.test.no_action_allocation_id')::uuid; v_result jsonb;
BEGIN
  v_result:=public.staff_decide_physical_receipt_review_v2(rid,'close_no_action',jsonb_build_array(jsonb_build_object('remedy_allocation_id',aid,'approved_remedy_type','no_action','approved_remedy_qty',1,'supplier_cost_mode','not_applicable')),'no_liability','No-action regression');
  IF v_result->>'status'<>'closed_no_action' THEN RAISE EXCEPTION 'No-action route failed.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations WHERE id=aid AND status='closed_no_action' AND approved_remedy_type='no_action' AND approved_remedy_qty=1) THEN RAISE EXCEPTION 'No-action allocation state failed.'; END IF;
END
$supervisor_no_action$;
ROLLBACK TO SAVEPOINT supervisor_no_action;

-- Existing exception route with mixed refund/replacement links both disputes atomically.
SAVEPOINT supervisor_existing;
DO $supervisor_existing$
DECLARE
  rid uuid:=current_setting('app.test.existing_review_id')::uuid;
  refund_id uuid:=current_setting('app.test.refund_allocation_id')::uuid;
  replacement_id uuid:=current_setting('app.test.replacement_allocation_id')::uuid;
  v_result jsonb;
  v_links integer;
BEGIN
  v_result:=public.staff_decide_physical_receipt_review_v2(
    rid,
    'approve_existing_exception',
    jsonb_build_array(
      jsonb_build_object('remedy_allocation_id',refund_id,'approved_remedy_type','refund','approved_remedy_qty',1,'supplier_cost_mode','not_applicable'),
      jsonb_build_object('remedy_allocation_id',replacement_id,'approved_remedy_type','replacement','approved_remedy_qty',1,'supplier_cost_mode','pending_supplier_evidence')
    ),
    'retailer',
    'Existing exception regression'
  );
  IF v_result->>'status'<>'approved_to_existing_exception' THEN RAISE EXCEPTION 'Existing-exception route failed.'; END IF;
  SELECT count(*) INTO v_links FROM public.physical_receipt_review_dispute_links WHERE physical_receipt_review_id=rid AND desired_outcome IN ('refund','replacement');
  IF v_links<>2 THEN RAISE EXCEPTION 'Expected two outcome-specific dispute links, found %.', v_links; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations WHERE id=refund_id AND status='linked_to_exception' AND dispute_line_id IS NOT NULL)
     OR NOT EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations WHERE id=replacement_id AND status='linked_to_exception' AND dispute_line_id IS NOT NULL)
  THEN RAISE EXCEPTION 'Existing-exception allocations were not linked atomically.'; END IF;
END
$supervisor_existing$;
ROLLBACK TO SAVEPOINT supervisor_existing;

-- Clear the last authenticated identity and prove the runtime blocks anon completely.
RESET ROLE;
SELECT set_config('request.jwt.claims', '{}', true);
SELECT set_config('request.jwt.claim.sub', '', true);
SET LOCAL ROLE anon;

DO $unauthenticated_fail_closed$
DECLARE
  v_count integer;
  v_denied boolean;
  p text:=current_setting('app.test.evidence_path');
BEGIN
  v_denied:=false;
  BEGIN
    PERFORM public.importer_physical_receipt_reviews_v1(current_setting('app.test.importer_review_id')::uuid);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied:=true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Anon executed importer read RPC.'; END IF;

  v_denied:=false;
  BEGIN
    PERFORM public.staff_physical_receipt_reviews_v1(current_setting('app.test.existing_review_id')::uuid);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied:=true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Anon executed supervisor read RPC.'; END IF;

  v_denied:=false;
  BEGIN
    PERFORM public.can_read_physical_receipt_evidence_v1(p);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied:=true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Anon executed evidence helper.'; END IF;

  SELECT count(*) INTO v_count
  FROM storage.objects
  WHERE bucket_id='invoice-evidence' AND name=p;
  IF v_count<>0 THEN
    RAISE EXCEPTION 'Unauthenticated storage RLS exposed physical receipt evidence.';
  END IF;

  v_denied:=false;
  BEGIN
    PERFORM public.operator_submit_physical_receipt_proposal_v2(
      current_setting('app.test.importer_review_id')::uuid,
      jsonb_build_array(jsonb_build_object(
        'receipt_line_disposition_id',current_setting('app.test.importer_disposition_id')::uuid,
        'proposed_remedy_type','replacement',
        'proposed_remedy_qty',1
      )),
      'unauthenticated denial regression'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied:=true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Anon executed importer v2.'; END IF;

  v_denied:=false;
  BEGIN
    PERFORM public.staff_decide_physical_receipt_review_v2(
      current_setting('app.test.hold_review_id')::uuid,
      'return_for_information',
      '[]'::jsonb,
      'unknown',
      'unauthenticated denial regression'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied:=true;
  END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Anon executed supervisor v2.'; END IF;
END
$unauthenticated_fail_closed$;

RESET ROLE;

SELECT jsonb_build_object(
  'regression_result','PASS',
  'proof','runtime v1 denial; v2 grants; action-only queues; importer isolation; exact storage RLS; importer invalid and valid gateway behavior; all supervisor fractional routes; return, reject, investigation, no-action and mixed existing-exception behavior; unauthenticated read, evidence, storage and write denial; all writes rolled back'
) AS regression_result;

ROLLBACK;
