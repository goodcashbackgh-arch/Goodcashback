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
          SELECT 1
          FROM src s1
          WHERE s1.customer_recharge_route IN ('supplementary_shipping_recharge_invoice','supplementary_shipping_recharge_invoice_review_required')
        ) THEN 'supplementary'
        ELSE 'main'
      END::text AS resolved_invoice_type,
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM src s2
          WHERE s2.blocker IS NOT NULL
        ) THEN 'blocked'
        ELSE 'draft_preview'
      END::text AS resolved_invoice_status,
      COALESCE(
        (
          SELECT s3.customer_recharge_route
          FROM src s3
          WHERE s3.customer_recharge_route IS NOT NULL
          LIMIT 1
        ),
        'sales_invoice_route_not_resolved'
      )::text AS resolved_customer_recharge_route,
      COALESCE(
        (
          SELECT s4.sales_invoice_state
          FROM src s4
          WHERE s4.sales_invoice_state IS NOT NULL
          LIMIT 1
        ),
        'sales_invoice_state_not_resolved'
      )::text AS resolved_sales_invoice_state
  ), line_calc AS (
    SELECT
      s.*,
      r.resolved_invoice_type,
      r.resolved_invoice_status,
      r.resolved_customer_recharge_route,
      r.resolved_sales_invoice_state,
      CASE
        WHEN r.resolved_invoice_type = 'supplementary' THEN 0::numeric
        ELSE COALESCE(s.adjusted_goods_basis_gbp, 0)
      END AS calc_goods_evidence_gbp,
      COALESCE(s.allocated_shipping_amount, 0) AS calc_shipping_evidence_gbp,
      CASE
        WHEN r.resolved_invoice_type = 'supplementary' THEN COALESCE(s.allocated_shipping_amount, 0)
        ELSE COALESCE(s.adjusted_goods_basis_gbp, 0) + COALESCE(s.allocated_shipping_amount, 0)
      END AS calc_bundled_customer_charge_gbp,
      CONCAT(
        CASE
          WHEN r.resolved_invoice_type = 'supplementary' THEN 'Supplementary principal export sale charge'
          ELSE 'Principal export sale charge'
        END,
        ' - ', COALESCE(NULLIF(s.order_ref, ''), s.order_id::text),
        ' - Booking ', COALESCE(NULLIF(s.booking_ref, ''), s.shipment_batch_id::text)
      )::text AS customer_payload_description
    FROM src s
    CROSS JOIN route r
  ), totals AS (
    SELECT
      COALESCE(SUM(lc.calc_goods_evidence_gbp), 0) AS total_goods_evidence_gbp,
      COALESCE(SUM(lc.calc_shipping_evidence_gbp), 0) AS total_shipping_evidence_gbp,
      COALESCE(SUM(lc.calc_bundled_customer_charge_gbp), 0) AS total_bundled_customer_charge_gbp,
      jsonb_agg(
        jsonb_build_object(
          'released_qty', lc.qty_allocated,
          'source_order_id', lc.order_id,
          'source_order_ref', lc.order_ref,
          'source_shipment_booking_ref', lc.booking_ref,
          'source_tracking_submission_id', lc.tracking_submission_id,
          'source_supplier_invoice_line_id', lc.supplier_invoice_line_id,
          'description', lc.customer_payload_description,
          'customer_charge_amount_gbp', lc.calc_bundled_customer_charge_gbp,
          'total_line_amount_gbp', lc.calc_bundled_customer_charge_gbp,
          'billed_or_credited_flag', 'billed',
          'presentation', 'bundled_principal_export_sale_charge',
          'sage_tax_rate_id', 'GB_ZERO',
          'sage_tax_rate_display', 'Zero Rated 0.00%',
          'display_vat_code', 'T0',
          'customer_gl_role', 'principal_export_sale_income',
          'ap_gl_role_note', 'AP shipper bill should use freight/shipping cost GL; customer sale uses principal export sale income treatment',
          'principal_status_note', 'Customer document is treated as principal sale, not agency recharge',
          'source', 'shipping_customer_invoice_readiness_preview'
        ) ORDER BY lc.order_ref NULLS LAST, lc.booking_ref NULLS LAST, lc.customer_payload_description NULLS LAST
      ) AS preview_line_items_json
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
    lc.resolved_invoice_status AS proposed_invoice_status,
    lc.resolved_customer_recharge_route AS customer_recharge_route,
    lc.resolved_sales_invoice_state AS sales_invoice_state,
    'T0 / GB_ZERO'::text AS vat_code,
    t.total_bundled_customer_charge_gbp AS proposed_amount_gbp,
    t.total_goods_evidence_gbp AS proposed_goods_amount_gbp,
    t.total_shipping_evidence_gbp AS proposed_shipping_amount_gbp,
    COALESCE(t.preview_line_items_json, '[]'::jsonb) AS line_items_json,
    lc.order_id,
    lc.order_ref,
    lc.tracking_submission_id,
    lc.tracking_ref,
    lc.supplier_invoice_line_id,
    lc.customer_payload_description AS item_description,
    COALESCE(lc.qty_allocated, 0) AS qty_allocated,
    lc.calc_goods_evidence_gbp AS goods_amount_gbp,
    lc.calc_shipping_evidence_gbp AS shipping_amount_gbp,
    lc.calc_bundled_customer_charge_gbp AS total_line_amount_gbp,
    CASE
      WHEN lc.blocker IS NOT NULL THEN 'blocked'
      WHEN lc.resolved_invoice_type = 'supplementary' THEN 'ready_for_supplementary_invoice_preview'
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
