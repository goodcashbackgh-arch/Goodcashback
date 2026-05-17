BEGIN;

-- Bulk candidate resolver for Accounting Command Centre v3.
-- Supports "selected visible page" vs "all matching current filter" without loading every row into the browser.
-- Read-only. It only returns candidate ids/countable rows for later server actions.

CREATE OR REPLACE FUNCTION public.internal_accounting_command_centre_bulk_candidates_v1(
  p_queue text DEFAULT 'actionable',
  p_lane text DEFAULT 'all',
  p_posting_gate text DEFAULT 'all',
  p_search text DEFAULT NULL,
  p_candidate_kind text DEFAULT 'all',
  p_selection_group text DEFAULT 'all',
  p_include_warnings boolean DEFAULT false,
  p_max_rows integer DEFAULT 5000
)
RETURNS TABLE (
  candidate_kind text,
  selection_group text,
  source_table text,
  source_id uuid,
  snapshot_id uuid,
  document_lane text,
  document_type text,
  order_ref text,
  reference_text text,
  counterparty_name text,
  amount_gbp numeric,
  work_queue text,
  posting_gate text,
  candidate_status text,
  excluded_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_queue text := COALESCE(NULLIF(p_queue, ''), 'actionable');
  v_lane text := COALESCE(NULLIF(p_lane, ''), 'all');
  v_posting_gate text := COALESCE(NULLIF(p_posting_gate, ''), 'all');
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_candidate_kind text := COALESCE(NULLIF(p_candidate_kind, ''), 'all');
  v_selection_group text := COALESCE(NULLIF(p_selection_group, ''), 'all');
  v_max_rows integer := LEAST(GREATEST(COALESCE(p_max_rows, 5000), 1), 10000);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: accounting bulk candidates require auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for accounting bulk candidates.';
  END IF;

  RETURN QUERY
  WITH live_ready AS (
    SELECT
      'freeze'::text AS out_candidate_kind,
      CASE
        WHEN rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices' THEN 'customer_sales'
        WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        ELSE 'unsupported'
      END::text AS out_selection_group,
      rq.source_table AS out_source_table,
      rq.source_id AS out_source_id,
      NULL::uuid AS out_snapshot_id,
      rq.document_lane AS out_document_lane,
      rq.document_type AS out_document_type,
      rq.order_ref AS out_order_ref,
      rq.reference_text AS out_reference_text,
      rq.counterparty_name AS out_counterparty_name,
      rq.amount_gbp AS out_amount_gbp,
      'live_ready_not_frozen'::text AS out_work_queue,
      'ready_to_freeze'::text AS out_posting_gate,
      rq.readiness_status AS out_candidate_status,
      CASE
        WHEN rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices' THEN NULL::text
        WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text
        ELSE 'unsupported_freeze_lane'
      END::text AS out_excluded_reason,
      rq.booking_ref AS out_booking_ref,
      NULL::text AS out_batch_ref,
      NULL::text AS out_idempotency_key
    FROM public.internal_ready_for_sage_queue_v2() rq
    WHERE COALESCE(rq.readiness_status, '') LIKE 'ready%'
      AND NOT EXISTS (
        SELECT 1
        FROM public.sage_posting_snapshots sps
        WHERE sps.active = true
          AND sps.source_table = rq.source_table
          AND sps.source_id = rq.source_id
          AND sps.document_lane = rq.document_lane
          AND sps.approval_status = 'approved_frozen'
          AND sps.sage_posting_status <> 'posted'
      )
  ), frozen_rows AS (
    SELECT
      'revalidate'::text AS out_candidate_kind,
      COALESCE(NULLIF(sq.document_lane, ''), 'unknown')::text AS out_selection_group,
      sq.source_table AS out_source_table,
      sq.source_id AS out_source_id,
      sq.snapshot_id AS out_snapshot_id,
      sq.document_lane AS out_document_lane,
      sq.document_type AS out_document_type,
      sq.order_ref AS out_order_ref,
      sq.reference_text AS out_reference_text,
      sq.counterparty_name AS out_counterparty_name,
      sq.amount_gbp AS out_amount_gbp,
      CASE
        WHEN sq.posting_gate_status = 'ready_to_post' THEN 'frozen_ready_to_post'
        WHEN sq.posting_gate_status = 'requires_revalidation' THEN 'requires_revalidation'
        WHEN sq.posting_gate_status = 'blocked_before_posting' THEN 'blocked_before_posting'
        WHEN sq.posting_gate_status = 'posting_failed' THEN 'posting_failed'
        WHEN sq.posting_gate_status = 'posted' OR sq.sage_posting_status = 'posted' THEN 'posted'
        ELSE COALESCE(sq.posting_gate_status, 'frozen')
      END::text AS out_work_queue,
      sq.posting_gate_status AS out_posting_gate,
      sq.revalidation_status AS out_candidate_status,
      CASE
        WHEN sq.sage_posting_status = 'posted' OR sq.posting_gate_status = 'posted' THEN 'already_posted'
        WHEN sq.revalidation_status = 'warning_only' AND NOT p_include_warnings THEN 'warning_excluded'
        ELSE NULL::text
      END::text AS out_excluded_reason,
      sq.booking_ref AS out_booking_ref,
      sq.batch_ref AS out_batch_ref,
      sq.idempotency_key AS out_idempotency_key
    FROM public.internal_sage_posting_snapshot_queue_v1() sq
  ), all_rows AS (
    SELECT * FROM live_ready
    UNION ALL
    SELECT * FROM frozen_rows
  ), searched AS (
    SELECT ar.*
    FROM all_rows ar
    WHERE (v_lane = 'all' OR ar.out_document_lane = v_lane)
      AND (v_posting_gate = 'all' OR ar.out_posting_gate = v_posting_gate)
      AND (v_candidate_kind = 'all' OR ar.out_candidate_kind = v_candidate_kind)
      AND (v_selection_group = 'all' OR ar.out_selection_group = v_selection_group)
      AND (
        v_search IS NULL
        OR lower(concat_ws(' ',
          ar.out_order_ref,
          ar.out_reference_text,
          ar.out_counterparty_name,
          ar.out_document_lane,
          ar.out_document_type,
          ar.out_batch_ref,
          ar.out_idempotency_key,
          ar.out_source_id::text,
          ar.out_snapshot_id::text,
          ar.out_booking_ref
        )) LIKE ('%' || v_search || '%')
      )
  ), queued AS (
    SELECT s.*
    FROM searched s
    WHERE
      v_queue = 'all'
      OR (v_queue = 'actionable' AND s.out_work_queue IN ('live_ready_not_frozen', 'frozen_ready_to_post', 'requires_revalidation', 'blocked_before_posting', 'posting_failed'))
      OR (v_queue = s.out_work_queue)
  )
  SELECT
    q.out_candidate_kind AS candidate_kind,
    q.out_selection_group AS selection_group,
    q.out_source_table AS source_table,
    q.out_source_id AS source_id,
    q.out_snapshot_id AS snapshot_id,
    q.out_document_lane AS document_lane,
    q.out_document_type AS document_type,
    q.out_order_ref AS order_ref,
    q.out_reference_text AS reference_text,
    q.out_counterparty_name AS counterparty_name,
    q.out_amount_gbp AS amount_gbp,
    q.out_work_queue AS work_queue,
    q.out_posting_gate AS posting_gate,
    q.out_candidate_status AS candidate_status,
    q.out_excluded_reason AS excluded_reason
  FROM queued q
  ORDER BY
    CASE q.out_candidate_kind WHEN 'freeze' THEN 0 WHEN 'revalidate' THEN 1 ELSE 2 END,
    q.out_order_ref NULLS LAST,
    q.out_source_id NULLS LAST,
    q.out_snapshot_id NULLS LAST
  LIMIT v_max_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_accounting_command_centre_bulk_candidates_v1(text, text, text, text, text, text, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_accounting_command_centre_bulk_candidates_v1(text, text, text, text, text, text, boolean, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
