BEGIN;

-- Cash short-reference cleanup.
-- Purpose: remove duplicated order/auth style references from Sage-facing cash receipt refs.
-- Keeps full proof in internal_reference_json.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_cash_short_reference_v1(
  p_direction text,
  p_statement_line_id uuid,
  p_source_id uuid,
  p_order_ref text DEFAULT NULL,
  p_auth_ref text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(left(
    regexp_replace(
      'GCB-' ||
      CASE WHEN lower(COALESCE(p_direction, '')) = 'in' THEN 'IN' ELSE 'OUT' END || '-' ||
      COALESCE(
        NULLIF(regexp_replace(COALESCE(p_auth_ref, ''), '[^A-Za-z0-9]+', '', 'g'), ''),
        NULLIF(regexp_replace(COALESCE(p_order_ref, ''), '[^A-Za-z0-9]+', '', 'g'), ''),
        replace(p_statement_line_id::text, '-', ''),
        replace(p_source_id::text, '-', '')
      ),
      '[^A-Za-z0-9-]+', '', 'g'
    ),
    32
  ));
$$;

WITH refreshed AS (
  SELECT
    s.id,
    public.internal_cash_short_reference_v1(
      CASE WHEN s.posting_category = 'customer_receipt_on_account' THEN 'in' ELSE 'out' END,
      s.statement_line_id,
      s.source_id,
      s.order_ref,
      COALESCE(s.internal_reference_json->>'auth_ref', s.internal_reference_json->>'reference_raw')
    ) AS new_short_ref
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND s.sage_posting_status = 'not_posted'
    AND s.posting_category = 'customer_receipt_on_account'
)
UPDATE public.cash_posting_snapshots s
SET
  short_reference = refreshed.new_short_ref,
  request_payload = jsonb_set(
    COALESCE(s.request_payload, '{}'::jsonb),
    '{contact_payment,reference}',
    to_jsonb(refreshed.new_short_ref),
    true
  ),
  updated_at = now()
FROM refreshed
WHERE refreshed.id = s.id
  AND s.short_reference IS DISTINCT FROM refreshed.new_short_ref;

UPDATE public.cash_posting_batch_rows r
SET
  request_payload = s.request_payload,
  updated_at = now()
FROM public.cash_posting_snapshots s
WHERE r.snapshot_id = s.id
  AND r.active = true
  AND r.posting_status IN ('not_posted', 'failed_retryable')
  AND r.request_payload IS DISTINCT FROM s.request_payload;

NOTIFY pgrst, 'reload schema';

COMMIT;
