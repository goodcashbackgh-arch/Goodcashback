BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Customer release remaining-preview prerequisite missing';
  END IF;
END $$;

-- Explicit source aliases avoid any collision between RETURNS TABLE output
-- variables and the identically named columns carried by the source CTE.
CREATE OR REPLACE FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(
  p_shipment_batch_id uuid
)
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
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required';
  END IF;

  RETURN QUERY
  WITH src AS (
    SELECT *
    FROM public.internal_customer_sales_release_sources_v1(p_shipment_batch_id)
  ), totals AS (
    SELECT
      COALESCE(
        SUM(source_row.customer_charge_amount_gbp)
          FILTER (WHERE source_row.blocker IS NULL),
        0
      )::numeric AS amount,
      COALESCE(
        SUM(source_row.goods_amount_gbp)
          FILTER (WHERE source_row.blocker IS NULL),
        0
      )::numeric AS goods,
      COALESCE(
        SUM(source_row.shipping_amount_gbp)
          FILTER (WHERE source_row.blocker IS NULL),
        0
      )::numeric AS shipping,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'source_order_id', source_row.source_order_id,
            'source_commercial_parent_order_id', source_row.commercial_parent_order_id,
            'source_shipment_batch_id', source_row.shipment_batch_id,
            'source_tracking_submission_id', source_row.tracking_submission_id,
            'source_tracking_line_allocation_id', source_row.tracking_line_allocation_id,
            'source_supplier_invoice_id', source_row.supplier_invoice_id,
            'source_supplier_invoice_line_id', source_row.supplier_invoice_line_id,
            'released_qty', source_row.release_qty,
            'goods_amount_gbp', source_row.goods_amount_gbp,
            'delivery_share_gbp', source_row.delivery_share_gbp,
            'discount_share_gbp', source_row.discount_share_gbp,
            'shipping_amount_gbp', source_row.shipping_amount_gbp,
            'customer_charge_amount_gbp', source_row.customer_charge_amount_gbp,
            'membership_fingerprint', source_row.membership_fingerprint,
            'description', source_row.item_description,
            'quantity', CASE WHEN source_row.release_qty > 0 THEN source_row.release_qty ELSE 1 END,
            'total_line_amount_gbp', source_row.customer_charge_amount_gbp,
            'ledger_account_role', 'export_sale_income',
            'source', 'customer_sales_release_ledger'
          )
          ORDER BY source_row.order_ref, source_row.tracking_ref, source_row.item_description
        ) FILTER (WHERE source_row.blocker IS NULL),
        '[]'::jsonb
      ) AS lines
    FROM src source_row
  )
  SELECT
    source_row.shipment_batch_id,
    source_row.booking_ref,
    source_row.importer_id,
    source_row.importer_name,
    source_row.shipper_id,
    source_row.shipper_name,
    source_row.proposed_invoice_type,
    CASE WHEN source_row.blocker IS NULL THEN 'draft_preview' ELSE 'blocked' END,
    CASE
      WHEN source_row.proposed_invoice_type = 'main' THEN 'main_customer_release_invoice'
      ELSE 'supplementary_customer_release_invoice'
    END,
    source_row.sales_invoice_state,
    'T0 / GB_ZERO'::text,
    total_row.amount,
    total_row.goods,
    total_row.shipping,
    total_row.lines,
    source_row.commercial_parent_order_id,
    source_row.order_ref,
    source_row.tracking_submission_id,
    source_row.tracking_ref,
    source_row.supplier_invoice_line_id,
    source_row.item_description,
    source_row.release_qty,
    source_row.goods_amount_gbp,
    source_row.shipping_amount_gbp,
    source_row.customer_charge_amount_gbp,
    CASE
      WHEN source_row.blocker IS NOT NULL THEN 'blocked'
      WHEN source_row.proposed_invoice_type = 'main' THEN 'ready_for_main_invoice_release_preview'
      ELSE 'ready_for_supplementary_invoice_preview'
    END,
    source_row.blocker
  FROM src source_row
  CROSS JOIN totals total_row
  WHERE source_row.blocker IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM src ready_source
       WHERE ready_source.blocker IS NULL
     )
  ORDER BY source_row.order_ref, source_row.tracking_ref, source_row.item_description;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
