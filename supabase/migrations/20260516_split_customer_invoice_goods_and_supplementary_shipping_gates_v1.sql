BEGIN;

-- Split customer invoice readiness from shipper/AP readiness.
-- Main customer invoice = stable received goods value only.
-- Supplementary customer invoice = later shipping recharge, still gated by accepted shipper doc + approved apportionment.

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
      COALESCE(otla.adjusted_net_value_gbp, 0)::numeric AS goods_amount_gbp,
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.sales_invoices si
          WHERE si.order_id = otla.order_id
            AND COALESCE(si.invoice_type::text, '') = 'main'
            AND COALESCE(si.sage_status::text, '') = 'posted'
        ) THEN 'main_sales_invoice_posted'
        WHEN EXISTS (
          SELECT 1
          FROM public.sales_invoices si
          WHERE si.order_id = otla.order_id
            AND COALESCE(si.invoice_type::text, '') = 'main'
            AND COALESCE(si.sage_status::text, '') = 'draft'
        ) THEN 'main_sales_invoice_draft_exists'
        WHEN EXISTS (
          SELECT 1
          FROM public.sales_invoices si
          WHERE si.order_id = otla.order_id
            AND COALESCE(si.invoice_type::text, '') = 'main'
            AND COALESCE(si.sage_status::text, '') = 'void'
        ) THEN 'main_sales_invoice_void_ignored'
        ELSE 'no_main_sales_invoice_found'
      END::text AS sales_invoice_state
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
  ), route AS (
    SELECT
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM goods_scope gs
          WHERE gs.sales_invoice_state = 'main_sales_invoice_posted'
        ) THEN 'supplementary'
        ELSE 'main'
      END::text AS resolved_invoice_type
  ), ap_scope AS (
    SELECT ap.*
    FROM route r
    CROSS JOIN LATERAL public.internal_shipping_ap_recharge_readiness_preview_v1(p_shipment_batch_id) ap
    WHERE r.resolved_invoice_type = 'supplementary'
  ), line_calc AS (
    SELECT
      gs.shipment_batch_id,
      gs.booking_ref,
      gs.importer_id,
      gs.importer_name,
      gs.shipper_id,
      gs.shipper_name,
      gs.tracking_submission_id,
      gs.tracking_ref,
      gs.order_id,
      gs.order_ref,
      gs.supplier_invoice_line_id,
      gs.item_description,
      gs.qty_allocated,
      gs.goods_amount_gbp,
      COALESCE(ap.allocated_shipping_amount, 0)::numeric AS shipping_amount_gbp,
      r.resolved_invoice_type,
      CASE
        WHEN r.resolved_invoice_type = 'supplementary' THEN COALESCE(ap.customer_recharge_route, 'supplementary_shipping_recharge_invoice_review_required')
        ELSE 'main_goods_invoice_release'
      END::text AS resolved_customer_recharge_route,
      gs.sales_invoice_state,
      CASE
        WHEN r.resolved_invoice_type = 'supplementary' THEN 0::numeric
        ELSE gs.goods_amount_gbp
      END AS calc_goods_invoice_gbp,
      CASE
        WHEN r.resolved_invoice_type = 'supplementary' THEN COALESCE(ap.allocated_shipping_amount, 0)::numeric
        ELSE 0::numeric
      END AS calc_shipping_invoice_gbp,
      CASE
        WHEN r.resolved_invoice_type = 'supplementary' THEN COALESCE(ap.allocated_shipping_amount, 0)::numeric
        ELSE gs.goods_amount_gbp
      END AS calc_total_invoice_gbp,
      CASE
        WHEN gs.order_id IS NULL THEN 'no_order_lines_linked_to_shipment_batch'
        WHEN gs.supplier_invoice_line_id IS NULL THEN 'shipment_line_missing_supplier_invoice_line'
        WHEN COALESCE(gs.qty_allocated, 0) <= 0 THEN 'allocated_quantity_missing'
        WHEN r.resolved_invoice_type = 'main' AND COALESCE(gs.goods_amount_gbp, 0) <= 0 THEN 'goods_amount_missing'
        WHEN r.resolved_invoice_type = 'supplementary' AND ap.blocker IS NOT NULL THEN ap.blocker
        WHEN r.resolved_invoice_type = 'supplementary' AND COALESCE(ap.allocated_shipping_amount, 0) <= 0 THEN 'allocated_shipping_amount_missing'
        ELSE NULL
      END::text AS blocker,
      CONCAT(
        CASE
          WHEN r.resolved_invoice_type = 'supplementary' THEN 'Supplementary export sale shipping charge'
          ELSE 'Export sale goods charge'
        END,
        ' - ', COALESCE(NULLIF(gs.order_ref, ''), gs.order_id::text),
        ' - Booking ', COALESCE(NULLIF(gs.booking_ref, ''), gs.shipment_batch_id::text)
      )::text AS customer_payload_description
    FROM goods_scope gs
    CROSS JOIN route r
    LEFT JOIN ap_scope ap
      ON ap.order_id IS NOT DISTINCT FROM gs.order_id
     AND ap.tracking_submission_id IS NOT DISTINCT FROM gs.tracking_submission_id
     AND ap.supplier_invoice_line_id IS NOT DISTINCT FROM gs.supplier_invoice_line_id
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
            WHEN lc.resolved_invoice_type = 'supplementary' THEN 'supplementary_shipping_export_sale_charge'
            ELSE 'main_goods_export_sale_charge'
          END,
          'sage_tax_rate_id', 'GB_ZERO',
          'sage_tax_rate_display', 'Zero Rated 0.00%',
          'display_vat_code', 'T0',
          'customer_gl_role', 'export_sale_income',
          'ap_gl_role_note', CASE
            WHEN lc.resolved_invoice_type = 'supplementary' THEN 'Supplementary shipping recharge waits for accepted shipper AP/apportionment.'
            ELSE 'Main goods invoice release does not require shipper AP invoice/apportionment.'
          END,
          'source', 'shipping_customer_invoice_readiness_preview_split_gate_v1'
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

CREATE OR REPLACE FUNCTION public.internal_customer_invoice_release_queue_v1()
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  importer_id uuid,
  importer_name text,
  shipper_id uuid,
  shipper_name text,
  proposed_invoice_type text,
  customer_action_label text,
  sales_invoice_state text,
  vat_code text,
  proposed_amount_gbp numeric,
  proposed_goods_amount_gbp numeric,
  proposed_shipping_amount_gbp numeric,
  order_count integer,
  line_count integer,
  ready_line_count integer,
  blocker_count integer,
  blockers text[],
  readiness_status text,
  first_order_ref text,
  order_refs text,
  created_draft_count integer,
  posted_invoice_count integer,
  queue_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer invoice release queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for customer invoice release queue.';
  END IF;

  RETURN QUERY
  WITH batches AS (
    SELECT DISTINCT sc.shipment_batch_id
    FROM public.internal_shipping_control_v1() sc
    WHERE sc.shipment_batch_id IS NOT NULL
      AND COALESCE(sc.allocation_status_summary, '') = 'contents_allocated'
      AND COALESCE(sc.receipt_status_summary, '') = 'received_clean'
  ), preview_rows AS (
    SELECT p.*
    FROM batches b
    CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(b.shipment_batch_id) p
  ), grouped AS (
    SELECT
      pr.shipment_batch_id,
      MAX(pr.booking_ref)::text AS booking_ref,
      (ARRAY_AGG(DISTINCT pr.importer_id) FILTER (WHERE pr.importer_id IS NOT NULL))[1] AS importer_id,
      MAX(pr.importer_name)::text AS importer_name,
      (ARRAY_AGG(DISTINCT pr.shipper_id) FILTER (WHERE pr.shipper_id IS NOT NULL))[1] AS shipper_id,
      MAX(pr.shipper_name)::text AS shipper_name,
      MAX(pr.proposed_invoice_type)::text AS proposed_invoice_type,
      MAX(pr.sales_invoice_state)::text AS sales_invoice_state,
      MAX(pr.vat_code)::text AS vat_code,
      MAX(pr.proposed_amount_gbp) AS proposed_amount_gbp,
      MAX(pr.proposed_goods_amount_gbp) AS proposed_goods_amount_gbp,
      MAX(pr.proposed_shipping_amount_gbp) AS proposed_shipping_amount_gbp,
      COUNT(DISTINCT pr.order_id)::integer AS order_count,
      COUNT(*)::integer AS line_count,
      COUNT(*) FILTER (WHERE pr.blocker IS NULL)::integer AS ready_line_count,
      COUNT(*) FILTER (WHERE pr.blocker IS NOT NULL)::integer AS blocker_count,
      ARRAY_REMOVE(ARRAY_AGG(DISTINCT pr.blocker), NULL)::text[] AS blockers,
      MIN(pr.order_ref)::text AS first_order_ref,
      STRING_AGG(DISTINCT pr.order_ref, ', ' ORDER BY pr.order_ref)::text AS order_refs,
      COUNT(DISTINCT si_draft.id)::integer AS created_draft_count,
      COUNT(DISTINCT si_posted.id)::integer AS posted_invoice_count
    FROM preview_rows pr
    LEFT JOIN public.sales_invoices si_draft
      ON si_draft.order_id = pr.order_id
     AND si_draft.invoice_type = pr.proposed_invoice_type
     AND si_draft.sage_status = 'draft'
    LEFT JOIN public.sales_invoices si_posted
      ON si_posted.order_id = pr.order_id
     AND si_posted.invoice_type = pr.proposed_invoice_type
     AND si_posted.sage_status = 'posted'
    GROUP BY pr.shipment_batch_id
  )
  SELECT
    g.shipment_batch_id,
    g.booking_ref,
    g.importer_id,
    g.importer_name,
    g.shipper_id,
    g.shipper_name,
    g.proposed_invoice_type,
    CASE
      WHEN g.proposed_invoice_type = 'supplementary' THEN 'Create supplementary export sale invoice'
      ELSE 'Create main goods export sale invoice'
    END::text AS customer_action_label,
    g.sales_invoice_state,
    g.vat_code,
    g.proposed_amount_gbp,
    g.proposed_goods_amount_gbp,
    g.proposed_shipping_amount_gbp,
    g.order_count,
    g.line_count,
    g.ready_line_count,
    g.blocker_count,
    COALESCE(g.blockers, ARRAY[]::text[]) AS blockers,
    CASE
      WHEN g.blocker_count > 0 THEN 'blocked'
      WHEN g.created_draft_count > 0 THEN 'draft_exists'
      WHEN g.posted_invoice_count > 0 THEN 'posted_exists'
      ELSE 'ready_to_create_draft'
    END::text AS readiness_status,
    g.first_order_ref,
    g.order_refs,
    g.created_draft_count,
    g.posted_invoice_count,
    CASE
      WHEN g.blocker_count > 0 THEN 'resolve_blockers'
      WHEN g.created_draft_count > 0 THEN 'review_existing_draft'
      WHEN g.posted_invoice_count > 0 THEN 'review_posted_invoice'
      ELSE 'ready_for_bulk_draft_creation'
    END::text AS queue_action
  FROM grouped g
  ORDER BY
    CASE
      WHEN g.blocker_count = 0 AND g.created_draft_count = 0 AND g.posted_invoice_count = 0 THEN 0
      WHEN g.created_draft_count > 0 THEN 1
      WHEN g.blocker_count > 0 THEN 2
      ELSE 3
    END,
    g.booking_ref NULLS LAST,
    g.first_order_ref NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_queue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_queue_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
