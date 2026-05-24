BEGIN;

-- Accounting Closure Control v6c.
-- Page-safe patch: keep the UI calling internal_accounting_closure_control_rows_v2,
-- but make v2 return attachment proof from sage_posting_snapshots.sage_attachment_*.
-- No Sage API calls. No posting. No allocation. No endpoint expansion.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing prerequisite function internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)';
  END IF;

  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2_base(text,text,text,integer,integer)') IS NULL THEN
    ALTER FUNCTION public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)
      RENAME TO internal_accounting_closure_control_rows_v2_base;
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
    FROM public.internal_accounting_closure_control_rows_v2_base(p_lane, p_state, p_search, p_limit, p_offset)
  ), patched AS (
    SELECT
      b.*,
      att.snapshot_id AS attachment_snapshot_id,
      att.sage_attachment_status,
      att.sage_attachment_object_id,
      att.sage_attachment_source_url,
      att.sage_attachment_file_name,
      att.sage_attachment_attached_at,
      att.sage_attachment_error_code,
      att.sage_attachment_error_message,
      CASE
        WHEN b.closure_lane NOT IN ('supplier_credit_note','supplier_goods_ap','shipper_ap') THEN b.attachment_state
        WHEN att.sage_attachment_status = 'attached' THEN 'attached'
        WHEN att.sage_attachment_status = 'not_required' THEN 'not_required'
        WHEN att.sage_attachment_status = 'unsupported' THEN 'attachment_unsupported'
        WHEN att.sage_attachment_status = 'pending' THEN 'attachment_pending'
        WHEN att.sage_attachment_status = 'failed_retryable' THEN 'attachment_failed_retryable'
        WHEN att.sage_attachment_status = 'failed_terminal' THEN 'attachment_failed_terminal'
        WHEN att.sage_attachment_status = 'not_attempted' AND NULLIF(att.sage_attachment_source_url, '') IS NOT NULL THEN 'source_available_attachment_not_attempted'
        WHEN att.sage_attachment_status = 'not_attempted' THEN 'source_attachment_not_attempted'
        WHEN att.sage_attachment_status IS NULL THEN 'attachment_status_not_found'
        ELSE COALESCE(att.sage_attachment_status, b.attachment_state)
      END::text AS resolved_attachment_state
    FROM base b
    LEFT JOIN LATERAL (
      SELECT
        s.id AS snapshot_id,
        s.sage_attachment_status,
        s.sage_attachment_object_id,
        COALESCE(
          NULLIF(s.sage_attachment_source_url, ''),
          NULLIF(s.resolved_payload #>> '{source_evidence,file_url}', ''),
          NULLIF(s.resolved_payload #>> '{source_payload,supplier_invoice_pdf_url}', ''),
          NULLIF(s.resolved_payload #>> '{source_payload,invoice_pdf_url}', ''),
          NULLIF(s.resolved_payload #>> '{source_payload,evidence,credit_note_file_url}', ''),
          NULLIF(s.resolved_payload #>> '{credit_note_file_url}', ''),
          NULLIF(s.commercial_payload #>> '{source_evidence,file_url}', ''),
          NULLIF(s.commercial_payload #>> '{supplier_invoice_pdf_url}', ''),
          NULLIF(s.commercial_payload #>> '{invoice_pdf_url}', ''),
          NULLIF(s.commercial_payload #>> '{credit_note_file_url}', '')
        )::text AS sage_attachment_source_url,
        s.sage_attachment_file_name,
        s.sage_attachment_attached_at,
        s.sage_attachment_error_code,
        s.sage_attachment_error_message
      FROM public.sage_posting_snapshots s
      WHERE b.closure_lane IN ('supplier_credit_note','supplier_goods_ap','shipper_ap')
        AND s.source_table = b.platform_source_table
        AND s.source_id = b.platform_source_id
        AND s.document_lane = b.closure_lane
      ORDER BY
        CASE
          WHEN s.sage_posting_status = 'posted' AND s.sage_invoice_id IS NOT NULL THEN 0
          WHEN COALESCE(s.active, false) = true AND s.superseded_by_snapshot_id IS NULL THEN 1
          ELSE 2
        END,
        COALESCE(s.sage_posted_at, s.created_at) DESC,
        s.created_at DESC,
        s.id DESC
      LIMIT 1
    ) att ON true
  )
  SELECT
    p.closure_row_id,
    p.closure_lane,
    p.closure_state,
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
    p.cash_or_credit_allocation_status,
    p.sage_target_artefact_id,
    p.resolved_attachment_state AS attachment_state,
    p.outstanding_amount_gbp,
    p.idempotency_key,
    p.duplicate_warning,
    p.blocker,
    p.next_action,
    p.trace_json || jsonb_build_object(
      'attachment_proof_version', 'v6c_v2_attachment_state',
      'attachment_snapshot_id', p.attachment_snapshot_id,
      'sage_attachment_status', p.sage_attachment_status,
      'sage_attachment_object_id', p.sage_attachment_object_id,
      'sage_attachment_source_url', p.sage_attachment_source_url,
      'sage_attachment_file_name', p.sage_attachment_file_name,
      'sage_attachment_attached_at', p.sage_attachment_attached_at,
      'sage_attachment_error_code', p.sage_attachment_error_code,
      'sage_attachment_error_message', p.sage_attachment_error_message,
      'resolved_attachment_state', p.resolved_attachment_state
    ) AS trace_json,
    p.total_count
  FROM patched p;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) IS
'Accounting Closure Control v6c: page-compatible v2 resolver with AP/CN attachment proof from sage_posting_snapshots.sage_attachment_* fields.';

NOTIFY pgrst, 'reload schema';

COMMIT;
