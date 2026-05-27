-- =============================================================================
-- 20260527_shipper_export_evidence_pack_preview_v1.sql
-- Multi Tenant Platform Build — draft COS + EEP pack preview data
--
-- Purpose:
--   Provide one controlled read model that both shipper users and internal staff
--   can use to generate the draft COS + EEP/packing-list download.
--
-- Scope:
--   This deliberately exposes only the fields needed for the shipper COS/EEP
--   evidence pack for the selected shipment batch. It does not post to Sage,
--   approve export evidence, or alter shipment truth.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.shipper_export_evidence_pack_preview_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  eep_ref text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  customer_name text,
  package_box_ref text,
  total_boxes integer,
  mbl_bol_sea_waybill_ref text,
  container_number text,
  seal_number text,
  vessel_voyage text,
  port_of_loading text,
  port_of_discharge text,
  place_of_delivery text,
  export_shipment_date date,
  final_package_confirmation text,
  authorised_name text,
  signature_stamp_confirmation_yn boolean,
  completion_status text,
  order_id uuid,
  order_ref text,
  sales_invoice_ref text,
  sage_account_ref text,
  supplier_invoice_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  unit_export_value_gbp numeric,
  total_export_value_gbp numeric,
  destination text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch_shipper_id uuid;
  v_is_staff boolean := false;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: export evidence pack preview requires auth.uid()';
  END IF;

  IF p_shipment_batch_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch id is required.';
  END IF;

  v_is_staff := public.is_active_staff();

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  SELECT b.shipper_id
    INTO v_batch_shipper_id
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id;

  IF v_batch_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found.';
  END IF;

  IF NOT v_is_staff AND (v_shipper_user_id IS NULL OR v_shipper_id IS DISTINCT FROM v_batch_shipper_id) THEN
    RAISE EXCEPTION 'Active shipper user for this shipment batch, or active staff, is required.';
  END IF;

  RETURN QUERY
  WITH batch AS (
    SELECT
      b.id,
      b.booking_ref::text AS booking_ref,
      CONCAT('EEP-', LEFT(regexp_replace(COALESCE(NULLIF(b.booking_ref, ''), b.id::text), '[^a-zA-Z0-9-]', '', 'g'), 24))::text AS eep_ref,
      b.shipper_id,
      s.name::text AS shipper_name,
      b.importer_id,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text AS customer_name,
      COALESCE(NULLIF(b.booking_ref, ''), CONCAT('EEP-', LEFT(regexp_replace(b.id::text, '[^a-zA-Z0-9-]', '', 'g'), 24)))::text AS package_box_ref,
      b.box_count,
      f.mbl_bol_sea_waybill_ref,
      f.container_number,
      f.seal_number,
      f.vessel_voyage,
      f.port_of_loading,
      f.port_of_discharge,
      f.place_of_delivery,
      f.export_shipment_date,
      f.final_package_confirmation,
      f.authorised_name,
      COALESCE(f.signature_stamp_confirmation_yn, false) AS signature_stamp_confirmation_yn,
      COALESCE(f.completion_status, 'completion_fields_draft')::text AS completion_status
    FROM public.shipper_shipment_batches b
    JOIN public.shippers s ON s.id = b.shipper_id
    LEFT JOIN public.importers i ON i.id = b.importer_id
    LEFT JOIN public.shipper_export_evidence_completion_fields f
      ON f.shipment_batch_id = b.id
    WHERE b.id = p_shipment_batch_id
  ), lines AS (
    SELECT
      ba.*,
      p.tracking_submission_id,
      otla.order_id,
      o.order_ref::text AS order_ref,
      otla.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Assorted retail goods')::text AS raw_item_description,
      COALESCE(otla.qty_allocated, 0)::numeric AS qty_allocated,
      COALESCE(otla.adjusted_net_value_gbp, 0)::numeric AS total_export_value_gbp,
      si.invoice_ref::text AS supplier_invoice_ref,
      sale.id::text AS sales_invoice_ref,
      NULL::text AS sage_account_ref
    FROM batch ba
    JOIN public.shipper_shipment_batch_packages p
      ON p.shipment_batch_id = ba.id
     AND p.active = true
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.tracking_submission_id = p.tracking_submission_id
    LEFT JOIN public.orders o
      ON o.id = otla.order_id
    LEFT JOIN public.supplier_invoice_lines sil
      ON sil.id = otla.supplier_invoice_line_id
    LEFT JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
    LEFT JOIN LATERAL (
      SELECT sales.id
      FROM public.sales_invoices sales
      WHERE sales.order_id = otla.order_id
        AND sales.invoice_type = 'main'
        AND sales.sage_status IN ('draft','posted')
      ORDER BY CASE WHEN sales.sage_status = 'posted' THEN 0 ELSE 1 END,
               sales.created_at DESC,
               sales.id DESC
      LIMIT 1
    ) sale ON true
  )
  SELECT
    l.id AS shipment_batch_id,
    l.booking_ref,
    l.eep_ref,
    l.shipper_id,
    l.shipper_name,
    l.importer_id,
    l.customer_name,
    l.package_box_ref,
    COALESCE(l.box_count, 0)::integer AS total_boxes,
    l.mbl_bol_sea_waybill_ref,
    l.container_number,
    l.seal_number,
    l.vessel_voyage,
    l.port_of_loading,
    l.port_of_discharge,
    l.place_of_delivery,
    l.export_shipment_date,
    l.final_package_confirmation,
    l.authorised_name,
    l.signature_stamp_confirmation_yn,
    l.completion_status,
    l.order_id,
    l.order_ref,
    l.sales_invoice_ref,
    l.sage_account_ref,
    l.supplier_invoice_ref,
    l.supplier_invoice_line_id,
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(COALESCE(l.raw_item_description, 'Assorted retail goods'), '^export\s+sale\s*-\s*', '', 'i'),
              '^export\s+sale\s+goods\s+charge\s*-\s*', '', 'i'),
            '^supplementary\s+export\s+sale\s+shipping\s+charge\s*-\s*', '', 'i'),
          '\s*-\s*ord[-\s_]*[a-zA-Z0-9-]+\s*$', '', 'i'),
        '\s*-\s*ord[-\s_]*[a-zA-Z0-9-]+\s*-\s*booking\s+[a-zA-Z0-9-]+\s*$', '', 'i'),
      '\s*-\s*booking\s+[a-zA-Z0-9-]+\s*$', '', 'i')::text AS item_description,
    l.qty_allocated,
    CASE WHEN COALESCE(l.qty_allocated, 0) = 0 THEN l.total_export_value_gbp ELSE ROUND(l.total_export_value_gbp / l.qty_allocated, 2) END AS unit_export_value_gbp,
    l.total_export_value_gbp,
    'Ghana'::text AS destination
  FROM lines l
  WHERE l.order_id IS NOT NULL
    AND l.supplier_invoice_line_id IS NOT NULL
    AND COALESCE(l.qty_allocated, 0) > 0
  ORDER BY l.customer_name, l.order_ref NULLS LAST, l.raw_item_description NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_export_evidence_pack_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_export_evidence_pack_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
