BEGIN;

-- Accounting Closure Control v10.
-- Fixes the final-state filter bug introduced by read-only closure wrappers.
-- Earlier wrappers can change rows from posted_not_closed -> posted_closed after the older
-- resolver has already applied p_state. Therefore filtering by posted_closed could hide rows
-- that the all-view correctly counted as posted_closed.
--
-- This wrapper always asks the prior resolver for all states, then applies p_state after all
-- v8/v9 closure patches have produced the final closure_state.
-- No Sage API calls. No posting. No allocation. Read-only filtering patch only.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing prerequisite function internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)';
  END IF;

  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2_pre_final_state_filter(text,text,text,integer,integer)') IS NULL THEN
    ALTER FUNCTION public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)
      RENAME TO internal_accounting_closure_control_rows_v2_pre_final_state_filter;
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
DECLARE
  v_state text := lower(COALESCE(NULLIF(trim(p_state), ''), 'all'));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: accounting closure control requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for accounting closure control.';
  END IF;

  RETURN QUERY
  WITH all_patched_rows AS (
    SELECT *
    FROM public.internal_accounting_closure_control_rows_v2_pre_final_state_filter(
      p_lane,
      'all',
      p_search,
      300,
      0
    )
  ), final_filtered AS (
    SELECT r.*
    FROM all_patched_rows r
    WHERE v_state = 'all' OR lower(r.closure_state) = v_state
  ), final_ranked AS (
    SELECT
      r.*,
      count(*) OVER () AS final_total_count
    FROM final_filtered r
  )
  SELECT
    r.closure_row_id,
    r.closure_lane,
    r.closure_state,
    r.platform_source_table,
    r.platform_source_id,
    r.order_id,
    r.order_ref,
    r.source_document_ref,
    r.source_amount_gbp,
    r.source_approval_state,
    r.sage_object_type,
    r.sage_object_id,
    r.sage_reference,
    r.posted_at,
    r.posting_batch_id,
    r.posting_batch_ref,
    r.posting_row_id,
    r.cash_or_credit_allocation_status,
    r.sage_target_artefact_id,
    r.attachment_state,
    r.outstanding_amount_gbp,
    r.idempotency_key,
    r.duplicate_warning,
    r.blocker,
    r.next_action,
    r.trace_json || jsonb_build_object(
      'closure_model_version_v10', 'final_state_filter_after_patch',
      'requested_state_filter', v_state,
      'state_filter_applied_after_patch', true
    ) AS trace_json,
    r.final_total_count AS total_count
  FROM final_ranked r
  ORDER BY
    CASE r.closure_state
      WHEN 'duplicate_risk' THEN 1
      WHEN 'failed' THEN 2
      WHEN 'posted_needs_review' THEN 3
      WHEN 'posted_not_closed' THEN 4
      WHEN 'ready_for_posting' THEN 5
      WHEN 'blocked' THEN 6
      WHEN 'posted_closed' THEN 7
      ELSE 8
    END,
    r.posted_at DESC NULLS LAST,
    r.source_document_ref NULLS LAST,
    r.closure_row_id
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) IS
'Accounting Closure Control v10: applies p_state after all read-only closure patches have produced the final closure_state.';

NOTIFY pgrst, 'reload schema';

COMMIT;
