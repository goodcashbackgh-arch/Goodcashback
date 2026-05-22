BEGIN;

-- Fix posted supplier credit note rows where live posting overwrote the resolver payload with the outbound Sage body.
-- Restores the frozen resolver payload for UI/control display and mirrors the credit note evidence URL into source_evidence.file_url,
-- which the existing batch page already understands.
-- No Sage API call. No change to posted Sage object ids.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

WITH source_payloads AS (
  SELECT
    r.id AS row_id,
    s.id AS snapshot_id,
    CASE
      WHEN NULLIF(s.resolved_payload #>> '{evidence,credit_note_file_url}', '') IS NOT NULL THEN
        jsonb_set(
          s.resolved_payload,
          '{source_evidence}',
          COALESCE(s.resolved_payload->'source_evidence', '{}'::jsonb)
            || jsonb_build_object('file_url', s.resolved_payload #>> '{evidence,credit_note_file_url}'),
          true
        )
      ELSE s.resolved_payload
    END AS restored_payload
  FROM public.sage_posting_batch_rows r
  JOIN public.sage_posting_snapshots s ON s.id = r.snapshot_id
  WHERE r.document_lane = 'supplier_credit_note'
    AND r.posting_status = 'posted'
    AND r.sage_object_id IS NOT NULL
    AND r.request_payload_json ? 'purchase_credit_note'
    AND s.resolved_payload IS NOT NULL
)
UPDATE public.sage_posting_batch_rows r
SET request_payload_json = p.restored_payload
FROM source_payloads p
WHERE r.id = p.row_id;

UPDATE public.sage_posting_snapshots s
SET sage_attachment_source_url = COALESCE(
      NULLIF(s.sage_attachment_source_url, ''),
      NULLIF(s.resolved_payload #>> '{evidence,credit_note_file_url}', '')
    ),
    sage_attachment_file_name = COALESCE(
      NULLIF(s.sage_attachment_file_name, ''),
      regexp_replace(COALESCE(NULLIF(s.reference_text, ''), NULLIF(s.order_ref, ''), s.id::text), '[^a-zA-Z0-9._-]+', '_', 'g') || '.pdf'
    )
WHERE s.document_lane = 'supplier_credit_note'
  AND s.sage_posting_status = 'posted'
  AND s.sage_invoice_id IS NOT NULL
  AND NULLIF(s.resolved_payload #>> '{evidence,credit_note_file_url}', '') IS NOT NULL;

NOTIFY pgrst, 'reload schema';
COMMIT;
