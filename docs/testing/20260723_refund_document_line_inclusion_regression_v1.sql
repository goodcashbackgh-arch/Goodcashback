-- Refund-document line inclusion regression v1.
-- Read-only checks. Run after 20260723g_refund_document_line_inclusion_control_v1.sql
-- and after excluding the duplicate £5 delivery_adjustment on NK-CN-190726-001.
--
-- Expected evidence truth for the live Ninja case:
--   included OCR goods              £179.99
--   included OCR delivery             £5.00
--   excluded duplicate adjustment     £5.00
--   accepted supplier credit         £184.99

BEGIN;
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'FAIL: dispute_refund_document_lines missing';
  END IF;
  IF to_regclass('public.dispute_refund_document_accounting_totals_vw') IS NULL THEN
    RAISE EXCEPTION 'FAIL: dispute_refund_document_accounting_totals_vw missing';
  END IF;
  IF to_regprocedure('public.refund_document_accepted_credit_gbp_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: refund_document_accepted_credit_gbp_v1(uuid) missing';
  END IF;
  IF to_regprocedure('public.refund_credit_note_submission_is_aligned_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: refund_credit_note_submission_is_aligned_v1(uuid) missing';
  END IF;
  IF to_regprocedure('public.staff_set_refund_line_inclusion_v1(uuid,uuid[],boolean,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: staff_set_refund_line_inclusion_v1(uuid,uuid[],boolean,text) missing';
  END IF;
  IF to_regprocedure('public.staff_release_refund_document_lines_to_supplier_control(uuid,uuid[],text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: staff_release_refund_document_lines_to_supplier_control(uuid,uuid[],text) missing';
  END IF;
  IF to_regprocedure('public.internal_supplier_credit_note_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: internal_supplier_credit_note_ready_rows_v1() missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dispute_refund_document_lines'
      AND column_name = 'included_in_supplier_credit_yn'
  ) THEN
    RAISE EXCEPTION 'FAIL: included_in_supplier_credit_yn column missing';
  END IF;
END $$;

-- The implementation definitions must retain the hard guards.
DO $$
DECLARE
  v_release_definition text;
  v_ocr_definition text;
  v_ready_definition text;
BEGIN
  v_release_definition := pg_get_functiondef(
    'public.staff_release_refund_document_lines_to_supplier_control(uuid,uuid[],text)'::regprocedure
  );
  v_ocr_definition := pg_get_functiondef(
    'public.staff_save_refund_credit_note_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,text,text,date,numeric,integer,jsonb,jsonb)'::regprocedure
  );
  v_ready_definition := pg_get_functiondef(
    'public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure
  );

  IF position('included_in_supplier_credit_yn' IN v_release_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: release RPC does not enforce included supplier-credit scope';
  END IF;
  IF position('Restore excluded OCR lines before replacing the OCR result.' IN v_ocr_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: OCR replacement guard is missing';
  END IF;
  IF position('included_in_supplier_credit_yn' IN v_ready_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: Sage readiness does not filter excluded lines';
  END IF;
  IF position('COALESCE(b.accepted_document_gross_gbp, 0)::numeric(18,2) AS accepted_gross_gbp' IN v_ready_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: Sage readiness is not using the authoritative accepted supplier-credit amount';
  END IF;
END $$;

-- Excluded evidence must never have progressed or been coded anywhere.
DO $$
DECLARE
  v_released bigint;
  v_coded bigint;
BEGIN
  SELECT count(*)
    INTO v_released
  FROM public.dispute_refund_document_lines l
  WHERE COALESCE(l.included_in_supplier_credit_yn, true) = false
    AND COALESCE(l.progressed_to_supplier_control_yn, false) = true;

  SELECT count(*)
    INTO v_coded
  FROM public.dispute_refund_document_lines l
  JOIN public.dispute_refund_document_line_accounting_codes c
    ON c.refund_document_line_id = l.id
  WHERE COALESCE(l.included_in_supplier_credit_yn, true) = false;

  IF v_released <> 0 THEN
    RAISE EXCEPTION 'FAIL: % excluded refund-document lines are released', v_released;
  END IF;
  IF v_coded <> 0 THEN
    RAISE EXCEPTION 'FAIL: % excluded refund-document lines are accounting coded', v_coded;
  END IF;
END $$;

-- Live Ninja duplicate scenario.
DO $$
DECLARE
  v_submission_id uuid;
  v_ocr_total numeric(12,2);
  v_included_ocr_total numeric(12,2);
  v_included_supplementary_total numeric(12,2);
  v_excluded_supplementary_total numeric(12,2);
  v_accepted_total numeric(12,2);
  v_stored_total numeric(12,2);
  v_excluded_count integer;
  v_aligned boolean;
  v_totals record;
BEGIN
  SELECT s.id, s.ocr_credit_note_total_gbp
    INTO v_submission_id, v_ocr_total
  FROM public.dispute_refund_evidence_submissions s
  WHERE s.document_mode = 'credit_note'
    AND upper(regexp_replace(COALESCE(s.credit_note_ref, ''), '[^A-Za-z0-9]+', '', 'g'))
      = upper(regexp_replace('NK-CN-190726-001', '[^A-Za-z0-9]+', '', 'g'))
  ORDER BY s.submitted_at DESC, s.id DESC
  LIMIT 1;

  IF v_submission_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: live Ninja credit-note submission NK-CN-190726-001 not found';
  END IF;

  SELECT
    round(COALESCE(sum(abs(COALESCE(l.amount_gbp, 0))) FILTER (
      WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true
        AND l.line_source = 'ocr_extracted'
    ), 0)::numeric, 2),
    round(COALESCE(sum(abs(COALESCE(l.amount_gbp, 0))) FILTER (
      WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true
        AND l.line_source IN ('delivery_adjustment', 'discount_adjustment')
    ), 0)::numeric, 2),
    round(COALESCE(sum(abs(COALESCE(l.amount_gbp, 0))) FILTER (
      WHERE COALESCE(l.included_in_supplier_credit_yn, true) = false
        AND l.line_source IN ('delivery_adjustment', 'discount_adjustment')
    ), 0)::numeric, 2),
    round(COALESCE(sum(abs(COALESCE(l.amount_gbp, 0))), 0)::numeric, 2),
    count(*) FILTER (WHERE COALESCE(l.included_in_supplier_credit_yn, true) = false)::integer
  INTO
    v_included_ocr_total,
    v_included_supplementary_total,
    v_excluded_supplementary_total,
    v_stored_total,
    v_excluded_count
  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission_id;

  v_accepted_total := public.refund_document_accepted_credit_gbp_v1(v_submission_id);
  v_aligned := public.refund_credit_note_submission_is_aligned_v1(v_submission_id);

  SELECT *
    INTO v_totals
  FROM public.dispute_refund_document_accounting_totals_vw t
  WHERE t.refund_evidence_submission_id = v_submission_id;

  IF abs(COALESCE(v_ocr_total, 0) - 184.99) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: OCR face total expected 184.99, got %', v_ocr_total;
  END IF;
  IF abs(COALESCE(v_included_ocr_total, 0) - 184.99) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: included OCR lines expected 184.99, got %', v_included_ocr_total;
  END IF;
  IF abs(COALESCE(v_included_supplementary_total, 0) - 0.00) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: included supplementary total expected 0.00, got %', v_included_supplementary_total;
  END IF;
  IF abs(COALESCE(v_excluded_supplementary_total, 0) - 5.00) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: excluded duplicate supplementary total expected 5.00, got %', v_excluded_supplementary_total;
  END IF;
  IF abs(COALESCE(v_stored_total, 0) - 189.99) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: immutable stored evidence expected 189.99, got %', v_stored_total;
  END IF;
  IF COALESCE(v_excluded_count, 0) < 1 THEN
    RAISE EXCEPTION 'FAIL: duplicate delivery adjustment was not retained as excluded audit evidence';
  END IF;
  IF abs(COALESCE(v_accepted_total, 0) - 184.99) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: accepted supplier credit expected 184.99, got %', v_accepted_total;
  END IF;
  IF v_aligned IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: formal credit note is not aligned after duplicate exclusion';
  END IF;
  IF v_totals.refund_evidence_submission_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: accounting totals row missing for live Ninja submission';
  END IF;
  IF abs(COALESCE(v_totals.accepted_document_gross_gbp, 0) - 184.99) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: accounting totals accepted gross expected 184.99, got %', v_totals.accepted_document_gross_gbp;
  END IF;
  IF abs(COALESCE(v_totals.included_ocr_gross_gbp, 0) - 184.99) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: accounting totals included OCR expected 184.99, got %', v_totals.included_ocr_gross_gbp;
  END IF;
  IF abs(COALESCE(v_totals.included_supplementary_gross_gbp, 0) - 0.00) > 0.01 THEN
    RAISE EXCEPTION 'FAIL: accounting totals supplementary expected 0.00, got %', v_totals.included_supplementary_gross_gbp;
  END IF;
END $$;

-- If the submission is already approved, the Sage-ready lane and resolved payload
-- must also remain at £184.99. Before approval, absence from the queue is expected.
DO $$
DECLARE
  v_submission_id uuid;
  v_approved boolean;
  v_ready record;
  v_resolved_gross numeric(18,2);
BEGIN
  SELECT
    s.id,
    s.supplier_approval_status = 'approved_current'
      AND s.supplier_control_status = 'approved_current'
  INTO v_submission_id, v_approved
  FROM public.dispute_refund_evidence_submissions s
  WHERE s.document_mode = 'credit_note'
    AND upper(regexp_replace(COALESCE(s.credit_note_ref, ''), '[^A-Za-z0-9]+', '', 'g'))
      = upper(regexp_replace('NK-CN-190726-001', '[^A-Za-z0-9]+', '', 'g'))
  ORDER BY s.submitted_at DESC, s.id DESC
  LIMIT 1;

  IF COALESCE(v_approved, false) THEN
    SELECT *
      INTO v_ready
    FROM public.internal_supplier_credit_note_ready_rows_v1() r
    WHERE r.source_id = v_submission_id;

    IF v_ready.source_id IS NULL THEN
      RAISE EXCEPTION 'FAIL: approved Ninja supplier credit is missing from Sage readiness';
    END IF;
    IF abs(COALESCE(v_ready.amount_gbp, 0) - 184.99) > 0.01 THEN
      RAISE EXCEPTION 'FAIL: Sage-ready accepted gross expected 184.99, got %', v_ready.amount_gbp;
    END IF;

    SELECT round(COALESCE(sum((line->>'gross_credit_gbp')::numeric), 0)::numeric, 2)
      INTO v_resolved_gross
    FROM jsonb_array_elements(COALESCE(v_ready.source_payload->'resolved_lines', '[]'::jsonb)) line;

    IF abs(COALESCE(v_resolved_gross, 0) - 184.99) > 0.01 THEN
      RAISE EXCEPTION 'FAIL: Sage resolved-line gross expected 184.99, got %', v_resolved_gross;
    END IF;
  END IF;
END $$;

SELECT
  s.id AS refund_evidence_submission_id,
  s.credit_note_ref,
  s.ocr_credit_note_total_gbp,
  t.included_ocr_gross_gbp,
  t.included_supplementary_gross_gbp,
  t.excluded_line_count,
  t.accepted_document_gross_gbp,
  s.match_status,
  s.supplier_control_status,
  s.supplier_approval_status
FROM public.dispute_refund_evidence_submissions s
JOIN public.dispute_refund_document_accounting_totals_vw t
  ON t.refund_evidence_submission_id = s.id
WHERE upper(regexp_replace(COALESCE(s.credit_note_ref, ''), '[^A-Za-z0-9]+', '', 'g'))
  = upper(regexp_replace('NK-CN-190726-001', '[^A-Za-z0-9]+', '', 'g'))
ORDER BY s.submitted_at DESC, s.id DESC
LIMIT 1;

SELECT 'PASS: refund-document line inclusion regression completed'::text AS regression_result;

ROLLBACK;
