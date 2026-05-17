BEGIN;

-- High-volume accounting command centre grid v1.
-- Contract v3: server-side filtered/paginated grid, default actionable queue, and summary counts.
-- This is read-only. It does not freeze, post, or mutate accounting documents.

CREATE OR REPLACE FUNCTION public.internal_accounting_command_centre_grid_v1(
  p_queue text DEFAULT 'actionable',
  p_lane text DEFAULT 'all',
  p_posting_gate text DEFAULT 'all',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  row_kind text,
  work_queue text,
  queue_row_id text,
  snapshot_id uuid,
  source_table text,
  source_id uuid,
  document_lane text,
  document_type text,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  reference_text text,
  mapping_state text,
  payload_state text,
  freeze_state text,
  revalidation_state text,
  posting_gate text,
  sage_status text,
  batch_ref text,
  idempotency_key text,
  row_created_at timestamptz,
  row_age_hours numeric,
  next_action text,
  next_action_href text,
  selectable boolean,
  selection_group text,
  blocker text,
  warning text,
  total_count bigint,
  summary_counts jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_queue text := COALESCE(NULLIF(p_queue, ''), 'actionable');
  v_lane text := COALESCE(NULLIF(p_lane, ''), 'all');
  v_posting_gate text := COALESCE(NULLIF(p_posting_gate, ''), 'all');
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: accounting command centre grid requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for accounting command centre grid.';
  END IF;

  RETURN QUERY
  WITH frozen_rows AS (
    SELECT
      'frozen_snapshot'::text AS out_row_kind,
      CASE
        WHEN sq.posting_gate_status = 'ready_to_post' THEN 'frozen_ready_to_post'
        WHEN sq.posting_gate_status = 'requires_revalidation' THEN 'requires_revalidation'
        WHEN sq.posting_gate_status = 'blocked_before_posting' THEN 'blocked_before_posting'
        WHEN sq.posting_gate_status = 'posting_failed' THEN 'posting_failed'
        WHEN sq.posting_gate_status = 'posted' OR sq.sage_posting_status = 'posted' THEN 'posted'
        ELSE COALESCE(sq.posting_gate_status, 'frozen')
      END::text AS out_work_queue,
      ('snapshot:' || sq.snapshot_id::text)::text AS out_queue_row_id,
      sq.snapshot_id AS out_snapshot_id,
      sq.source_table AS out_source_table,
      sq.source_id AS out_source_id,
      sq.document_lane AS out_document_lane,
      sq.document_type AS out_document_type,
      sq.order_id AS out_order_id,
      sq.order_ref AS out_order_ref,
      sq.shipment_batch_id AS out_shipment_batch_id,
      sq.booking_ref AS out_booking_ref,
      sq.counterparty_name AS out_counterparty_name,
      sq.amount_gbp AS out_amount_gbp,
      sq.currency_code AS out_currency_code,
      sq.reference_text AS out_reference_text,
      CASE
        WHEN sq.revalidation_status = 'stale_reapproval_required' AND COALESCE(sq.revalidation_notes, '') LIKE '%mapping%' THEN 'mapping_changed_since_approval'
        WHEN sq.revalidation_status = 'ok_to_post' THEN 'mapping_frozen_ok'
        ELSE COALESCE(sq.revalidation_status, 'mapping_unknown')
      END::text AS out_mapping_state,
      CASE
        WHEN sq.revalidation_status = 'stale_reapproval_required' AND COALESCE(sq.revalidation_notes, '') LIKE '%payload%' THEN 'payload_changed_since_approval'
        WHEN sq.revalidation_status = 'blocked_source_not_ready' THEN 'payload_not_ready'
        WHEN sq.revalidation_status = 'ok_to_post' THEN 'payload_frozen_ok'
        ELSE COALESCE(sq.revalidation_status, 'payload_unknown')
      END::text AS out_payload_state,
      sq.approval_status AS out_freeze_state,
      sq.revalidation_status AS out_revalidation_state,
      sq.posting_gate_status AS out_posting_gate,
      sq.sage_posting_status AS out_sage_status,
      sq.batch_ref AS out_batch_ref,
      sq.idempotency_key AS out_idempotency_key,
      sq.approved_at AS out_row_created_at,
      round(extract(epoch from (now() - sq.approved_at)) / 3600.0, 2)::numeric AS out_row_age_hours,
      CASE
        WHEN sq.posting_gate_status = 'ready_to_post' THEN 'Post to Sage later'
        WHEN sq.posting_gate_status = 'requires_revalidation' THEN 'Revalidate snapshot'
        WHEN sq.posting_gate_status = 'blocked_before_posting' THEN 'Resolve blocker or re-approve'
        WHEN sq.posting_gate_status = 'posting_failed' THEN 'Retry failed later'
        WHEN sq.posting_gate_status = 'posted' OR sq.sage_posting_status = 'posted' THEN 'View posted record'
        ELSE 'Review frozen snapshot'
      END::text AS out_next_action,
      ('/internal/accounting-command-centre/snapshots/' || sq.snapshot_id::text)::text AS out_next_action_href,
      false AS out_selectable,
      NULL::text AS out_selection_group,
      sq.posting_gate_blocker AS out_blocker,
      sq.revalidation_notes AS out_warning
    FROM public.internal_sage_posting_snapshot_queue_v1() sq
  ), live_ready AS (
    SELECT
      'live_ready_not_frozen'::text AS out_row_kind,
      'live_ready_not_frozen'::text AS out_work_queue,
      rq.queue_row_id AS out_queue_row_id,
      NULL::uuid AS out_snapshot_id,
      rq.source_table AS out_source_table,
      rq.source_id AS out_source_id,
      rq.document_lane AS out_document_lane,
      rq.document_type AS out_document_type,
      rq.order_id AS out_order_id,
      rq.order_ref AS out_order_ref,
      rq.shipment_batch_id AS out_shipment_batch_id,
      rq.booking_ref AS out_booking_ref,
      rq.counterparty_name AS out_counterparty_name,
      rq.amount_gbp AS out_amount_gbp,
      rq.currency_code AS out_currency_code,
      rq.reference_text AS out_reference_text,
      CASE
        WHEN rq.readiness_status LIKE 'ready%' THEN 'mapping_resolved_or_not_required'
        ELSE 'mapping_review'
      END::text AS out_mapping_state,
      rq.readiness_status AS out_payload_state,
      'not_frozen'::text AS out_freeze_state,
      'not_applicable'::text AS out_revalidation_state,
      'ready_to_freeze'::text AS out_posting_gate,
      rq.sage_status AS out_sage_status,
      NULL::text AS out_batch_ref,
      NULL::text AS out_idempotency_key,
      NULL::timestamptz AS out_row_created_at,
      NULL::numeric AS out_row_age_hours,
      CASE
        WHEN rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices' THEN 'Freeze customer sales'
        WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'
        ELSE 'Resolver required before freeze'
      END::text AS out_next_action,
      '/internal/accounting-command-centre'::text AS out_next_action_href,
      (rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices')
        OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents') AS out_selectable,
      CASE
        WHEN rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices' THEN 'customer_sales'
        WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        ELSE NULL::text
      END AS out_selection_group,
      rq.blocker AS out_blocker,
      rq.notes_text AS out_warning
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
  ), all_rows AS (
    SELECT * FROM live_ready
    UNION ALL
    SELECT * FROM frozen_rows
  ), searched AS (
    SELECT ar.*
    FROM all_rows ar
    WHERE (v_lane = 'all' OR ar.out_document_lane = v_lane)
      AND (v_posting_gate = 'all' OR ar.out_posting_gate = v_posting_gate)
      AND (
        v_search IS NULL
        OR lower(concat_ws(' ',
          ar.out_queue_row_id,
          ar.out_order_ref,
          ar.out_reference_text,
          ar.out_counterparty_name,
          ar.out_document_lane,
          ar.out_document_type,
          ar.out_batch_ref,
          ar.out_idempotency_key,
          ar.out_source_id::text
        )) LIKE ('%' || v_search || '%')
      )
  ), summary AS (
    SELECT jsonb_build_object(
      'live_ready_not_frozen', COUNT(*) FILTER (WHERE s.out_work_queue = 'live_ready_not_frozen'),
      'frozen_ready_to_post', COUNT(*) FILTER (WHERE s.out_work_queue = 'frozen_ready_to_post'),
      'requires_revalidation', COUNT(*) FILTER (WHERE s.out_work_queue = 'requires_revalidation'),
      'blocked_before_posting', COUNT(*) FILTER (WHERE s.out_work_queue = 'blocked_before_posting'),
      'posting_failed', COUNT(*) FILTER (WHERE s.out_work_queue = 'posting_failed'),
      'posted', COUNT(*) FILTER (WHERE s.out_work_queue = 'posted'),
      'selectable', COUNT(*) FILTER (WHERE s.out_selectable = true),
      'total_ready_value', COALESCE(SUM(s.out_amount_gbp) FILTER (WHERE s.out_work_queue = 'frozen_ready_to_post'), 0),
      'filtered_total', COUNT(*)
    ) AS summary_counts
    FROM searched s
  ), queued AS (
    SELECT s.*
    FROM searched s
    WHERE
      v_queue = 'all'
      OR (v_queue = 'actionable' AND s.out_work_queue IN ('live_ready_not_frozen', 'frozen_ready_to_post', 'requires_revalidation', 'blocked_before_posting', 'posting_failed'))
      OR (v_queue = s.out_work_queue)
  ), counted AS (
    SELECT q.*, COUNT(*) OVER () AS out_total_count
    FROM queued q
  ), paged AS (
    SELECT c.*
    FROM counted c
    ORDER BY
      CASE c.out_work_queue
        WHEN 'live_ready_not_frozen' THEN 0
        WHEN 'requires_revalidation' THEN 1
        WHEN 'blocked_before_posting' THEN 2
        WHEN 'posting_failed' THEN 3
        WHEN 'frozen_ready_to_post' THEN 4
        WHEN 'posted' THEN 5
        ELSE 9
      END,
      c.out_order_ref NULLS LAST,
      c.out_reference_text NULLS LAST,
      c.out_source_id NULLS LAST
    LIMIT v_limit OFFSET v_offset
  )
  SELECT
    p.out_row_kind AS row_kind,
    p.out_work_queue AS work_queue,
    p.out_queue_row_id AS queue_row_id,
    p.out_snapshot_id AS snapshot_id,
    p.out_source_table AS source_table,
    p.out_source_id AS source_id,
    p.out_document_lane AS document_lane,
    p.out_document_type AS document_type,
    p.out_order_id AS order_id,
    p.out_order_ref AS order_ref,
    p.out_shipment_batch_id AS shipment_batch_id,
    p.out_booking_ref AS booking_ref,
    p.out_counterparty_name AS counterparty_name,
    p.out_amount_gbp AS amount_gbp,
    p.out_currency_code AS currency_code,
    p.out_reference_text AS reference_text,
    p.out_mapping_state AS mapping_state,
    p.out_payload_state AS payload_state,
    p.out_freeze_state AS freeze_state,
    p.out_revalidation_state AS revalidation_state,
    p.out_posting_gate AS posting_gate,
    p.out_sage_status AS sage_status,
    p.out_batch_ref AS batch_ref,
    p.out_idempotency_key AS idempotency_key,
    p.out_row_created_at AS row_created_at,
    p.out_row_age_hours AS row_age_hours,
    p.out_next_action AS next_action,
    p.out_next_action_href AS next_action_href,
    p.out_selectable AS selectable,
    p.out_selection_group AS selection_group,
    p.out_blocker AS blocker,
    p.out_warning AS warning,
    p.out_total_count AS total_count,
    summary.summary_counts AS summary_counts
  FROM paged p
  CROSS JOIN summary;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_accounting_command_centre_grid_v1(text, text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_accounting_command_centre_grid_v1(text, text, text, text, integer, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
