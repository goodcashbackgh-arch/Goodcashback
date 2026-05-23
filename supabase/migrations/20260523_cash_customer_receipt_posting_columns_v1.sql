BEGIN;

-- Cash customer receipt Sage posting support.
-- Additive only: stores posting attempts/results for cash batches and rows.
-- No data rewrite and no Sage API call.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

ALTER TABLE public.cash_posting_batches
  ADD COLUMN IF NOT EXISTS posting_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS posting_completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS success_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS failed_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.cash_posting_batch_rows
  ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_attempt_at timestamptz,
  ADD COLUMN IF NOT EXISTS posted_at timestamptz,
  ADD COLUMN IF NOT EXISTS sage_object_type text,
  ADD COLUMN IF NOT EXISTS sage_reference text,
  ADD COLUMN IF NOT EXISTS error_code text,
  ADD COLUMN IF NOT EXISTS error_message text;

CREATE INDEX IF NOT EXISTS ix_cash_posting_batch_rows_posting_status
  ON public.cash_posting_batch_rows(batch_id, posting_status)
  WHERE active = true;

CREATE OR REPLACE FUNCTION public.internal_cash_posting_batch_history_v1(p_limit integer DEFAULT 30)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  posting_category text,
  batch_status text,
  row_count integer,
  total_amount_gbp numeric,
  not_posted_count integer,
  posted_count integer,
  failed_count integer,
  created_at timestamptz,
  created_by_staff_id uuid,
  created_by_name text,
  detail_href text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.batch_ref::text,
    b.posting_category::text,
    b.batch_status::text,
    b.row_count::integer,
    b.total_amount_gbp::numeric,
    count(r.id) FILTER (WHERE r.posting_status IN ('not_posted','failed_retryable'))::integer,
    count(r.id) FILTER (WHERE r.posting_status IN ('posted','posted_needs_review'))::integer,
    count(r.id) FILTER (WHERE r.posting_status LIKE 'failed%')::integer,
    b.created_at,
    b.created_by_staff_id,
    COALESCE(s.full_name, 'Unknown staff')::text,
    ('/internal/accounting-command-centre/cash-posting/batches/' || b.id::text)::text
  FROM public.cash_posting_batches b
  LEFT JOIN public.cash_posting_batch_rows r ON r.batch_id = b.id AND r.active = true
  LEFT JOIN public.staff s ON s.id = b.created_by_staff_id
  WHERE b.active = true
  GROUP BY b.id, b.batch_ref, b.posting_category, b.batch_status, b.row_count, b.total_amount_gbp, b.created_at, b.created_by_staff_id, s.full_name
  ORDER BY b.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 30), 100));
END;
$$;

-- Return type changes require dropping first because PostgreSQL cannot alter OUT parameters in-place.
DROP FUNCTION IF EXISTS public.internal_cash_posting_batch_detail_v1(uuid);

CREATE FUNCTION public.internal_cash_posting_batch_detail_v1(p_batch_id uuid)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  batch_status text,
  batch_posting_category text,
  batch_row_count integer,
  batch_total_amount_gbp numeric,
  batch_created_at timestamptz,
  batch_created_by_name text,
  batch_notes text,
  batch_row_id uuid,
  snapshot_id uuid,
  source_id uuid,
  source_type text,
  posting_category text,
  row_validation_status text,
  row_posting_status text,
  blocker text,
  amount_gbp numeric,
  posting_date date,
  short_reference text,
  idempotency_key text,
  statement_line_id uuid,
  order_id uuid,
  order_ref text,
  counterparty_type text,
  counterparty_id uuid,
  counterparty_name text,
  sage_contact_id text,
  sage_contact_name text,
  sage_bank_account_id text,
  sage_object_id text,
  sage_payment_on_account_id text,
  request_payload jsonb,
  internal_reference_json jsonb,
  sage_response_payload jsonb,
  created_at timestamptz,
  attempt_count integer,
  last_attempt_at timestamptz,
  posted_at timestamptz,
  sage_object_type text,
  sage_reference text,
  error_code text,
  error_message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.batch_ref::text,
    b.batch_status::text,
    b.posting_category::text,
    b.row_count::integer,
    b.total_amount_gbp::numeric,
    b.created_at,
    COALESCE(st.full_name, 'Unknown staff')::text,
    b.notes::text,
    r.id,
    s.id,
    s.source_id,
    s.source_type::text,
    s.posting_category::text,
    r.validation_status::text,
    r.posting_status::text,
    r.blocker::text,
    r.amount_gbp::numeric,
    s.posting_date,
    s.short_reference::text,
    r.idempotency_key::text,
    s.statement_line_id,
    s.order_id,
    s.order_ref::text,
    s.counterparty_type::text,
    s.counterparty_id,
    s.counterparty_name::text,
    s.sage_contact_id::text,
    s.sage_contact_name::text,
    s.sage_bank_account_id::text,
    COALESCE(r.sage_object_id, s.sage_object_id)::text,
    COALESCE(r.sage_payment_on_account_id, s.sage_payment_on_account_id)::text,
    COALESCE(r.request_payload, s.request_payload, '{}'::jsonb),
    COALESCE(s.internal_reference_json, '{}'::jsonb),
    COALESCE(r.response_payload, s.sage_response_payload),
    r.created_at,
    r.attempt_count,
    r.last_attempt_at,
    r.posted_at,
    r.sage_object_type::text,
    r.sage_reference::text,
    r.error_code::text,
    r.error_message::text
  FROM public.cash_posting_batches b
  JOIN public.cash_posting_batch_rows r ON r.batch_id = b.id AND r.active = true
  JOIN public.cash_posting_snapshots s ON s.id = r.snapshot_id AND s.active = true
  LEFT JOIN public.staff st ON st.id = b.created_by_staff_id
  WHERE b.active = true AND b.id = p_batch_id
  ORDER BY r.created_at ASC, r.id ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_cash_posting_batch_history_v1(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_cash_posting_batch_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_batch_history_v1(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_batch_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;