BEGIN;

DO $regression$
DECLARE
  v_importer_def text;
  v_staff_def text;
  v_evidence_def text;
  v_importer_acl aclitem[];
  v_staff_acl aclitem[];
  v_evidence_acl aclitem[];
BEGIN
  IF to_regprocedure('public.importer_physical_receipt_reviews_v1(uuid)') IS NULL
     OR to_regprocedure('public.staff_physical_receipt_reviews_v1(uuid)') IS NULL
     OR to_regprocedure('public.can_read_physical_receipt_evidence_v1(text)') IS NULL
  THEN
    RAISE EXCEPTION 'Operational read authorities are missing.';
  END IF;

  SELECT pg_get_functiondef('public.importer_physical_receipt_reviews_v1(uuid)'::regprocedure), p.proacl
  INTO v_importer_def, v_importer_acl
  FROM pg_proc p
  WHERE p.oid = 'public.importer_physical_receipt_reviews_v1(uuid)'::regprocedure;

  SELECT pg_get_functiondef('public.staff_physical_receipt_reviews_v1(uuid)'::regprocedure), p.proacl
  INTO v_staff_def, v_staff_acl
  FROM pg_proc p
  WHERE p.oid = 'public.staff_physical_receipt_reviews_v1(uuid)'::regprocedure;

  SELECT pg_get_functiondef('public.can_read_physical_receipt_evidence_v1(text)'::regprocedure), p.proacl
  INTO v_evidence_def, v_evidence_acl
  FROM pg_proc p
  WHERE p.oid = 'public.can_read_physical_receipt_evidence_v1(text)'::regprocedure;

  IF v_importer_def NOT ILIKE '%SECURITY DEFINER%'
     OR v_importer_def NOT ILIKE '%operator_importers%'
     OR v_importer_def NOT ILIKE '%awaiting_importer_proposal%'
     OR v_importer_def NOT ILIKE '%returned_for_information%'
     OR v_importer_def NOT ILIKE '%p_review_id IS NULL%'
     OR v_importer_def ~* '\m(INSERT|UPDATE|DELETE)\M'
  THEN
    RAISE EXCEPTION 'Importer operational read definition violates the audited read-only/action-queue contract.';
  END IF;

  IF v_staff_def NOT ILIKE '%SECURITY DEFINER%'
     OR v_staff_def NOT ILIKE '%role_type IN (''admin'', ''supervisor'')%'
     OR v_staff_def NOT ILIKE '%awaiting_supervisor_review%'
     OR v_staff_def NOT ILIKE '%physical_receipt_review_dispute_links%'
     OR v_staff_def NOT ILIKE '%desired_outcome%'
     OR v_staff_def ~* '\m(INSERT|UPDATE|DELETE)\M'
  THEN
    RAISE EXCEPTION 'Staff operational read definition violates the audited read-only/action-queue contract.';
  END IF;

  IF v_evidence_def NOT ILIKE '%SECURITY DEFINER%'
     OR v_evidence_def NOT ILIKE '%storage_object_path = p_storage_object_path%'
     OR v_evidence_def NOT ILIKE '%operator_importers%'
     OR v_evidence_def NOT ILIKE '%role_type IN (''admin'', ''supervisor'')%'
     OR v_evidence_def ~* '\m(INSERT|UPDATE|DELETE)\M'
  THEN
    RAISE EXCEPTION 'Evidence authorization definition violates the exact review-role contract.';
  END IF;

  IF has_function_privilege('anon', 'public.importer_physical_receipt_reviews_v1(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.staff_physical_receipt_reviews_v1(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.can_read_physical_receipt_evidence_v1(text)', 'EXECUTE')
     OR COALESCE(array_to_string(v_importer_acl, ','), '') LIKE '%=X/%'
     OR COALESCE(array_to_string(v_staff_acl, ','), '') LIKE '%=X/%'
     OR COALESCE(array_to_string(v_evidence_acl, ','), '') LIKE '%=X/%'
  THEN
    RAISE EXCEPTION 'Operational read authority is executable by anon or PUBLIC.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.importer_physical_receipt_reviews_v1(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.staff_physical_receipt_reviews_v1(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.can_read_physical_receipt_evidence_v1(text)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'Authenticated execution grant is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'physical_receipt_evidence_importer_read_v1'
      AND cmd = 'SELECT'
      AND qual ILIKE '%invoice-evidence%'
      AND qual ILIKE '%can_read_physical_receipt_evidence_v1%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'physical_receipt_evidence_staff_read_v1'
      AND cmd = 'SELECT'
      AND qual ILIKE '%invoice-evidence%'
      AND qual ILIKE '%can_read_physical_receipt_evidence_v1%'
  ) THEN
    RAISE EXCEPTION 'Exact physical receipt evidence SELECT policies are missing or broadened.';
  END IF;

  IF public.can_read_physical_receipt_evidence_v1(NULL) IS DISTINCT FROM false
     OR public.can_read_physical_receipt_evidence_v1('') IS DISTINCT FROM false
     OR public.can_read_physical_receipt_evidence_v1('not/a/real/object') IS DISTINCT FROM false
  THEN
    RAISE EXCEPTION 'Evidence authorization does not fail closed for unauthenticated/invalid paths.';
  END IF;
END
$regression$;

ROLLBACK;
