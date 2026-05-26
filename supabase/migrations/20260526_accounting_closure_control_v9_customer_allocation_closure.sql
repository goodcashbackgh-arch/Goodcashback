BEGIN;

-- Accounting Closure Control v9.
-- Page-safe wrapper over the current v2 resolver.
-- Closes customer receipt-on-account and customer sales rows when the platform has stored
-- a posted Sage /contact_allocations result proving payment-on-account allocation to the
-- final Sage sales invoice artefact.
-- No Sage API calls. No posting. No allocation. Read-only diagnostic patch only.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing prerequisite function internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)';
  END IF;

  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2_pre_customer_allocation_closure(text,text,text,integer,integer)') IS NULL THEN
    ALTER FUNCTION public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)
      RENAME TO internal_accounting_closure_control_rows_v2_pre_customer_allocation_closure;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_accounting_closure_control_rows_v2(
  p_lane text DEFAULT 'all',
  p_state text DEFAULT 'all',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  closure_row_id text,
  closure_lane text,
  closure_state text,
  platform_source_table text,
  platform_source_id uuid,
  order_id uuid,
  order_ref text,
  source_document_ref text,
  source_amount_gbp numeric,
  source_approval_state text,
  sage_object_type text,
  sage_object_id text,
  sage_reference text,
  posted_at timestamptz,
  posting_batch_id uuid,
  posting_batch_ref text,
  posting_row_id uuid,
  cash_or_credit_allocation_status text,
  sage_target_artefact_id text,
  attachment_state text,
  outstanding_amount_gbp numeric,
  idempotency_key text,
  duplicate_warning text,
  blocker text,
  next_action text,
  trace_json jsonb,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: accounting closure control requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for accounting closure control.';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT *
    FROM public.internal_accounting_closure_control_rows_v2_pre_customer_allocation_closure(
      p_lane, p_state, p_search, p_limit, p_offset
    )
  ), patched AS (
    SELECT
      b.*,
      customer_match.matched_customer_allocation_row_count,
      customer_match.matched_customer_allocation_status,
      customer_match.matched_customer_allocation_id,
      customer_match.matched_customer_payment_id,
      customer_match.matched_customer_target_id,
      customer_match.matched_customer_batch_ref,
      (
        b.closure_lane = 'customer_receipt_on_account'
        AND b.closure_state IN ('posted_not_closed','posted_needs_review')
        AND NULLIF(trim(COALESCE(b.sage_object_id, '')), '') IS NOT NULL
        AND COALESCE(b.cash_or_credit_allocation_status, '') LIKE 'allocated%'
        AND NULLIF(trim(COALESCE(b.sage_target_artefact_id, b.trace_json->>'sage_allocation_target_object_id', '')), '') IS NOT NULL
      ) AS is_closed_customer_receipt,
      (
        b.closure_lane = 'customer_sales'
        AND b.closure_state IN ('posted_not_closed','posted_needs_review')
        AND NULLIF(trim(COALESCE(b.sage_object_id, '')), '') IS NOT NULL
        AND (
          COALESCE(b.cash_or_credit_allocation_status, '') LIKE 'allocated%'
          OR COALESCE(customer_match.matched_customer_allocation_row_count, 0) > 0
        )
      ) AS is_closed_customer_sales
    FROM base b
    LEFT JOIN LATERAL (
      SELECT
        count(*)::integer AS matched_customer_allocation_row_count,
        string_agg(DISTINCT COALESCE(NULLIF(cbr.sage_allocation_status, ''), NULLIF(cps.sage_allocation_status, ''), 'allocated'), ', ' ORDER BY COALESCE(NULLIF(cbr.sage_allocation_status, ''), NULLIF(cps.sage_allocation_status, ''), 'allocated'))::text AS matched_customer_allocation_status,
        max(COALESCE(NULLIF(cbr.sage_allocation_id, ''), NULLIF(cps.sage_allocation_id, '')))::text AS matched_customer_allocation_id,
        max(COALESCE(NULLIF(cbr.sage_object_id, ''), NULLIF(cps.sage_object_id, '')))::text AS matched_customer_payment_id,
        max(COALESCE(NULLIF(cbr.sage_allocation_target_object_id, ''), NULLIF(cps.sage_allocation_target_object_id, '')))::text AS matched_customer_target_id,
        max(cb.batch_ref)::text AS matched_customer_batch_ref
      FROM public.cash_posting_batch_rows cbr
      JOIN public.cash_posting_snapshots cps ON cps.id = cbr.snapshot_id AND cps.active = true
      LEFT JOIN public.cash_posting_batches cb ON cb.id = cbr.batch_id AND cb.active = true
      WHERE b.closure_lane = 'customer_sales'
        AND cbr.active = true
        AND cbr.posting_category = 'customer_receipt_on_account'
        AND cbr.posting_status IN ('posted','posted_needs_review')
        AND COALESCE(NULLIF(cbr.sage_allocation_status, ''), NULLIF(cps.sage_allocation_status, '')) LIKE 'allocated%'
        AND NULLIF(trim(COALESCE(b.sage_object_id, '')), '') IS NOT NULL
        AND (
          COALESCE(NULLIF(cbr.sage_allocation_target_object_id, ''), NULLIF(cps.sage_allocation_target_object_id, '')) = b.sage_object_id
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
              CASE
                WHEN jsonb_typeof(COALESCE(cbr.sage_allocation_request_payload, cps.sage_allocation_request_payload, '{}'::jsonb) #> '{contact_allocation,allocated_artefacts}') = 'array'
                  THEN COALESCE(cbr.sage_allocation_request_payload, cps.sage_allocation_request_payload, '{}'::jsonb) #> '{contact_allocation,allocated_artefacts}'
                ELSE '[]'::jsonb
              END
            ) AS artefact(row_json)
            WHERE artefact.row_json->>'artefact_id' = b.sage_object_id
          )
        )
    ) customer_match ON true
  )
  SELECT
    p.closure_row_id,
    p.closure_lane,
    CASE
      WHEN p.is_closed_customer_receipt OR p.is_closed_customer_sales THEN 'posted_closed'
      ELSE p.closure_state
    END AS closure_state,
    p.platform_source_table,
    p.platform_source_id,
    p.order_id,
    p.order_ref,
    p.source_document_ref,
    p.source_amount_gbp,
    p.source_approval_state,
    p.sage_object_type,
    p.sage_object_id,
    p.sage_reference,
    p.posted_at,
    p.posting_batch_id,
    p.posting_batch_ref,
    p.posting_row_id,
    CASE
      WHEN p.is_closed_customer_receipt THEN COALESCE(NULLIF(p.cash_or_credit_allocation_status, ''), 'allocated')
      WHEN p.is_closed_customer_sales THEN COALESCE(NULLIF(p.cash_or_credit_allocation_status, ''), p.matched_customer_allocation_status, 'allocated')
      ELSE p.cash_or_credit_allocation_status
    END AS cash_or_credit_allocation_status,
    CASE
      WHEN p.is_closed_customer_receipt THEN COALESCE(p.sage_target_artefact_id, p.trace_json->>'sage_allocation_target_object_id')
      WHEN p.is_closed_customer_sales THEN COALESCE(p.sage_target_artefact_id, p.matched_customer_target_id, p.sage_object_id)
      ELSE p.sage_target_artefact_id
    END AS sage_target_artefact_id,
    p.attachment_state,
    p.outstanding_amount_gbp,
    p.idempotency_key,
    p.duplicate_warning,
    CASE
      WHEN p.is_closed_customer_receipt OR p.is_closed_customer_sales THEN NULL::text
      ELSE p.blocker
    END AS blocker,
    CASE
      WHEN p.is_closed_customer_receipt OR p.is_closed_customer_sales THEN 'No action'
      ELSE p.next_action
    END AS next_action,
    p.trace_json || jsonb_build_object(
      'closure_model_version_v9', 'customer_receipt_sales_allocation_closure',
      'v9_closed_customer_receipt', p.is_closed_customer_receipt,
      'v9_closed_customer_sales', p.is_closed_customer_sales,
      'matched_customer_allocation_row_count', p.matched_customer_allocation_row_count,
      'matched_customer_allocation_status', p.matched_customer_allocation_status,
      'matched_customer_allocation_id', p.matched_customer_allocation_id,
      'matched_customer_payment_id', p.matched_customer_payment_id,
      'matched_customer_target_id', p.matched_customer_target_id,
      'matched_customer_batch_ref', p.matched_customer_batch_ref
    ) AS trace_json,
    p.total_count
  FROM patched p;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) IS
'Accounting Closure Control v9: closes customer receipt-on-account and customer sales rows when stored Sage contact allocation proves POA-to-sales-invoice allocation.';

NOTIFY pgrst, 'reload schema';

COMMIT;
