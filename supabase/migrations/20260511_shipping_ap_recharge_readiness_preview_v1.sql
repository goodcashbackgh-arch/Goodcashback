BEGIN;

CREATE OR REPLACE FUNCTION public.internal_shipping_ap_recharge_readiness_preview_v1(p_shipment_batch_id uuid)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  shipping_document_id uuid,
  shipping_document_kind text,
  shipping_document_ref text,
  shipping_document_date date,
  shipping_document_currency text,
  shipping_document_total numeric,
  shipping_document_review_status text,
  shipping_cost_allocation_id uuid,
  shipping_apportionment_status text,
  shipping_apportionment_approved_at timestamptz,
  order_id uuid,
  order_ref text,
  tracking_submission_id uuid,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  adjusted_goods_basis_gbp numeric,
  allocated_shipping_amount numeric,
  ap_document_route text,
  customer_recharge_route text,
  sales_invoice_state text,
  readiness_status text,
  blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_has_sales_invoices boolean := false;
  v_has_invoice_type boolean := false;
  v_has_status boolean := false;
  v_has_order_id boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipping AP/recharge readiness preview requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for shipping AP/recharge readiness preview.';
  END IF;

  SELECT to_regclass('public.sales_invoices') IS NOT NULL INTO v_has_sales_invoices;

  IF v_has_sales_invoices THEN
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'sales_invoices' AND column_name = 'invoice_type'
    ) INTO v_has_invoice_type;
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'sales_invoices' AND column_name = 'status'
    ) INTO v_has_status;
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'sales_invoices' AND column_name = 'order_id'
    ) INTO v_has_order_id;
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp._shipping_sales_state_tmp (
    order_id uuid PRIMARY KEY,
    sales_invoice_state text,
    customer_recharge_route text
  ) ON COMMIT DROP;
  TRUNCATE pg_temp._shipping_sales_state_tmp;

  IF v_has_sales_invoices AND v_has_order_id THEN
    IF v_has_invoice_type AND v_has_status THEN
      EXECUTE $sql$
        INSERT INTO pg_temp._shipping_sales_state_tmp(order_id, sales_invoice_state, customer_recharge_route)
        SELECT
          o.id,
          CASE
            WHEN EXISTS (
              SELECT 1 FROM public.sales_invoices si
              WHERE si.order_id = o.id
                AND COALESCE(si.invoice_type::text, '') = 'main'
                AND COALESCE(si.status::text, '') NOT IN ('voided','cancelled','rejected')
            ) THEN 'main_sales_invoice_exists'
            ELSE 'no_main_sales_invoice_found'
          END,
          CASE
            WHEN EXISTS (
              SELECT 1 FROM public.sales_invoices si
              WHERE si.order_id = o.id
                AND COALESCE(si.invoice_type::text, '') = 'main'
                AND COALESCE(si.status::text, '') NOT IN ('voided','cancelled','rejected')
            ) THEN 'supplementary_shipping_recharge_invoice'
            ELSE 'include_shipping_in_main_sales_invoice_release'
          END
        FROM public.orders o
        WHERE EXISTS (
          SELECT 1
          FROM public.shipper_shipment_batch_packages p
          JOIN public.order_tracking_line_allocations otla ON otla.tracking_submission_id = p.tracking_submission_id
          WHERE p.shipment_batch_id = $1
            AND p.active = true
            AND otla.order_id = o.id
        )
      $sql$ USING p_shipment_batch_id;
    ELSIF v_has_invoice_type THEN
      EXECUTE $sql$
        INSERT INTO pg_temp._shipping_sales_state_tmp(order_id, sales_invoice_state, customer_recharge_route)
        SELECT
          o.id,
          CASE
            WHEN EXISTS (
              SELECT 1 FROM public.sales_invoices si
              WHERE si.order_id = o.id
                AND COALESCE(si.invoice_type::text, '') = 'main'
            ) THEN 'main_sales_invoice_exists_status_unknown'
            ELSE 'no_main_sales_invoice_found'
          END,
          CASE
            WHEN EXISTS (
              SELECT 1 FROM public.sales_invoices si
              WHERE si.order_id = o.id
                AND COALESCE(si.invoice_type::text, '') = 'main'
            ) THEN 'supplementary_shipping_recharge_invoice'
            ELSE 'include_shipping_in_main_sales_invoice_release'
          END
        FROM public.orders o
        WHERE EXISTS (
          SELECT 1
          FROM public.shipper_shipment_batch_packages p
          JOIN public.order_tracking_line_allocations otla ON otla.tracking_submission_id = p.tracking_submission_id
          WHERE p.shipment_batch_id = $1
            AND p.active = true
            AND otla.order_id = o.id
        )
      $sql$ USING p_shipment_batch_id;
    ELSE
      EXECUTE $sql$
        INSERT INTO pg_temp._shipping_sales_state_tmp(order_id, sales_invoice_state, customer_recharge_route)
        SELECT
          o.id,
          CASE
            WHEN EXISTS (SELECT 1 FROM public.sales_invoices si WHERE si.order_id = o.id) THEN 'sales_invoice_exists_type_unknown'
            ELSE 'no_sales_invoice_found'
          END,
          CASE
            WHEN EXISTS (SELECT 1 FROM public.sales_invoices si WHERE si.order_id = o.id) THEN 'supplementary_shipping_recharge_invoice_review_required'
            ELSE 'include_shipping_in_main_sales_invoice_release'
          END
        FROM public.orders o
        WHERE EXISTS (
          SELECT 1
          FROM public.shipper_shipment_batch_packages p
          JOIN public.order_tracking_line_allocations otla ON otla.tracking_submission_id = p.tracking_submission_id
          WHERE p.shipment_batch_id = $1
            AND p.active = true
            AND otla.order_id = o.id
        )
      $sql$ USING p_shipment_batch_id;
    END IF;
  END IF;

  RETURN QUERY
  WITH batch AS (
    SELECT b.*, s.name AS shipper_name, COALESCE(NULLIF(i.trading_name, ''), i.company_name) AS importer_name
    FROM public.shipper_shipment_batches b
    JOIN public.shippers s ON s.id = b.shipper_id
    LEFT JOIN public.importers i ON i.id = b.importer_id
    WHERE b.id = p_shipment_batch_id
  ), current_doc AS (
    SELECT DISTINCT ON (sd.shipment_batch_id)
      sd.*
    FROM public.shipping_documents sd
    WHERE sd.shipment_batch_id = p_shipment_batch_id
      AND sd.active = true
    ORDER BY sd.shipment_batch_id,
      CASE WHEN sd.review_status = 'accepted_current' THEN 0 ELSE 1 END,
      sd.created_at DESC
  ), current_allocation AS (
    SELECT sca.*
    FROM public.shipping_cost_allocations sca
    JOIN current_doc d ON d.id = sca.shipping_document_id
    WHERE sca.active = true
    ORDER BY sca.approved_at DESC NULLS LAST, sca.created_at DESC
    LIMIT 1
  ), line_scope AS (
    SELECT
      p.tracking_submission_id,
      ots.tracking_ref::text,
      otla.order_id,
      o.order_ref::text,
      otla.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
      otla.qty_allocated,
      otla.adjusted_net_value_gbp,
      scal.allocated_amount
    FROM public.shipper_shipment_batch_packages p
    LEFT JOIN public.order_tracking_submissions ots ON ots.id = p.tracking_submission_id
    LEFT JOIN public.order_tracking_line_allocations otla ON otla.tracking_submission_id = p.tracking_submission_id
    LEFT JOIN public.orders o ON o.id = otla.order_id
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = otla.supplier_invoice_line_id
    LEFT JOIN current_allocation ca ON true
    LEFT JOIN public.shipping_cost_allocation_lines scal
      ON scal.shipping_cost_allocation_id = ca.id
     AND scal.tracking_submission_id = p.tracking_submission_id
     AND scal.supplier_invoice_line_id = otla.supplier_invoice_line_id
    WHERE p.shipment_batch_id = p_shipment_batch_id
      AND p.active = true
  )
  SELECT
    b.id AS shipment_batch_id,
    b.booking_ref::text,
    b.shipper_id,
    b.shipper_name::text,
    b.importer_id,
    b.importer_name::text,
    d.id AS shipping_document_id,
    d.document_kind::text,
    COALESCE(d.extracted_document_ref, d.document_ref)::text AS shipping_document_ref,
    COALESCE(d.extracted_document_date, d.document_date) AS shipping_document_date,
    COALESCE(d.extracted_currency_code, d.currency_code, 'GBP')::text AS shipping_document_currency,
    COALESCE(d.extracted_total_amount, d.total_amount, 0) AS shipping_document_total,
    d.review_status::text AS shipping_document_review_status,
    ca.id AS shipping_cost_allocation_id,
    ca.allocation_status::text AS shipping_apportionment_status,
    ca.approved_at AS shipping_apportionment_approved_at,
    ls.order_id,
    ls.order_ref,
    ls.tracking_submission_id,
    ls.tracking_ref,
    ls.supplier_invoice_line_id,
    ls.item_description,
    COALESCE(ls.qty_allocated, 0),
    COALESCE(ls.adjusted_net_value_gbp, 0),
    COALESCE(ls.allocated_amount, 0),
    'sage_ap_invoice_for_shipper_charge'::text AS ap_document_route,
    COALESCE(st.customer_recharge_route, 'sales_invoice_route_not_resolved')::text AS customer_recharge_route,
    COALESCE(st.sales_invoice_state, CASE WHEN v_has_sales_invoices THEN 'sales_invoice_state_not_found_for_order' ELSE 'sales_invoice_table_not_available' END)::text AS sales_invoice_state,
    CASE
      WHEN d.id IS NULL THEN 'blocked_missing_shipper_document'
      WHEN d.review_status <> 'accepted_current' THEN 'blocked_shipper_document_not_accepted'
      WHEN ca.id IS NULL OR ca.allocation_status <> 'approved' THEN 'blocked_shipping_apportionment_not_approved'
      WHEN ls.order_id IS NULL THEN 'blocked_no_allocated_order_lines'
      WHEN COALESCE(ls.allocated_amount, 0) <= 0 THEN 'blocked_no_allocated_shipping_amount'
      ELSE 'ready_for_ap_and_customer_recharge_payload_preview'
    END::text AS readiness_status,
    CASE
      WHEN d.id IS NULL THEN 'missing_shipper_invoice_or_receipt'
      WHEN d.review_status <> 'accepted_current' THEN 'shipper_document_requires_supervisor_acceptance'
      WHEN ca.id IS NULL OR ca.allocation_status <> 'approved' THEN 'shipping_cost_apportionment_not_approved'
      WHEN ls.order_id IS NULL THEN 'no_order_lines_linked_to_shipment_batch'
      WHEN COALESCE(ls.allocated_amount, 0) <= 0 THEN 'allocated_shipping_amount_missing'
      ELSE NULL
    END::text AS blocker
  FROM batch b
  LEFT JOIN current_doc d ON d.shipment_batch_id = b.id
  LEFT JOIN current_allocation ca ON true
  LEFT JOIN line_scope ls ON true
  LEFT JOIN pg_temp._shipping_sales_state_tmp st ON st.order_id = ls.order_id
  ORDER BY ls.order_ref NULLS LAST, ls.tracking_ref NULLS LAST, ls.item_description NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_ap_recharge_readiness_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_ap_recharge_readiness_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
