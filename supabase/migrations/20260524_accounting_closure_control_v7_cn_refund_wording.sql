BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_accounting_closure_control_rows_v2';
  END IF;
  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2_pre_cn_refund_wording(text,text,text,integer,integer)') IS NULL THEN
    ALTER FUNCTION public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)
      RENAME TO internal_accounting_closure_control_rows_v2_pre_cn_refund_wording;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_accounting_closure_control_rows_v2(
  p_lane text DEFAULT 'all', p_state text DEFAULT 'all', p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100, p_offset integer DEFAULT 0
)
RETURNS TABLE (
  closure_row_id text, closure_lane text, closure_state text,
  platform_source_table text, platform_source_id uuid, order_id uuid, order_ref text,
  source_document_ref text, source_amount_gbp numeric, source_approval_state text,
  sage_object_type text, sage_object_id text, sage_reference text, posted_at timestamptz,
  posting_batch_id uuid, posting_batch_ref text, posting_row_id uuid,
  cash_or_credit_allocation_status text, sage_target_artefact_id text,
  attachment_state text, outstanding_amount_gbp numeric, idempotency_key text,
  duplicate_warning text, blocker text, next_action text, trace_json jsonb, total_count bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    b.closure_row_id, b.closure_lane, b.closure_state,
    b.platform_source_table, b.platform_source_id, b.order_id, b.order_ref,
    b.source_document_ref, b.source_amount_gbp, b.source_approval_state,
    b.sage_object_type, b.sage_object_id, b.sage_reference, b.posted_at,
    b.posting_batch_id, b.posting_batch_ref, b.posting_row_id,
    b.cash_or_credit_allocation_status, b.sage_target_artefact_id,
    b.attachment_state, b.outstanding_amount_gbp, b.idempotency_key,
    b.duplicate_warning,
    CASE WHEN b.closure_lane = 'supplier_credit_note' AND b.closure_state = 'posted_not_closed'
      THEN 'Supplier credit note is posted. It remains open because the refund receipt has not yet been matched and allocated.'
      ELSE b.blocker END AS blocker,
    CASE WHEN b.closure_lane = 'supplier_credit_note' AND b.closure_state = 'posted_not_closed'
      THEN 'Match and allocate the refund receipt'
      ELSE b.next_action END AS next_action,
    CASE WHEN b.closure_lane = 'supplier_credit_note' AND b.closure_state = 'posted_not_closed'
      THEN b.trace_json || jsonb_build_object('closure_model_version','v7_cn_refund_wording','cn_refund_note','Posted CN waits for matched refund receipt')
      ELSE b.trace_json END AS trace_json,
    b.total_count
  FROM public.internal_accounting_closure_control_rows_v2_pre_cn_refund_wording(
    p_lane, p_state, p_search, p_limit, p_offset
  ) b;
$$;

GRANT EXECUTE ON FUNCTION public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer) TO authenticated;
COMMENT ON FUNCTION public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer) IS
'Accounting Closure Control v7: supplier CN open blocker says refund receipt has not yet been matched and allocated.';
NOTIFY pgrst, 'reload schema';
COMMIT;
