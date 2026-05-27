BEGIN;

-- COS / EEP must follow the actual posted customer export sales invoice.
-- It must not present internal goods/shipping split values as COS values, and it must
-- never use supplementary shipping-only invoices as packing-list/export lines.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

ALTER TABLE public.sales_invoices
  ADD COLUMN IF NOT EXISTS sage_reference text;

UPDATE public.sales_invoices si
SET sage_reference = COALESCE(
  NULLIF(si.sage_reference, ''),
  NULLIF(src.sage_display_ref, ''),
  NULLIF(si.sage_invoice_id, '')
)
FROM (
  SELECT DISTINCT ON (br.source_id)
    br.source_id AS sales_invoice_id,
    COALESCE(
      NULLIF(br.response_payload_json #>> '{displayed_as}', ''),
      NULLIF(br.response_payload_json #>> '{sales_invoice,displayed_as}', ''),
      NULLIF(br.response_payload_json #>> '{invoice_number}', ''),
      NULLIF(br.response_payload_json #>> '{sales_invoice,invoice_number}', ''),
      NULLIF(br.sage_reference, ''),
      NULLIF(br.sage_object_id, '')
    ) AS sage_display_ref
  FROM public.sage_posting_batch_rows br
  WHERE br.source_table = 'sales_invoices'
    AND br.source_id IS NOT NULL
    AND br.posting_status = 'posted'
  ORDER BY br.source_id, br.posted_at DESC NULLS LAST, br.id DESC
) src
WHERE si.id = src.sales_invoice_id
  AND NULLIF(si.sage_reference, '') IS NULL;

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
  ), allocation_lines AS (
    SELECT
      ba.*,
      p.tracking_submission_id,
      otla.order_id,
      o.order_ref::text AS order_ref,
      otla.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Assorted retail goods')::text AS raw_item_description,
      COALESCE(otla.qty_allocated, 0)::numeric AS qty_allocated,
      COALESCE(otla.adjusted_net_value_gbp, 0)::numeric AS total_export_value_gbp,
      si.invoice_ref::text AS supplier_invoice_ref
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
    WHERE otla.order_id IS NOT NULL
      AND otla.supplier_invoice_line_id IS NOT NULL
      AND COALESCE(otla.qty_allocated, 0) > 0
  ), allocation_summary AS (
    SELECT
      al.id AS shipment_batch_id,
      al.booking_ref,
      al.eep_ref,
      al.shipper_id,
      al.shipper_name,
      al.importer_id,
      al.customer_name,
      al.package_box_ref,
      COALESCE(al.box_count, 0)::integer AS total_boxes,
      al.mbl_bol_sea_waybill_ref,
      al.container_number,
      al.seal_number,
      al.vessel_voyage,
      al.port_of_loading,
      al.port_of_discharge,
      al.place_of_delivery,
      al.export_shipment_date,
      al.final_package_confirmation,
      al.authorised_name,
      al.signature_stamp_confirmation_yn,
      al.completion_status,
      al.order_id,
      MAX(al.order_ref)::text AS order_ref,
      (ARRAY_AGG(al.supplier_invoice_line_id ORDER BY al.supplier_invoice_line_id::text))[1] AS supplier_invoice_line_id,
      MAX(al.supplier_invoice_ref)::text AS supplier_invoice_ref,
      STRING_AGG(DISTINCT al.raw_item_description, ' / ' ORDER BY al.raw_item_description)::text AS fallback_description,
      SUM(al.qty_allocated)::numeric AS fallback_qty,
      SUM(al.total_export_value_gbp)::numeric AS fallback_total_export_value_gbp
    FROM allocation_lines al
    GROUP BY
      al.id, al.booking_ref, al.eep_ref, al.shipper_id, al.shipper_name, al.importer_id,
      al.customer_name, al.package_box_ref, al.box_count, al.mbl_bol_sea_waybill_ref,
      al.container_number, al.seal_number, al.vessel_voyage, al.port_of_loading,
      al.port_of_discharge, al.place_of_delivery, al.export_shipment_date,
      al.final_package_confirmation, al.authorised_name, al.signature_stamp_confirmation_yn,
      al.completion_status, al.order_id
  ), posted_main AS (
    SELECT DISTINCT ON (a.order_id)
      a.*,
      sales.id AS sales_invoice_row_id,
      COALESCE(
        NULLIF(sales.sage_reference, ''),
        NULLIF(br.response_payload_json #>> '{displayed_as}', ''),
        NULLIF(br.response_payload_json #>> '{sales_invoice,displayed_as}', ''),
        NULLIF(br.response_payload_json #>> '{invoice_number}', ''),
        NULLIF(br.response_payload_json #>> '{sales_invoice,invoice_number}', ''),
        NULLIF(br.sage_reference, ''),
        NULLIF(sales.sage_invoice_id, ''),
        sales.id::text
      ) AS display_sales_invoice_ref,
      sps.commercial_payload,
      sps.resolved_payload,
      sales.amount_gbp AS sales_invoice_amount_gbp
    FROM allocation_summary a
    JOIN public.sales_invoices sales
      ON sales.order_id = a.order_id
     AND COALESCE(sales.invoice_type::text, '') = 'main'
     AND COALESCE(sales.sage_status::text, '') = 'posted'
    LEFT JOIN LATERAL (
      SELECT row.*
      FROM public.sage_posting_batch_rows row
      WHERE row.source_table = 'sales_invoices'
        AND row.source_id = sales.id
        AND row.posting_status = 'posted'
      ORDER BY row.posted_at DESC NULLS LAST, row.id DESC
      LIMIT 1
    ) br ON true
    LEFT JOIN LATERAL (
      SELECT snap.*
      FROM public.sage_posting_snapshots snap
      WHERE snap.source_table = 'sales_invoices'
        AND snap.source_id = sales.id
        AND snap.sage_posting_status = 'posted'
      ORDER BY snap.sage_posted_at DESC NULLS LAST, snap.approved_at DESC NULLS LAST, snap.id DESC
      LIMIT 1
    ) sps ON true
    ORDER BY a.order_id, sales.sage_posted_at DESC NULLS LAST, sales.created_at DESC, sales.id DESC
  ), posted_main_lines AS (
    SELECT
      pm.*,
      line_item.value AS line_json,
      line_item.ordinality
    FROM posted_main pm
    LEFT JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(pm.commercial_payload -> 'lines') = 'array' THEN pm.commercial_payload -> 'lines'
        WHEN jsonb_typeof(pm.resolved_payload -> 'resolved_lines') = 'array' THEN pm.resolved_payload -> 'resolved_lines'
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS line_item(value, ordinality) ON true
  ), invoice_rows AS (
    SELECT
      pml.shipment_batch_id,
      pml.booking_ref,
      pml.eep_ref,
      pml.shipper_id,
      pml.shipper_name,
      pml.importer_id,
      pml.customer_name,
      pml.package_box_ref,
      pml.total_boxes,
      pml.mbl_bol_sea_waybill_ref,
      pml.container_number,
      pml.seal_number,
      pml.vessel_voyage,
      pml.port_of_loading,
      pml.port_of_discharge,
      pml.place_of_delivery,
      pml.export_shipment_date,
      pml.final_package_confirmation,
      pml.authorised_name,
      pml.signature_stamp_confirmation_yn,
      pml.completion_status,
      pml.order_id,
      pml.order_ref,
      pml.display_sales_invoice_ref::text AS sales_invoice_ref,
      NULL::text AS sage_account_ref,
      pml.supplier_invoice_ref,
      pml.supplier_invoice_line_id,
      COALESCE(NULLIF(pml.line_json #>> '{description}', ''), pml.fallback_description, 'Assorted retail goods')::text AS item_description,
      COALESCE(NULLIF(pml.line_json #>> '{quantity}', '')::numeric, NULLIF(pml.line_json #>> '{released_qty}', '')::numeric, pml.fallback_qty, 1)::numeric AS qty_allocated,
      CASE
        WHEN COALESCE(NULLIF(pml.line_json #>> '{quantity}', '')::numeric, NULLIF(pml.line_json #>> '{released_qty}', '')::numeric, pml.fallback_qty, 1) = 0 THEN COALESCE(NULLIF(pml.line_json #>> '{unit_price_gbp}', '')::numeric, NULLIF(pml.line_json #>> '{total_line_amount_gbp}', '')::numeric, NULLIF(pml.line_json #>> '{customer_charge_amount_gbp}', '')::numeric, pml.sales_invoice_amount_gbp, pml.fallback_total_export_value_gbp, 0)
        ELSE ROUND(
          COALESCE(NULLIF(pml.line_json #>> '{total_line_amount_gbp}', '')::numeric, NULLIF(pml.line_json #>> '{customer_charge_amount_gbp}', '')::numeric, NULLIF(pml.line_json #>> '{unit_price_gbp}', '')::numeric, pml.sales_invoice_amount_gbp, pml.fallback_total_export_value_gbp, 0)
          / COALESCE(NULLIF(pml.line_json #>> '{quantity}', '')::numeric, NULLIF(pml.line_json #>> '{released_qty}', '')::numeric, pml.fallback_qty, 1),
          2
        )
      END::numeric AS unit_export_value_gbp,
      COALESCE(NULLIF(pml.line_json #>> '{total_line_amount_gbp}', '')::numeric, NULLIF(pml.line_json #>> '{customer_charge_amount_gbp}', '')::numeric, NULLIF(pml.line_json #>> '{unit_price_gbp}', '')::numeric, pml.sales_invoice_amount_gbp, pml.fallback_total_export_value_gbp, 0)::numeric AS total_export_value_gbp,
      'Ghana'::text AS destination
    FROM posted_main_lines pml
  ), fallback_rows AS (
    SELECT
      a.shipment_batch_id,
      a.booking_ref,
      a.eep_ref,
      a.shipper_id,
      a.shipper_name,
      a.importer_id,
      a.customer_name,
      a.package_box_ref,
      a.total_boxes,
      a.mbl_bol_sea_waybill_ref,
      a.container_number,
      a.seal_number,
      a.vessel_voyage,
      a.port_of_loading,
      a.port_of_discharge,
      a.place_of_delivery,
      a.export_shipment_date,
      a.final_package_confirmation,
      a.authorised_name,
      a.signature_stamp_confirmation_yn,
      a.completion_status,
      a.order_id,
      a.order_ref,
      NULL::text AS sales_invoice_ref,
      NULL::text AS sage_account_ref,
      a.supplier_invoice_ref,
      a.supplier_invoice_line_id,
      a.fallback_description AS item_description,
      a.fallback_qty AS qty_allocated,
      CASE WHEN COALESCE(a.fallback_qty, 0) = 0 THEN a.fallback_total_export_value_gbp ELSE ROUND(a.fallback_total_export_value_gbp / a.fallback_qty, 2) END AS unit_export_value_gbp,
      a.fallback_total_export_value_gbp AS total_export_value_gbp,
      'Ghana'::text AS destination
    FROM allocation_summary a
    WHERE NOT EXISTS (
      SELECT 1
      FROM posted_main pm
      WHERE pm.order_id = a.order_id
    )
  ), final_rows AS (
    SELECT * FROM invoice_rows
    UNION ALL
    SELECT * FROM fallback_rows
  )
  SELECT
    fr.shipment_batch_id,
    fr.booking_ref,
    fr.eep_ref,
    fr.shipper_id,
    fr.shipper_name,
    fr.importer_id,
    fr.customer_name,
    fr.package_box_ref,
    fr.total_boxes,
    fr.mbl_bol_sea_waybill_ref,
    fr.container_number,
    fr.seal_number,
    fr.vessel_voyage,
    fr.port_of_loading,
    fr.port_of_discharge,
    fr.place_of_delivery,
    fr.export_shipment_date,
    fr.final_package_confirmation,
    fr.authorised_name,
    fr.signature_stamp_confirmation_yn,
    fr.completion_status,
    fr.order_id,
    fr.order_ref,
    fr.sales_invoice_ref,
    fr.sage_account_ref,
    fr.supplier_invoice_ref,
    fr.supplier_invoice_line_id,
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(COALESCE(fr.item_description, 'Assorted retail goods'), '^export\s+sale\s*-\s*', '', 'i'),
              '^export\s+sale\s+goods\s+charge\s*-\s*', '', 'i'),
            '^supplementary\s+export\s+sale\s+shipping\s+charge\s*-\s*', '', 'i'),
          '\s*-\s*ord[-\s_]*[a-zA-Z0-9-]+\s*$', '', 'i'),
        '\s*-\s*ord[-\s_]*[a-zA-Z0-9-]+\s*-\s*booking\s+[a-zA-Z0-9-]+\s*$', '', 'i'),
      '\s*-\s*booking\s+[a-zA-Z0-9-]+\s*$', '', 'i')::text AS item_description,
    fr.qty_allocated,
    fr.unit_export_value_gbp,
    fr.total_export_value_gbp,
    fr.destination
  FROM final_rows fr
  WHERE COALESCE(fr.qty_allocated, 0) > 0
    AND COALESCE(fr.total_export_value_gbp, 0) > 0
  ORDER BY fr.customer_name, fr.order_ref NULLS LAST, fr.item_description NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_export_evidence_pack_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_export_evidence_pack_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
