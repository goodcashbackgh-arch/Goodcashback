BEGIN;

-- Require an explicit document date for formal supplier credit notes without
-- stranding legacy undated rows that still need OCR, rejection or remediation.
-- New/dated rows fail closed; legacy undated rows remain editable but cannot
-- be released, approved, frozen or surfaced as Sage-ready until dated.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sage_posting_snapshots';
  END IF;
  IF to_regprocedure('public.internal_supplier_credit_note_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_supplier_credit_note_ready_rows_v1()';
  END IF;
END $$;

-- Only copy an OCR date into the formal date field where the OCR result is
-- complete, matched, balanced and has never been actively frozen for Sage.
UPDATE public.dispute_refund_evidence_submissions s
SET credit_note_date = s.ocr_credit_note_date
WHERE s.document_mode = 'credit_note'
  AND s.credit_note_date IS NULL
  AND s.ocr_credit_note_date IS NOT NULL
  AND s.ocr_status = 'completed'
  AND s.match_status = 'matched_ready_to_release'
  AND s.amount_balance_status = 'balanced'
  AND NOT EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot
    WHERE snapshot.source_table = 'dispute_refund_evidence_submissions'
      AND snapshot.source_id = s.id
      AND snapshot.active = true
  );

-- A NOT VALID CHECK still applies to every subsequent UPDATE and would strand
-- legacy undated rows. Replace it with transition guards that permit OCR and
-- remediation while blocking the accounting progression gates.
ALTER TABLE public.dispute_refund_evidence_submissions
  DROP CONSTRAINT IF EXISTS dispute_refund_evidence_credit_note_date_required_chk;

CREATE OR REPLACE FUNCTION public.enforce_formal_credit_note_date_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.document_mode IS DISTINCT FROM 'credit_note'
     OR NEW.credit_note_date IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    RAISE EXCEPTION 'Formal supplier credit notes require credit_note_date.'
      USING ERRCODE = '23514';
  END IF;

  -- Any row that was not already a legacy undated formal credit note may not
  -- become one, and a dated formal credit note may not have its date cleared.
  IF OLD.document_mode IS DISTINCT FROM 'credit_note'
     OR OLD.credit_note_date IS NOT NULL THEN
    RAISE EXCEPTION 'Formal supplier credit notes require credit_note_date.'
      USING ERRCODE = '23514';
  END IF;

  -- Existing undated rows may receive OCR/review/remediation updates, but they
  -- cannot cross the release or approval gates until the date is supplied.
  IF NEW.supplier_control_status IS DISTINCT FROM OLD.supplier_control_status
     AND NEW.supplier_control_status IN ('released_to_supplier_control', 'approved_current') THEN
    RAISE EXCEPTION 'Formal supplier credit note date is required before release.'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.supplier_approval_status IS DISTINCT FROM OLD.supplier_approval_status
     AND NEW.supplier_approval_status = 'approved_current' THEN
    RAISE EXCEPTION 'Formal supplier credit note date is required before approval.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispute_refund_evidence_credit_note_date_guard_trg
  ON public.dispute_refund_evidence_submissions;
CREATE TRIGGER dispute_refund_evidence_credit_note_date_guard_trg
BEFORE INSERT OR UPDATE ON public.dispute_refund_evidence_submissions
FOR EACH ROW
EXECUTE FUNCTION public.enforce_formal_credit_note_date_guard_v1();

CREATE OR REPLACE FUNCTION public.enforce_formal_credit_note_line_release_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_becoming_released boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_becoming_released := COALESCE(NEW.progressed_to_supplier_control_yn, false);
  ELSE
    v_becoming_released := COALESCE(NEW.progressed_to_supplier_control_yn, false)
      AND NOT COALESCE(OLD.progressed_to_supplier_control_yn, false);
  END IF;

  IF v_becoming_released AND EXISTS (
    SELECT 1
    FROM public.dispute_refund_evidence_submissions s
    WHERE s.id = NEW.refund_evidence_submission_id
      AND s.document_mode = 'credit_note'
      AND s.credit_note_date IS NULL
  ) THEN
    RAISE EXCEPTION 'Formal supplier credit note date is required before line release.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispute_refund_document_lines_credit_note_date_guard_trg
  ON public.dispute_refund_document_lines;
CREATE TRIGGER dispute_refund_document_lines_credit_note_date_guard_trg
BEFORE INSERT OR UPDATE OF progressed_to_supplier_control_yn
ON public.dispute_refund_document_lines
FOR EACH ROW
EXECUTE FUNCTION public.enforce_formal_credit_note_line_release_guard_v1();

CREATE OR REPLACE FUNCTION public.enforce_formal_credit_note_sage_freeze_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.source_table = 'dispute_refund_evidence_submissions'
     AND EXISTS (
       SELECT 1
       FROM public.dispute_refund_evidence_submissions s
       WHERE s.id = NEW.source_id
         AND s.document_mode = 'credit_note'
         AND s.credit_note_date IS NULL
     ) THEN
    RAISE EXCEPTION 'Formal supplier credit note date is required before Sage freeze.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sage_posting_snapshots_credit_note_date_guard_trg
  ON public.sage_posting_snapshots;
CREATE TRIGGER sage_posting_snapshots_credit_note_date_guard_trg
BEFORE INSERT OR UPDATE OF source_table, source_id, active
ON public.sage_posting_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.enforce_formal_credit_note_sage_freeze_guard_v1();

REVOKE ALL ON FUNCTION public.enforce_formal_credit_note_date_guard_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_formal_credit_note_line_release_guard_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_formal_credit_note_sage_freeze_guard_v1() FROM PUBLIC;

-- Patch the existing readiness function in place, preserving its OID and all
-- downstream dependencies. Formal credit notes receive no fallback date and
-- surface the date blocker before every other Sage-readiness condition.
DO $patch$
DECLARE
  v_definition text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef('public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure)
  INTO v_definition;

  IF position('WHEN b.document_mode = ''credit_note'' THEN b.credit_note_date' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old_date$      COALESCE(
        b.credit_note_date,
        b.refund_statement_date,
        b.supplier_approved_at::date,
        b.submitted_at::date,
        CURRENT_DATE
      )::date AS document_date$old_date$,
$new_date$      CASE
        WHEN b.document_mode = 'credit_note' THEN b.credit_note_date
        ELSE COALESCE(
          b.credit_note_date,
          b.refund_statement_date,
          b.supplier_approved_at::date,
          b.submitted_at::date,
          CURRENT_DATE
        )::date
      END AS document_date$new_date$
    );
    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not patch formal credit-note document-date fallback in internal_supplier_credit_note_ready_rows_v1()';
    END IF;
  END IF;

  IF position('blocked_supplier_credit_note_date_missing' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old_status$    CASE
      WHEN a.original_supplier_invoice_id IS NULL THEN 'blocked_supplier_credit_original_supplier_invoice_missing'$old_status$,
$new_status$    CASE
      WHEN a.document_mode = 'credit_note' AND a.credit_note_date IS NULL THEN 'blocked_supplier_credit_note_date_missing'
      WHEN a.original_supplier_invoice_id IS NULL THEN 'blocked_supplier_credit_original_supplier_invoice_missing'$new_status$
    );
    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not add formal credit-note readiness status blocker';
    END IF;
  END IF;

  IF position('formal supplier credit note date missing' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old_blocker$    CASE
      WHEN a.original_supplier_invoice_id IS NULL THEN 'original supplier invoice id missing'$old_blocker$,
$new_blocker$    CASE
      WHEN a.document_mode = 'credit_note' AND a.credit_note_date IS NULL THEN 'formal supplier credit note date missing'
      WHEN a.original_supplier_invoice_id IS NULL THEN 'original supplier invoice id missing'$new_blocker$
    );
    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not add formal credit-note readiness blocker message';
    END IF;
  END IF;

  EXECUTE v_definition;
END;
$patch$;

REVOKE ALL ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() TO authenticated;

COMMIT;
