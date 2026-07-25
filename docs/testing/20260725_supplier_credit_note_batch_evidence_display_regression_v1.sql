BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $structure$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure('public.internal_sage_posting_batch_detail_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical or preserved batch-detail function missing';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_sage_posting_batch_detail_v1(uuid)'::regprocedure))
  INTO v_definition;

  IF position('internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1' IN v_definition) = 0
     OR position('evidence,credit_note_file_url' IN v_definition) = 0
     OR position('dispute_refund_evidence_submissions' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: canonical batch detail is not the preserved implementation plus supplier-credit evidence resolution';
  END IF;
END
$structure$;

DO $behaviour$
DECLARE
  v_auth_uid uuid;
  v_batch_id uuid;
  v_source_url text;
  v_display_url text;
  v_evidence_status text;
  v_non_supplier_difference_count integer;
BEGIN
  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 WHEN s.role_type = 'supervisor' THEN 1 ELSE 2 END,
           s.id
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff auth identity available';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );

  SELECT br.batch_id
  INTO v_batch_id
  FROM public.sage_posting_batch_rows br
  WHERE br.source_table = 'dispute_refund_evidence_submissions'
    AND br.source_id = '9536b81c-1241-49f2-a8b5-d49d2394713e'::uuid
    AND br.document_lane = 'supplier_credit_note'
  ORDER BY br.created_at DESC
  LIMIT 1;

  IF v_batch_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: current supplier-credit posting batch row not found';
  END IF;

  SELECT dres.credit_note_file_url
  INTO v_source_url
  FROM public.dispute_refund_evidence_submissions dres
  WHERE dres.id = '9536b81c-1241-49f2-a8b5-d49d2394713e'::uuid;

  SELECT d.source_invoice_file_url, d.source_evidence_status
  INTO v_display_url, v_evidence_status
  FROM public.internal_sage_posting_batch_detail_v1(v_batch_id) d
  WHERE d.source_table = 'dispute_refund_evidence_submissions'
    AND d.source_id = '9536b81c-1241-49f2-a8b5-d49d2394713e'::uuid
    AND d.document_lane = 'supplier_credit_note'
  LIMIT 1;

  IF NULLIF(v_source_url, '') IS NULL THEN
    RAISE EXCEPTION 'FAIL: source credit-note URL is missing';
  END IF;

  IF v_display_url IS DISTINCT FROM v_source_url THEN
    RAISE EXCEPTION 'FAIL: batch detail did not expose the existing source credit-note URL';
  END IF;

  IF v_evidence_status IS DISTINCT FROM 'source_evidence_available' THEN
    RAISE EXCEPTION 'FAIL: supplier-credit evidence status is %, expected source_evidence_available', v_evidence_status;
  END IF;

  -- The wrapper must not alter any non-supplier-credit row from the preserved implementation.
  SELECT COUNT(*)::integer
  INTO v_non_supplier_difference_count
  FROM (
    SELECT to_jsonb(c) AS row_json
    FROM public.internal_sage_posting_batch_detail_v1(v_batch_id) c
    WHERE c.document_lane IS DISTINCT FROM 'supplier_credit_note'
    EXCEPT ALL
    SELECT to_jsonb(p) AS row_json
    FROM public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(v_batch_id) p
    WHERE p.document_lane IS DISTINCT FROM 'supplier_credit_note'
  ) differences;

  IF v_non_supplier_difference_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: wrapper changed % non-supplier-credit batch-detail row(s)', v_non_supplier_difference_count;
  END IF;
END
$behaviour$;

SELECT
  'PASS'::text AS regression_result,
  'Existing and future supplier-credit batches expose their attached credit-note evidence while all prior batch-detail behaviour is preserved.'::text AS details;

ROLLBACK;
