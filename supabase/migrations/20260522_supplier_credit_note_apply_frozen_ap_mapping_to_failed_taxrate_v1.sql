BEGIN;

-- Fix supplier credit note rows that failed because the line-level tax code was sent to Sage.
-- Supplier and shipper AP posting use frozen mapping_snapshot Sage IDs.
-- This applies the same rule to failed supplier credit note frozen rows: prefer SUPPLIER_GOODS_AP_LEDGER and SUPPLIER_GOODS_AP_TAX_RATE from mapping_snapshot.
-- No Sage API call. No schema change. Does not touch posted rows.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

WITH patched AS (
  SELECT
    r.id,
    r.batch_id,
    jsonb_set(
      r.request_payload_json,
      '{resolved_lines}',
      COALESCE((
        SELECT jsonb_agg(
          line.value
          || CASE
               WHEN NULLIF(r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}', '') IS NOT NULL
               THEN jsonb_build_object(
                      'sage_ledger_account_id', r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}',
                      'resolved_ledger_account_id', r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}'
                    )
               ELSE '{}'::jsonb
             END
          || CASE
               WHEN NULLIF(r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}', '') IS NOT NULL
               THEN jsonb_build_object(
                      'sage_tax_rate_id', r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}',
                      'tax_rate_id', r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}',
                      'resolved_tax_rate_id', r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}'
                    )
               ELSE '{}'::jsonb
             END
          ORDER BY ordinality
        )
        FROM jsonb_array_elements(COALESCE(r.request_payload_json->'resolved_lines', '[]'::jsonb)) WITH ORDINALITY AS line(value, ordinality)
      ), '[]'::jsonb),
      true
    ) AS patched_payload
  FROM public.sage_posting_batch_rows r
  WHERE r.document_lane = 'supplier_credit_note'
    AND r.sage_object_id IS NULL
    AND r.posting_status IN ('failed_terminal', 'failed_retryable')
    AND r.payload_validation_status = 'dry_run_validated'
    AND r.error_message = 'Couldn''t find TaxRate.'
    AND NULLIF(r.request_payload_json #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}', '') IS NOT NULL
)
UPDATE public.sage_posting_batch_rows r
SET request_payload_json = p.patched_payload,
    posting_status = 'validated',
    error_code = NULL,
    error_message = NULL,
    response_payload_json = '{}'::jsonb
FROM patched p
WHERE r.id = p.id;

UPDATE public.sage_posting_snapshots s
SET resolved_payload = jsonb_set(
      s.resolved_payload,
      '{resolved_lines}',
      COALESCE((
        SELECT jsonb_agg(
          line.value
          || CASE
               WHEN NULLIF(s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}', '') IS NOT NULL
               THEN jsonb_build_object(
                      'sage_ledger_account_id', s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}',
                      'resolved_ledger_account_id', s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}'
                    )
               ELSE '{}'::jsonb
             END
          || CASE
               WHEN NULLIF(s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}', '') IS NOT NULL
               THEN jsonb_build_object(
                      'sage_tax_rate_id', s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}',
                      'tax_rate_id', s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}',
                      'resolved_tax_rate_id', s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}'
                    )
               ELSE '{}'::jsonb
             END
          ORDER BY ordinality
        )
        FROM jsonb_array_elements(COALESCE(s.resolved_payload->'resolved_lines', '[]'::jsonb)) WITH ORDINALITY AS line(value, ordinality)
      ), '[]'::jsonb),
      true
    ),
    sage_posting_status = 'not_posted',
    last_posting_error = NULL
WHERE s.document_lane = 'supplier_credit_note'
  AND s.sage_invoice_id IS NULL
  AND s.sage_posting_status = 'posting_failed'
  AND s.last_posting_error = 'Couldn''t find TaxRate.'
  AND NULLIF(s.resolved_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}', '') IS NOT NULL;

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
