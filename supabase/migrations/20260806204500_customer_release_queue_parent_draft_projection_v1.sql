BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/addenda/CUSTOMER_RELEASE_QUEUE_PARENT_DRAFT_OWNERSHIP_PROJECTION_ADDENDUM_v1.md
--
-- Projection-only correction. No operational-row DML.

DO $preflight$
DECLARE
  v_actual text;
BEGIN
  IF to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Customer release queue projection prerequisites are missing.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  )) INTO v_actual;

  IF v_actual IS DISTINCT FROM '823d4488e24c335596d55351c3e752c3' THEN
    RAISE EXCEPTION
      'Queue fingerprint mismatch: expected diagnosed live definition %, found %',
      '823d4488e24c335596d55351c3e752c3', v_actual;
  END IF;
END
$preflight$;

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
      AND (
        COALESCE(shipping_control.receipt_status_summary, '') = 'received_clean'
        OR EXISTS (
          SELECT 1
          FROM public.shipper_shipment_batch_effective_lines_v1(
            shipping_control.shipment_batch_id
          ) effective_line
          WHERE public.internal_customer_sales_release_exact_clean_proof_v1(
            shipping_control.shipment_batch_id,
            effective_line.tracking_line_allocation_id
          )
        )
      )
  ), preview_rows AS (
    SELECT preview.*
    FROM batches batch_row
    CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(
      batch_row.shipment_batch_id
    ) preview
  ), batch_orders AS (
    SELECT DISTINCT
      preview.shipment_batch_id,
      preview.order_id
    FROM preview_rows preview
    WHERE preview.order_id IS NOT NULL
  ), grouped AS (
    SELECT
      preview.shipment_batch_id,
      MAX(preview.booking_ref)::text AS booking_ref,
      (ARRAY_AGG(DISTINCT preview.importer_id)
        FILTER (WHERE preview.importer_id IS NOT NULL))[1] AS importer_id,
      MAX(preview.importer_name)::text AS importer_name,
      (ARRAY_AGG(DISTINCT preview.shipper_id)
        FILTER (WHERE preview.shipper_id IS NOT NULL))[1] AS shipper_id,
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
      STRING_AGG(DISTINCT preview.order_ref, ', ' ORDER BY preview.order_ref)::text AS order_refs
    FROM preview_rows preview
    GROUP BY preview.shipment_batch_id
  ), invoice_state AS (
    SELECT
      batch_order.shipment_batch_id,
      COUNT(DISTINCT invoice.id) FILTER (
        WHERE invoice.sage_status = 'draft'
      )::integer AS draft_count,
      COUNT(DISTINCT invoice.id) FILTER (
        WHERE invoice.sage_status = 'posted'
      )::integer AS posted_count
    FROM batch_orders batch_order
    LEFT JOIN public.sales_invoices invoice
      ON invoice.order_id = batch_order.order_id
     AND invoice.invoice_type IN ('main', 'supplementary')
    GROUP BY batch_order.shipment_batch_id
  ), draft_membership AS (
    SELECT
      release_line.source_shipment_batch_id AS shipment_batch_id,
      COUNT(*)::integer AS owned_line_count,
      ROUND(COALESCE(SUM(release_line.customer_charge_amount_gbp), 0), 2)::numeric AS owned_amount,
      ROUND(COALESCE(SUM(release_line.goods_amount_gbp), 0), 2)::numeric AS owned_goods,
      ROUND(COALESCE(SUM(release_line.shipping_amount_gbp), 0), 2)::numeric AS owned_shipping
    FROM public.customer_sales_release_lines release_line
    JOIN public.sales_invoices invoice
      ON invoice.id = release_line.sales_invoice_id
     AND invoice.invoice_type IN ('main', 'supplementary')
     AND invoice.sage_status = 'draft'
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.source_shipment_batch_id
  ), resolved AS (
    SELECT
      grouped.*,
      COALESCE(invoice_state.draft_count, 0)::integer AS draft_count,
      COALESCE(invoice_state.posted_count, 0)::integer AS posted_count,
      COALESCE(draft_membership.owned_line_count, 0)::integer AS owned_line_count,
      COALESCE(draft_membership.owned_amount, 0)::numeric AS owned_amount,
      COALESCE(draft_membership.owned_goods, 0)::numeric AS owned_goods,
      COALESCE(draft_membership.owned_shipping, 0)::numeric AS owned_shipping,
      (
        grouped.ready_count > 0
        AND ROUND(COALESCE(grouped.amount, 0), 2) > 0
      ) AS genuinely_ready
    FROM grouped
    LEFT JOIN invoice_state
      ON invoice_state.shipment_batch_id = grouped.shipment_batch_id
    LEFT JOIN draft_membership
      ON draft_membership.shipment_batch_id = grouped.shipment_batch_id
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
      WHEN resolved.owned_line_count > 0
        THEN 'Review existing customer sales draft'
      WHEN resolved.draft_count > 0
        THEN 'Wait for active customer sales draft'
      WHEN resolved.proposed_invoice_type = 'main'
        THEN 'Create main export sale invoice'
      WHEN resolved.proposed_invoice_type = 'supplementary'
        THEN 'Create supplementary export sale invoice'
      ELSE 'Create customer sales invoice drafts'
    END::text,
    resolved.sales_invoice_state,
    resolved.vat_code,
    CASE WHEN resolved.owned_line_count > 0
      THEN resolved.owned_amount ELSE COALESCE(resolved.amount, 0) END,
    CASE WHEN resolved.owned_line_count > 0
      THEN resolved.owned_goods ELSE COALESCE(resolved.goods, 0) END,
    CASE WHEN resolved.owned_line_count > 0
      THEN resolved.owned_shipping ELSE COALESCE(resolved.shipping, 0) END,
    resolved.order_count,
    resolved.line_count,
    CASE WHEN resolved.owned_line_count > 0
      THEN resolved.owned_line_count ELSE resolved.ready_count END,
    CASE WHEN resolved.owned_line_count > 0
      THEN 0 ELSE resolved.blocker_count END,
    CASE WHEN resolved.owned_line_count > 0
      THEN ARRAY[]::text[]
      ELSE COALESCE(resolved.blockers, ARRAY[]::text[])
    END,
    CASE
      WHEN resolved.owned_line_count > 0
        THEN 'released_in_existing_draft'
      WHEN resolved.draft_count > 0
        THEN 'blocked_by_another_active_draft'
      WHEN resolved.genuinely_ready
        THEN 'ready_to_create_draft'
      WHEN resolved.posted_count > 0
        THEN 'posted_exists'
      ELSE 'blocked'
    END::text,
    resolved.first_order_ref,
    resolved.order_refs,
    resolved.draft_count,
    resolved.posted_count,
    CASE
      WHEN resolved.owned_line_count > 0
        THEN 'review_existing_draft'
      WHEN resolved.draft_count > 0
        THEN 'wait_for_active_parent_draft'
      WHEN resolved.genuinely_ready
        THEN 'ready_for_bulk_draft_creation'
      WHEN resolved.posted_count > 0
        THEN 'review_posted_invoice'
      ELSE 'resolve_blockers'
    END::text
  FROM resolved
  ORDER BY
    CASE
      WHEN resolved.owned_line_count > 0 THEN 0
      WHEN resolved.draft_count > 0 THEN 1
      WHEN resolved.genuinely_ready THEN 2
      WHEN resolved.posted_count > 0 THEN 3
      ELSE 4
    END,
    resolved.booking_ref;
END;
$function$;

REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_queue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_queue_v1() TO authenticated;

DO $postflight$
DECLARE
  v_definition text;
  v_actual text;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'released_in_existing_draft') = 0
     OR strpos(v_definition, 'blocked_by_another_active_draft') = 0
     OR strpos(v_definition, 'draft_membership') = 0
     OR strpos(v_definition, 'batch_orders') = 0
     OR strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'ready_to_create_draft') = 0
     OR strpos(v_definition, 'posted_exists') = 0
  THEN
    RAISE EXCEPTION 'Queue ownership projection correction was not installed completely.';
  END IF;

  IF strpos(
       regexp_replace(lower(v_definition), '[[:space:]]+', ' ', 'g'),
       'from preview_rows preview left join public.sales_invoices'
     ) > 0
  THEN
    RAISE EXCEPTION 'Queue still joins invoice history into preview-row aggregation.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '2e75a619e3cc3cc2fc364d3cb5a85cc3' THEN
    RAISE EXCEPTION 'Protected draft creator changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '25be89183956fe7f756472b0075b4f58' THEN
    RAISE EXCEPTION 'Protected readiness preview changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.customer_sales_release_guard_v1()'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'd50b362d97a46f36a07acdb237231b46' THEN
    RAISE EXCEPTION 'Protected release guard changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.customer_sales_release_financial_guard_v1()'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'c492d47d33c6419d14d4cb26799fbfb9' THEN
    RAISE EXCEPTION 'Protected financial guard changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_resolved_customer_sales_sage_payload_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '4f8266c7932461b4e19afc789817d31f' THEN
    RAISE EXCEPTION 'Protected resolved Sage payload changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.approve_vat_release(uuid,uuid,jsonb)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '13491a2d250a480ebb1ac607ce7acce5' THEN
    RAISE EXCEPTION 'Protected VAT authority changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.recompute_order_status(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'f7c40c868381252a5432f70894ca2b2f' THEN
    RAISE EXCEPTION 'Protected order-status authority changed.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
