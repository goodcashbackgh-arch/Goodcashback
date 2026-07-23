BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines';
  END IF;
  IF to_regprocedure('public.staff_correct_refund_credit_note_header_v1(uuid,text,date,numeric,text,text,date,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: staff_correct_refund_credit_note_header_v1(uuid,text,date,numeric,text,text,date,numeric,text)';
  END IF;
  IF to_regprocedure('public.staff_save_refund_credit_note_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,text,text,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: staff_save_refund_credit_note_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,text,text,date,numeric,integer,jsonb,jsonb)';
  END IF;
  IF to_regprocedure('public.internal_supplier_credit_note_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_supplier_credit_note_ready_rows_v1()';
  END IF;
END $$;

-- Add the columns before recompiling existing functions so their definitions can
-- safely reference the new inclusion state. The main migration adds the durable
-- constraint, index, views, triggers and RPCs.
ALTER TABLE public.dispute_refund_document_lines
  ADD COLUMN IF NOT EXISTS included_in_supplier_credit_yn boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS exclusion_reason text NULL,
  ADD COLUMN IF NOT EXISTS excluded_by_staff_id uuid NULL REFERENCES public.staff(id),
  ADD COLUMN IF NOT EXISTS excluded_at timestamptz NULL;

-- Patch the header-correction line-total query without depending on indentation,
-- keyword case or pg_get_functiondef formatting.
DO $patch_header$
DECLARE
  v_definition text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef(
    'public.staff_correct_refund_credit_note_header_v1(uuid,text,date,numeric,text,text,date,numeric,text)'::regprocedure
  ) INTO v_definition;

  IF position('included_in_supplier_credit_yn' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := regexp_replace(
      v_definition,
      E'(INTO[[:space:]]+v_line_count,[[:space:]]*v_line_total[[:space:]]+FROM[[:space:]]+public\\.dispute_refund_document_lines[[:space:]]+l[[:space:]]+WHERE[[:space:]]+l\\.refund_evidence_submission_id[[:space:]]*=[[:space:]]*v_submission\\.id)[[:space:]]*;',
      E'\\1\n    AND COALESCE(l.included_in_supplier_credit_yn, true) = true\n    AND l.line_source = ''ocr_extracted'';',
      'i'
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not patch staff_correct_refund_credit_note_header_v1 with the whitespace-tolerant inclusion anchor.';
    END IF;

    EXECUTE v_definition;
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_correct_refund_credit_note_header_v1(uuid,text,date,numeric,text,text,date,numeric,text)'::regprocedure
  ) INTO v_definition;

  IF position('included_in_supplier_credit_yn' IN v_definition) = 0
     OR position('line_source = ''ocr_extracted''' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Header-correction inclusion patch verification failed.';
  END IF;
END;
$patch_header$;

-- Protect excluded OCR audit rows from replacement and require the extracted
-- line total to agree with the OCR face total.
DO $patch_ocr$
DECLARE
  v_definition text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef(
    'public.staff_save_refund_credit_note_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,text,text,date,numeric,integer,jsonb,jsonb)'::regprocedure
  ) INTO v_definition;

  IF position('Restore excluded OCR lines before replacing the OCR result.' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := regexp_replace(
      v_definition,
      E'(delete[[:space:]]+from[[:space:]]+public\\.dispute_refund_document_lines[[:space:]]+l[[:space:]]+where[[:space:]]+l\\.refund_evidence_submission_id[[:space:]]*=[[:space:]]*p_refund_evidence_submission_id[[:space:]]+and[[:space:]]+l\\.line_source[[:space:]]*=[[:space:]]*''ocr_extracted''[[:space:]]+and[[:space:]]+l\\.progressed_to_supplier_control_yn[[:space:]]*=[[:space:]]*false[[:space:]]*;)',
      E'if exists (\n    select 1\n    from public.dispute_refund_document_lines l\n    where l.refund_evidence_submission_id = p_refund_evidence_submission_id\n      and l.line_source = ''ocr_extracted''\n      and coalesce(l.included_in_supplier_credit_yn, true) = false\n  ) then\n    raise exception ''Restore excluded OCR lines before replacing the OCR result.'';\n  end if;\n\n  \\1',
      'i'
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not add the whitespace-tolerant excluded OCR replacement guard.';
    END IF;
  END IF;

  IF position('abs(v_line_total - v_ocr_total) > 0.01' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := regexp_replace(
      v_definition,
      E'if[[:space:]]+v_inserted_count[[:space:]]*=[[:space:]]*0[[:space:]]+then[[:space:]]+v_match_status[[:space:]]*:=[[:space:]]*''needs_supervisor_review''[[:space:]]*;[[:space:]]+end[[:space:]]+if[[:space:]]*;',
      E'if v_inserted_count = 0 or abs(v_line_total - v_ocr_total) > 0.01 then\n    v_match_status := ''needs_supervisor_review'';\n  end if;',
      'i'
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not add the whitespace-tolerant OCR line-total alignment guard.';
    END IF;
  END IF;

  EXECUTE v_definition;

  SELECT pg_get_functiondef(
    'public.staff_save_refund_credit_note_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,text,text,date,numeric,integer,jsonb,jsonb)'::regprocedure
  ) INTO v_definition;

  IF position('Restore excluded OCR lines before replacing the OCR result.' IN v_definition) = 0
     OR position('abs(v_line_total - v_ocr_total) > 0.01' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'OCR inclusion patch verification failed.';
  END IF;
END;
$patch_ocr$;

-- Make Sage readiness consume the authoritative accepted amount and included
-- progressed evidence only. Both replacements are anchored to their exact
-- semantic clauses but tolerate whitespace and keyword casing.
DO $patch_ready$
DECLARE
  v_definition text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure
  ) INTO v_definition;

  IF position('COALESCE(b.accepted_document_gross_gbp, 0)::numeric(18,2) AS accepted_gross_gbp' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := regexp_replace(
      v_definition,
      E'GREATEST[[:space:]]*\\([[:space:]]*COALESCE[[:space:]]*\\([[:space:]]*b\\.accepted_document_gross_gbp[[:space:]]*,[[:space:]]*0[[:space:]]*\\)[[:space:]]*,[[:space:]]*COALESCE[[:space:]]*\\([[:space:]]*b\\.captured_refund_amount_abs_gbp[[:space:]]*,[[:space:]]*0[[:space:]]*\\)[[:space:]]*,[[:space:]]*COALESCE[[:space:]]*\\([[:space:]]*b\\.expected_exception_amount_abs_gbp[[:space:]]*,[[:space:]]*0[[:space:]]*\\)[[:space:]]*,[[:space:]]*COALESCE[[:space:]]*\\([[:space:]]*b\\.amount_impact_gbp[[:space:]]*,[[:space:]]*0[[:space:]]*\\)[[:space:]]*\\)[[:space:]]*::[[:space:]]*numeric[[:space:]]*\\([[:space:]]*18[[:space:]]*,[[:space:]]*2[[:space:]]*\\)[[:space:]]+AS[[:space:]]+accepted_gross_gbp[[:space:]]*,',
      'COALESCE(b.accepted_document_gross_gbp, 0)::numeric(18,2) AS accepted_gross_gbp,',
      'i'
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not replace the supplier-credit GREATEST fallback with the whitespace-tolerant anchor.';
    END IF;
  END IF;

  IF position('COALESCE(l.included_in_supplier_credit_yn, true) = true' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := regexp_replace(
      v_definition,
      E'(FROM[[:space:]]+public\\.dispute_refund_document_lines[[:space:]]+l[[:space:]]+LEFT[[:space:]]+JOIN[[:space:]]+public\\.dispute_refund_document_line_accounting_codes[[:space:]]+c[[:space:]]+ON[[:space:]]+c\\.refund_document_line_id[[:space:]]*=[[:space:]]*l\\.id[[:space:]]+WHERE[[:space:]]+COALESCE[[:space:]]*\\([[:space:]]*l\\.progressed_to_supplier_control_yn[[:space:]]*,[[:space:]]*false[[:space:]]*\\)[[:space:]]*=[[:space:]]*true)',
      E'\\1\n      AND COALESCE(l.included_in_supplier_credit_yn, true) = true',
      'i'
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not filter excluded source lines from Sage readiness with the whitespace-tolerant anchor.';
    END IF;
  END IF;

  EXECUTE v_definition;

  SELECT pg_get_functiondef(
    'public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure
  ) INTO v_definition;

  IF position('COALESCE(b.accepted_document_gross_gbp, 0)::numeric(18,2) AS accepted_gross_gbp' IN v_definition) = 0
     OR position('COALESCE(l.included_in_supplier_credit_yn, true) = true' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Supplier-credit Sage readiness inclusion patch verification failed.';
  END IF;
END;
$patch_ready$;

COMMIT;
