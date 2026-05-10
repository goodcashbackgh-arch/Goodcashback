-- =============================================================================
-- 20260510_internal_shipping_batch_detail_v1.sql
-- Multi Tenant Platform Build — internal shipment batch detail read model
--
-- Purpose:
--   Staff/supervisor read-only detail for an importer shipment batch. This fixes
--   the control-centre link so staff do not get sent to shipper-only routes.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_shipping_batch_detail_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  batch_status text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  shipment_cutoff_at timestamptz,
  dispatched_at timestamptz,
  box_count integer,
  batch_notes text,
  package_link_id uuid,
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  tracking_date date,
  tracking_evidence_url text,
  allocated_qty numeric,
  allocation_status_summary text,
  latest_receipt_status text,
  latest_receipt_note text,
  latest_receipt_evidence_url text,
  latest_receipt_recorded_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipping batch detail requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal shipping batch detail.';
  END IF;

  IF p_shipment_batch_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch id is required.';
  END IF;

  RETURN QUERY
  SELECT
    b.id AS shipment_batch_id,
    b.booking_ref::text,
    b.status::text AS batch_status,
    b.shipper_id,
    s.name::text AS shipper_name,
    b.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    b.shipment_cutoff_at,
    b.dispatched_at,
    b.box_count,
    b.notes::text AS batch_notes,
    p.id AS package_link_id,
    p.tracking_submission_id,
    p.order_id,
    o.order_ref::text,
    r.name::text AS retailer_name,
    c.name::text AS courier_name,
    ots.tracking_ref::text,
    ots.tracking_date,
    ots.tracking_screenshot_url::text AS tracking_evidence_url,
    COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
    COALESCE(alloc.status_summary, 'not_allocated')::text AS allocation_status_summary,
    latest_receipt.receipt_status::text AS latest_receipt_status,
    latest_receipt.condition_note::text AS latest_receipt_note,
    latest_receipt.evidence_url::text AS latest_receipt_evidence_url,
    latest_receipt.created_at AS latest_receipt_recorded_at
  FROM public.shipper_shipment_batches b
  JOIN public.shippers s ON s.id = b.shipper_id
  LEFT JOIN public.importers i ON i.id = b.importer_id
  LEFT JOIN public.shipper_shipment_batch_packages p
    ON p.shipment_batch_id = b.id
   AND p.active = true
  LEFT JOIN public.orders o ON o.id = p.order_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.order_tracking_submissions ots ON ots.id = p.tracking_submission_id
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  LEFT JOIN LATERAL (
    SELECT
      SUM(otla.qty_allocated) AS allocated_qty,
      string_agg(DISTINCT otla.allocation_status, ', ' ORDER BY otla.allocation_status) AS status_summary
    FROM public.order_tracking_line_allocations otla
    WHERE otla.tracking_submission_id = p.tracking_submission_id
  ) alloc ON p.tracking_submission_id IS NOT NULL
  LEFT JOIN LATERAL (
    SELECT spr.receipt_status, spr.condition_note, spr.evidence_url, spr.created_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = p.tracking_submission_id
    ORDER BY spr.created_at DESC
    LIMIT 1
  ) latest_receipt ON p.tracking_submission_id IS NOT NULL
  WHERE b.id = p_shipment_batch_id
  ORDER BY p.created_at NULLS LAST, o.order_ref NULLS LAST, ots.tracking_date NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_batch_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_batch_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
