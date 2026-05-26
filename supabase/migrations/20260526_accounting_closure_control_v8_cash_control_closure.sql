BEGIN;

-- Accounting Closure Control v8.
-- Page-safe wrapper over the current v2 resolver.
-- Fixes two closure contradictions:
-- 1) Bank fee / FX-card control cash rows do not require document allocation, so a posted Sage object is closed.
-- 2) AP document rows must close when any posted cash row proves allocation to their Sage artefact id,
--    even if the older closure resolver did not pick up the target from the latest cash row shape.
-- No Sage API calls. No posting. No allocation. Read-only diagnostic patch only.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing prerequisite function internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)';
  END IF;

  IF to_regprocedure('public.internal_accounting_closure_control_rows_v2_pre_cash_control_closure(text,text,text,integer,integer)') IS NULL THEN
    ALTER FUNCTION public.internal_accounting_closure_control_rows_v2(text,text,text,integer,integer)
      RENAME TO internal_accounting_closure_control_rows_v2_pre_cash_control_closure;
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
    FROM public.internal_accounting_closure_control_rows_v2_pre_cash_control_closure(
      p_lane, p_state, p_search, p_limit, p_offset
    )
  ), patched AS (
    SELECT
      b.*,
      cash_match.matched_cash_row_count,
      cash_match.matched_cash_allocation_status,
      cash_match.matched_cash_payment_id,
      cash_match.matched_cash_target_id,
      cash_match.matched_cash_batch_ref,
      (
        b.closure_lane IN ('bank_fee','fx_card_difference')
        AND b.closure_state = 'posted_not_closed'
        AND NULLIF(trim(COALESCE(b.sage_object_id, '')), '') IS NOT NULL
      ) AS is_closed_cash_control_row,
      (
        b.closure_lane IN ('supplier_goods_ap','shipper_ap')
        AND b.closure_state IN ('posted_not_closed','posted_needs_review')
        AND NULLIF(trim(COALESCE(b.sage_object_id, '')), '') IS NOT NULL
        AND COALESCE(cash_match.matched_cash_row_count, 0) > 0
      ) AS is_closed_ap_by_cash_target
    FROM base b
    LEFT JOIN LATERAL (
      SELECT
        count(*)::integer AS matched_cash_row_count,
        string_agg(DISTINCT COALESCE(NULLIF(cbr.sage_allocation_status, ''), NULLIF(cps.sage_allocation_status, ''), 'allocated_in_contact_payment'), ', ' ORDER BY COALESCE(NULLIF(cbr.sage_allocation_status, ''), NULLIF(cps.sage_allocation_status, ''), 'allocated_in_contact_payment'))::text AS matched_cash_allocation_status,
        max(COALESCE(NULLIF(cbr.sage_object_id, ''), NULLIF(cps.sage_object_id, '')))::text AS matched_cash_payment_id,
        max(COALESCE(NULLIF(cbr.sage_allocation_target_object_id, ''), NULLIF(cps.sage_allocation_target_object_id, '')))::text AS matched_cash_target_id,
        max(cb.batch_ref)::text AS matched_cash_batch_ref
      FROM public.cash_posting_batch_rows cbr
      JOIN public.cash_posting_snapshots cps ON cps.id = cbr.snapshot_id AND cps.active = true
      LEFT JOIN public.cash_posting_batches cb ON cb.id = cbr.batch_id AND cb.active = true
      WHERE b.closure_lane IN ('supplier_goods_ap','shipper_ap')
        AND cbr.active = true
        AND cbr.posting_status IN ('posted','posted_needs_review')
        AND NULLIF(trim(COALESCE(b.sage_object_id, '')), '') IS NOT NULL
        AND (
          COALESCE(NULLIF(cbr.sage_allocation_target_object_id, ''), NULLIF(cps.sage_allocation_target_object_id, '')) = b.sage_object_id
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
              CASE
                WHEN jsonb_typeof(COALESCE(cbr.sage_allocation_request_payload, cbr.request_payload, cps.sage_allocation_request_payload, cps.request_payload, '{}'::jsonb) #> '{contact_payment,allocated_artefacts}') = 'array'
                  THEN COALESCE(cbr.sage_allocation_request_payload, cbr.request_payload, cps.sage_allocation_request_payload, cps.request_payload, '{}'::jsonb) #> '{contact_payment,allocated_artefacts}'
                ELSE '[]'::jsonb
              END
            ) AS artefact(row_json)
            WHERE artefact.row_json->>'artefact_id' = b.sage_object_id
          )
        )
    ) cash_match ON true
  )
  SELECT
    p.closure_row_id,
    p.closure_lane,
    CASE
      WHEN p.is_closed_cash_control_row OR p.is_closed_ap_by_cash_target THEN 'posted_closed'
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
      WHEN p.is_closed_cash_control_row THEN 'not_applicable_control_posting_closed'
      WHEN p.is_closed_ap_by_cash_target THEN COALESCE(p.matched_cash_allocation_status, 'allocated_in_contact_payment')
      ELSE p.cash_or_credit_allocation_status
    END AS cash_or_credit_allocation_status,
    CASE
      WHEN p.is_closed_ap_by_cash_target THEN COALESCE(p.sage_target_artefact_id, p.matched_cash_target_id, p.sage_object_id)
      ELSE p.sage_target_artefact_id
    END AS sage_target_artefact_id,
    p.attachment_state,
    p.outstanding_amount_gbp,
    p.idempotency_key,
    p.duplicate_warning,
    CASE
      WHEN p.is_closed_cash_control_row OR p.is_closed_ap_by_cash_target THEN NULL::text
      ELSE p.blocker
    END AS blocker,
    CASE
      WHEN p.is_closed_cash_control_row OR p.is_closed_ap_by_cash_target THEN 'No action'
      ELSE p.next_action
    END AS next_action,
    p.trace_json || jsonb_build_object(
      'closure_model_version_v8', 'cash_control_and_ap_target_closure',
      'v8_closed_cash_control_row', p.is_closed_cash_control_row,
      'v8_closed_ap_by_cash_target', p.is_closed_ap_by_cash_target,
      'matched_cash_row_count', p.matched_cash_row_count,
      'matched_cash_allocation_status', p.matched_cash_allocation_status,
      'matched_cash_payment_id', p.matched_cash_payment_id,
      'matched_cash_target_id', p.matched_cash_target_id,
      'matched_cash_batch_ref', p.matched_cash_batch_ref
    ) AS trace_json,
    p.total_count
  FROM patched p;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_accounting_closure_control_rows_v2(text, text, text, integer, integer) IS
'Accounting Closure Control v8: closes bank fee/FX control postings with Sage objects and AP rows proven by posted cash allocation target artefacts.';

NOTIFY pgrst, 'reload schema';

COMMIT;
