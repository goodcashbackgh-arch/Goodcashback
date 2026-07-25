BEGIN;

-- Narrow retailer-refund-IN workbench patch.
-- Preserves the complete existing cash workbench resolver as a base function and
-- overrides only confirmed retailer_refund_received rows when their exact
-- approved-current supplier-credit settlement has posted to Sage.
-- No treasury, reconciliation, allocation, freeze, batch or Sage write logic changes.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_cash_posting_workbench_rows_v1';
  END IF;
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Missing dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing sage_posting_snapshots';
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure('public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(text,text,text,text,integer,integer)') IS NULL THEN
    ALTER FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)
      RENAME TO internal_cash_posting_workbench_rows_pre_refund_readiness_v1;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_cash_posting_workbench_rows_v1(
  p_direction text DEFAULT 'all',
  p_category text DEFAULT 'all',
  p_status text DEFAULT 'all',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  queue_row_id text,
  source_type text,
  source_id uuid,
  statement_line_id uuid,
  statement_id uuid,
  statement_date_text text,
  direction text,
  category text,
  counterparty_type text,
  counterparty_id uuid,
  counterparty_name text,
  order_id uuid,
  order_ref text,
  auth_ref text,
  reference_raw text,
  amount_local numeric,
  local_currency text,
  amount_gbp numeric,
  matched_target_type text,
  matched_target_id uuid,
  matched_target_ref text,
  sage_contact_id text,
  sage_contact_name text,
  sage_bank_account_id text,
  target_sage_object_id text,
  posting_status text,
  blocker text,
  selectable boolean,
  detail_json jsonb,
  total_count bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH base_rows AS (
    SELECT *
    FROM public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(
      p_direction,
      p_category,
      'all',
      p_search,
      300,
      0
    )
  ), resolved AS (
    SELECT
      b.queue_row_id,
      b.source_type,
      b.source_id,
      b.statement_line_id,
      b.statement_id,
      b.statement_date_text,
      b.direction,
      b.category,
      b.counterparty_type,
      b.counterparty_id,
      b.counterparty_name,
      b.order_id,
      b.order_ref,
      b.auth_ref,
      b.reference_raw,
      b.amount_local,
      b.local_currency,
      b.amount_gbp,
      b.matched_target_type,
      b.matched_target_id,
      b.matched_target_ref,
      b.sage_contact_id,
      b.sage_contact_name,
      b.sage_bank_account_id,
      CASE
        WHEN b.category = 'retailer_refund_received' AND rr.ready THEN rr.sage_invoice_id
        ELSE b.target_sage_object_id
      END::text AS target_sage_object_id,
      CASE
        WHEN b.category = 'retailer_refund_received' AND rr.ready THEN 'ready_to_freeze'
        ELSE b.posting_status
      END::text AS posting_status,
      CASE
        WHEN b.category = 'retailer_refund_received' AND rr.ready THEN NULL::text
        ELSE b.blocker
      END::text AS blocker,
      CASE
        WHEN b.category = 'retailer_refund_received' AND rr.ready THEN true
        ELSE b.selectable
      END AS selectable,
      CASE
        WHEN b.category = 'retailer_refund_received' AND rr.ready THEN
          COALESCE(b.detail_json, '{}'::jsonb) || jsonb_build_object(
            'endpoint', 'POST /contact_payments',
            'transaction_type_id', 'VENDOR_REFUND',
            'is_refund', true,
            'payment_type', 'receipt',
            'document_mode', rr.document_mode,
            'refund_evidence_submission_id', rr.evidence_submission_id,
            'supplier_credit_settlement_sage_id', rr.sage_invoice_id,
            'supplier_credit_note_sage_id', rr.sage_invoice_id,
            'target_sage_object_id', rr.sage_invoice_id,
            'supplier_credit_snapshot_id', rr.sage_snapshot_id
          )
        ELSE b.detail_json
      END AS detail_json
    FROM base_rows b
    LEFT JOIN LATERAL (
      SELECT
        true AS ready,
        e.id AS evidence_submission_id,
        e.document_mode::text AS document_mode,
        s.id AS sage_snapshot_id,
        s.sage_invoice_id::text AS sage_invoice_id
      FROM public.dispute_refund_evidence_submissions e
      JOIN public.sage_posting_snapshots s
        ON s.source_id = e.id
       AND s.document_lane = 'supplier_credit_note'
       AND s.sage_posting_status = 'posted'
       AND NULLIF(trim(COALESCE(s.sage_invoice_id, '')), '') IS NOT NULL
      WHERE b.category = 'retailer_refund_received'
        AND e.dispute_id = b.matched_target_id
        AND e.supplier_approval_status = 'approved_current'
        AND e.supplier_control_status = 'approved_current'
        AND b.direction = 'in'
        AND b.amount_gbp > 0
        AND NULLIF(trim(COALESCE(b.sage_contact_id, '')), '') IS NOT NULL
        AND NULLIF(trim(COALESCE(b.sage_bank_account_id, '')), '') IS NOT NULL
      ORDER BY s.sage_posted_at DESC NULLS LAST, s.created_at DESC
      LIMIT 1
    ) rr ON true
  ), filtered AS (
    SELECT r.*
    FROM resolved r
    WHERE lower(COALESCE(NULLIF(trim(p_status), ''), 'all')) = 'all'
       OR lower(r.posting_status) = lower(trim(p_status))
       OR (lower(trim(p_status)) = 'blocked' AND lower(r.posting_status) LIKE 'blocked%')
       OR (lower(trim(p_status)) = 'ready' AND lower(r.posting_status) = 'ready_to_freeze')
  )
  SELECT
    f.queue_row_id,
    f.source_type,
    f.source_id,
    f.statement_line_id,
    f.statement_id,
    f.statement_date_text,
    f.direction,
    f.category,
    f.counterparty_type,
    f.counterparty_id,
    f.counterparty_name,
    f.order_id,
    f.order_ref,
    f.auth_ref,
    f.reference_raw,
    f.amount_local,
    f.local_currency,
    f.amount_gbp,
    f.matched_target_type,
    f.matched_target_id,
    f.matched_target_ref,
    f.sage_contact_id,
    f.sage_contact_name,
    f.sage_bank_account_id,
    f.target_sage_object_id,
    f.posting_status,
    f.blocker,
    f.selectable,
    f.detail_json,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date_text DESC NULLS LAST, f.category, f.counterparty_name, f.queue_row_id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$function$;

REVOKE ALL ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) TO authenticated;

COMMENT ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) IS
'Reuses the complete prior cash workbench resolver and narrowly releases retailer-refund IN rows only after an exact approved-current supplier-credit settlement has posted to Sage.';

NOTIFY pgrst, 'reload schema';

COMMIT;
