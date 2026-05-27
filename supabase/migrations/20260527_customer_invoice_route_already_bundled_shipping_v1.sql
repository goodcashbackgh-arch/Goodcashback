BEGIN;

-- Correct customer invoice routing where the main customer sales invoice already bundled
-- the shipment's goods value and apportioned shipping charge. Prevents a posted bundled
-- main invoice from being presented as if a supplementary shipping recharge is still due.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(p_shipment_batch_id uuid)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  importer_id uuid,
  importer_name text,
  shipper_id uuid,
  shipper_name text,
  proposed_invoice_type text,
  proposed_invoice_status text,
  customer_recharge_route text,
  sales_invoice_state text,
  vat_code text,
  proposed_amount_gbp numeric,
  proposed_goods_amount_gbp numeric,
  proposed_shipping_amount_gbp numeric,
  line_items_json jsonb,
  order_id uuid,
  order_ref text,
  tracking_submission_id uuid,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  goods_amount_gbp numeric,
  shipping_amount_gbp numeric,
  total_line_amount_gbp numeric,
  readiness_status text,
  blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer invoice readiness preview requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for customer invoice readiness preview.';
  END IF;

  RETURN QUERY
  WITH batch AS (
    SELECT
      b.id,
      b.booking_ref::text AS booking_ref,
      b.importer_id,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
      b.shipper_id,
      s.name::text AS shipper_name
    FROM public.shipper_shipment_batches b
    JOIN public.shippers s ON s.id = b.shipper_id
    LEFT JOIN public.importers i ON i.id = b.importer_id
    WHERE b.id = p_shipment_batch_id
  ), goods_scope AS (
    SELECT
      b.id AS shipment_batch_id,
      b.booking_ref,
      b.importer_id,
      b.importer_name,
      b.shipper_id,
      b.shipper_name,
      p.tracking_submission_id,
      ots.tracking_ref::text AS tracking_ref,
      otla.order_id,
      o.order_ref::text AS order_ref,
      otla.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
      COALESCE(otla.qty_allocated, 0)::numeric AS qty_allocated,
      COALESCE(otla.adjusted_net_value_gbp, 0)::numeric AS goods_amount_gbp
    FROM batch b
    JOIN public.shipper_shipment_batch_packages p
      ON p.shipment_batch_id = b.id
     AND p.active = true
    LEFT JOIN public.order_tracking_submissions ots
      ON ots.id = p.tracking_submission_id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.tracking_submission_id = p.tracking_submission_id
    LEFT JOIN public.orders o
      ON o.id = otla.order_id
    LEFT JOIN public.supplier_invoice_lines sil
      ON sil.id = otla.supplier_invoice_line_id
  ), ap_scope AS (
    SELECT ap.*
    FROM public.internal_shipping_ap_recharge_readiness_preview_v1(p_shipment_batch_id) ap
  ), line_basis AS (
    SELECT
      gs.*,
      COALESCE(ap.allocated_shipping_amount, 0)::numeric AS allocated_shipping_amount,
      ap.blocker AS ap_blocker,
      ap.customer_recharge_route AS ap_customer_recharge_route
    FROM goods_scope gs
    LEFT JOIN ap_scope ap
      ON ap.order_id IS NOT DISTINCT FROM gs.order_id
     AND ap.tracking_submission_id IS NOT DISTINCT FROM gs.tracking_submission_id
     AND ap.supplier_invoice_line_id IS NOT DISTINCT FROM gs.supplier_invoice_line_id
  ), order_totals AS (
    SELECT
      lb.order_id,
      COALESCE(SUM(lb.goods_amount_gbp), 0)::numeric AS goods_amount_gbp,
      COALESCE(SUM(lb.allocated_shipping_amount), 0)::numeric AS shipping_amount_gbp,
      COALESCE(SUM(lb.goods_amount_gbp + lb.allocated_shipping_amount), 0)::numeric AS bundled_amount_gbp
    FROM line_basis lb
    WHERE lb.order_id IS NOT NULL
    GROUP BY lb.order_id
  ), order_invoice_flags AS (
    SELECT
      ot.order_id,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices si
        WHERE si.order_id = ot.order_id
          AND COALESCE(si.invoice_type::text, '') = 'main'
          AND COALESCE(si.sage_status::text, '') = 'posted'
      ) AS has_posted_main_invoice,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices si
        WHERE si.order_id = ot.order_id
          AND COALESCE(si.invoice_type::text, '') = 'main'
          AND COALESCE(si.sage_status::text, '') = 'draft'
      ) AS has_draft_main_invoice,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices si
        WHERE si.order_id = ot.order_id
          AND COALESCE(si.invoice_type::text, '') = 'main'
          AND COALESCE(si.sage_status::text, '') = 'void'
      ) AS has_void_main_invoice,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices si
        WHERE si.order_id = ot.order_id
          AND COALESCE(si.invoice_type::text, '') = 'main'
          AND COALESCE(si.sage_status::text, '') = 'posted'
          AND (
            (si.commercial_payload #>> '{draft_control,shipment_batch_id}') = p_shipment_batch_id::text
            OR (
              ot.shipping_amount_gbp > 0
              AND ABS(COALESCE(si.amount_gbp, 0)::numeric - ot.bundled_amount_gbp) <= 0.01
              AND COALESCE(si.amount_gbp, 0)::numeric > ot.goods_amount_gbp
            )
          )
      ) AS has_posted_bundled_main_invoice
    FROM order_totals ot
  ), route AS (
    SELECT
      CASE
        WHEN COALESCE(bool_or(oif.has_posted_bundled_main_invoice), false)
          AND NOT COALESCE(bool_or(oif.has_posted_main_invoice AND NOT oif.has_posted_bundled_main_invoice), false)
          THEN 'already_bundled_main'
        WHEN COALESCE(bool_or(oif.has_posted_main_invoice), false)
          THEN 'supplementary'
        ELSE 'main'
      END::text AS resolved_route
    FROM order_invoice_flags oif
  ), line_calc AS (
    SELECT
      lb.shipment_batch_id,
      lb.booking_ref,
      lb.importer_id,
      lb.importer_name,
      lb.shipper_id,
      lb.shipper_name,
      lb.tracking_submission_id,
      lb.tracking_ref,
      lb.order_id,
      lb.order_ref,
      lb.supplier_invoice_line_id,
      lb.item_description,
      lb.qty_allocated,
      lb.goods_amount_gbp,
      lb.allocated_shipping_amount AS shipping_amount_gbp,
      r.resolved_route,
      CASE
        WHEN r.resolved_route = 'already_bundled_main' THEN 'main'
        ELSE r.resolved_route
      END::text AS resolved_invoice_type,
      CASE
        WHEN r.resolved_route = 'already_bundled_main' THEN 'already_bundled_in_main_sales_invoice'
        WHEN r.resolved_route = 'supplementary' THEN COALESCE(lb.ap_customer_recharge_route, 'supplementary_shipping_recharge_invoice_review_required')
        ELSE 'main_goods_invoice_release'
      END::text AS resolved_customer_recharge_route,
      CASE
        WHEN COALESCE(oif.has_posted_bundled_main_invoice, false) THEN 'main_sales_invoice_posted_bundled'
        WHEN COALESCE(oif.has_posted_main_invoice, false) THEN 'main_sales_invoice_posted'
        WHEN COALESCE(oif.has_draft_main_invoice, false) THEN 'main_sales_invoice_draft_exists'
        WHEN COALESCE(oif.has_void_main_invoice, false) THEN 'main_sales_invoice_void_ignored'
        ELSE 'no_main_sales_invoice_found'
      END::text AS sales_invoice_state,
      CASE
        WHEN r.resolved_route = 'supplementary' THEN 0::numeric
        ELSE lb.goods_amount_gbp
      END AS calc_goods_invoice_gbp,
      CASE
        WHEN r.resolved_route IN ('supplementary', 'already_bundled_main') THEN lb.allocated_shipping_amount
        ELSE 0::numeric
      END AS calc_shipping_invoice_gbp,
      CASE
        WHEN r.resolved_route = 'supplementary' THEN lb.allocated_shipping_amount
        WHEN r.resolved_route = 'already_bundled_main' THEN lb.goods_amount_gbp + lb.allocated_shipping_amount
        ELSE lb.goods_amount_gbp
      END AS calc_total_invoice_gbp,
      CASE
        WHEN lb.order_id IS NULL THEN 'no_order_lines_linked_to_shipment_batch'
        WHEN lb.supplier_invoice_line_id IS NULL THEN 'shipment_line_missing_supplier_invoice_line'
        WHEN COALESCE(lb.qty_allocated, 0) <= 0 THEN 'allocated_quantity_missing'
        WHEN r.resolved_route = 'main' AND COALESCE(lb.goods_amount_gbp, 0) <= 0 THEN 'goods_amount_missing'
        WHEN r.resolved_route = 'supplementary' AND lb.ap_blocker IS NOT NULL THEN lb.ap_blocker
        WHEN r.resolved_route = 'supplementary' AND COALESCE(lb.allocated_shipping_amount, 0) <= 0 THEN 'allocated_shipping_amount_missing'
        ELSE NULL
      END::text AS blocker,
      CONCAT(
        CASE
          WHEN r.resolved_route = 'supplementary' THEN 'Supplementary export sale shipping charge'
          ELSE 'Export sale goods charge'
        END,
        ' - ', COALESCE(NULLIF(lb.order_ref, ''), lb.order_id::text),
        ' - Booking ', COALESCE(NULLIF(lb.booking_ref, ''), lb.shipment_batch_id::text)
      )::text AS customer_payload_description
    FROM line_basis lb
    CROSS JOIN route r
    LEFT JOIN order_invoice_flags oif
      ON oif.order_id = lb.order_id
  ), totals AS (
    SELECT
      COALESCE(SUM(lc.calc_goods_invoice_gbp), 0) AS total_goods_invoice_gbp,
      COALESCE(SUM(lc.calc_shipping_invoice_gbp), 0) AS total_shipping_invoice_gbp,
      COALESCE(SUM(lc.calc_total_invoice_gbp), 0) AS total_customer_invoice_gbp,
      jsonb_agg(
        jsonb_build_object(
          'released_qty', lc.qty_allocated,
          'source_order_id', lc.order_id,
          'source_order_ref', lc.order_ref,
          'source_shipment_booking_ref', lc.booking_ref,
          'source_tracking_submission_id', lc.tracking_submission_id,
          'source_supplier_invoice_line_id', lc.supplier_invoice_line_id,
          'description', lc.customer_payload_description,
          'customer_charge_amount_gbp', lc.calc_total_invoice_gbp,
          'total_line_amount_gbp', lc.calc_total_invoice_gbp,
          'billed_or_credited_flag', 'billed',
          'presentation', CASE
            WHEN lc.resolved_route = 'already_bundled_main' THEN 'bundled_goods_and_shipping_export_sale_charge'
            WHEN lc.resolved_route = 'supplementary' THEN 'supplementary_shipping_export_sale_charge'
            ELSE 'main_goods_export_sale_charge'
          END,
          'sage_tax_rate_id', 'GB_ZERO',
          'sage_tax_rate_display', 'Zero Rated 0.00%',
          'display_vat_code', 'T0',
          'customer_gl_role', 'export_sale_income',
          'ap_gl_role_note', CASE
            WHEN lc.resolved_route = 'already_bundled_main' THEN 'Main customer sales invoice already bundles goods and apportioned shipping for this shipment batch.'
            WHEN lc.resolved_route = 'supplementary' THEN 'Supplementary shipping recharge waits for accepted shipper AP/apportionment.'
            ELSE 'Main goods invoice release does not require shipper AP invoice/apportionment.'
          END,
          'source', 'shipping_customer_invoice_readiness_preview_bundled_route_v1'
        ) ORDER BY lc.order_ref NULLS LAST, lc.booking_ref NULLS LAST, lc.customer_payload_description NULLS LAST
      ) FILTER (WHERE lc.calc_total_invoice_gbp > 0) AS preview_line_items_json
    FROM line_calc lc
  )
  SELECT
    lc.shipment_batch_id,
    lc.booking_ref,
    lc.importer_id,
    lc.importer_name,
    lc.shipper_id,
    lc.shipper_name,
    lc.resolved_invoice_type AS proposed_invoice_type,
    CASE
      WHEN lc.blocker IS NOT NULL THEN 'blocked'
      ELSE 'draft_preview'
    END::text AS proposed_invoice_status,
    lc.resolved_customer_recharge_route AS customer_recharge_route,
    lc.sales_invoice_state,
    'T0 / GB_ZERO'::text AS vat_code,
    t.total_customer_invoice_gbp AS proposed_amount_gbp,
    t.total_goods_invoice_gbp AS proposed_goods_amount_gbp,
    t.total_shipping_invoice_gbp AS proposed_shipping_amount_gbp,
    COALESCE(t.preview_line_items_json, '[]'::jsonb) AS line_items_json,
    lc.order_id,
    lc.order_ref,
    lc.tracking_submission_id,
    lc.tracking_ref,
    lc.supplier_invoice_line_id,
    lc.customer_payload_description AS item_description,
    COALESCE(lc.qty_allocated, 0) AS qty_allocated,
    lc.calc_goods_invoice_gbp AS goods_amount_gbp,
    lc.calc_shipping_invoice_gbp AS shipping_amount_gbp,
    lc.calc_total_invoice_gbp AS total_line_amount_gbp,
    CASE
      WHEN lc.blocker IS NOT NULL THEN 'blocked'
      WHEN lc.resolved_route = 'already_bundled_main' THEN 'already_bundled_in_main_sales_invoice'
      WHEN lc.resolved_route = 'supplementary' THEN 'ready_for_supplementary_invoice_preview'
      ELSE 'ready_for_main_invoice_release_preview'
    END::text AS readiness_status,
    lc.blocker
  FROM line_calc lc
  CROSS JOIN totals t
  ORDER BY lc.order_ref NULLS LAST, lc.booking_ref NULLS LAST, lc.customer_payload_description NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
