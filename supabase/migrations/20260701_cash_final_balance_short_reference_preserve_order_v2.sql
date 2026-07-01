BEGIN;

-- Follow-up to the 32-char Sage reference hotfix.
-- Preserve the visible order ref in final-balance receipt short refs where possible,
-- and shorten the allocation discriminator instead of chopping the order number.
-- Example: GCB-IN-FB-ORD-1777736251155-d445 (32 chars)

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_cash_final_balance_short_reference_v1(
  p_order_ref text,
  p_order_id uuid,
  p_allocation_id uuid
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH cleaned AS (
    SELECT
      left(
        COALESCE(
          NULLIF(regexp_replace(COALESCE(p_order_ref, ''), '[^A-Za-z0-9-]+', '', 'g'), ''),
          replace(p_order_id::text, '-', '')
        ),
        17
      ) AS order_part,
      replace(p_allocation_id::text, '-', '') AS allocation_part
  ), budgeted AS (
    SELECT
      order_part,
      allocation_part,
      GREATEST(1, 32 - length('GCB-IN-FB-') - length(order_part) - 1) AS allocation_chars
    FROM cleaned
  )
  SELECT left(
    'GCB-IN-FB-' || order_part || '-' || left(allocation_part, allocation_chars),
    32
  )
  FROM budgeted;
$$;

DO $$
DECLARE
  v_def text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)'::regprocedure)
    INTO v_def;
  v_before := v_def;

  v_def := replace(
    v_def,
    $old_original$'short_reference', ('GCB-IN-FB-' || left(COALESCE(o.order_ref::text, o.id::text), 16) || '-' || left(adv.allocation_id::text, 8))$old_original$,
    $new_ref$'short_reference', public.internal_cash_final_balance_short_reference_v1(o.order_ref::text, o.id, adv.allocation_id)$new_ref$
  );

  v_def := replace(
    v_def,
    $old_hotfix$'short_reference', left(('GCB-IN-FB-' || left(COALESCE(o.order_ref::text, o.id::text), 13) || '-' || left(adv.allocation_id::text, 8)), 32)$old_hotfix$,
    $new_ref$'short_reference', public.internal_cash_final_balance_short_reference_v1(o.order_ref::text, o.id, adv.allocation_id)$new_ref$
  );

  IF v_def = v_before THEN
    RAISE EXCEPTION 'Expected final-balance short_reference expression not found in internal_cash_posting_workbench_rows_v1';
  END IF;

  EXECUTE v_def;
END $$;

WITH candidate_snapshots AS (
  SELECT
    s.id AS snapshot_id,
    public.internal_cash_final_balance_short_reference_v1(s.order_ref, s.order_id, s.source_id) AS safe_ref
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND s.posting_category = 'customer_receipt_on_account'
    AND s.source_type = 'dva_final_balance_allocation'
    AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted'
    AND NULLIF(trim(COALESCE(s.sage_object_id, '')), '') IS NULL
), updated_snapshots AS (
  UPDATE public.cash_posting_snapshots s
  SET
    short_reference = c.safe_ref,
    request_payload = jsonb_set(
      COALESCE(s.request_payload, '{}'::jsonb),
      '{contact_payment,reference}',
      to_jsonb(c.safe_ref),
      true
    ),
    sage_posting_status = 'not_posted',
    sage_response_payload = NULL,
    updated_at = now()
  FROM candidate_snapshots c
  WHERE c.snapshot_id = s.id
    AND (
      s.short_reference IS DISTINCT FROM c.safe_ref
      OR s.request_payload #>> '{contact_payment,reference}' IS DISTINCT FROM c.safe_ref
      OR s.sage_posting_status = 'posting_failed'
    )
  RETURNING s.id AS snapshot_id
), updated_rows AS (
  UPDATE public.cash_posting_batch_rows r
  SET
    request_payload = s.request_payload,
    posting_status = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND (
         COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
         OR COALESCE(r.response_payload::text, '') ILIKE '%maximum is 32%'
       )
      THEN 'not_posted'
      ELSE r.posting_status
    END,
    response_payload = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND (
         COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
         OR COALESCE(r.response_payload::text, '') ILIKE '%maximum is 32%'
       )
      THEN NULL
      ELSE r.response_payload
    END,
    error_code = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND (
         COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
         OR COALESCE(r.response_payload::text, '') ILIKE '%maximum is 32%'
       )
      THEN NULL
      ELSE r.error_code
    END,
    error_message = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND (
         COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
         OR COALESCE(r.response_payload::text, '') ILIKE '%maximum is 32%'
       )
      THEN NULL
      ELSE r.error_message
    END,
    updated_at = now()
  FROM public.cash_posting_snapshots s
  JOIN updated_snapshots u ON u.snapshot_id = s.id
  WHERE r.active = true
    AND r.snapshot_id = s.id
    AND NULLIF(trim(COALESCE(r.sage_object_id, '')), '') IS NULL
  RETURNING r.batch_id
), affected_batches AS (
  SELECT DISTINCT batch_id FROM updated_rows WHERE batch_id IS NOT NULL
), batch_counts AS (
  SELECT
    b.id AS batch_id,
    count(r.id)::integer AS row_count,
    COALESCE(sum(r.amount_gbp), 0)::numeric(18,2) AS total_amount_gbp,
    count(*) FILTER (WHERE r.posting_status IN ('posted','posted_needs_review'))::integer AS success_count,
    count(*) FILTER (WHERE r.posting_status LIKE 'failed%')::integer AS failed_count
  FROM affected_batches ab
  JOIN public.cash_posting_batches b ON b.id = ab.batch_id
  JOIN public.cash_posting_batch_rows r ON r.batch_id = b.id AND r.active = true
  GROUP BY b.id
)
UPDATE public.cash_posting_batches b
SET
  batch_status = CASE
    WHEN bc.failed_count > 0 AND bc.success_count > 0 THEN 'partially_posted'
    WHEN bc.failed_count > 0 THEN 'failed'
    WHEN bc.success_count = bc.row_count AND bc.row_count > 0 THEN 'posted'
    ELSE 'validated'
  END,
  row_count = bc.row_count,
  total_amount_gbp = bc.total_amount_gbp,
  success_count = bc.success_count,
  failed_count = bc.failed_count,
  posting_completed_at = CASE
    WHEN bc.failed_count > 0 OR (bc.success_count = bc.row_count AND bc.row_count > 0) THEN b.posting_completed_at
    ELSE NULL
  END,
  updated_at = now()
FROM batch_counts bc
WHERE bc.batch_id = b.id;

NOTIFY pgrst, 'reload schema';

COMMIT;
