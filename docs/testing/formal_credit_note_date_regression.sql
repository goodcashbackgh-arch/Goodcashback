-- Self-contained behavioural regression for the formal credit-note date guard.
-- Run with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f docs/testing/formal_credit_note_date_regression.sql
BEGIN;

CREATE TEMP TABLE test_refund_submissions (
  id integer PRIMARY KEY,
  document_mode text NOT NULL,
  credit_note_date date,
  ocr_credit_note_date date,
  ocr_status text NOT NULL DEFAULT 'not_started',
  match_status text NOT NULL DEFAULT 'pending_ocr',
  amount_balance_status text NOT NULL DEFAULT 'pending',
  supplier_approval_status text NOT NULL DEFAULT 'pending',
  supplier_control_status text NOT NULL DEFAULT 'not_released',
  ocr_raw_json jsonb,
  remediation_notes text
);

CREATE TEMP TABLE test_refund_lines (
  id integer PRIMARY KEY,
  refund_evidence_submission_id integer NOT NULL REFERENCES test_refund_submissions(id),
  progressed_to_supplier_control_yn boolean NOT NULL DEFAULT false
);

CREATE TEMP TABLE test_sage_snapshots (
  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_table text NOT NULL,
  source_id integer NOT NULL,
  active boolean NOT NULL DEFAULT true
);

INSERT INTO test_refund_submissions (
  id,
  document_mode,
  credit_note_date,
  ocr_credit_note_date,
  ocr_status,
  match_status,
  amount_balance_status
) VALUES
  (1, 'credit_note', NULL, DATE '2026-07-01', 'completed', 'matched_ready_to_release', 'balanced'),
  (2, 'credit_note', NULL, DATE '2026-07-02', 'processing', 'matched_ready_to_release', 'balanced'),
  (3, 'credit_note', NULL, DATE '2026-07-03', 'completed', 'needs_supervisor_review', 'balanced'),
  (4, 'credit_note', NULL, DATE '2026-07-04', 'completed', 'matched_ready_to_release', 'variance'),
  (5, 'credit_note', NULL, DATE '2026-07-05', 'completed', 'matched_ready_to_release', 'balanced'),
  (6, 'credit_note', NULL, DATE '2026-07-06', 'completed', 'matched_ready_to_release', 'balanced'),
  (7, 'credit_note', DATE '2026-07-07', NULL, 'completed', 'matched_ready_to_release', 'balanced'),
  (8, 'credit_note', NULL, NULL, 'not_started', 'pending_ocr', 'pending'),
  (9, 'refund_proof_no_credit_note', NULL, NULL, 'not_applicable', 'not_applicable', 'balanced'),
  (10, 'no_document', NULL, NULL, 'not_applicable', 'not_applicable', 'balanced');

INSERT INTO test_sage_snapshots (source_table, source_id, active) VALUES
  ('dispute_refund_evidence_submissions', 5, true),
  ('dispute_refund_evidence_submissions', 6, false);

-- Mirror the production migration's deliberately narrow legacy backfill.
UPDATE test_refund_submissions s
SET credit_note_date = s.ocr_credit_note_date
WHERE s.document_mode = 'credit_note'
  AND s.credit_note_date IS NULL
  AND s.ocr_credit_note_date IS NOT NULL
  AND s.ocr_status = 'completed'
  AND s.match_status = 'matched_ready_to_release'
  AND s.amount_balance_status = 'balanced'
  AND NOT EXISTS (
    SELECT 1
    FROM test_sage_snapshots snapshot
    WHERE snapshot.source_table = 'dispute_refund_evidence_submissions'
      AND snapshot.source_id = s.id
      AND snapshot.active = true
  );

DO $$
BEGIN
  IF (SELECT credit_note_date FROM test_refund_submissions WHERE id = 1)
       IS DISTINCT FROM DATE '2026-07-01' THEN
    RAISE EXCEPTION 'eligible completed/matched/balanced/unfrozen row was not backfilled';
  END IF;

  IF (SELECT credit_note_date FROM test_refund_submissions WHERE id = 6)
       IS DISTINCT FROM DATE '2026-07-06' THEN
    RAISE EXCEPTION 'inactive historical snapshot incorrectly prevented backfill';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM test_refund_submissions
    WHERE id IN (2, 3, 4, 5)
      AND credit_note_date IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'incomplete, unmatched, unbalanced or actively frozen row was backfilled';
  END IF;

  IF (SELECT credit_note_date FROM test_refund_submissions WHERE id = 7)
       IS DISTINCT FROM DATE '2026-07-07' THEN
    RAISE EXCEPTION 'existing explicit credit-note date was changed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM test_refund_submissions
    WHERE id IN (9, 10)
      AND credit_note_date IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'non-formal evidence mode was affected by backfill';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.test_formal_credit_note_date_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_temp
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

  IF OLD.document_mode IS DISTINCT FROM 'credit_note'
     OR OLD.credit_note_date IS NOT NULL THEN
    RAISE EXCEPTION 'Formal supplier credit notes require credit_note_date.'
      USING ERRCODE = '23514';
  END IF;

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

CREATE TRIGGER test_refund_submission_date_guard
BEFORE INSERT OR UPDATE ON test_refund_submissions
FOR EACH ROW
EXECUTE FUNCTION pg_temp.test_formal_credit_note_date_guard();

CREATE OR REPLACE FUNCTION pg_temp.test_formal_credit_note_line_release_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_temp
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
    FROM test_refund_submissions s
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

CREATE TRIGGER test_refund_line_date_guard
BEFORE INSERT OR UPDATE OF progressed_to_supplier_control_yn ON test_refund_lines
FOR EACH ROW
EXECUTE FUNCTION pg_temp.test_formal_credit_note_line_release_guard();

CREATE OR REPLACE FUNCTION pg_temp.test_formal_credit_note_sage_freeze_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_temp
AS $$
BEGIN
  IF NEW.source_table = 'dispute_refund_evidence_submissions'
     AND EXISTS (
       SELECT 1
       FROM test_refund_submissions s
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

CREATE TRIGGER test_sage_snapshot_date_guard
BEFORE INSERT OR UPDATE OF source_table, source_id, active ON test_sage_snapshots
FOR EACH ROW
EXECUTE FUNCTION pg_temp.test_formal_credit_note_sage_freeze_guard();

-- New undated formal credit notes are rejected.
DO $$
BEGIN
  BEGIN
    INSERT INTO test_refund_submissions (id, document_mode)
    VALUES (11, 'credit_note');
    RAISE EXCEPTION 'new undated formal credit note was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;

-- Existing undated legacy rows remain available for OCR and remediation.
UPDATE test_refund_submissions
SET ocr_status = 'completed',
    match_status = 'needs_supervisor_review',
    amount_balance_status = 'variance',
    ocr_raw_json = '{"source":"regression"}'::jsonb,
    remediation_notes = 'OCR/remediation update allowed'
WHERE id = 8;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM test_refund_submissions
    WHERE id = 8
      AND credit_note_date IS NULL
      AND ocr_status = 'completed'
      AND remediation_notes = 'OCR/remediation update allowed'
  ) THEN
    RAISE EXCEPTION 'legacy undated row could not receive OCR/remediation updates';
  END IF;
END $$;

-- Release is blocked below the RPC at the line transition itself.
INSERT INTO test_refund_lines (id, refund_evidence_submission_id)
VALUES (81, 8);

DO $$
BEGIN
  BEGIN
    UPDATE test_refund_lines
    SET progressed_to_supplier_control_yn = true
    WHERE id = 81;
    RAISE EXCEPTION 'legacy undated row was released';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  IF (SELECT progressed_to_supplier_control_yn FROM test_refund_lines WHERE id = 81) THEN
    RAISE EXCEPTION 'failed release was not rolled back';
  END IF;
END $$;

-- Header release and approval transitions are independently blocked.
DO $$
BEGIN
  BEGIN
    UPDATE test_refund_submissions
    SET supplier_control_status = 'released_to_supplier_control'
    WHERE id = 8;
    RAISE EXCEPTION 'legacy undated header entered released status';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    UPDATE test_refund_submissions
    SET supplier_approval_status = 'approved_current'
    WHERE id = 8;
    RAISE EXCEPTION 'legacy undated row was approved';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;

-- Sage readiness receives a blocker and no fallback document date.
DO $$
DECLARE
  v_status text;
  v_document_date date;
BEGIN
  SELECT
    CASE
      WHEN document_mode = 'credit_note' AND credit_note_date IS NULL
        THEN 'blocked_supplier_credit_note_date_missing'
      ELSE 'ready_for_supplier_credit_note_purchase_credit_note_draft'
    END,
    CASE
      WHEN document_mode = 'credit_note' THEN credit_note_date
      ELSE COALESCE(credit_note_date, DATE '2026-07-19')
    END
  INTO v_status, v_document_date
  FROM test_refund_submissions
  WHERE id = 8;

  IF v_status <> 'blocked_supplier_credit_note_date_missing'
     OR v_document_date IS NOT NULL THEN
    RAISE EXCEPTION 'legacy undated formal credit note entered Sage readiness or received a fallback date';
  END IF;
END $$;

-- Even a direct Sage freeze attempt fails closed.
DO $$
BEGIN
  BEGIN
    INSERT INTO test_sage_snapshots (source_table, source_id, active)
    VALUES ('dispute_refund_evidence_submissions', 8, true);
    RAISE EXCEPTION 'legacy undated formal credit note was frozen for Sage';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;

-- Dated formal rows and non-formal modes remain unaffected.
INSERT INTO test_refund_lines (id, refund_evidence_submission_id) VALUES
  (71, 7),
  (91, 9);

UPDATE test_refund_lines
SET progressed_to_supplier_control_yn = true
WHERE id IN (71, 91);

UPDATE test_refund_submissions
SET supplier_control_status = 'approved_current',
    supplier_approval_status = 'approved_current'
WHERE id IN (7, 9);

INSERT INTO test_refund_submissions (
  id,
  document_mode,
  credit_note_date
) VALUES
  (12, 'credit_note', DATE '2026-07-12'),
  (13, 'refund_proof_no_credit_note', NULL);

-- A non-formal row cannot be converted into an undated formal credit note, and
-- an existing explicit formal date cannot be cleared.
DO $$
BEGIN
  BEGIN
    UPDATE test_refund_submissions
    SET document_mode = 'credit_note'
    WHERE id = 10;
    RAISE EXCEPTION 'non-formal row was converted to an undated formal credit note';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    UPDATE test_refund_submissions
    SET credit_note_date = NULL
    WHERE id = 7;
    RAISE EXCEPTION 'explicit formal credit-note date was cleared';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;

ROLLBACK;
