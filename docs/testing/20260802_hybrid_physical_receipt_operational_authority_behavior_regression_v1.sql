\set ON_ERROR_STOP on

-- Required psql variables are intentionally referenced directly so a missing
-- fixture fails before any assertion runs.
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
  THEN RAISE EXCEPTION 'Operational v2 gateways are missing.'; END IF;
  IF has_function_privilege('authenticated','public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)','EXECUTE')
     OR has_function_privilege('authenticated','public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)','EXECUTE')
  THEN RAISE EXCEPTION 'Authenticated direct v1 execution remains available.'; END IF;
  IF NOT has_function_privilege('authenticated','public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)','EXECUTE')
  THEN RAISE EXCEPTION 'Authenticated v2 execution is missing.'; END IF;
END
$preflight$;

SET LOCAL ROLE authenticated;

-- Access matrix helper: each identity is applied through request.jwt.claims.
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_A_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $authorised_importer$
DECLARE v jsonb; c integer; rid uuid:=current_setting('app.test.importer_review_id')::uuid; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.importer_physical_receipt_reviews_v1(rid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>1 THEN RAISE EXCEPTION 'Authorised importer detail failed.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Authorised importer evidence helper failed.'; END IF;
  SELECT count(*) INTO c FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF c<>1 THEN RAISE EXCEPTION 'Authorised importer storage RLS failed.'; END IF;
END
$authorised_importer$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_B_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $other_importer$
DECLARE v jsonb; c integer; rid uuid:=current_setting('app.test.importer_review_id')::uuid; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.importer_physical_receipt_reviews_v1(rid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>0 THEN RAISE EXCEPTION 'Cross-importer detail succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) THEN RAISE EXCEPTION 'Cross-importer evidence helper succeeded.'; END IF;
  SELECT count(*) INTO c FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF c<>0 THEN RAISE EXCEPTION 'Cross-importer storage RLS succeeded.'; END IF;
END
$other_importer$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'REVOKED_IMPORTER_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $revoked_importer$
DECLARE v jsonb; rid uuid:=current_setting('app.test.importer_review_id')::uuid; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.importer_physical_receipt_reviews_v1(rid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>0 THEN RAISE EXCEPTION 'Revoked importer detail succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) THEN RAISE EXCEPTION 'Revoked importer evidence succeeded.'; END IF;
END
$revoked_importer$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'SUPERVISOR_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $supervisor$
DECLARE v jsonb; c integer; rid uuid:=current_setting('app.test.supervisor_review_id')::uuid; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.staff_physical_receipt_reviews_v1(rid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>1 THEN RAISE EXCEPTION 'Supervisor detail failed.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Supervisor evidence helper failed.'; END IF;
  SELECT count(*) INTO c FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=p;
  IF c<>1 THEN RAISE EXCEPTION 'Supervisor storage RLS failed.'; END IF;
END
$supervisor$;

SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'ORDINARY_STAFF_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $ordinary_staff$
DECLARE v jsonb; rid uuid:=current_setting('app.test.supervisor_review_id')::uuid; p text:=current_setting('app.test.evidence_path');
BEGIN
  v:=public.staff_physical_receipt_reviews_v1(rid);
  IF jsonb_array_length(COALESCE(v->'reviews','[]'::jsonb))<>0 THEN RAISE EXCEPTION 'Ordinary staff detail succeeded.'; END IF;
  IF public.can_read_physical_receipt_evidence_v1(p) THEN RAISE EXCEPTION 'Ordinary staff evidence succeeded.'; END IF;
END
$ordinary_staff$;

-- Exact importer rejection and mutation invariants.
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'IMPORTER_A_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $importer_fraction$
DECLARE rid uuid:=current_setting('app.test.importer_review_id')::uuid; did uuid:=current_setting('app.test.importer_disposition_id')::uuid; s1 text; s2 text; n1 integer; n2 integer; failed boolean:=false;
BEGIN
  SELECT status INTO s1 FROM public.physical_receipt_reviews WHERE id=rid;
  SELECT count(*) INTO n1 FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid;
  BEGIN
    PERFORM public.operator_submit_physical_receipt_proposal_v2(rid,jsonb_build_array(jsonb_build_object('receipt_line_disposition_id',did,'proposed_remedy_type','replacement','proposed_remedy_qty',1.0004)),'fraction test');
  EXCEPTION WHEN OTHERS THEN failed:=true; END;
  IF NOT failed THEN RAISE EXCEPTION 'Importer v2 accepted 1.0004.'; END IF;
  SELECT status INTO s2 FROM public.physical_receipt_reviews WHERE id=rid;
  SELECT count(*) INTO n2 FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=rid;
  IF s2 IS DISTINCT FROM s1 OR n2<>n1 THEN RAISE EXCEPTION 'Rejected importer call mutated data.'; END IF;
END
$importer_fraction$;

-- Exact supervisor rejection covers investigation/no-action as well as refund/replacement.
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', :'SUPERVISOR_AUTH_USER_ID', 'role', 'authenticated')::text, true);
DO $supervisor_fraction$
DECLARE rid uuid:=current_setting('app.test.supervisor_review_id')::uuid; aid uuid:=current_setting('app.test.supervisor_allocation_id')::uuid; s1 text; s2 text; q1 numeric; q2 numeric; failed boolean:=false;
BEGIN
  SELECT status INTO s1 FROM public.physical_receipt_reviews WHERE id=rid;
  SELECT approved_remedy_qty INTO q1 FROM public.physical_exception_remedy_allocations WHERE id=aid;
  BEGIN
    PERFORM public.staff_decide_physical_receipt_review_v2(rid,'approve_investigation',jsonb_build_array(jsonb_build_object('remedy_allocation_id',aid,'approved_remedy_type','hold_investigate','approved_remedy_qty',1.5,'supplier_cost_mode','not_applicable')),'unknown','fraction test');
  EXCEPTION WHEN OTHERS THEN failed:=true; END;
  IF NOT failed THEN RAISE EXCEPTION 'Supervisor v2 accepted 1.5 investigation quantity.'; END IF;
  SELECT status INTO s2 FROM public.physical_receipt_reviews WHERE id=rid;
  SELECT approved_remedy_qty INTO q2 FROM public.physical_exception_remedy_allocations WHERE id=aid;
  IF s2 IS DISTINCT FROM s1 OR q2 IS DISTINCT FROM q1 THEN RAISE EXCEPTION 'Rejected supervisor call mutated data.'; END IF;
END
$supervisor_fraction$;

RESET ROLE;
DO $invalid_paths$
BEGIN
  IF public.can_read_physical_receipt_evidence_v1(NULL) IS DISTINCT FROM false
     OR public.can_read_physical_receipt_evidence_v1('') IS DISTINCT FROM false
     OR public.can_read_physical_receipt_evidence_v1('not/a/real/object') IS DISTINCT FROM false
  THEN RAISE EXCEPTION 'Invalid evidence paths did not fail closed.'; END IF;
END
$invalid_paths$;

ROLLBACK;
