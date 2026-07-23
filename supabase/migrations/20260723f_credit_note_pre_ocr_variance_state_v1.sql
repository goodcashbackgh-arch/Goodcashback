BEGIN;

-- Formal credit notes are not amount-compared until OCR has completed.
-- Keep the existing operator submission, OCR, coding, bank and Sage workflows unchanged.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.normalise_credit_note_pre_ocr_state_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.document_mode = 'credit_note'
     AND COALESCE(NEW.ocr_status, 'not_started') <> 'completed'
     AND COALESCE(NEW.match_status, 'pending_ocr') = 'pending_ocr' THEN
    NEW.variance_abs_gbp := NULL;
    NEW.amount_balance_status := 'unknown';
    NEW.supervisor_review_status := 'not_required';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispute_refund_evidence_pre_ocr_state_trg
  ON public.dispute_refund_evidence_submissions;

CREATE TRIGGER dispute_refund_evidence_pre_ocr_state_trg
BEFORE INSERT OR UPDATE OF
  document_mode,
  ocr_status,
  match_status,
  variance_abs_gbp,
  amount_balance_status,
  supervisor_review_status
ON public.dispute_refund_evidence_submissions
FOR EACH ROW
EXECUTE FUNCTION public.normalise_credit_note_pre_ocr_state_v1();

-- Correct only untouched formal-credit-note submissions that are still waiting
-- for OCR and have not entered supplier control, approval or Sage freezing.
UPDATE public.dispute_refund_evidence_submissions s
SET
  variance_abs_gbp = NULL,
  amount_balance_status = 'unknown',
  supervisor_review_status = 'not_required'
WHERE s.document_mode = 'credit_note'
  AND COALESCE(s.ocr_status, 'not_started') <> 'completed'
  AND s.match_status = 'pending_ocr'
  AND s.supplier_control_status = 'not_released'
  AND s.supplier_approval_status = 'blocked'
  AND NOT EXISTS (
    SELECT 1
    FROM public.dispute_refund_document_lines l
    WHERE l.refund_evidence_submission_id = s.id
      AND COALESCE(l.progressed_to_supplier_control_yn, false) = true
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot
    WHERE snapshot.source_table = 'dispute_refund_evidence_submissions'
      AND snapshot.source_id = s.id
      AND snapshot.active = true
  )
  AND (
    s.variance_abs_gbp IS NOT NULL
    OR s.amount_balance_status IS DISTINCT FROM 'unknown'
    OR s.supervisor_review_status IS DISTINCT FROM 'not_required'
  );

REVOKE ALL ON FUNCTION public.normalise_credit_note_pre_ocr_state_v1() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

COMMIT;
