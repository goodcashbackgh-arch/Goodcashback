BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Contract: docs/addenda/CUSTOMER_RELEASE_QUEUE_FULLY_RELEASED_SUPPRESSION_ADDENDUM_v1.md
-- Surgical boundary: readiness preview + release queue only.

DO $preflight$
DECLARE
  v_creator_definition text;
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
  THEN
    RAISE EXCEPTION 'Customer release queue prerequisite function missing';
  END IF;

  SELECT pg_get_functiondef(
           'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
         )
  INTO v_creator_definition;

  IF strpos(v_creator_definition, 'internal_customer_sales_release_sources_v1') = 0
     OR strpos(v_creator_definition, 'WHERE s.blocker IS NULL') = 0
     OR strpos(v_creator_definition, 'COALESCE(v_amount,0)<=0') = 0
  THEN
    RAISE EXCEPTION 'Existing draft creator is not already fail-closed against stale or fully released source';
  END IF;
END;
$preflight$;

CREATE OR REPLACE FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(
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
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required';
  END IF;

  RETURN QUERY
  WITH source_rows AS (
    SELECT source_row.*
    FROM public.internal_customer_sales_release_sources_v1(p_shipment_batch_id) source_row
  ), normalised_rows AS (
    SELECT
      source_row.*,
      (
        source_row.blocker IS NULL
        AND ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2) > 0
      ) AS genuinely_ready,
      CASE
        WHEN source_row.blocker IS NULL
         AND ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2) > 0
          THEN ROUND(COALESCE(source_row.release_qty, 0), 3)
        ELSE 0::numeric
      END AS ready_qty,
      CASE
        WHEN source_row.blocker IS NULL
         AND ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2) > 0
          THEN ROUND(COALESCE(source_row.goods_amount_gbp, 0), 2)
        ELSE 0::numeric
      END AS ready_goods,
      CASE
        WHEN source_row.blocker IS NULL
         AND ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2) > 0
          THEN ROUND(COALESCE(source_row.shipping_amount_gbp, 0), 2)
        ELSE 0::numeric
      END AS ready_shipping,
      CASE
        WHEN source_row.blocker IS NULL
         AND ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2) > 0
          THEN ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2)
        ELSE 0::numeric
      END AS ready_charge
    FROM source_rows source_row
  ), totals AS (
    SELECT
      ROUND(COALESCE(SUM(normalised.ready_charge), 0), 2)::numeric AS amount,
      ROUND(COALESCE(SUM(normalised.ready_goods), 0), 2)::numeric AS goods,
      ROUND(COALESCE(SUM(normalised.ready_shipping), 0), 2)::numeric AS shipping,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'source_order_id', normalised.source_order_id,
            'source_commercial_parent_order_id', normalised.commercial_parent_order_id,
            'source_shipment_batch_id', normalised.shipment_batch_id,
            'source_tracking_submission_id', normalised.tracking_submission_id,
            'source_tracking_line_allocation_id', normalised.tracking_line_allocation_id,
            'source_supplier_invoice_id', normalised.supplier_invoice_id,
            'source_supplier_invoice_line_id', normalised.supplier_invoice_line_id,
            'released_qty', normalised.ready_qty,
            'goods_amount_gbp', normalised.ready_goods,
            'delivery_share_gbp', normalised.delivery_share_gbp,
            'discount_share_gbp', normalised.discount_share_gbp,
            'shipping_amount_gbp', normalised.ready_shipping,
            'customer_charge_amount_gbp', normalised.ready_charge,
            'membership_fingerprint', normalised.membership_fingerprint,
            'description', normalised.item_description,
            'quantity', CASE WHEN normalised.ready_qty > 0 THEN normalised.ready_qty ELSE 1 END,
            'total_line_amount_gbp', normalised.ready_charge,
            'ledger_account_role', 'export_sale_income',
            'source', 'customer_sales_release_ledger'
          )
          ORDER BY normalised.order_ref, normalised.tracking_ref, normalised.item_description
        ) FILTER (WHERE normalised.genuinely_ready),
        '[]'::jsonb
      ) AS lines
    FROM normalised_rows normalised
  )
  SELECT
    row_data.shipment_batch_id,
    row_data.booking_ref,
    row_data.importer_id,
    row_data.importer_name,
    row_data.shipper_id,
    row_data.shipper_name,
    row_data.proposed_invoice_type,
    CASE WHEN row_data.genuinely_ready THEN 'draft_preview' ELSE 'blocked' END::text,
    CASE
      WHEN row_data.proposed_invoice_type = 'main' THEN 'main_customer_release_invoice'
      ELSE 'supplementary_customer_release_invoice'
    END::text,
    row_data.sales_invoice_state,
    'T0 / GB_ZERO'::text,
    totals.amount,
    totals.goods,
    totals.shipping,
    totals.lines,
    row_data.commercial_parent_order_id,
    row_data.order_ref,
    row_data.tracking_submission_id,
    row_data.tracking_ref,
    row_data.supplier_invoice_line_id,
    row_data.item_description,
    row_data.ready_qty,
    row_data.ready_goods,
    row_data.ready_shipping,
    row_data.ready_charge,
    CASE
      WHEN NOT row_data.genuinely_ready THEN 'blocked'
      WHEN row_data.proposed_invoice_type = 'main' THEN 'ready_for_main_invoice_release_preview'
      ELSE 'ready_for_supplementary_invoice_preview'
    END::text,
    CASE
      WHEN row_data.genuinely_ready THEN NULL::text
      WHEN row_data.blocker IS NOT NULL THEN row_data.blocker
      ELSE 'non_positive_customer_release_delta'
    END::text
  FROM normalised_rows row_data
  CROSS JOIN totals
  WHERE row_data.genuinely_ready
     OR NOT EXISTS (
       SELECT 1
       FROM normalised_rows ready_row
       WHERE ready_row.genuinely_ready
     )
  ORDER BY row_data.order_ref, row_data.tracking_ref, row_data.item_description;
END;
$function$;

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
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required';
  END IF;

  RETURN QUERY
  WITH batches AS (
    SELECT DISTINCT shipping_control.shipment_batch_id
    FROM public.internal_shipping_control_v1() shipping_control
    WHERE shipping_control.shipment_batch_id IS NOT NULL
      AND COALESCE(shipping_control.allocation_status_summary, '') = 'contents_allocated'
      AND COALESCE(shipping_control.receipt_status_summary, '') = 'received_clean'
  ), preview_rows AS (
    SELECT preview.*
    FROM batches batch_row
    CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(
      batch_row.shipment_batch_id
    ) preview
  ), grouped AS (
    SELECT
      preview.shipment_batch_id,
      MAX(preview.booking_ref)::text AS booking_ref,
      (ARRAY_AGG(DISTINCT preview.importer_id) FILTER (WHERE preview.importer_id IS NOT NULL))[1] AS importer_id,
      MAX(preview.importer_name)::text AS importer_name,
      (ARRAY_AGG(DISTINCT preview.shipper_id) FILTER (WHERE preview.shipper_id IS NOT NULL))[1] AS shipper_id,
      MAX(preview.shipper_name)::text AS shipper_name,
      CASE
        WHEN COUNT(DISTINCT preview.proposed_invoice_type) = 1
          THEN MAX(preview.proposed_invoice_type)::text
        ELSE 'mixed'::text
      END AS proposed_invoice_type,
      MAX(preview.sales_invoice_state)::text AS sales_invoice_state,
      MAX(preview.vat_code)::text AS vat_code,
      MAX(preview.proposed_amount_gbp)::numeric AS amount,
      MAX(preview.proposed_goods_amount_gbp)::numeric AS goods,
      MAX(preview.proposed_shipping_amount_gbp)::numeric AS shipping,
      COUNT(DISTINCT preview.order_id)::integer AS order_count,
      COUNT(*)::integer AS line_count,
      COUNT(*) FILTER (
        WHERE preview.blocker IS NULL
          AND ROUND(COALESCE(preview.total_line_amount_gbp, 0), 2) > 0
      )::integer AS ready_count,
      COUNT(*) FILTER (WHERE preview.blocker IS NOT NULL)::integer AS blocker_count,
      ARRAY_REMOVE(ARRAY_AGG(DISTINCT preview.blocker), NULL)::text[] AS blockers,
      MIN(preview.order_ref)::text AS first_order_ref,
      STRING_AGG(DISTINCT preview.order_ref, ', ' ORDER BY preview.order_ref)::text AS order_refs,
      COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'draft')::integer AS draft_count,
      COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'posted')::integer AS posted_count
    FROM preview_rows preview
    LEFT JOIN public.sales_invoices invoice
      ON invoice.order_id = preview.order_id
     AND invoice.invoice_type IN ('main', 'supplementary')
    GROUP BY preview.shipment_batch_id
  ), resolved AS (
    SELECT
      grouped.*,
      (
        grouped.ready_count > 0
        AND ROUND(COALESCE(grouped.amount, 0), 2) > 0
      ) AS genuinely_ready
    FROM grouped
  )
  SELECT
    resolved.shipment_batch_id,
    resolved.booking_ref,
    resolved.importer_id,
    resolved.importer_name,
    resolved.shipper_id,
    resolved.shipper_name,
    resolved.proposed_invoice_type,
    CASE
      WHEN resolved.proposed_invoice_type = 'main' THEN 'Create main export sale invoice'
      WHEN resolved.proposed_invoice_type = 'supplementary' THEN 'Create supplementary export sale invoice'
      ELSE 'Create customer sales invoice drafts'
    END::text,
    resolved.sales_invoice_state,
    resolved.vat_code,
    COALESCE(resolved.amount, 0),
    COALESCE(resolved.goods, 0),
    COALESCE(resolved.shipping, 0),
    resolved.order_count,
    resolved.line_count,
    resolved.ready_count,
    resolved.blocker_count,
    COALESCE(resolved.blockers, ARRAY[]::text[]),
    CASE
      WHEN resolved.draft_count > 0 THEN 'draft_exists'
      WHEN resolved.genuinely_ready THEN 'ready_to_create_draft'
      WHEN resolved.posted_count > 0 THEN 'posted_exists'
      WHEN resolved.blocker_count > 0 THEN 'blocked'
      ELSE 'blocked'
    END::text,
    resolved.first_order_ref,
    resolved.order_refs,
    resolved.draft_count,
    resolved.posted_count,
    CASE
      WHEN resolved.draft_count > 0 THEN 'review_existing_draft'
      WHEN resolved.genuinely_ready THEN 'ready_for_bulk_draft_creation'
      WHEN resolved.posted_count > 0 THEN 'review_posted_invoice'
      ELSE 'resolve_blockers'
    END::text
  FROM resolved
  ORDER BY
    CASE
      WHEN resolved.draft_count > 0 THEN 0
      WHEN resolved.genuinely_ready THEN 1
      WHEN resolved.posted_count > 0 THEN 2
      ELSE 3
    END,
    resolved.booking_ref;
END;
$function$;

REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_queue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_queue_v1() TO authenticated;

DO $postflight$
DECLARE
  v_preview_definition text;
  v_queue_definition text;
  v_creator_definition text;
BEGIN
  SELECT pg_get_functiondef(
           'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
         )
  INTO v_preview_definition;

  SELECT pg_get_functiondef(
           'public.internal_customer_invoice_release_queue_v1()'::regprocedure
         )
  INTO v_queue_definition;

  SELECT pg_get_functiondef(
           'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
         )
  INTO v_creator_definition;

  IF strpos(v_preview_definition, 'genuinely_ready') = 0
     OR strpos(v_preview_definition, 'non_positive_customer_release_delta') = 0
     OR strpos(v_preview_definition, 'ready_charge') = 0
  THEN
    RAISE EXCEPTION 'Readiness preview fully-released suppression was not installed';
  END IF;

  IF strpos(v_queue_definition, 'ROUND(COALESCE(grouped.amount, 0), 2) > 0') = 0
     OR strpos(v_queue_definition, 'WHEN resolved.posted_count > 0 THEN ''posted_exists''') = 0
     OR strpos(v_queue_definition, 'WHEN resolved.genuinely_ready THEN ''ready_to_create_draft''') = 0
  THEN
    RAISE EXCEPTION 'Release queue positive-delta/posted suppression was not installed';
  END IF;

  IF strpos(v_creator_definition, 'internal_customer_sales_release_sources_v1') = 0
     OR strpos(v_creator_definition, 'WHERE s.blocker IS NULL') = 0
     OR strpos(v_creator_definition, 'COALESCE(v_amount,0)<=0') = 0
  THEN
    RAISE EXCEPTION 'Existing draft creator fail-closed protection changed unexpectedly';
  END IF;
END;
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
