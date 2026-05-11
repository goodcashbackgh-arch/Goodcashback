BEGIN;

CREATE OR REPLACE FUNCTION public.internal_shipping_control_v1()
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  batch_status text,
  shipment_cutoff_at timestamptz,
  dispatched_at timestamptz,
  box_count integer,
  created_at timestamptz,
  package_count bigint,
  order_count bigint,
  allocated_package_count bigint,
  unallocated_package_count bigint,
  item_qty numeric,
  receipt_issue_count bigint,
  package_refs_preview text,
  order_refs_preview text,
  receipt_status_summary text,
  allocation_status_summary text,
  shipper_invoice_status text,
  export_evidence_status text,
  master_shipment_status text,
  sage_readiness_status text,
  next_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipping control requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal shipping control.';
  END IF;

  RETURN QUERY
  WITH package_scope AS (
    SELECT
      b.id AS shipment_batch_id,
      p.id AS package_link_id,
      p.tracking_submission_id,
      p.order_id,
      o.order_ref::text AS order_ref,
      ots.tracking_ref::text AS tracking_ref,
      COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
      latest_receipt.receipt_status::text AS latest_receipt_status
    FROM public.shipper_shipment_batches b
    LEFT JOIN public.shipper_shipment_batch_packages p
      ON p.shipment_batch_id = b.id
     AND p.active = true
    LEFT JOIN public.orders o
      ON o.id = p.order_id
    LEFT JOIN public.order_tracking_submissions ots
      ON ots.id = p.tracking_submission_id
    LEFT JOIN LATERAL (
      SELECT SUM(otla.qty_allocated) AS allocated_qty
      FROM public.order_tracking_line_allocations otla
      WHERE otla.tracking_submission_id = p.tracking_submission_id
    ) alloc ON p.tracking_submission_id IS NOT NULL
    LEFT JOIN LATERAL (
      SELECT spr.receipt_status
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = p.tracking_submission_id
      ORDER BY spr.created_at DESC
      LIMIT 1
    ) latest_receipt ON p.tracking_submission_id IS NOT NULL
  ), latest_docs AS (
    SELECT DISTINCT ON (sd.shipment_batch_id)
      sd.id AS shipping_document_id,
      sd.shipment_batch_id,
      sd.review_status,
      sd.ocr_status
    FROM public.shipping_documents sd
    WHERE sd.active = true
    ORDER BY sd.shipment_batch_id, sd.created_at DESC
  ), active_apportionment AS (
    SELECT
      sca.shipping_document_id,
      sca.shipment_batch_id,
      sca.allocation_status
    FROM public.shipping_cost_allocations sca
    WHERE sca.active = true
  )
  SELECT
    b.id AS shipment_batch_id,
    b.booking_ref::text,
    b.shipper_id,
    s.name::text AS shipper_name,
    b.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    b.status::text AS batch_status,
    b.shipment_cutoff_at,
    b.dispatched_at,
    b.box_count,
    b.created_at,
    COUNT(ps.package_link_id)::bigint AS package_count,
    COUNT(DISTINCT ps.order_id)::bigint AS order_count,
    COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) > 0)::bigint AS allocated_package_count,
    COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) = 0)::bigint AS unallocated_package_count,
    COALESCE(SUM(ps.allocated_qty), 0::numeric) AS item_qty,
    COUNT(ps.package_link_id) FILTER (WHERE ps.latest_receipt_status IN ('received_damaged','held_query','not_received'))::bigint AS receipt_issue_count,
    string_agg(DISTINCT ps.tracking_ref, ', ' ORDER BY ps.tracking_ref) FILTER (WHERE ps.tracking_ref IS NOT NULL)::text AS package_refs_preview,
    string_agg(DISTINCT ps.order_ref, ', ' ORDER BY ps.order_ref) FILTER (WHERE ps.order_ref IS NOT NULL)::text AS order_refs_preview,
    CASE
      WHEN COUNT(ps.package_link_id) = 0 THEN 'no_packages'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE ps.latest_receipt_status IN ('received_damaged','held_query','not_received')) > 0 THEN 'receipt_issue'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE ps.latest_receipt_status = 'received_clean') = COUNT(ps.package_link_id) THEN 'received_clean'
      ELSE 'mixed_or_missing_receipt'
    END::text AS receipt_status_summary,
    CASE
      WHEN COUNT(ps.package_link_id) = 0 THEN 'no_packages'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) = 0) > 0 THEN 'allocation_missing'
      ELSE 'contents_allocated'
    END::text AS allocation_status_summary,
    CASE
      WHEN ld.shipment_batch_id IS NULL THEN 'not_started'
      WHEN ld.review_status = 'accepted_current' THEN 'accepted_current'
      WHEN ld.review_status = 'uploaded_pending_ocr' THEN 'uploaded_pending_ocr'
      WHEN ld.ocr_status IN ('queued','processing') THEN ld.ocr_status
      WHEN ld.review_status IS NOT NULL THEN ld.review_status
      ELSE 'uploaded_pending_ocr'
    END::text AS shipper_invoice_status,
    'not_started'::text AS export_evidence_status,
    'not_grouped'::text AS master_shipment_status,
    CASE
      WHEN aa.allocation_status = 'approved' THEN 'shipping_apportionment_approved'
      WHEN ld.review_status = 'accepted_current' THEN 'shipping_apportionment_pending'
      ELSE 'not_ready'
    END::text AS sage_readiness_status,
    CASE
      WHEN b.status = 'voided' THEN 'voided_no_action'
      WHEN COUNT(ps.package_link_id) = 0 THEN 'check_empty_batch'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) = 0) > 0 THEN 'operator_supervisor_allocation_needed'
      WHEN ld.shipment_batch_id IS NULL THEN 'shipper_invoice_or_export_review_needed'
      WHEN ld.review_status <> 'accepted_current' THEN 'shipping_document_uploaded_needs_supervisor_processing'
      WHEN aa.allocation_status IS DISTINCT FROM 'approved' THEN 'shipping_apportionment_pending'
      ELSE 'ready_for_sage_ap_readiness_review'
    END::text AS next_action
  FROM public.shipper_shipment_batches b
  JOIN public.shippers s ON s.id = b.shipper_id
  LEFT JOIN public.importers i ON i.id = b.importer_id
  LEFT JOIN package_scope ps ON ps.shipment_batch_id = b.id
  LEFT JOIN latest_docs ld ON ld.shipment_batch_id = b.id
  LEFT JOIN active_apportionment aa ON aa.shipping_document_id = ld.shipping_document_id
  GROUP BY b.id, b.booking_ref, b.shipper_id, s.name, b.importer_id, i.trading_name, i.company_name,
           b.status, b.shipment_cutoff_at, b.dispatched_at, b.box_count, b.created_at,
           ld.shipment_batch_id, ld.review_status, ld.ocr_status, ld.shipping_document_id, aa.allocation_status
  ORDER BY b.created_at DESC;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
