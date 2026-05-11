BEGIN;

CREATE OR REPLACE FUNCTION public.internal_shipping_document_detail_v1(
  p_shipping_document_id uuid
)
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  shipper_name text,
  importer_name text,
  document_kind text,
  document_ref text,
  document_date date,
  currency_code text,
  total_amount numeric,
  file_url text,
  ocr_status text,
  review_status text,
  notes text,
  version_no integer,
  created_at timestamptz,
  accepted_at timestamptz,
  reviewed_at timestamptz,
  review_note text,
  extracted_document_ref text,
  extracted_document_date date,
  extracted_currency_code text,
  extracted_total_amount numeric,
  package_count bigint,
  item_qty numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipping document detail requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal shipping document detail.';
  END IF;

  RETURN QUERY
  WITH package_counts AS (
    SELECT
      p.shipment_batch_id,
      COUNT(*)::bigint AS package_count,
      COALESCE(SUM(alloc.allocated_qty), 0::numeric) AS item_qty
    FROM public.shipper_shipment_batch_packages p
    LEFT JOIN LATERAL (
      SELECT SUM(otla.qty_allocated) AS allocated_qty
      FROM public.order_tracking_line_allocations otla
      WHERE otla.tracking_submission_id = p.tracking_submission_id
    ) alloc ON true
    WHERE p.active = true
    GROUP BY p.shipment_batch_id
  )
  SELECT
    sd.id AS shipping_document_id,
    sd.shipment_batch_id,
    b.booking_ref::text,
    s.name::text AS shipper_name,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    sd.document_kind::text,
    sd.document_ref::text,
    sd.document_date,
    sd.currency_code::text,
    sd.total_amount,
    sd.file_url::text,
    sd.ocr_status::text,
    sd.review_status::text,
    sd.notes::text,
    sd.version_no,
    sd.created_at,
    sd.accepted_at,
    sd.reviewed_at,
    sd.review_note::text,
    sd.extracted_document_ref::text,
    sd.extracted_document_date,
    sd.extracted_currency_code::text,
    sd.extracted_total_amount,
    COALESCE(pc.package_count, 0)::bigint AS package_count,
    COALESCE(pc.item_qty, 0::numeric) AS item_qty
  FROM public.shipping_documents sd
  JOIN public.shipper_shipment_batches b ON b.id = sd.shipment_batch_id
  JOIN public.shippers s ON s.id = sd.shipper_id
  LEFT JOIN public.importers i ON i.id = sd.importer_id
  LEFT JOIN package_counts pc ON pc.shipment_batch_id = sd.shipment_batch_id
  WHERE sd.id = p_shipping_document_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_document_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
