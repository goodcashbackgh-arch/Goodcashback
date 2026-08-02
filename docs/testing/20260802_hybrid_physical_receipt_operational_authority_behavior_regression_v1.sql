\set ON_ERROR_STOP on

-- Required psql variables:
-- IMPORTER_A_AUTH_USER_ID IMPORTER_B_AUTH_USER_ID REVOKED_IMPORTER_AUTH_USER_ID
-- SUPERVISOR_AUTH_USER_ID ORDINARY_STAFF_AUTH_USER_ID
-- IMPORTER_ACTION_REVIEW_ID IMPORTER_ACTION_DISPOSITION_ID
-- SUPERVISOR_ACTION_REVIEW_ID SUPERVISOR_ACTION_ALLOCATION_ID EVIDENCE_OBJECT_PATH

\if :{?IMPORTER_A_AUTH_USER_ID}\else\error 'IMPORTER_A_AUTH_USER_ID is required'\endif
\if :{?IMPORTER_B_AUTH_USER_ID}\else\error 'IMPORTER_B_AUTH_USER_ID is required'\endif
\if :{?REVOKED_IMPORTER_AUTH_USER_ID}\else\error 'REVOKED_IMPORTER_AUTH_USER_ID is required'\endif
\if :{?SUPERVISOR_AUTH_USER_ID}\else\error 'SUPERVISOR_AUTH_USER_ID is required'\endif
\if :{?ORDINARY_STAFF_AUTH_USER_ID}\else\error 'ORDINARY_STAFF_AUTH_USER_ID is required'\endif
\if :{?IMPORTER_ACTION_REVIEW_ID}\else\error 'IMPORTER_ACTION_REVIEW_ID is required'\endif
\if :{?IMPORTER_ACTION_DISPOSITION_ID}\else\error 'IMPORTER_ACTION_DISPOSITION_ID is required'\endif
\if :{?SUPERVISOR_ACTION_REVIEW_ID}\else\error 'SUPERVISOR_ACTION_REVIEW_ID is required'\endif
\if :{?SUPERVISOR_ACTION_ALLOCATION_ID}\else\error 'SUPERVISOR_ACTION_ALLOCATION_ID is required'\endif
\if :{?EVIDENCE_OBJECT_PATH}\else\error 'EVIDENCE_OBJECT_PATH is required'\endif

BEGIN;
SELECT set_config('app.test.importer_review_id', :'IMPORTER_ACTION_REVIEW_ID', true);
SELECT set_config('app.test.importer_disposition_id', :'IMPORTER_ACTION_DISPOSITION_ID', true);
SELECT set_config('app.test.supervisor_review_id', :'SUPERVISOR_ACTION_REVIEW_ID', true);
SELECT set_config('app.test.supervisor_allocation_id', :'SUPERVISOR_ACTION_ALLOCATION_ID', true);
SELECT set_config('app.test.evidence_path', :'EVIDENCE_OBJECT_PATH', true);

DO $preflight$
BEGIN
  IF to_regprocedure('public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)') IS NULL
     OR to_regprocedure('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)') IS NULL
     OR to_regprocedure('public.importer_physical_receipt_reviews_v1(uuid)') IS NULL
     OR to_regprocedure('public.staff_physical_receipt_reviews_v1(uuid)') IS NULL
     OR to_regprocedure('public.can_read_physical_receipt_evidence_v1(text)') IS NULL
  THEN RAISE EXCEPTION 'Operational v2 gateways and read authorities must be installed first.'; END IF;

  IF has_function_privilege('authenticated','public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)','EXECUTE')
     OR has_function_privilege('authenticated','public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)','EXECUTE')
  THEN RAISE EXCEPTION 'Authenticated direct v1 execution remains available.'; END IF;

  IF NOT has_function_privilege('authenticated','public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)','EXECUTE')
  THEN RAISE EXCEPTION 'Authenticated v2 execution is missing.'; END IF;
END
$preflight$;

SET LOCAL ROLE authenticated;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_A_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $importer_a$
DECLARE v_result jsonb; v_count integer; v_review uuid := current_setting('app.test.importer_review_id')::uuid; v_path text := current_setting('app.test.evidence_path');
BEGIN
  v_result := public.importer_physical_receipt_reviews_v1(v_review);
  IF jsonb_array_length(COALESCE(v_result->'reviews','[]'::jsonb)) <> 1 THEN RAISE EXCEPTION 'Authorised importer cannot read exact review.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(v_path) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Authorised importer cannot read evidence.'; END IF;
  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=v_path;
  IF v_count <> 1 THEN RAISE EXCEPTION 'Authorised importer storage RLS did not expose exact object.'; END IF;
END
$importer_a$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_B_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $importer_b$
DECLARE v_result jsonb; v_count integer; v_review uuid := current_setting('app.test.importer_review_id')::uuid; v_path text := current_setting('app.test.evidence_path');
BEGIN
  v_result := public.importer_physical_receipt_reviews_v1(v_review);
  IF jsonb_array_length(COALESCE(v_result->'reviews','[]'::jsonb)) <> 0 THEN RAISE EXCEPTION 'Cross-importer review access succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(v_path) THEN RAISE EXCEPTION 'Cross-importer evidence access succeeded.'; END IF;
  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=v_path;
  IF v_count <> 0 THEN RAISE EXCEPTION 'Cross-importer storage RLS access succeeded.'; END IF;
END
$importer_b$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'REVOKED_IMPORTER_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $revoked$
DECLARE v_result jsonb; v_review uuid := current_setting('app.test.importer_review_id')::uuid; v_path text := current_setting('app.test.evidence_path');
BEGIN
  v_result := public.importer_physical_receipt_reviews_v1(v_review);
  IF jsonb_array_length(COALESCE(v_result->'reviews','[]'::jsonb)) <> 0 THEN RAISE EXCEPTION 'Revoked importer review access succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(v_path) THEN RAISE EXCEPTION 'Revoked importer evidence access succeeded.'; END IF;
END
$revoked$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'SUPERVISOR_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $supervisor$
DECLARE v_result jsonb; v_count integer; v_review uuid := current_setting('app.test.supervisor_review_id')::uuid; v_path text := current_setting('app.test.evidence_path');
BEGIN
  v_result := public.staff_physical_receipt_reviews_v1(v_review);
  IF jsonb_array_length(COALESCE(v_result->'reviews','[]'::jsonb)) <> 1 THEN RAISE EXCEPTION 'Supervisor cannot read exact review.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(v_path) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Supervisor cannot read evidence.'; END IF;
  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=v_path;
  IF v_count <> 1 THEN RAISE EXCEPTION 'Supervisor storage RLS did not expose exact object.'; END IF;
END
$supervisor$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'ORDINARY_STAFF_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $ordinary_staff$
DECLARE v_result jsonb; v_review uuid := current_setting('app.test.supervisor_review_id')::uuid; v_path text := current_setting('app.test.evidence_path');
BEGIN
  v_result := public.staff_physical_receipt_reviews_v1(v_review);
  IF jsonb_array_length(COALESCE(v_result->'reviews','[]'::jsonb)) <> 0 THEN RAISE EXCEPTION 'Ordinary staff review access succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(v_path) THEN RAISE EXCEPTION 'Ordinary staff evidence access succeeded.'; END IF;
END
$ordinary_staff$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_A_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $importer_fractional$
DECLARE
  v_review uuid := current_setting('app.test.importer_review_id')::uuid;
  v_disposition uuid := current_setting('app.test.importer_disposition_id')::uuid;
  v_before_status text; v_after_status text; v_before_count integer; v_after_count integer; v_failed boolean := false;
BEGIN
  SELECT status INTO v_before_status FROM public.physical_receipt_reviews WHERE id=v_review;
  SELECT count(*) INTO v_before_count FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=v_review;
  BEGIN
    PERFORM public.operator_submit_physical_receipt_proposal_v2(v_review, jsonb_build_array(jsonb_build_object(
      'receipt_line_disposition_id',v_disposition,'proposed_remedy_type','replacement','proposed_remedy_qty',1.0004)), 'Regression fractional rejection');
  EXCEPTION WHEN OTHERS THEN v_failed := true; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Importer v2 accepted 1.0004.'; END IF;
  SELECT status INTO v_after_status FROM public.physical_receipt_reviews WHERE id=v_review;
  SELECT count(*) INTO v_after_count FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=v_review;
  IF v_after_status IS DISTINCT FROM v_before_status OR v_after_count <> v_before_count THEN RAISE EXCEPTION 'Rejected importer call mutated data.'; END IF;
END
$importer_fractional$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'SUPERVISOR_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $supervisor_fractional$
DECLARE
  v_review uuid := current_setting('app.test.supervisor_review_id')::uuid;
  v_allocation uuid := current_setting('app.test.supervisor_allocation_id')::uuid;
  v_before_status text; v_after_status text; v_before_qty numeric; v_after_qty numeric; v_failed boolean := false;
BEGIN
  SELECT status INTO v_before_status FROM public.physical_receipt_reviews WHERE id=v_review;
  SELECT approved_remedy_qty INTO v_before_qty FROM public.physical_exception_remedy_allocations WHERE id=v_allocation;
  BEGIN
    PERFORM public.staff_decide_physical_receipt_review_v2(v_review,'approve_investigation',jsonb_build_array(jsonb_build_object(
      'remedy_allocation_id',v_allocation,'approved_remedy_type','hold_investigate','approved_remedy_qty',1.5,'supplier_cost_mode','not_applicable')),
      'unknown','Regression fractional rejection');
  EXCEPTION WHEN OTHERS THEN v_failed := true; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'Supervisor v2 accepted fractional investigation quantity.'; END IF;
  SELECT status INTO v_after_status FROM public.physical_receipt_reviews WHERE id=v_review;
  SELECT approved_remedy_qty INTO v_after_qty FROM public.physical_exception_remedy_allocations WHERE id=v_allocation;
  IF v_after_status IS DISTINCT FROM v_before_status OR v_after_qty IS DISTINCT FROM v_before_qty THEN RAISE EXCEPTION 'Rejected supervisor call mutated data.'; END IF;
END
$supervisor_fractional$;

RESET ROLE;
DO $invalid_paths$
BEGIN
  IF public.can_read_physical_receipt_evidence_v1(NULL) IS DISTINCT FROM false
     OR public.can_read_physical_receipt_evidence_v1('') IS DISTINCT FROM false
     OR public.can_read_physical_receipt_evidence_v1('not/a/real/object') IS DISTINCT FROM false
  THEN RAISE EXCEPTION 'Invalid evidence path did not fail closed.'; END IF;
END
$invalid_paths$;

ROLLBACK;
