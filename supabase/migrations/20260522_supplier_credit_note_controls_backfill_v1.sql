BEGIN;

-- Supplier credit note posting failed before Sage because the frozen payload had controls nested under source_payload.controls,
-- while the live TypeScript poster reads request_payload_json.controls.
-- This patch lifts controls to the frozen posting payload for future freezes and backfills active unposted rows/snapshots.
-- No Sage API call. No schema change.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid;
  v_sql text;
BEGIN
  v_oid := to_regprocedure('public.internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text) missing; skipping function patch';
  ELSE
    v_sql := pg_get_functiondef(v_oid);

    IF position('''controls'', COALESCE(lr.source_payload->''controls''' in v_sql) > 0 THEN
      RAISE NOTICE 'supplier credit note freeze already lifts controls to top-level payload';
    ELSIF position('''evidence'', COALESCE(lr.source_payload->''evidence'', ''{}''::jsonb),' in v_sql) > 0
      AND position('''source_payload'', COALESCE(lr.source_payload, ''{}''::jsonb),' in v_sql) > 0 THEN
      v_sql := replace(
        v_sql,
        '''evidence'', COALESCE(lr.source_payload->''evidence'', ''{}''::jsonb),
        ''source_payload'', COALESCE(lr.source_payload, ''{}''::jsonb),',
        '''evidence'', COALESCE(lr.source_payload->''evidence'', ''{}''::jsonb),
        ''controls'', COALESCE(lr.source_payload->''controls'', ''{}''::jsonb),
        ''source_payload'', COALESCE(lr.source_payload, ''{}''::jsonb),'
      );
      EXECUTE v_sql;
    ELSE
      RAISE NOTICE 'supplier credit note freeze payload pattern not found; no function replacement applied';
    END IF;
  END IF;
END
$patch$;

UPDATE public.sage_posting_snapshots s
SET resolved_payload = jsonb_set(
      s.resolved_payload,
      '{controls}',
      s.resolved_payload #> '{source_payload,controls}',
      true
    ),
    updated_at = now(),
    last_posting_error = CASE
      WHEN s.last_posting_error = 'Supplier credit note gross is not reconciled to the approved refund document.' THEN NULL
      ELSE s.last_posting_error
    END,
    sage_posting_status = CASE
      WHEN s.sage_posting_status = 'posting_failed'
       AND s.last_posting_error = 'Supplier credit note gross is not reconciled to the approved refund document.'
      THEN 'not_posted'
      ELSE s.sage_posting_status
    END
WHERE s.document_lane = 'supplier_credit_note'
  AND s.sage_posting_status <> 'posted'
  AND s.resolved_payload #> '{source_payload,controls}' IS NOT NULL
  AND NOT (s.resolved_payload ? 'controls');

UPDATE public.sage_posting_batch_rows r
SET request_payload_json = jsonb_set(
      r.request_payload_json,
      '{controls}',
      r.request_payload_json #> '{source_payload,controls}',
      true
    ),
    posting_status = CASE
      WHEN r.posting_status = 'failed_terminal'
       AND r.error_message = 'Supplier credit note gross is not reconciled to the approved refund document.'
      THEN 'validated'
      ELSE r.posting_status
    END,
    error_code = CASE
      WHEN r.error_message = 'Supplier credit note gross is not reconciled to the approved refund document.' THEN NULL
      ELSE r.error_code
    END,
    error_message = CASE
      WHEN r.error_message = 'Supplier credit note gross is not reconciled to the approved refund document.' THEN NULL
      ELSE r.error_message
    END
WHERE r.document_lane = 'supplier_credit_note'
  AND r.sage_object_id IS NULL
  AND r.request_payload_json #> '{source_payload,controls}' IS NOT NULL
  AND NOT (r.request_payload_json ? 'controls');

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
AND b.status = 'failed';

NOTIFY pgrst, 'reload schema';
COMMIT;
