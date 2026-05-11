BEGIN;

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
  WITH src AS (
    SELECT *
    FROM public.internal_shipping_ap_recharge_readiness_preview_v1(p_shipment_batch_id)
  ), route AS (
    SELECT
      CASE
        WHEN EXISTS (
          SELECT 1 FROM src
          WHERE customer_recharge_route IN ('supplementary_shipping_recharge_invoice','supplementary_shipping_recharge_invoice_review_required')
        ) THEN 'supplementary'
        ELSE 'main'
      END::text AS proposed_invoice_type,
      CASE
        WHEN EXISTS (SELECT 1 FROM src WHERE blocker IS NOT NULL) THEN 'blocked'
        ELSE 'draft_preview'
      END::text AS proposed_invoice_status,
      COALESCE(
        (SELECT customer_recharge_route FROM src WHERE customer_recharge_route IS NOT NULL LIMIT 1),
        'sales_invoice_route_not_resolved'
      )::text AS customer_recharge_route,
      COALESCE(
        (SELECT sales_invoice_state FROM src WHERE sales_invoice_state IS NOT NULL LIMIT 1),
        'sales_invoice_state_not_resolved'
      )::text AS sales_invoice_state
  ), line_calc AS (
    SELECT
      s.*,
      r.proposed_invoice_type,
      r.proposed_invoice_status,
      r.customer_recharge_route AS resolved_customer_recharge_route,
      r.sales_invoice_state AS resolved_sales_invoice_state,
      CASE
        WHEN r.proposed_invoice_type = 'supplementary' THEN 0::numeric
        ELSE COALESCE(s.adjusted_goods_basis_gbp, 0)
      END AS proposed_goods_amount_gbp,
      COALESCE(s.allocated_shipping_amount, 0) AS proposed_shipping_amount_gbp,
      CASE
        WHEN r.proposed_invoice_type = 'supplementary' THEN COALESCE(s.allocated_shipping_amount, 0)
        ELSE COALESCE(s.adjusted_goods_basis_gbp, 0) + COALESCE(s.allocated_shipping_amount, 0)
      END AS proposed_line_total_gbp
    FROM src s
    CROSS JOIN route r
  ), totals AS (
    SELECT
      COALESCE(SUM(proposed_goods_amount_gbp), 0) AS proposed_goods_amount_gbp,
      COALESCE(SUM(proposed_shipping_amount_gbp), 0) AS proposed_shipping_amount_gbp,
      COALESCE(SUM(proposed_line_total_gbp), 0) AS proposed_amount_gbp,
      jsonb_agg(
        jsonb_build_object(
          'released_qty', qty_allocated,
          'source_order_id', order_id,
          'source_tracking_submission_id', tracking_submission_id,
          'source_supplier_invoice_line_id', supplier_invoice_line_id,
          'description', item_description,
          'goods_amount_gbp', proposed_goods_amount_gbp,
          'shipping_amount_gbp', proposed_shipping_amount_gbp,
          'total_line_amount_gbp', proposed_line_total_gbp,
          'billed_or_credited_flag', 'billed',
          'source', 'shipping_customer_invoice_readiness_preview'
        ) ORDER BY order_ref NULLS LAST, tracking_ref NULLS LAST, item_description NULLS LAST
      ) AS line_items_json
    FROM line_calc
  )
  SELECT
    lc.shipment_batch_id,
    lc.booking_ref,
    lc.importer_id,
    lc.importer_name,
    lc.shipper_id,
    lc.shipper_name,
    lc.proposed_invoice_type,
    lc.proposed_invoice_status,
    lc.resolved_customer_recharge_route,
    lc.resolved_sales_invoice_state,
    'T0'::text AS vat_code,
    t.proposed_amount_gbp,
    t.proposed_goods_amount_gbp,
    t.proposed_shipping_amount_gbp,
    COALESCE(t.line_items_json, '[]'::jsonb),
    lc.order_id,
    lc.order_ref,
    lc.tracking_submission_id,
    lc.tracking_ref,
    lc.supplier_invoice_line_id,
    lc.item_description,
    COALESCE(lc.qty_allocated, 0),
    lc.proposed_goods_amount_gbp,
    lc.proposed_shipping_amount_gbp,
    lc.proposed_line_total_gbp,
    CASE
      WHEN lc.blocker IS NOT NULL THEN 'blocked'
      WHEN lc.proposed_invoice_type = 'supplementary' THEN 'ready_for_supplementary_invoice_preview'
      ELSE 'ready_for_main_invoice_release_preview'
    END::text AS readiness_status,
    lc.blocker
  FROM line_calc lc
  CROSS JOIN totals t
  ORDER BY lc.order_ref NULLS LAST, lc.tracking_ref NULLS LAST, lc.item_description NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
