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
      CASE WHEN EXISTS (
        SELECT 1 FROM src s1
        WHERE s1.customer_recharge_route IN ('supplementary_shipping_recharge_invoice','supplementary_shipping_recharge_invoice_review_required')
      ) THEN 'supplementary' ELSE 'main' END::text AS inv_type,
      CASE WHEN EXISTS (SELECT 1 FROM src s2 WHERE s2.blocker IS NOT NULL) THEN 'blocked' ELSE 'draft_preview' END::text AS inv_status,
      COALESCE((SELECT s3.customer_recharge_route FROM src s3 WHERE s3.customer_recharge_route IS NOT NULL LIMIT 1),'sales_invoice_route_not_resolved')::text AS route_value,
      COALESCE((SELECT s4.sales_invoice_state FROM src s4 WHERE s4.sales_invoice_state IS NOT NULL LIMIT 1),'sales_invoice_state_not_resolved')::text AS si_state
  ), l AS (
    SELECT s.*, r.inv_type, r.inv_status, r.route_value, r.si_state,
      CASE WHEN r.inv_type='supplementary' THEN 0::numeric ELSE COALESCE(s.adjusted_goods_basis_gbp,0) END AS goods_evidence,
      COALESCE(s.allocated_shipping_amount,0) AS shipping_evidence,
      CASE WHEN r.inv_type='supplementary' THEN COALESCE(s.allocated_shipping_amount,0) ELSE COALESCE(s.adjusted_goods_basis_gbp,0)+COALESCE(s.allocated_shipping_amount,0) END AS bundled_amount,
      CASE WHEN r.inv_type='supplementary' THEN 'Supplementary export sale charge' ELSE COALESCE(NULLIF(s.item_description,''),'Goods') END::text AS sage_line_description
    FROM src s CROSS JOIN r
  ), h AS (
    SELECT
      COALESCE((SELECT l1.order_ref FROM l l1 WHERE l1.order_ref IS NOT NULL LIMIT 1), '')::text AS sage_reference,
      CONCAT('Booking ', COALESCE((SELECT l2.booking_ref FROM l l2 WHERE l2.booking_ref IS NOT NULL LIMIT 1), ''))::text AS sage_notes
  ), t AS (
    SELECT COALESCE(SUM(l2.goods_evidence),0) goods_total, COALESCE(SUM(l2.shipping_evidence),0) shipping_total, COALESCE(SUM(l2.bundled_amount),0) invoice_total,
      jsonb_build_object(
        'sage_header', jsonb_build_object(
          'reference', h.sage_reference,
          'notes', h.sage_notes,
          'reference_source', 'order_ref',
          'notes_source', 'booking_ref'
        ),
        'tax_resolution', jsonb_build_object(
          'tax_treatment', 'zero_rated_export',
          'sage_tax_rate_id', NULL,
          'sage_tax_rate_resolution_required', true,
          'display_vat_code', 'zero-rated export'
        ),
        'lines', jsonb_agg(jsonb_build_object(
          'description', l2.sage_line_description,
          'quantity', COALESCE(l2.qty_allocated,1),
          'unit_price_gbp', CASE WHEN COALESCE(l2.qty_allocated,0) = 0 THEN l2.bundled_amount ELSE ROUND(l2.bundled_amount / l2.qty_allocated, 2) END,
          'total_line_amount_gbp', l2.bundled_amount,
          'ledger_account_role', 'export_sale_income'
        ) ORDER BY l2.order_ref NULLS LAST, l2.booking_ref NULLS LAST, l2.sage_line_description NULLS LAST)
      ) payload
    FROM l l2 CROSS JOIN h
    GROUP BY h.sage_reference, h.sage_notes
  )
  SELECT l.shipment_batch_id,l.booking_ref,l.importer_id,l.importer_name,l.shipper_id,l.shipper_name,
    l.inv_type,l.inv_status,l.route_value,l.si_state,'zero-rated export - Sage tax rate unresolved'::text,
    t.invoice_total,t.goods_total,t.shipping_total,COALESCE(t.payload,'{}'::jsonb),
    l.order_id,l.order_ref,l.tracking_submission_id,l.tracking_ref,l.supplier_invoice_line_id,l.sage_line_description,
    COALESCE(l.qty_allocated,0),l.goods_evidence,l.shipping_evidence,l.bundled_amount,
    CASE WHEN l.blocker IS NOT NULL THEN 'blocked' WHEN l.inv_type='supplementary' THEN 'ready_for_supplementary_invoice_preview' ELSE 'ready_for_main_invoice_release_preview' END::text,
    l.blocker
  FROM l CROSS JOIN t
  ORDER BY l.order_ref NULLS LAST, l.booking_ref NULLS LAST, l.sage_line_description NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
