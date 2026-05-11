BEGIN;

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
      AND COALESCE(sc.shipper_invoice_status, '') = 'accepted_current'
      AND COALESCE(sc.sage_readiness_status, '') = 'shipping_apportionment_approved'
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
      ELSE 'Add to main invoice draft/release'
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
