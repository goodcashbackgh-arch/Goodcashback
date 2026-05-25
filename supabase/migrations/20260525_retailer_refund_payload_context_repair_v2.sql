BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_snapshots'; END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_batch_rows'; END IF;
END $$;

WITH source_context AS (
  SELECT
    s.id AS snapshot_id,
    s.sage_contact_id,
    s.sage_bank_account_id,
    s.posting_date,
    s.amount_gbp,
    s.short_reference,
    COALESCE(
      s.request_payload #>> '{supplier_refund_candidate,matched_target_ref}',
      s.internal_reference_json #>> '{matched_target_ref}',
      s.internal_reference_json #>> '{matched_target_id}',
      s.order_ref,
      s.source_id::text
    ) AS matched_target_ref
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND s.posting_category = 'retailer_refund_received'
), repaired_snapshots AS (
  UPDATE public.cash_posting_snapshots s
  SET
    request_payload = jsonb_set(
      jsonb_set(
        COALESCE(s.request_payload, '{}'::jsonb),
        '{supplier_refund_candidate}',
        COALESCE(s.request_payload->'supplier_refund_candidate', '{}'::jsonb)
          || jsonb_build_object(
            'contact_id', sc.sage_contact_id,
            'bank_account_id', sc.sage_bank_account_id,
            'date', sc.posting_date::text,
            'total_amount', sc.amount_gbp,
            'reference', sc.short_reference,
            'matched_target_ref', sc.matched_target_ref
          ),
        true
      ),
      '{internal_reference_json}',
      COALESCE(s.request_payload->'internal_reference_json', '{}'::jsonb)
        || jsonb_build_object(
          'target_sage_contact_id', sc.sage_contact_id,
          'target_sage_bank_account_id', sc.sage_bank_account_id
        ),
      true
    ),
    internal_reference_json = COALESCE(s.internal_reference_json, '{}'::jsonb)
      || jsonb_build_object(
        'target_sage_contact_id', sc.sage_contact_id,
        'target_sage_bank_account_id', sc.sage_bank_account_id
      ),
    sage_posting_status = CASE
      WHEN s.sage_object_id IS NULL AND s.sage_posting_status = 'posting_failed' THEN 'not_posted'
      ELSE s.sage_posting_status
    END,
    updated_at = now()
  FROM source_context sc
  WHERE s.id = sc.snapshot_id
    AND NULLIF(trim(COALESCE(sc.sage_contact_id, '')), '') IS NOT NULL
    AND NULLIF(trim(COALESCE(sc.sage_bank_account_id, '')), '') IS NOT NULL
    AND (
      NULLIF(trim(COALESCE(s.request_payload #>> '{supplier_refund_candidate,contact_id}', '')), '') IS NULL
      OR NULLIF(trim(COALESCE(s.request_payload #>> '{supplier_refund_candidate,bank_account_id}', '')), '') IS NULL
      OR s.sage_posting_status = 'posting_failed'
    )
  RETURNING s.id
), repaired_rows AS (
  UPDATE public.cash_posting_batch_rows br
  SET
    request_payload = jsonb_set(
      jsonb_set(
        COALESCE(br.request_payload, '{}'::jsonb),
        '{supplier_refund_candidate}',
        COALESCE(br.request_payload->'supplier_refund_candidate', '{}'::jsonb)
          || jsonb_build_object(
            'contact_id', sc.sage_contact_id,
            'bank_account_id', sc.sage_bank_account_id,
            'date', sc.posting_date::text,
            'total_amount', sc.amount_gbp,
            'reference', sc.short_reference,
            'matched_target_ref', sc.matched_target_ref
          ),
        true
      ),
      '{internal_reference_json}',
      COALESCE(br.request_payload->'internal_reference_json', '{}'::jsonb)
        || jsonb_build_object(
          'target_sage_contact_id', sc.sage_contact_id,
          'target_sage_bank_account_id', sc.sage_bank_account_id
        ),
      true
    ),
    posting_status = CASE
      WHEN br.sage_object_id IS NULL AND br.posting_status = 'failed_terminal' AND br.error_code = 'payload_builder_failed' THEN 'failed_retryable'
      ELSE br.posting_status
    END,
    error_code = CASE
      WHEN br.sage_object_id IS NULL AND br.posting_status = 'failed_terminal' AND br.error_code = 'payload_builder_failed' THEN NULL
      ELSE br.error_code
    END,
    error_message = CASE
      WHEN br.sage_object_id IS NULL AND br.posting_status = 'failed_terminal' AND br.error_code = 'payload_builder_failed' THEN NULL
      ELSE br.error_message
    END,
    updated_at = now()
  FROM source_context sc
  WHERE br.snapshot_id = sc.snapshot_id
    AND br.active = true
    AND br.posting_category = 'retailer_refund_received'
    AND NULLIF(trim(COALESCE(sc.sage_contact_id, '')), '') IS NOT NULL
    AND NULLIF(trim(COALESCE(sc.sage_bank_account_id, '')), '') IS NOT NULL
    AND (
      NULLIF(trim(COALESCE(br.request_payload #>> '{supplier_refund_candidate,contact_id}', '')), '') IS NULL
      OR NULLIF(trim(COALESCE(br.request_payload #>> '{supplier_refund_candidate,bank_account_id}', '')), '') IS NULL
      OR (br.posting_status = 'failed_terminal' AND br.error_code = 'payload_builder_failed')
    )
  RETURNING br.batch_id
), affected_batches AS (
  SELECT DISTINCT batch_id FROM repaired_rows
), active_totals AS (
  SELECT
    b.id AS batch_id,
    count(br.id)::integer AS active_count,
    COALESCE(sum(br.amount_gbp), 0)::numeric(18,2) AS active_total,
    count(br.id) FILTER (WHERE br.posting_status IN ('posted','posted_needs_review'))::integer AS success_count,
    count(br.id) FILTER (WHERE br.posting_status LIKE 'failed%')::integer AS failed_count
  FROM affected_batches ab
  JOIN public.cash_posting_batches b ON b.id = ab.batch_id
  LEFT JOIN public.cash_posting_batch_rows br ON br.batch_id = b.id AND br.active = true
  GROUP BY b.id
)
UPDATE public.cash_posting_batches b
SET
  row_count = at.active_count,
  total_amount_gbp = at.active_total,
  success_count = at.success_count,
  failed_count = at.failed_count,
  batch_status = CASE
    WHEN at.active_count = 0 THEN 'cancelled'
    WHEN at.failed_count > 0 AND at.success_count > 0 THEN 'partially_posted'
    WHEN at.failed_count > 0 THEN 'failed'
    WHEN at.success_count = at.active_count AND at.active_count > 0 THEN 'posted'
    ELSE 'validated'
  END,
  updated_at = now()
FROM active_totals at
WHERE b.id = at.batch_id;

NOTIFY pgrst, 'reload schema';

COMMIT;
