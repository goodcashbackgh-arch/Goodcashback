BEGIN;

-- Reset supplier credit note rows that failed only because the app-side Sage poster wrongly required original_supplier_invoice_id.
-- Sage purchase credit note payload does not require original supplier invoice id.
-- No Sage API call. No schema change. Does not touch already-posted rows.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

UPDATE public.sage_posting_batch_rows r
SET posting_status = 'validated',
    error_code = NULL,
    error_message = NULL,
    response_payload_json = NULL
WHERE r.document_lane = 'supplier_credit_note'
  AND r.sage_object_id IS NULL
  AND r.posting_status IN ('failed_terminal', 'failed_retryable')
  AND r.payload_validation_status = 'dry_run_validated'
  AND r.error_message = 'Missing original supplier invoice id.';

UPDATE public.sage_posting_snapshots s
SET sage_posting_status = 'not_posted',
    last_posting_error = NULL
WHERE s.document_lane = 'supplier_credit_note'
  AND s.sage_posting_status = 'posting_failed'
  AND s.sage_invoice_id IS NULL
  AND s.last_posting_error = 'Missing original supplier invoice id.';

UPDATE public.sage_posting_batches b
SET status = 'validated',
    batch_status = 'frozen_pending_posting',
    failed_count = 0,
    posting_completed_at = NULL
WHERE b.id IN (
  SELECT DISTINCT r.batch_id
  FROM public.sage_posting_batch_rows r
  WHERE r.document_lane = 'supplier_credit_note'
    AND r.sage_object_id IS NULL
    AND r.posting_status = 'validated'
    AND r.payload_validation_status = 'dry_run_validated'
)
AND b.status = 'failed'
AND NOT EXISTS (
  SELECT 1
  FROM public.sage_posting_batch_rows r2
  WHERE r2.batch_id = b.id
    AND r2.posting_status IN ('failed_terminal', 'failed_retryable')
);

NOTIFY pgrst, 'reload schema';
COMMIT;
