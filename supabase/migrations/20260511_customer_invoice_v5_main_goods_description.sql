BEGIN;

CREATE OR REPLACE FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(p_shipment_batch_id uuid)
RETURNS TABLE (
  shipment_batch_id uuid, booking_ref text, importer_id uuid, importer_name text, shipper_id uuid, shipper_name text,
  proposed_invoice_type text, proposed_invoice_status text, customer_recharge_route text, sales_invoice_state text, vat_code text,
  proposed_amount_gbp numeric, proposed_goods_amount_gbp numeric, proposed_shipping_amount_gbp numeric, line_items_json jsonb,
  order_id uuid, order_ref text, tracking_submission_id uuid, tracking_ref text, supplier_invoice_line_id uuid,
  item_description text, qty_allocated numeric, goods_amount_gbp numeric, shipping_amount_gbp numeric, total_line_amount_gbp numeric,
  readiness_status text, blocker text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user'; END IF;
  IF NOT public.is_active_staff() THEN RAISE EXCEPTION 'Active staff account required'; END IF;

  RETURN QUERY
  WITH src AS (
    SELECT * FROM public.internal_shipping_ap_recharge_readiness_preview_v1(p_shipment_batch_id)
  ), r AS (
    SELECT
      CASE WHEN EXISTS (SELECT 1 FROM src WHERE customer_recharge_route IN ('supplementary_shipping_recharge_invoice','supplementary_shipping_recharge_invoice_review_required')) THEN 'supplementary' ELSE 'main' END::text AS inv_type,
      CASE WHEN EXISTS (SELECT 1 FROM src WHERE blocker IS NOT NULL) THEN 'blocked' ELSE 'draft_preview' END::text AS inv_status,
      COALESCE((SELECT customer_recharge_route FROM src WHERE customer_recharge_route IS NOT NULL LIMIT 1),'sales_invoice_route_not_resolved')::text AS route,
      COALESCE((SELECT sales_invoice_state FROM src WHERE sales_invoice_state IS NOT NULL LIMIT 1),'sales_invoice_state_not_resolved')::text AS si_state
  ), l AS (
    SELECT s.*, r.inv_type, r.inv_status, r.route, r.si_state,
      CASE WHEN r.inv_type='supplementary' THEN 0::numeric ELSE COALESCE(s.adjusted_goods_basis_gbp,0) END AS goods_evidence,
      COALESCE(s.allocated_shipping_amount,0) AS shipping_evidence,
      CASE WHEN r.inv_type='supplementary' THEN COALESCE(s.allocated_shipping_amount,0) ELSE COALESCE(s.adjusted_goods_basis_gbp,0)+COALESCE(s.allocated_shipping_amount,0) END AS bundled_amount,
      CASE WHEN r.inv_type='supplementary'
        THEN CONCAT('Supplementary export sale charge - ', COALESCE(NULLIF(s.order_ref,''),s.order_id::text), ' - Booking ', COALESCE(NULLIF(s.booking_ref,''),s.shipment_batch_id::text))
        ELSE CONCAT(COALESCE(NULLIF(s.item_description,''),'Goods'), ' - ', COALESCE(NULLIF(s.order_ref,''),s.order_id::text), ' - Booking ', COALESCE(NULLIF(s.booking_ref,''),s.shipment_batch_id::text))
      END::text AS customer_desc
    FROM src s CROSS JOIN r
  ), t AS (
    SELECT COALESCE(SUM(goods_evidence),0) goods_total, COALESCE(SUM(shipping_evidence),0) shipping_total, COALESCE(SUM(bundled_amount),0) invoice_total,
      jsonb_agg(jsonb_build_object(
        'released_qty', qty_allocated,
        'description', customer_desc,
        'customer_charge_amount_gbp', bundled_amount,
        'total_line_amount_gbp', bundled_amount,
        'billed_or_credited_flag', 'billed',
        'presentation', 'bundled_export_sale_charge',
        'sage_tax_rate_id', 'GB_ZERO',
        'sage_tax_rate_display', 'Zero Rated 0.00%',
        'display_vat_code', 'T0',
        'customer_gl_role', 'export_sale_income',
        'source_order_id', order_id,
        'source_order_ref', order_ref,
        'source_shipment_booking_ref', booking_ref,
        'source_tracking_submission_id', tracking_submission_id,
        'source_supplier_invoice_line_id', supplier_invoice_line_id,
        'source', 'shipping_customer_invoice_readiness_preview'
      ) ORDER BY order_ref NULLS LAST, booking_ref NULLS LAST, customer_desc NULLS LAST) payload
    FROM l
  )
  SELECT l.shipment_batch_id,l.booking_ref,l.importer_id,l.importer_name,l.shipper_id,l.shipper_name,
    l.inv_type,l.inv_status,l.route,l.si_state,'T0 / GB_ZERO'::text,
    t.invoice_total,t.goods_total,t.shipping_total,COALESCE(t.payload,'[]'::jsonb),
    l.order_id,l.order_ref,l.tracking_submission_id,l.tracking_ref,l.supplier_invoice_line_id,l.customer_desc,
    COALESCE(l.qty_allocated,0),l.goods_evidence,l.shipping_evidence,l.bundled_amount,
    CASE WHEN l.blocker IS NOT NULL THEN 'blocked' WHEN l.inv_type='supplementary' THEN 'ready_for_supplementary_invoice_preview' ELSE 'ready_for_main_invoice_release_preview' END::text,
    l.blocker
  FROM l CROSS JOIN t
  ORDER BY l.order_ref NULLS LAST, l.booking_ref NULLS LAST, l.customer_desc NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
