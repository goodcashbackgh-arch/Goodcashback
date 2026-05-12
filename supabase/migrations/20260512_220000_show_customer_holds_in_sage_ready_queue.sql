BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regprocedure('public.internal_sage_mapping_configured_v1(text)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_sage_mapping_configured_v1(text)';
  END IF;
  IF to_regprocedure('public.internal_ready_for_sage_queue_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_ready_for_sage_queue_v1()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_customer_tax_ready boolean;
  v_customer_sales_ledger_ready boolean;
  v_shipper_ap_ledger_ready boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: ready for Sage queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for ready for Sage queue.';
  END IF;

  v_customer_tax_ready := public.internal_sage_mapping_configured_v1('ZERO_RATED_EXPORT_TAX_RATE');
  v_customer_sales_ledger_ready := public.internal_sage_mapping_configured_v1('EXPORT_SALE_INCOME_LEDGER');
  v_shipper_ap_ledger_ready := public.internal_sage_mapping_configured_v1('SHIPPER_FREIGHT_COST_LEDGER');

  RETURN QUERY
  WITH base_queue AS (
    SELECT q.*,
      EXISTS (
        SELECT 1
        FROM public.customer_pre_shipment_hold_requests h
        WHERE h.order_id = q.order_id
          AND h.status IN ('requested','supervisor_approved')
      ) AS has_unresolved_customer_hold
    FROM public.internal_ready_for_sage_queue_v1() q
  ), mapped_queue AS (
    SELECT
      q.queue_row_id,
      q.document_lane,
      q.document_type,
      q.source_table,
      q.source_id,
      q.order_id,
      q.order_ref,
      q.shipment_batch_id,
      q.booking_ref,
      q.counterparty_name,
      q.amount_gbp,
      q.currency_code,
      q.invoice_type,
      q.sage_status,
      q.sage_invoice_id,
      q.sage_posted_at,
      CASE
        WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
          THEN 'internally_marked_posted_no_sage_confirmation'
        WHEN q.sage_status = 'posted'
          THEN 'sage_confirmation_recorded'
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN 'blocked_customer_pre_shipment_hold'
        WHEN q.document_lane = 'customer_sales'
          AND q.sage_status = 'draft'
          AND (v_customer_tax_ready IS DISTINCT FROM true OR v_customer_sales_ledger_ready IS DISTINCT FROM true)
          THEN 'blocked_sage_mapping_required'
        WHEN q.document_lane = 'customer_sales'
          AND q.sage_status = 'draft'
          THEN 'ready_for_sage_posting_preview'
        WHEN q.document_lane = 'shipper_ap'
          AND v_shipper_ap_ledger_ready IS DISTINCT FROM true
          THEN 'blocked_sage_mapping_required'
        ELSE q.readiness_status
      END AS readiness_status,
      CASE
        WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
          THEN 'legacy_internal_posted_status_without_sage_confirmation'
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN 'customer_pre_shipment_hold_unresolved'
        WHEN q.document_lane = 'customer_sales'
          AND q.sage_status = 'draft'
          AND (v_customer_tax_ready IS DISTINCT FROM true OR v_customer_sales_ledger_ready IS DISTINCT FROM true)
          THEN concat_ws(', ',
            CASE WHEN v_customer_tax_ready IS DISTINCT FROM true THEN 'missing_zero_rated_export_tax_rate' END,
            CASE WHEN v_customer_sales_ledger_ready IS DISTINCT FROM true THEN 'missing_export_sales_income_ledger' END
          )
        WHEN q.document_lane = 'shipper_ap'
          AND v_shipper_ap_ledger_ready IS DISTINCT FROM true
          THEN 'missing_shipper_freight_cost_ledger'
        ELSE q.blocker
      END AS blocker,
      q.reference_text,
      q.notes_text,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN '/internal/customer-holds'
        WHEN q.document_lane = 'customer_sales'
          AND NULLIF(q.source_payload #>> '{draft_control,shipment_batch_id}', '') IS NOT NULL
          THEN '/internal/shipping-control/customer-invoice/' || (q.source_payload #>> '{draft_control,shipment_batch_id}')
        ELSE q.detail_href
      END AS detail_href,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN COALESCE(q.source_payload, '{}'::jsonb) || jsonb_build_object('customer_hold_blocker', true)
        ELSE q.source_payload
      END AS source_payload
    FROM base_queue q
  )
  SELECT *
  FROM mapped_queue

  UNION ALL

  SELECT
    ('customer_hold:' || h.id::text)::text AS queue_row_id,
    'customer_sales'::text AS document_lane,
    'customer_pre_shipment_hold'::text AS document_type,
    'customer_pre_shipment_hold_requests'::text AS source_table,
    h.id AS source_id,
    h.order_id,
    o.order_ref::text AS order_ref,
    NULL::uuid AS shipment_batch_id,
    NULL::text AS booking_ref,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Customer / importer')::text AS counterparty_name,
    o.order_total_gbp_declared::numeric AS amount_gbp,
    'GBP'::text AS currency_code,
    'customer_sales_hold_blocker'::text AS invoice_type,
    'blocked'::text AS sage_status,
    NULL::text AS sage_invoice_id,
    NULL::timestamptz AS sage_posted_at,
    'blocked_customer_pre_shipment_hold'::text AS readiness_status,
    'customer_pre_shipment_hold_unresolved'::text AS blocker,
    COALESCE(o.order_ref::text, h.order_id::text) AS reference_text,
    ('Customer hold ' || h.status || ' at ' || h.requested_scope || ' scope. ' || COALESCE(NULLIF(h.reason, ''), 'No reason recorded.'))::text AS notes_text,
    '/internal/customer-holds'::text AS detail_href,
    jsonb_build_object(
      'customer_hold_blocker', true,
      'hold_request_id', h.id,
      'hold_status', h.status,
      'requested_scope', h.requested_scope,
      'tracking_submission_id', h.tracking_submission_id,
      'supplier_invoice_line_id', h.supplier_invoice_line_id,
      'reason', h.reason,
      'created_at', h.created_at,
      'supervisor_review_note', h.supervisor_review_note
    ) AS source_payload
  FROM public.customer_pre_shipment_hold_requests h
  JOIN public.orders o ON o.id = h.order_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  WHERE h.status IN ('requested','supervisor_approved')
    AND NOT EXISTS (
      SELECT 1
      FROM mapped_queue mq
      WHERE mq.document_lane = 'customer_sales'
        AND mq.order_id = h.order_id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
