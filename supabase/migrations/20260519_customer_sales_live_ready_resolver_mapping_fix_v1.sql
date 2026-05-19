BEGIN;

-- Customer sales live-ready resolver fix.
--
-- Problem:
--   Some legacy sales_invoices.line_items_json rows still carry:
--     tax_resolution.sage_tax_rate_resolution_required = true
--   even though the current Sage mapping settings now have the required
--   customer-sales tax/ledger mappings configured.
--
-- Effect:
--   internal_ready_for_sage_queue_v1 classifies those sales invoices as
--   blocked_sage_tax_mapping_required, so the Accounting Command Centre
--   Actionable grid hides them from live_ready_not_frozen.
--
-- Fix:
--   v2 becomes the current resolver wrapper for customer sales. It uses
--   internal_resolved_customer_sales_sage_payload_v1() and live
--   sage_mapping_settings, instead of trusting stale commercial draft JSON.
--
-- No Sage API call. No source invoice deletion. No posting state mutation.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_resolved_customer_sales_sage_payload_v1(uuid)';
  END IF;
  IF to_regprocedure('public.internal_ready_for_sage_queue_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_ready_for_sage_queue_v1()';
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: ready for Sage queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for ready for Sage queue.';
  END IF;

  RETURN QUERY
  WITH base AS (
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
        WHEN q.document_lane = 'customer_sales'
          AND r.sales_invoice_id IS NOT NULL
        THEN r.payload_status
        WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'internally_marked_posted_no_sage_confirmation'
        WHEN q.sage_status = 'posted'
        THEN 'sage_confirmation_recorded'
        ELSE q.readiness_status
      END::text AS readiness_status,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND r.sales_invoice_id IS NOT NULL
        THEN r.blocker
        WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'legacy_internal_posted_status_without_sage_confirmation'
        ELSE q.blocker
      END::text AS blocker,
      COALESCE(r.reference_text, q.reference_text)::text AS reference_text,
      COALESCE(NULLIF(r.notes_text, ''), q.notes_text)::text AS notes_text,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND NULLIF(COALESCE(r.resolved_payload #>> '{commercial_payload,draft_control,shipment_batch_id}', q.source_payload #>> '{draft_control,shipment_batch_id}', ''), '') IS NOT NULL
        THEN '/internal/shipping-control/customer-invoice/' || COALESCE(r.resolved_payload #>> '{commercial_payload,draft_control,shipment_batch_id}', q.source_payload #>> '{draft_control,shipment_batch_id}')
        ELSE q.detail_href
      END::text AS detail_href,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND r.sales_invoice_id IS NOT NULL
        THEN r.resolved_payload
        ELSE q.source_payload
      END::jsonb AS source_payload
    FROM public.internal_ready_for_sage_queue_v1() q
    LEFT JOIN LATERAL public.internal_resolved_customer_sales_sage_payload_v1(q.source_id) r
      ON q.document_lane = 'customer_sales'
     AND q.source_table = 'sales_invoices'
  )
  SELECT
    b.queue_row_id,
    b.document_lane,
    b.document_type,
    b.source_table,
    b.source_id,
    b.order_id,
    b.order_ref,
    b.shipment_batch_id,
    b.booking_ref,
    b.counterparty_name,
    b.amount_gbp,
    b.currency_code,
    b.invoice_type,
    b.sage_status,
    b.sage_invoice_id,
    b.sage_posted_at,
    b.readiness_status,
    b.blocker,
    b.reference_text,
    CASE
      WHEN COALESCE(b.source_payload->>'customer_hold_blocker', 'false') = 'true'
        OR b.document_type = 'customer_pre_shipment_hold'
        OR b.blocker = 'customer_pre_shipment_hold_unresolved'
      THEN concat_ws(' ',
        CASE
          WHEN counts.requested_count > 0 THEN
            counts.approved_count::text || ' approved and ' || counts.requested_count::text || ' requested customer hold(s) remain unresolved.'
          ELSE
            COALESCE(NULLIF(counts.approved_count, 0), counts.active_count)::text || ' approved customer hold(s) remain unresolved.'
        END,
        CASE
          WHEN NULLIF(scope.scope_text, '') IS NOT NULL THEN 'Scope: ' || scope.scope_text || '.'
        END,
        CASE
          WHEN NULLIF(reasons.reason_text, '') IS NOT NULL THEN 'Reason: ' || reasons.reason_text || '.'
        END
      )
      ELSE b.notes_text
    END AS notes_text,
    b.detail_href,
    b.source_payload
  FROM base b
  LEFT JOIN LATERAL (
    SELECT
      COALESCE(NULLIF(b.source_payload->>'active_hold_count','')::int, 0) AS active_count,
      COALESCE(NULLIF(b.source_payload->>'approved_hold_count','')::int, 0) AS approved_count,
      COALESCE(NULLIF(b.source_payload->>'requested_hold_count','')::int, 0) AS requested_count,
      COALESCE(NULLIF(b.source_payload->>'line_hold_count','')::int, 0) AS line_count,
      COALESCE(NULLIF(b.source_payload->>'tracking_hold_count','')::int, 0) AS tracking_count,
      COALESCE(NULLIF(b.source_payload->>'order_hold_count','')::int, 0) AS order_count
  ) counts ON true
  LEFT JOIN LATERAL (
    SELECT concat_ws(', ',
      CASE WHEN counts.line_count > 0 THEN counts.line_count::text || ' line-level hold(s)' END,
      CASE WHEN counts.tracking_count > 0 THEN counts.tracking_count::text || ' tracking hold(s)' END,
      CASE WHEN counts.order_count > 0 THEN counts.order_count::text || ' order hold(s)' END
    ) AS scope_text
  ) scope ON true
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT NULLIF(btrim(reason), ''), ' | ' ORDER BY NULLIF(btrim(reason), '')) AS reason_text
    FROM jsonb_to_recordset(COALESCE(b.source_payload->'hold_rows', '[]'::jsonb)) AS hold_row(reason text)
  ) reasons ON true;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
