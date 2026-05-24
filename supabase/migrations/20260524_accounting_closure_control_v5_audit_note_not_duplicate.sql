BEGIN;

-- Accounting Closure Control v5 wrapper.
-- Keeps actual duplicate_warning for real duplicate/idempotency risks only.
-- Moves snapshot-batch-vs-posting-row-batch differences into trace_json.audit_note.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
    FROM public.internal_accounting_closure_control_rows_v1(p_lane, p_state, p_search, p_limit, p_offset)
  ), patched AS (
    SELECT
      b.*,
      row_batch.row_batch_id,
      row_batch.row_batch_ref,
      row_batch.row_id AS resolved_posting_row_id,
      row_batch.row_status AS resolved_posting_row_status,
      CASE
        WHEN row_batch.row_batch_id IS NOT NULL
          AND b.posting_batch_id IS NOT NULL
          AND row_batch.row_batch_id <> b.posting_batch_id
        THEN 'Snapshot batch differs from actual posting-row batch; closure uses posting-row batch.'
        ELSE NULL::text
      END AS audit_note
    FROM base b
    LEFT JOIN LATERAL (
      SELECT
        r.id AS row_id,
        r.batch_id AS row_batch_id,
        sb.batch_ref AS row_batch_ref,
        r.posting_status AS row_status
      FROM public.sage_posting_batch_rows r
      JOIN public.sage_posting_batches sb ON sb.id = r.batch_id
      WHERE b.trace_json->>'source_kind' = 'sage_posting_snapshot'
        AND r.snapshot_id = NULLIF(b.trace_json->>'snapshot_id', '')::uuid
        AND r.posting_status <> 'excluded'
      ORDER BY
        CASE WHEN r.posting_status = 'posted' THEN 0 ELSE 1 END,
        r.posted_at DESC NULLS LAST,
        r.created_at DESC,
        r.id DESC
      LIMIT 1
    ) row_batch ON true
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
    COALESCE(p.row_batch_id, p.posting_batch_id) AS posting_batch_id,
    COALESCE(p.row_batch_ref, p.posting_batch_ref) AS posting_batch_ref,
    COALESCE(p.resolved_posting_row_id, p.posting_row_id) AS posting_row_id,
    p.cash_or_credit_allocation_status,
    p.sage_target_artefact_id,
    p.attachment_state,
    p.outstanding_amount_gbp,
    p.idempotency_key,
    p.duplicate_warning,
    p.blocker,
    p.next_action,
    CASE
      WHEN p.trace_json->>'source_kind' = 'sage_posting_snapshot' THEN
        jsonb_set(
          jsonb_set(
            jsonb_set(
              jsonb_set(
                jsonb_set(
                  jsonb_set(
                    p.trace_json,
                    '{snapshot_batch_id}',
                    to_jsonb(p.posting_batch_id),
                    true
                  ),
                  '{snapshot_batch_ref}',
                  to_jsonb(p.posting_batch_ref),
                  true
                ),
                '{batch_id}',
                to_jsonb(COALESCE(p.row_batch_id, p.posting_batch_id)),
                true
              ),
              '{batch_ref}',
              to_jsonb(COALESCE(p.row_batch_ref, p.posting_batch_ref)),
              true
            ),
            '{action_href}',
            CASE
              WHEN p.row_batch_id IS NOT NULL THEN to_jsonb('/internal/accounting-command-centre/batches/' || p.row_batch_id::text)
              ELSE 'null'::jsonb
            END,
            true
          ),
          '{audit_note}',
          CASE WHEN p.audit_note IS NOT NULL THEN to_jsonb(p.audit_note) ELSE 'null'::jsonb END,
          true
        ) || jsonb_build_object(
          'actual_posting_row_batch_id', p.row_batch_id,
          'actual_posting_row_batch_ref', p.row_batch_ref,
          'actual_posting_row_id', p.resolved_posting_row_id,
          'actual_posting_row_status', p.resolved_posting_row_status,
          'action_href_status', CASE WHEN p.row_batch_id IS NOT NULL THEN 'available_actual_posting_row_batch' ELSE 'not_available_batch_has_no_matching_row' END,
          'closure_model_version', 'v5_audit_note_not_duplicate'
        )
      ELSE p.trace_json
    END AS trace_json,
    p.total_count
  FROM patched p;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) IS
'Accounting Closure Control v5 wrapper: real duplicate warnings remain duplicate_warning; batch-resolution differences are neutral trace_json.audit_note.';

NOTIFY pgrst, 'reload schema';

COMMIT;
