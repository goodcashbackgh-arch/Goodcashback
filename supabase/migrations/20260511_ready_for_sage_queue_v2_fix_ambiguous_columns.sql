BEGIN;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v1()
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
  WITH customer_sales AS (
    SELECT
      ('sales_invoice:' || si.id::text)::text AS out_queue_row_id,
      'customer_sales'::text AS out_document_lane,
      CASE
        WHEN si.invoice_type = 'main' THEN 'customer_sales_invoice'
        WHEN si.invoice_type = 'supplementary' THEN 'customer_supplementary_invoice'
        WHEN si.invoice_type = 'credit_note' THEN 'customer_credit_note'
        ELSE ('customer_' || si.invoice_type::text)
      END::text AS out_document_type,
      'sales_invoices'::text AS out_source_table,
      si.id AS out_source_id,
      si.order_id AS out_order_id,
      o.order_ref::text AS out_order_ref,
      NULL::uuid AS out_shipment_batch_id,
      COALESCE(si.line_items_json #>> '{sage_header,notes}', '')::text AS out_booking_ref,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Customer')::text AS out_counterparty_name,
      si.amount_gbp AS out_amount_gbp,
      'GBP'::text AS out_currency_code,
      si.invoice_type::text AS out_invoice_type,
      si.sage_status::text AS out_sage_status,
      si.sage_invoice_id::text AS out_sage_invoice_id,
      si.sage_posted_at AS out_sage_posted_at,
      CASE
        WHEN si.sage_status = 'draft'
          AND si.sage_invoice_id IS NULL
          AND si.sage_posted_at IS NULL
          AND COALESCE(si.line_items_json #>> '{tax_resolution,sage_tax_rate_resolution_required}', 'true') = 'true'
          THEN 'blocked_sage_tax_mapping_required'
        WHEN si.sage_status = 'draft'
          AND si.sage_invoice_id IS NULL
          AND si.sage_posted_at IS NULL
          THEN 'ready_for_sage_posting_preview'
        WHEN si.sage_status = 'posted' THEN 'posted_to_sage_or_marked_posted'
        WHEN si.sage_status = 'void' THEN 'voided_no_action'
        ELSE 'needs_review'
      END::text AS out_readiness_status,
      CASE
        WHEN si.sage_status = 'draft'
          AND si.sage_invoice_id IS NULL
          AND si.sage_posted_at IS NULL
          AND COALESCE(si.line_items_json #>> '{tax_resolution,sage_tax_rate_resolution_required}', 'true') = 'true'
          THEN 'sage_tax_rate_id_not_resolved'
        ELSE NULL::text
      END AS out_blocker,
      COALESCE(si.line_items_json #>> '{sage_header,reference}', o.order_ref::text)::text AS out_reference_text,
      COALESCE(si.line_items_json #>> '{sage_header,notes}', '')::text AS out_notes_text,
      ('/internal/sage-ready/customer-sales/' || si.id::text)::text AS out_detail_href,
      si.line_items_json AS out_source_payload
    FROM public.sales_invoices si
    LEFT JOIN public.orders o ON o.id = si.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    WHERE si.sage_status IN ('draft', 'posted', 'void')
  ), ap_batches AS (
    SELECT DISTINCT sc.shipment_batch_id
    FROM public.internal_shipping_control_v1() sc
    WHERE sc.shipment_batch_id IS NOT NULL
      AND COALESCE(sc.shipper_invoice_status, '') = 'accepted_current'
      AND COALESCE(sc.sage_readiness_status, '') = 'shipping_apportionment_approved'
  ), ap_preview AS (
    SELECT p.*
    FROM ap_batches b
    CROSS JOIN LATERAL public.internal_shipping_ap_recharge_readiness_preview_v1(b.shipment_batch_id) p
  ), ap_purchase_intents AS (
    SELECT
      ('shipping_ap_intent:' || pr.shipping_document_id::text)::text AS out_queue_row_id,
      'shipper_ap'::text AS out_document_lane,
      'shipper_ap_purchase_invoice_intent'::text AS out_document_type,
      'shipping_documents'::text AS out_source_table,
      pr.shipping_document_id AS out_source_id,
      NULL::uuid AS out_order_id,
      STRING_AGG(DISTINCT pr.order_ref, ', ' ORDER BY pr.order_ref)::text AS out_order_ref,
      pr.shipment_batch_id AS out_shipment_batch_id,
      MAX(pr.booking_ref)::text AS out_booking_ref,
      MAX(pr.shipper_name)::text AS out_counterparty_name,
      MAX(COALESCE(pr.shipping_document_total, 0))::numeric AS out_amount_gbp,
      MAX(COALESCE(pr.shipping_document_currency, 'GBP'))::text AS out_currency_code,
      'purchase_invoice'::text AS out_invoice_type,
      'not_drafted'::text AS out_sage_status,
      NULL::text AS out_sage_invoice_id,
      NULL::timestamptz AS out_sage_posted_at,
      CASE
        WHEN COUNT(*) FILTER (WHERE pr.blocker IS NOT NULL) > 0 THEN 'blocked'
        ELSE 'ready_for_ap_purchase_invoice_draft'
      END::text AS out_readiness_status,
      CASE
        WHEN COUNT(*) FILTER (WHERE pr.blocker IS NOT NULL) > 0 THEN STRING_AGG(DISTINCT pr.blocker, ', ' ORDER BY pr.blocker)
        ELSE NULL::text
      END AS out_blocker,
      COALESCE(MAX(pr.shipping_document_ref), MAX(pr.booking_ref), pr.shipping_document_id::text)::text AS out_reference_text,
      ('Booking ' || COALESCE(MAX(pr.booking_ref), ''))::text AS out_notes_text,
      ('/internal/shipping-control/readiness/' || pr.shipment_batch_id::text)::text AS out_detail_href,
      jsonb_build_object(
        'document_ref', MAX(pr.shipping_document_ref),
        'document_date', MAX(pr.shipping_document_date),
        'booking_ref', MAX(pr.booking_ref),
        'shipper_name', MAX(pr.shipper_name),
        'document_total', MAX(pr.shipping_document_total),
        'currency', MAX(pr.shipping_document_currency),
        'route', 'shipper_ap_purchase_invoice_intent',
        'status', 'source_ready_not_posted_to_sage'
      ) AS out_source_payload
    FROM ap_preview pr
    WHERE pr.shipping_document_id IS NOT NULL
    GROUP BY pr.shipping_document_id, pr.shipment_batch_id
  ), final_rows AS (
    SELECT * FROM customer_sales
    UNION ALL
    SELECT * FROM ap_purchase_intents
  )
  SELECT
    fr.out_queue_row_id AS queue_row_id,
    fr.out_document_lane AS document_lane,
    fr.out_document_type AS document_type,
    fr.out_source_table AS source_table,
    fr.out_source_id AS source_id,
    fr.out_order_id AS order_id,
    fr.out_order_ref AS order_ref,
    fr.out_shipment_batch_id AS shipment_batch_id,
    fr.out_booking_ref AS booking_ref,
    fr.out_counterparty_name AS counterparty_name,
    fr.out_amount_gbp AS amount_gbp,
    fr.out_currency_code AS currency_code,
    fr.out_invoice_type AS invoice_type,
    fr.out_sage_status AS sage_status,
    fr.out_sage_invoice_id AS sage_invoice_id,
    fr.out_sage_posted_at AS sage_posted_at,
    fr.out_readiness_status AS readiness_status,
    fr.out_blocker AS blocker,
    fr.out_reference_text AS reference_text,
    fr.out_notes_text AS notes_text,
    fr.out_detail_href AS detail_href,
    fr.out_source_payload AS source_payload
  FROM final_rows fr
  ORDER BY
    CASE fr.out_document_lane
      WHEN 'customer_sales' THEN 0
      WHEN 'shipper_ap' THEN 1
      ELSE 2
    END,
    CASE
      WHEN fr.out_readiness_status LIKE 'blocked%' THEN 0
      WHEN fr.out_readiness_status LIKE 'ready%' THEN 1
      WHEN fr.out_readiness_status LIKE 'posted%' THEN 2
      ELSE 3
    END,
    fr.out_reference_text NULLS LAST,
    fr.out_source_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
