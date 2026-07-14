BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Forward-only replacement: preserve receipt truth while exposing whether a
-- received-clean package is already linked to an active, non-voided shipment.
DROP FUNCTION IF EXISTS public.shipper_package_receipt_dashboard_v1();

CREATE FUNCTION public.shipper_package_receipt_dashboard_v1()
RETURNS TABLE (
  shipper_user_id uuid,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  order_id uuid,
  order_ref text,
  retailer_name text,
  tracking_submission_id uuid,
  courier_name text,
  tracking_ref text,
  tracking_date text,
  submitted_at timestamptz,
  is_final_delivery_yn boolean,
  tracking_evidence_url text,
  tracking_note text,
  allocated_qty numeric,
  allocated_net_value_gbp numeric,
  allocation_status_summary text,
  latest_receipt_status text,
  latest_receipt_note text,
  latest_receipt_evidence_url text,
  latest_receipt_recorded_at timestamptz,
  active_shipment_batch_id uuid,
  active_shipment_booking_ref text,
  active_shipment_batch_status text,
  in_active_shipment_yn boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper receipt dashboard requires auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    v_shipper_user_id AS shipper_user_id,
    s.id AS shipper_id,
    s.name::text AS shipper_name,
    o.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    o.id AS order_id,
    o.order_ref::text AS order_ref,
    r.name::text AS retailer_name,
    ots.id AS tracking_submission_id,
    c.name::text AS courier_name,
    ots.tracking_ref::text AS tracking_ref,
    ots.tracking_date::text AS tracking_date,
    ots.submitted_at,
    ots.is_final_delivery_yn,
    ots.tracking_screenshot_url::text AS tracking_evidence_url,
    ots.note::text AS tracking_note,
    COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
    COALESCE(alloc.allocated_net_value_gbp, 0::numeric) AS allocated_net_value_gbp,
    COALESCE(alloc.status_summary, 'not_allocated')::text AS allocation_status_summary,
    latest_receipt.receipt_status::text AS latest_receipt_status,
    latest_receipt.condition_note::text AS latest_receipt_note,
    latest_receipt.evidence_url::text AS latest_receipt_evidence_url,
    latest_receipt.recorded_at AS latest_receipt_recorded_at,
    shipment_link.shipment_batch_id AS active_shipment_batch_id,
    shipment_link.booking_ref AS active_shipment_booking_ref,
    shipment_link.batch_status AS active_shipment_batch_status,
    (shipment_link.shipment_batch_id IS NOT NULL) AS in_active_shipment_yn
  FROM public.orders o
  JOIN public.shippers s ON s.id = o.shipper_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.order_tracking_submissions ots
    ON ots.order_id = o.id
   AND ots.superseded_at IS NULL
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  LEFT JOIN LATERAL (
    SELECT
      SUM(otla.qty_allocated) AS allocated_qty,
      SUM(otla.adjusted_net_value_gbp) AS allocated_net_value_gbp,
      string_agg(DISTINCT otla.allocation_status, ', ' ORDER BY otla.allocation_status) AS status_summary
    FROM public.order_tracking_line_allocations otla
    WHERE otla.order_id = o.id
      AND otla.tracking_submission_id = ots.id
  ) alloc ON ots.id IS NOT NULL
  LEFT JOIN LATERAL (
    SELECT spr.receipt_status, spr.condition_note, spr.evidence_url, spr.recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = ots.id
    ORDER BY spr.created_at DESC
    LIMIT 1
  ) latest_receipt ON ots.id IS NOT NULL
  LEFT JOIN LATERAL (
    SELECT
      ssbp.shipment_batch_id,
      ssb.booking_ref::text AS booking_ref,
      ssb.status::text AS batch_status
    FROM public.shipper_shipment_batch_packages ssbp
    JOIN public.shipper_shipment_batches ssb
      ON ssb.id = ssbp.shipment_batch_id
    WHERE ssbp.tracking_submission_id = ots.id
      AND ssbp.active = true
      AND ssb.status <> 'voided'
    ORDER BY ssbp.created_at DESC
    LIMIT 1
  ) shipment_link ON ots.id IS NOT NULL
  WHERE o.shipper_id = v_shipper_id
  ORDER BY o.created_at DESC, ots.tracking_date DESC NULLS LAST, ots.submitted_at DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_package_receipt_dashboard_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_package_receipt_dashboard_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
