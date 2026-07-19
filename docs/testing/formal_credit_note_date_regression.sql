-- Self-contained regression for the formal credit-note date guard.
-- Run with: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f docs/testing/formal_credit_note_date_regression.sql
BEGIN;

CREATE TEMP TABLE test_refund_submissions (
  id integer PRIMARY KEY,
  document_mode text NOT NULL,
  credit_note_date date,
  ocr_credit_note_date date
);
CREATE TEMP TABLE test_sage_snapshots (
  source_table text NOT NULL,
  source_id integer NOT NULL,
  sage_posting_status text NOT NULL
);

INSERT INTO test_refund_submissions VALUES
  (1, 'credit_note', NULL, DATE '2026-07-01'),
  (2, 'credit_note', NULL, DATE '2026-07-02'),
  (3, 'credit_note', NULL, NULL),
  (4, 'credit_note', DATE '2026-07-04', NULL),
  (5, 'refund_proof_no_credit_note', NULL, NULL),
  (6, 'no_document', NULL, NULL);
INSERT INTO test_sage_snapshots VALUES
  ('dispute_refund_evidence_submissions', 2, 'not_posted');

-- Mirror the additive migration's deliberately conservative backfill.
UPDATE test_refund_submissions s
SET credit_note_date = s.ocr_credit_note_date
WHERE s.document_mode = 'credit_note'
  AND s.credit_note_date IS NULL
  AND s.ocr_credit_note_date IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM test_sage_snapshots snapshot
    WHERE snapshot.source_table = 'dispute_refund_evidence_submissions'
      AND snapshot.source_id = s.id
  );

DO $$
BEGIN
  IF (SELECT credit_note_date FROM test_refund_submissions WHERE id = 1) <> DATE '2026-07-01' THEN
    RAISE EXCEPTION 'safe unfrozen OCR date was not backfilled';
  END IF;
  IF (SELECT credit_note_date FROM test_refund_submissions WHERE id = 2) IS NOT NULL THEN
    RAISE EXCEPTION 'frozen submission was incorrectly backfilled';
  END IF;
  IF (SELECT credit_note_date FROM test_refund_submissions WHERE id = 4) <> DATE '2026-07-04' THEN
    RAISE EXCEPTION 'explicit formal credit-note date was changed';
  END IF;
  IF EXISTS (
    SELECT 1 FROM test_refund_submissions
    WHERE id IN (5, 6) AND credit_note_date IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'no-credit-note evidence mode was affected';
  END IF;
END $$;

ALTER TABLE test_refund_submissions
  ADD CONSTRAINT test_formal_credit_note_date_required
  CHECK (document_mode <> 'credit_note' OR credit_note_date IS NOT NULL)
  NOT VALID;

-- A dated formal credit note and both non-formal modes remain accepted.
INSERT INTO test_refund_submissions VALUES
  (7, 'credit_note', DATE '2026-07-07', NULL),
  (8, 'refund_proof_no_credit_note', NULL, NULL),
  (9, 'no_document', NULL, NULL);

-- A blank new formal credit note must be rejected by database enforcement.
DO $$
BEGIN
  BEGIN
    INSERT INTO test_refund_submissions VALUES (10, 'credit_note', NULL, NULL);
    RAISE EXCEPTION 'blank formal credit-note date was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;

-- Mirror readiness date selection: formal notes never receive a fallback date.
DO $$
DECLARE
  v_status text;
  v_document_date date;
BEGIN
  SELECT
    CASE WHEN document_mode = 'credit_note' AND credit_note_date IS NULL
      THEN 'blocked_supplier_credit_note_date_missing'
      ELSE 'ready_for_supplier_credit_note_purchase_credit_note_draft'
    END,
    CASE WHEN document_mode = 'credit_note'
      THEN credit_note_date
      ELSE COALESCE(credit_note_date, DATE '2026-07-19')
    END
  INTO v_status, v_document_date
  FROM test_refund_submissions WHERE id = 3;

  IF v_status <> 'blocked_supplier_credit_note_date_missing' OR v_document_date IS NOT NULL THEN
    RAISE EXCEPTION 'undated formal credit note entered readiness or received a fallback date';
  END IF;
END $$;

ROLLBACK;
