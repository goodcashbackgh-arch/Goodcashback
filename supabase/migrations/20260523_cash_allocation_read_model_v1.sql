BEGIN;

-- Unified cash allocation read model.
-- SECURITY DEFINER so the allocation page does not depend on direct table RLS reads.
-- Phase 1: posted customer receipt/payment-on-account -> matched posted customer sales invoice.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_cash_allocation_workbench_rows_v1(
  p_status text DEFAULT 'all',
  p_category text DEFAULT 'all',
  p_q text DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS TABLE (
  allocation_source_id uuid,
  cash_batch_row_id uuid,
  cash_snapshot_id uuid,
  cash_batch_id uuid,
  cash_batch_ref text,
  allocation_category text,
  allocation_status text,
  selectable boolean,
  blocker text,
  direction text,
  order_id uuid,
  order_ref text,
  counterparty_name text,
  sage_contact_id text,
  receipt_sage_object_id text,
  payment_on_account_id text,
  receipt_amount_gbp numeric,
  target_snapshot_id uuid,
  target_sales_invoice_id uuid,
  target_sage_invoice_id text,
  target_reference text,
  target_contact_id text,
  target_invoice_amount_gbp numeric,
  allocation_amount_gbp numeric,
  residual_gbp numeric,
  short_reference text,
  statement_line_id uuid,
  auth_ref text,
  request_payload jsonb,
  trace_json jsonb,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;

  RETURN QUERY
  WITH cash_rows AS (
    SELECT
      r.id AS cash_batch_row_id,
      r.snapshot_id AS cash_snapshot_id,
      r.batch_id AS cash_batch_id,
      b.batch_ref::text AS cash_batch_ref,
      s.order_id,
      s.order_ref::text AS order_ref,
      s.counterparty_name::text AS counterparty_name,
      s.sage_contact_id::text AS sage_contact_id,
      COALESCE(r.sage_object_id, s.sage_object_id)::text AS receipt_sage_object_id,
      COALESCE(r.sage_payment_on_account_id, s.sage_payment_on_account_id)::text AS payment_on_account_id,
      r.amount_gbp::numeric(18,2) AS receipt_amount_gbp,
      s.short_reference::text AS short_reference,
      s.statement_line_id,
      COALESCE(s.internal_reference_json->>'auth_ref', s.internal_reference_json->>'reference_raw')::text AS auth_ref,
      r.posting_status::text AS receipt_posting_status,
      COALESCE(r.sage_allocation_status, s.sage_allocation_status, 'not_allocated')::text AS existing_allocation_status,
      COALESCE(r.sage_allocation_amount_gbp, s.sage_allocation_amount_gbp, 0)::numeric(18,2) AS existing_allocation_amount_gbp,
      COALESCE(r.sage_allocation_error_message, s.sage_allocation_error_message)::text AS existing_allocation_error_message,
      r.created_at
    FROM public.cash_posting_batch_rows r
    JOIN public.cash_posting_batches b ON b.id = r.batch_id AND b.active = true
    JOIN public.cash_posting_snapshots s ON s.id = r.snapshot_id AND s.active = true
    WHERE r.active = true
      AND r.posting_category = 'customer_receipt_on_account'
      AND r.posting_status IN ('posted', 'posted_needs_review')
  ), target_stats AS (
    SELECT
      cr.cash_batch_row_id,
      count(ss.id)::integer AS target_count
    FROM cash_rows cr
    LEFT JOIN public.sage_posting_snapshots ss
      ON ss.active = true
     AND ss.document_lane = 'customer_sales'
     AND ss.sage_posting_status = 'posted'
     AND ss.sage_invoice_id IS NOT NULL
     AND ss.order_id = cr.order_id
    GROUP BY cr.cash_batch_row_id
  ), target_one AS (
    SELECT DISTINCT ON (cr.cash_batch_row_id)
      cr.cash_batch_row_id,
      ss.id AS target_snapshot_id,
      ss.source_id AS target_sales_invoice_id,
      ss.sage_invoice_id::text AS target_sage_invoice_id,
      COALESCE(ss.reference_text, ss.order_ref, ss.sage_invoice_id)::text AS target_reference,
      COALESCE(
        ss.resolved_payload #>> '{sage_header,contact_id}',
        ss.resolved_payload #>> '{sage_header,sage_contact_id}',
        ss.resolved_payload #>> '{customer_target,sage_contact_id}',
        ss.resolved_payload #>> '{customer,sage_contact_id}'
      )::text AS target_contact_id,
      COALESCE(ss.amount_gbp, 0)::numeric(18,2) AS target_invoice_amount_gbp
    FROM cash_rows cr
    JOIN public.sage_posting_snapshots ss
      ON ss.active = true
     AND ss.document_lane = 'customer_sales'
     AND ss.sage_posting_status = 'posted'
     AND ss.sage_invoice_id IS NOT NULL
     AND ss.order_id = cr.order_id
    ORDER BY cr.cash_batch_row_id, ss.sage_posted_at DESC NULLS LAST, ss.created_at DESC, ss.id DESC
  ), assessed AS (
    SELECT
      cr.*,
      COALESCE(ts.target_count, 0) AS target_count,
      to1.target_snapshot_id,
      to1.target_sales_invoice_id,
      to1.target_sage_invoice_id,
      to1.target_reference,
      to1.target_contact_id,
      to1.target_invoice_amount_gbp,
      LEAST(
        GREATEST(cr.receipt_amount_gbp - COALESCE(cr.existing_allocation_amount_gbp, 0), 0),
        GREATEST(COALESCE(to1.target_invoice_amount_gbp, 0), 0)
      )::numeric(18,2) AS allocation_amount_gbp,
      (
        cr.receipt_amount_gbp - LEAST(
          GREATEST(cr.receipt_amount_gbp - COALESCE(cr.existing_allocation_amount_gbp, 0), 0),
          GREATEST(COALESCE(to1.target_invoice_amount_gbp, 0), 0)
        )
      )::numeric(18,2) AS residual_gbp
    FROM cash_rows cr
    LEFT JOIN target_stats ts ON ts.cash_batch_row_id = cr.cash_batch_row_id
    LEFT JOIN target_one to1 ON to1.cash_batch_row_id = cr.cash_batch_row_id
  ), final_rows AS (
    SELECT
      a.*,
      CASE
        WHEN a.existing_allocation_status = 'allocated' THEN 'allocated'
        WHEN a.existing_allocation_status LIKE 'failed%' THEN 'failed'
        WHEN a.receipt_posting_status NOT IN ('posted','posted_needs_review') THEN 'blocked'
        WHEN NULLIF(trim(COALESCE(a.receipt_sage_object_id, '')), '') IS NULL THEN 'blocked'
        WHEN NULLIF(trim(COALESCE(a.payment_on_account_id, '')), '') IS NULL THEN 'blocked'
        WHEN COALESCE(a.target_count, 0) = 0 THEN 'blocked'
        WHEN a.target_count > 1 THEN 'blocked'
        WHEN NULLIF(trim(COALESCE(a.target_sage_invoice_id, '')), '') IS NULL THEN 'blocked'
        WHEN NULLIF(trim(COALESCE(a.target_contact_id, '')), '') IS NULL THEN 'blocked'
        WHEN a.target_contact_id IS DISTINCT FROM a.sage_contact_id THEN 'blocked'
        WHEN a.receipt_amount_gbp <= 0 THEN 'blocked'
        WHEN COALESCE(a.target_invoice_amount_gbp, 0) <= 0 THEN 'blocked'
        WHEN a.allocation_amount_gbp <= 0 THEN 'blocked'
        ELSE 'ready'
      END AS allocation_status,
      CASE
        WHEN a.existing_allocation_status = 'allocated' THEN 'already allocated'
        WHEN a.existing_allocation_status LIKE 'failed%' THEN COALESCE(a.existing_allocation_error_message, 'allocation previously failed')
        WHEN a.receipt_posting_status NOT IN ('posted','posted_needs_review') THEN 'receipt has not been posted to Sage'
        WHEN NULLIF(trim(COALESCE(a.receipt_sage_object_id, '')), '') IS NULL THEN 'receipt Sage contact_payment id missing'
        WHEN NULLIF(trim(COALESCE(a.payment_on_account_id, '')), '') IS NULL THEN 'receipt payment_on_account id missing'
        WHEN COALESCE(a.target_count, 0) = 0 THEN 'matched sales invoice has not been posted to Sage'
        WHEN a.target_count > 1 THEN 'multiple posted sales invoices found for this order'
        WHEN NULLIF(trim(COALESCE(a.target_sage_invoice_id, '')), '') IS NULL THEN 'target Sage sales invoice id missing'
        WHEN NULLIF(trim(COALESCE(a.target_contact_id, '')), '') IS NULL THEN 'target sales invoice Sage contact id missing'
        WHEN a.target_contact_id IS DISTINCT FROM a.sage_contact_id THEN 'receipt/contact mismatch'
        WHEN a.receipt_amount_gbp <= 0 THEN 'receipt amount is not positive'
        WHEN COALESCE(a.target_invoice_amount_gbp, 0) <= 0 THEN 'target invoice amount is not positive'
        WHEN a.allocation_amount_gbp <= 0 THEN 'no positive amount available to allocate'
        ELSE NULL::text
      END AS blocker
    FROM assessed a
  )
  SELECT
    fr.cash_batch_row_id AS allocation_source_id,
    fr.cash_batch_row_id,
    fr.cash_snapshot_id,
    fr.cash_batch_id,
    fr.cash_batch_ref,
    'customer_receipt_to_sales_invoice'::text AS allocation_category,
    fr.allocation_status,
    (fr.allocation_status = 'ready')::boolean AS selectable,
    fr.blocker,
    'in'::text AS direction,
    fr.order_id,
    fr.order_ref,
    fr.counterparty_name,
    fr.sage_contact_id,
    fr.receipt_sage_object_id,
    fr.payment_on_account_id,
    fr.receipt_amount_gbp,
    fr.target_snapshot_id,
    fr.target_sales_invoice_id,
    fr.target_sage_invoice_id,
    fr.target_reference,
    fr.target_contact_id,
    fr.target_invoice_amount_gbp,
    fr.allocation_amount_gbp,
    fr.residual_gbp,
    fr.short_reference,
    fr.statement_line_id,
    fr.auth_ref,
    CASE WHEN fr.allocation_status = 'ready' THEN jsonb_build_object(
      'endpoint', '/contact_allocations',
      'method', 'POST',
      'contact_allocation', jsonb_build_object(
        'contact_id', fr.sage_contact_id,
        'transaction_type_id', 'CUSTOMER_ALLOCATION',
        'allocated_artefacts', jsonb_build_array(
          jsonb_build_object('artefact_id', fr.target_sage_invoice_id, 'amount', fr.allocation_amount_gbp),
          jsonb_build_object('artefact_id', fr.payment_on_account_id, 'amount', -fr.allocation_amount_gbp)
        )
      )
    ) ELSE NULL::jsonb END AS request_payload,
    jsonb_build_object(
      'cash_batch_ref', fr.cash_batch_ref,
      'cash_batch_row_id', fr.cash_batch_row_id,
      'cash_snapshot_id', fr.cash_snapshot_id,
      'order_id', fr.order_id,
      'order_ref', fr.order_ref,
      'statement_line_id', fr.statement_line_id,
      'auth_ref', fr.auth_ref,
      'receipt_sage_object_id', fr.receipt_sage_object_id,
      'payment_on_account_id', fr.payment_on_account_id,
      'target_sales_invoice_id', fr.target_sales_invoice_id,
      'target_sage_invoice_id', fr.target_sage_invoice_id,
      'target_snapshot_id', fr.target_snapshot_id,
      'receipt_amount_gbp', fr.receipt_amount_gbp,
      'target_invoice_amount_gbp', fr.target_invoice_amount_gbp,
      'allocation_amount_gbp', fr.allocation_amount_gbp,
      'residual_gbp', fr.residual_gbp
    ) AS trace_json,
    fr.created_at
  FROM final_rows fr
  WHERE (COALESCE(p_category, 'all') = 'all' OR 'customer_receipt_to_sales_invoice' = p_category)
    AND (COALESCE(p_status, 'all') = 'all' OR fr.allocation_status = p_status)
    AND (
      NULLIF(trim(COALESCE(p_q, '')), '') IS NULL
      OR fr.order_ref ILIKE '%' || p_q || '%'
      OR fr.counterparty_name ILIKE '%' || p_q || '%'
      OR fr.short_reference ILIKE '%' || p_q || '%'
      OR fr.auth_ref ILIKE '%' || p_q || '%'
      OR fr.target_reference ILIKE '%' || p_q || '%'
    )
  ORDER BY
    CASE fr.allocation_status WHEN 'ready' THEN 1 WHEN 'failed' THEN 2 WHEN 'blocked' THEN 3 WHEN 'allocated' THEN 4 ELSE 5 END,
    fr.created_at DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_cash_allocation_workbench_rows_v1(text, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_cash_allocation_workbench_rows_v1(text, text, text, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_cash_allocation_workbench_rows_v1(text, text, text, integer) IS 'Unified cash allocation workbench read model. SECURITY DEFINER. Phase 1 customer receipt on account to posted customer sales invoice.';

NOTIFY pgrst, 'reload schema';

COMMIT;
