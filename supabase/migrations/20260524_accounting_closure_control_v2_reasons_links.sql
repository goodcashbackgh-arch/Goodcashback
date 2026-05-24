BEGIN;

-- Accounting Closure Control v2.
-- Read-only refinement: clearer not-closed reasons, supplier credit-note settlement wording,
-- and drill-down hrefs in trace_json. No posting/allocation/endpoint expansion.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_accounting_closure_control_rows_v1(
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
  v_lane text := lower(COALESCE(NULLIF(trim(p_lane), ''), 'all'));
  v_state text := lower(COALESCE(NULLIF(trim(p_state), ''), 'all'));
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
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
  WITH sage_rows AS (
    SELECT
      ('sage:' || s.id::text)::text AS closure_row_id,
      s.document_lane::text AS closure_lane,
      s.source_table::text AS platform_source_table,
      s.source_id AS platform_source_id,
      s.order_id,
      s.order_ref::text AS order_ref,
      COALESCE(NULLIF(s.reference_text, ''), NULLIF(s.order_ref, ''), s.source_id::text)::text AS source_document_ref,
      s.amount_gbp::numeric AS source_amount_gbp,
      concat_ws(' / ', s.approval_status, s.revalidation_status, COALESCE(br.payload_validation_status, NULL))::text AS source_approval_state,
      COALESCE(br.sage_object_type,
        CASE
          WHEN s.document_lane = 'customer_sales' THEN 'sales_invoice'
          WHEN s.document_lane IN ('supplier_goods_ap','shipper_ap') THEN 'purchase_invoice'
          WHEN s.document_lane = 'supplier_credit_note' THEN 'purchase_credit_note'
          ELSE s.document_type
        END
      )::text AS sage_object_type,
      COALESCE(NULLIF(br.sage_object_id, ''), NULLIF(s.sage_invoice_id, ''))::text AS sage_object_id,
      COALESCE(NULLIF(br.sage_reference, ''), NULLIF(s.reference_text, ''))::text AS sage_reference,
      COALESCE(br.posted_at, s.sage_posted_at) AS posted_at,
      s.batch_id AS posting_batch_id,
      b.batch_ref::text AS posting_batch_ref,
      br.id AS posting_row_id,
      CASE
        WHEN s.document_lane = 'supplier_credit_note'
          AND COALESCE(br.posting_status, s.sage_posting_status) IN ('posted','posted_needs_review')
          AND COALESCE(alloc.allocation_status, '') = ''
          THEN 'credit_note_posted_settlement_unproven'
        ELSE COALESCE(alloc.allocation_status, 'not_assessed_v2')
      END::text AS cash_or_credit_allocation_status,
      alloc.target_object_id::text AS sage_target_artefact_id,
      CASE
        WHEN s.document_lane = 'supplier_credit_note' THEN 'source_attachment_not_proven_in_closure_v2'
        WHEN s.document_lane IN ('supplier_goods_ap','shipper_ap') THEN 'source_attachment_not_proven_in_closure_v2'
        ELSE 'not_applicable'
      END::text AS attachment_state,
      NULL::numeric AS outstanding_amount_gbp,
      s.idempotency_key::text,
      COALESCE(br.posting_status, s.sage_posting_status)::text AS raw_posting_status,
      s.sage_posting_status::text AS snapshot_posting_status,
      COALESCE(br.error_message, s.last_posting_error)::text AS raw_error,
      ('/internal/accounting-command-centre/batches/' || s.batch_id::text)::text AS detail_href,
      jsonb_build_object(
        'source_kind', 'sage_posting_snapshot',
        'snapshot_id', s.id,
        'batch_id', s.batch_id,
        'batch_ref', b.batch_ref,
        'batch_row_id', br.id,
        'action_href', ('/internal/accounting-command-centre/batches/' || s.batch_id::text),
        'source_table', s.source_table,
        'source_id', s.source_id,
        'document_lane', s.document_lane,
        'document_type', s.document_type,
        'approval_status', s.approval_status,
        'revalidation_status', s.revalidation_status,
        'snapshot_sage_posting_status', s.sage_posting_status,
        'row_posting_status', br.posting_status,
        'sage_object_type', br.sage_object_type,
        'sage_object_id', COALESCE(br.sage_object_id, s.sage_invoice_id),
        'sage_reference', br.sage_reference,
        'allocation_status', alloc.allocation_status,
        'allocation_target_object_id', alloc.target_object_id,
        'closure_contract', 'ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1',
        'closure_model_version', 'v2_reasons_links'
      ) AS trace_json
    FROM public.sage_posting_snapshots s
    JOIN public.sage_posting_batches b ON b.id = s.batch_id
    LEFT JOIN LATERAL (
      SELECT r.*
      FROM public.sage_posting_batch_rows r
      WHERE r.snapshot_id = s.id
        AND r.posting_status <> 'excluded'
      ORDER BY r.created_at DESC, r.id DESC
      LIMIT 1
    ) br ON true
    LEFT JOIN LATERAL (
      SELECT
        string_agg(DISTINCT COALESCE(NULLIF(cbr.sage_allocation_status, ''), NULLIF(cps.sage_allocation_status, ''), 'not_allocated'), ', ') AS allocation_status,
        max(COALESCE(cbr.sage_allocation_target_object_id, cps.sage_allocation_target_object_id)) AS target_object_id,
        sum(COALESCE(cbr.sage_allocation_amount_gbp, cps.sage_allocation_amount_gbp, 0)) AS allocated_amount
      FROM public.cash_posting_batch_rows cbr
      JOIN public.cash_posting_snapshots cps ON cps.id = cbr.snapshot_id AND cps.active = true
      WHERE cbr.active = true
        AND cbr.posting_status IN ('posted','posted_needs_review')
        AND COALESCE(cbr.sage_allocation_target_object_id, cps.sage_allocation_target_object_id) = COALESCE(NULLIF(br.sage_object_id, ''), NULLIF(s.sage_invoice_id, ''))
    ) alloc ON true
    WHERE s.active = true
  ), cash_rows AS (
    SELECT
      ('cash:' || c.id::text)::text AS closure_row_id,
      c.posting_category::text AS closure_lane,
      c.source_type::text AS platform_source_table,
      c.source_id AS platform_source_id,
      c.order_id,
      c.order_ref::text AS order_ref,
      COALESCE(NULLIF(c.short_reference, ''), NULLIF(c.order_ref, ''), c.source_id::text)::text AS source_document_ref,
      c.amount_gbp::numeric AS source_amount_gbp,
      concat_ws(' / ', c.freeze_status, c.validation_status, COALESCE(cbr.validation_status, NULL))::text AS source_approval_state,
      COALESCE(cbr.sage_object_type, 'contact_payment')::text AS sage_object_type,
      COALESCE(NULLIF(cbr.sage_object_id, ''), NULLIF(c.sage_object_id, ''))::text AS sage_object_id,
      cbr.sage_reference::text AS sage_reference,
      cbr.posted_at AS posted_at,
      cb.id AS posting_batch_id,
      cb.batch_ref::text AS posting_batch_ref,
      cbr.id AS posting_row_id,
      COALESCE(cbr.sage_allocation_status, c.sage_allocation_status, 'not_allocated')::text AS cash_or_credit_allocation_status,
      COALESCE(cbr.sage_allocation_target_object_id, c.sage_allocation_target_object_id)::text AS sage_target_artefact_id,
      'not_applicable'::text AS attachment_state,
      NULL::numeric AS outstanding_amount_gbp,
      c.idempotency_key::text,
      COALESCE(cbr.posting_status, c.sage_posting_status)::text AS raw_posting_status,
      c.sage_posting_status::text AS snapshot_posting_status,
      COALESCE(cbr.error_message, c.sage_allocation_error_message)::text AS raw_error,
      ('/internal/accounting-command-centre/cash-posting/batches/' || cb.id::text)::text AS detail_href,
      jsonb_build_object(
        'source_kind', 'cash_posting_snapshot',
        'snapshot_id', c.id,
        'batch_id', cb.id,
        'batch_ref', cb.batch_ref,
        'batch_row_id', cbr.id,
        'action_href', ('/internal/accounting-command-centre/cash-posting/batches/' || cb.id::text),
        'posting_category', c.posting_category,
        'source_type', c.source_type,
        'source_id', c.source_id,
        'statement_line_id', c.statement_line_id,
        'order_id', c.order_id,
        'order_ref', c.order_ref,
        'sage_object_id', COALESCE(cbr.sage_object_id, c.sage_object_id),
        'sage_payment_on_account_id', COALESCE(cbr.sage_payment_on_account_id, c.sage_payment_on_account_id),
        'sage_allocation_status', COALESCE(cbr.sage_allocation_status, c.sage_allocation_status),
        'sage_allocation_target_object_id', COALESCE(cbr.sage_allocation_target_object_id, c.sage_allocation_target_object_id),
        'closure_contract', 'ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1',
        'closure_model_version', 'v2_reasons_links'
      ) AS trace_json
    FROM public.cash_posting_snapshots c
    LEFT JOIN LATERAL (
      SELECT r.*
      FROM public.cash_posting_batch_rows r
      WHERE r.snapshot_id = c.id
        AND r.active = true
      ORDER BY r.created_at DESC, r.id DESC
      LIMIT 1
    ) cbr ON true
    LEFT JOIN public.cash_posting_batches cb ON cb.id = cbr.batch_id AND cb.active = true
    WHERE c.active = true
  ), all_rows AS (
    SELECT * FROM sage_rows
    UNION ALL
    SELECT * FROM cash_rows
  ), assessed AS (
    SELECT
      ar.*,
      count(*) OVER (PARTITION BY ar.idempotency_key) AS idempotency_seen_count,
      CASE
        WHEN count(*) OVER (PARTITION BY ar.idempotency_key) > 1 THEN 'duplicate_risk'
        WHEN ar.raw_posting_status LIKE 'failed%' OR ar.snapshot_posting_status IN ('posting_failed') THEN 'failed'
        WHEN ar.raw_posting_status IN ('posted','posted_needs_review') OR ar.snapshot_posting_status = 'posted' THEN
          CASE
            WHEN NULLIF(trim(COALESCE(ar.sage_object_id, '')), '') IS NULL THEN 'posted_needs_review'
            WHEN ar.closure_lane IN ('supplier_invoice_payment','shipper_invoice_payment') AND ar.cash_or_credit_allocation_status LIKE 'allocated%' THEN 'posted_closed'
            WHEN ar.closure_lane IN ('supplier_goods_ap','shipper_ap') AND ar.cash_or_credit_allocation_status LIKE 'allocated%' THEN 'posted_closed'
            ELSE 'posted_not_closed'
          END
        WHEN ar.raw_posting_status IN ('included','validated','not_posted') OR ar.source_approval_state ILIKE '%ok_to_post%' OR ar.source_approval_state ILIKE '%validated%' THEN 'ready_for_posting'
        WHEN ar.raw_posting_status IS NULL THEN 'not_reached'
        ELSE 'blocked'
      END::text AS calculated_state,
      CASE
        WHEN count(*) OVER (PARTITION BY ar.idempotency_key) > 1 THEN 'Duplicate idempotency key appears in the closure set.'
        ELSE NULL::text
      END AS calculated_duplicate_warning
    FROM all_rows ar
  ), final_rows AS (
    SELECT
      a.*,
      CASE
        WHEN a.calculated_state = 'duplicate_risk' THEN 'Duplicate/idempotency risk. Do not treat as closed until duplicate source/posting is resolved.'
        WHEN a.calculated_state = 'failed' THEN COALESCE(NULLIF(a.raw_error, ''), 'Posting failed. Open the batch detail and inspect Sage request/response.')
        WHEN a.calculated_state = 'posted_needs_review' THEN 'Posted/accepted state exists, but the Sage object id or required artefact id is missing.'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane = 'supplier_credit_note' THEN 'Supplier credit note is posted to Sage, but settlement/allocation against the intended purchase invoice is not proven in platform closure data.'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane = 'customer_receipt_on_account' THEN 'Customer receipt/contact payment is posted, but allocation from payment-on-account to the final sales invoice is not proven yet.'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane = 'customer_sales' THEN 'Customer sales invoice is posted, but receipt/allocation closure against the Sage sales invoice is not proven yet.'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane = 'supplier_goods_ap' THEN 'Supplier goods purchase invoice is posted, but supplier payment allocation/settlement is not linked back to this Sage purchase invoice.'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane = 'shipper_ap' THEN 'Shipper purchase invoice is posted, but shipper payment allocation/settlement is not linked back to this Sage purchase invoice.'
        WHEN a.calculated_state = 'posted_not_closed' THEN 'Posted, but allocation/settlement/attachment/source-update closure is not fully proven.'
        WHEN a.calculated_state = 'ready_for_posting' THEN 'Ready or frozen/validated. Closure waits for posting result.'
        WHEN a.calculated_state = 'blocked' THEN COALESCE(NULLIF(a.raw_error, ''), 'Blocked or stale. Inspect source approval/revalidation state.')
        ELSE NULL::text
      END AS calculated_blocker,
      CASE
        WHEN a.calculated_state = 'posted_closed' THEN 'No action'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane = 'supplier_credit_note' THEN 'Prove supplier credit note settlement/allocation'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane IN ('customer_receipt_on_account','customer_sales') THEN 'Prove customer receipt-to-sales allocation'
        WHEN a.calculated_state = 'posted_not_closed' AND a.closure_lane IN ('supplier_goods_ap','shipper_ap') THEN 'Prove AP payment allocation'
        WHEN a.calculated_state = 'posted_needs_review' THEN 'Review Sage response / artefact id'
        WHEN a.calculated_state = 'duplicate_risk' THEN 'Resolve duplicate risk'
        WHEN a.calculated_state = 'failed' THEN 'Review failed posting'
        WHEN a.calculated_state = 'ready_for_posting' THEN 'Post via existing batch flow'
        ELSE 'Inspect source state'
      END::text AS calculated_next_action
    FROM assessed a
  ), filtered AS (
    SELECT f.*
    FROM final_rows f
    WHERE (v_lane = 'all' OR lower(f.closure_lane) = v_lane)
      AND (v_state = 'all' OR lower(f.calculated_state) = v_state)
      AND (
        v_search IS NULL OR lower(concat_ws(' ',
          f.closure_lane,
          f.calculated_state,
          f.platform_source_table,
          f.platform_source_id::text,
          f.order_ref,
          f.source_document_ref,
          f.sage_object_type,
          f.sage_object_id,
          f.sage_reference,
          f.posting_batch_ref,
          f.idempotency_key,
          f.raw_error
        )) LIKE '%' || v_search || '%'
      )
  )
  SELECT
    f.closure_row_id,
    f.closure_lane,
    f.calculated_state AS closure_state,
    f.platform_source_table,
    f.platform_source_id,
    f.order_id,
    f.order_ref,
    f.source_document_ref,
    f.source_amount_gbp,
    f.source_approval_state,
    f.sage_object_type,
    f.sage_object_id,
    f.sage_reference,
    f.posted_at,
    f.posting_batch_id,
    f.posting_batch_ref,
    f.posting_row_id,
    f.cash_or_credit_allocation_status,
    f.sage_target_artefact_id,
    f.attachment_state,
    f.outstanding_amount_gbp,
    f.idempotency_key,
    f.calculated_duplicate_warning AS duplicate_warning,
    f.calculated_blocker AS blocker,
    f.calculated_next_action AS next_action,
    f.trace_json,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY
    CASE f.calculated_state
      WHEN 'duplicate_risk' THEN 1
      WHEN 'failed' THEN 2
      WHEN 'posted_needs_review' THEN 3
      WHEN 'posted_not_closed' THEN 4
      WHEN 'ready_for_posting' THEN 5
      WHEN 'blocked' THEN 6
      WHEN 'posted_closed' THEN 7
      ELSE 8
    END,
    f.posted_at DESC NULLS LAST,
    f.source_document_ref NULLS LAST,
    f.closure_row_id
  LIMIT v_limit OFFSET v_offset;
END;
$$;

COMMENT ON FUNCTION public.internal_accounting_closure_control_rows_v1(text, text, text, integer, integer) IS
'Accounting Closure Control v2 read-only rows: clearer closure reasons, supplier CN settlement wording, and detail hrefs inside trace_json. No writes.';

NOTIFY pgrst, 'reload schema';

COMMIT;
