BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- Customer-sales goods + shipping delta release v1
--
-- Purpose
--   Keep Mini-build 1/2 exact supplier-line and tracking identity, Mini-build 3
--   durable release membership and repeated supplementary documents, and the
--   planned Mini-build 4 ledger-aware review/credit boundary while correcting
--   one route defect: the first/main release currently suppresses exact approved
--   shipper cost merely because no main invoice exists yet.
--
-- Rules retained
--   * first non-void release for a commercial parent = main;
--   * later positive newly eligible deltas = supplementary;
--   * one active draft per commercial parent remains immutable;
--   * goods and shipping are never accepted from client amounts;
--   * exact active release membership is subtracted before another release;
--   * shipping-only first/main release is not permitted;
--   * shipping-only supplementary remains permitted;
--   * no customer, supplier, shipment, funding, VAT or Sage route is replaced.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_customer_sales_release_sources_v1(uuid)';
  END IF;
  IF to_regprocedure('public.customer_sales_release_financial_guard_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.customer_sales_release_financial_guard_v1()';
  END IF;
  IF to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Missing Mini-build 3 draft function';
  END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.customer_sales_release_legacy_issues') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.staff') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shipper_shipment_batch_packages') IS NULL
     OR to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.customer_pre_shipment_hold_requests') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.shipping_documents') IS NULL
     OR to_regclass('public.shipping_cost_allocations') IS NULL
     OR to_regclass('public.shipping_cost_allocation_lines') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
  THEN
    RAISE EXCEPTION 'Customer-sales delta release prerequisite relation missing';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_customer_sales_release_sources_v1(
  p_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  importer_id uuid,
  importer_name text,
  shipper_id uuid,
  shipper_name text,
  commercial_parent_order_id uuid,
  source_order_id uuid,
  order_ref text,
  tracking_submission_id uuid,
  tracking_ref text,
  tracking_line_allocation_id uuid,
  supplier_invoice_id uuid,
  supplier_invoice_line_id uuid,
  item_description text,
  release_qty numeric,
  goods_amount_gbp numeric,
  delivery_share_gbp numeric,
  discount_share_gbp numeric,
  shipping_amount_gbp numeric,
  customer_charge_amount_gbp numeric,
  proposed_invoice_type text,
  sales_invoice_state text,
  membership_fingerprint text,
  blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required for customer release source resolution';
  END IF;

  RETURN QUERY
  WITH raw AS (
    SELECT
      b.id AS batch_id,
      b.booking_ref::text AS booking_ref,
      b.importer_id,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
      b.shipper_id,
      s.name::text AS shipper_name,
      a.order_id AS source_order_id,
      CASE
        WHEN o.order_type = 'replacement_child' AND o.parent_order_id IS NOT NULL
          THEN o.parent_order_id
        ELSE o.id
      END AS commercial_parent_order_id,
      parent_o.order_ref::text AS order_ref,
      a.tracking_submission_id,
      ots.tracking_ref::text AS tracking_ref,
      a.id AS tracking_line_allocation_id,
      sil.supplier_invoice_id,
      a.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Goods')::text AS item_description,
      COALESCE(a.qty_allocated, 0)::numeric AS allocated_qty,
      COALESCE(a.adjusted_net_value_gbp, 0)::numeric AS allocated_goods,
      COALESCE(a.retailer_delivery_share_gbp, 0)::numeric AS allocated_delivery,
      COALESCE(a.discount_share_gbp, 0)::numeric AS allocated_discount,
      si.review_status::text AS review_status,
      COALESCE(si.blocked_from_sage_yn, false) AS blocked_from_sage_yn,
      sil.eligible_for_invoice_yn::text AS eligible_for_invoice_yn,
      receipt.receipt_status::text AS latest_receipt_status,
      COALESCE(shipping.allocated_amount, 0)::numeric AS allocated_shipping,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices existing_main
        WHERE existing_main.order_id = CASE
          WHEN o.order_type = 'replacement_child' AND o.parent_order_id IS NOT NULL
            THEN o.parent_order_id
          ELSE o.id
        END
          AND existing_main.invoice_type = 'main'
          AND existing_main.sage_status <> 'void'
      ) AS has_main,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices existing_draft
        WHERE existing_draft.order_id = CASE
          WHEN o.order_type = 'replacement_child' AND o.parent_order_id IS NOT NULL
            THEN o.parent_order_id
          ELSE o.id
        END
          AND existing_draft.invoice_type IN ('main', 'supplementary')
          AND existing_draft.sage_status = 'draft'
      ) AS has_active_draft,
      EXISTS (
        SELECT 1
        FROM public.customer_sales_release_legacy_issues legacy_issue
        JOIN public.sales_invoices legacy_invoice
          ON legacy_invoice.id = legacy_issue.sales_invoice_id
        WHERE legacy_invoice.order_id = CASE
          WHEN o.order_type = 'replacement_child' AND o.parent_order_id IS NOT NULL
            THEN o.parent_order_id
          ELSE o.id
        END
          AND legacy_issue.resolved_at IS NULL
      ) AS has_legacy_issue,
      EXISTS (
        SELECT 1
        FROM public.customer_pre_shipment_hold_requests hold_row
        WHERE hold_row.order_id IN (
          o.id,
          CASE
            WHEN o.order_type = 'replacement_child' AND o.parent_order_id IS NOT NULL
              THEN o.parent_order_id
            ELSE o.id
          END
        )
          AND hold_row.resolved_at IS NULL
          AND hold_row.status IN ('requested', 'supervisor_approved')
          AND (
            hold_row.requested_scope = 'order'
            OR (
              hold_row.requested_scope = 'tracking'
              AND hold_row.tracking_submission_id = a.tracking_submission_id
            )
            OR (
              hold_row.requested_scope = 'line'
              AND hold_row.supplier_invoice_line_id = a.supplier_invoice_line_id
            )
          )
      ) AS has_hold,
      EXISTS (
        SELECT 1
        FROM public.dispute_lines dispute_line
        JOIN public.disputes dispute_row
          ON dispute_row.id = dispute_line.dispute_id
        WHERE dispute_line.supplier_invoice_line_id = a.supplier_invoice_line_id
          AND dispute_line.resolved_at IS NULL
          AND dispute_row.resolved_at IS NULL
      ) AS has_exception
    FROM public.shipper_shipment_batches b
    JOIN public.shipper_shipment_batch_packages package_row
      ON package_row.shipment_batch_id = b.id
     AND package_row.active = true
    JOIN public.order_tracking_submissions ots
      ON ots.id = package_row.tracking_submission_id
    JOIN public.order_tracking_line_allocations a
      ON a.tracking_submission_id = package_row.tracking_submission_id
    JOIN public.orders o
      ON o.id = a.order_id
    JOIN public.orders parent_o
      ON parent_o.id = CASE
        WHEN o.order_type = 'replacement_child' AND o.parent_order_id IS NOT NULL
          THEN o.parent_order_id
        ELSE o.id
      END
    JOIN public.supplier_invoice_lines sil
      ON sil.id = a.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
    JOIN public.shippers s
      ON s.id = b.shipper_id
    LEFT JOIN public.importers i
      ON i.id = b.importer_id
    LEFT JOIN LATERAL (
      SELECT receipt_row.receipt_status
      FROM public.shipper_package_receipts receipt_row
      WHERE receipt_row.tracking_submission_id = a.tracking_submission_id
      ORDER BY receipt_row.recorded_at DESC,
               receipt_row.created_at DESC,
               receipt_row.id DESC
      LIMIT 1
    ) receipt ON true
    LEFT JOIN LATERAL (
      SELECT allocation_line.allocated_amount
      FROM public.shipping_documents shipping_document
      JOIN public.shipping_cost_allocations shipping_allocation
        ON shipping_allocation.shipping_document_id = shipping_document.id
       AND shipping_allocation.active = true
       AND shipping_allocation.allocation_status = 'approved'
      JOIN public.shipping_cost_allocation_lines allocation_line
        ON allocation_line.shipping_cost_allocation_id = shipping_allocation.id
       AND allocation_line.tracking_submission_id = a.tracking_submission_id
       AND allocation_line.supplier_invoice_line_id = a.supplier_invoice_line_id
      WHERE shipping_document.shipment_batch_id = b.id
        AND shipping_document.active = true
        AND shipping_document.review_status = 'accepted_current'
      ORDER BY shipping_allocation.approved_at DESC NULLS LAST,
               shipping_allocation.created_at DESC,
               shipping_allocation.id DESC
      LIMIT 1
    ) shipping ON true
    WHERE b.id = p_batch_id
  ), used_goods AS (
    SELECT
      release_line.tracking_line_allocation_id,
      SUM(release_line.released_qty)::numeric AS released_qty,
      SUM(release_line.goods_amount_gbp)::numeric AS released_goods,
      SUM(release_line.delivery_share_gbp)::numeric AS released_delivery,
      SUM(release_line.discount_share_gbp)::numeric AS released_discount
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.tracking_line_allocation_id
  ), used_shipping AS (
    SELECT
      release_line.tracking_line_allocation_id,
      release_line.source_shipment_batch_id,
      SUM(release_line.shipping_amount_gbp)::numeric AS released_shipping
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.release_status = 'active'
      AND release_line.shipping_amount_gbp > 0
    GROUP BY
      release_line.tracking_line_allocation_id,
      release_line.source_shipment_batch_id
  ), calc AS (
    SELECT
      raw_row.*,
      GREATEST(raw_row.allocated_qty - COALESCE(goods_used.released_qty, 0), 0)::numeric AS remaining_qty,
      GREATEST(raw_row.allocated_goods - COALESCE(goods_used.released_goods, 0), 0)::numeric AS remaining_goods,
      GREATEST(raw_row.allocated_delivery - COALESCE(goods_used.released_delivery, 0), 0)::numeric AS remaining_delivery,
      GREATEST(raw_row.allocated_discount - COALESCE(goods_used.released_discount, 0), 0)::numeric AS remaining_discount,
      GREATEST(raw_row.allocated_shipping - COALESCE(shipping_used.released_shipping, 0), 0)::numeric AS remaining_shipping,
      (
        COALESCE(shipping_used.released_shipping, 0)
          > raw_row.allocated_shipping + 0.02
      ) AS shipping_released_above_current_approval
    FROM raw raw_row
    LEFT JOIN used_goods goods_used
      ON goods_used.tracking_line_allocation_id = raw_row.tracking_line_allocation_id
    LEFT JOIN used_shipping shipping_used
      ON shipping_used.tracking_line_allocation_id = raw_row.tracking_line_allocation_id
     AND shipping_used.source_shipment_batch_id = raw_row.batch_id
  ), emitted AS (
    SELECT
      calc_row.*,
      CASE
        WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_qty
        ELSE 0::numeric
      END AS emit_qty,
      ROUND(calc_row.remaining_goods, 2)::numeric AS emit_goods,
      ROUND(
        CASE WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_delivery ELSE 0 END,
        2
      )::numeric AS emit_delivery,
      ROUND(
        CASE WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_discount ELSE 0 END,
        2
      )::numeric AS emit_discount,
      ROUND(
        CASE
          WHEN calc_row.has_main THEN calc_row.remaining_shipping
          WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_shipping
          ELSE 0
        END,
        2
      )::numeric AS emit_shipping
    FROM calc calc_row
  )
  SELECT
    emitted_row.batch_id,
    emitted_row.booking_ref,
    emitted_row.importer_id,
    emitted_row.importer_name,
    emitted_row.shipper_id,
    emitted_row.shipper_name,
    emitted_row.commercial_parent_order_id,
    emitted_row.source_order_id,
    emitted_row.order_ref,
    emitted_row.tracking_submission_id,
    emitted_row.tracking_ref,
    emitted_row.tracking_line_allocation_id,
    emitted_row.supplier_invoice_id,
    emitted_row.supplier_invoice_line_id,
    emitted_row.item_description,
    emitted_row.emit_qty,
    emitted_row.emit_goods,
    emitted_row.emit_delivery,
    emitted_row.emit_discount,
    emitted_row.emit_shipping,
    ROUND(emitted_row.emit_goods + emitted_row.emit_shipping, 2)::numeric,
    CASE WHEN emitted_row.has_main THEN 'supplementary' ELSE 'main' END::text,
    CASE
      WHEN emitted_row.has_main THEN 'main_sales_invoice_exists'
      ELSE 'no_main_sales_invoice_found'
    END::text,
    md5(concat_ws(
      '|',
      emitted_row.batch_id,
      emitted_row.commercial_parent_order_id,
      emitted_row.tracking_line_allocation_id,
      emitted_row.emit_qty,
      emitted_row.emit_goods,
      emitted_row.emit_delivery,
      emitted_row.emit_discount,
      emitted_row.emit_shipping
    )),
    CASE
      WHEN emitted_row.has_legacy_issue
        THEN 'customer_sales_release_legacy_provenance_unresolved'
      WHEN emitted_row.has_active_draft
        THEN 'customer_sales_release_draft_already_exists'
      WHEN emitted_row.review_status NOT IN ('approved_current', 'ref_corrected_approved')
        OR emitted_row.blocked_from_sage_yn
        THEN 'supplier_invoice_not_approved_current'
      WHEN lower(COALESCE(emitted_row.eligible_for_invoice_yn, '')) NOT IN ('y', 'yes', 'true', '1')
        THEN 'supplier_line_not_progressed'
      WHEN emitted_row.latest_receipt_status IS DISTINCT FROM 'received_clean'
        THEN 'package_not_received_clean'
      WHEN emitted_row.has_hold
        THEN 'customer_hold_active'
      WHEN emitted_row.has_exception
        THEN 'unresolved_exception'
      WHEN emitted_row.shipping_released_above_current_approval
        THEN 'released_shipping_exceeds_current_approved_allocation'
      WHEN NOT emitted_row.has_main
        AND emitted_row.emit_goods <= 0
        AND emitted_row.remaining_shipping > 0
        THEN 'shipping_only_main_not_permitted'
      WHEN ROUND(emitted_row.emit_goods + emitted_row.emit_shipping, 2) <= 0
        THEN 'source_fully_released'
      ELSE NULL
    END::text
  FROM emitted emitted_row;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_customer_sales_release_sources_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_sales_release_sources_v1(uuid) TO authenticated;

-- Keep delivery/discount cumulative controls global to the exact tracking
-- allocation. Scope shipping consumption to the exact shipment batch because
-- approved shipper cost is a shipment-batch fact and the same operational source
-- may participate in later batches/tranches.
CREATE OR REPLACE FUNCTION public.customer_sales_release_financial_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_alloc record;
  v_parent uuid;
  v_delivery numeric;
  v_discount numeric;
  v_shipping numeric;
  v_shipping_limit numeric;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.release_status = 'reversed' THEN
    RETURN NEW;
  END IF;

  SELECT allocation_row.*, order_row.order_type, order_row.parent_order_id
  INTO v_alloc
  FROM public.order_tracking_line_allocations allocation_row
  JOIN public.orders order_row
    ON order_row.id = allocation_row.order_id
  WHERE allocation_row.id = NEW.tracking_line_allocation_id
  FOR UPDATE OF allocation_row;

  v_parent := CASE
    WHEN v_alloc.order_type = 'replacement_child' AND v_alloc.parent_order_id IS NOT NULL
      THEN v_alloc.parent_order_id
    ELSE v_alloc.order_id
  END;

  IF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests hold_row
    WHERE hold_row.order_id IN (NEW.order_id, v_parent)
      AND hold_row.resolved_at IS NULL
      AND hold_row.status IN ('requested', 'supervisor_approved')
      AND (
        hold_row.requested_scope = 'order'
        OR (
          hold_row.requested_scope = 'tracking'
          AND hold_row.tracking_submission_id = NEW.tracking_submission_id
        )
        OR (
          hold_row.requested_scope = 'line'
          AND hold_row.supplier_invoice_line_id = NEW.supplier_invoice_line_id
        )
      )
  ) THEN
    RAISE EXCEPTION 'Active source or commercial-parent customer hold conflicts with release membership';
  END IF;

  SELECT
    COALESCE(SUM(release_line.delivery_share_gbp), 0),
    COALESCE(SUM(release_line.discount_share_gbp), 0)
  INTO v_delivery, v_discount
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.tracking_line_allocation_id = NEW.tracking_line_allocation_id
    AND release_line.release_status = 'active'
    AND (TG_OP = 'INSERT' OR release_line.id <> NEW.id);

  IF v_delivery + NEW.delivery_share_gbp > COALESCE(v_alloc.retailer_delivery_share_gbp, 0) + 0.02 THEN
    RAISE EXCEPTION 'Cumulative release delivery share exceeds exact tracking allocation';
  END IF;

  IF v_discount + NEW.discount_share_gbp > COALESCE(v_alloc.discount_share_gbp, 0) + 0.02 THEN
    RAISE EXCEPTION 'Cumulative release discount share exceeds exact tracking allocation';
  END IF;

  IF NEW.shipping_amount_gbp > 0 THEN
    IF NEW.source_shipment_batch_id IS NULL THEN
      RAISE EXCEPTION 'Shipping release requires exact source shipment batch';
    END IF;

    SELECT COALESCE(SUM(release_line.shipping_amount_gbp), 0)
    INTO v_shipping
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.tracking_line_allocation_id = NEW.tracking_line_allocation_id
      AND release_line.source_shipment_batch_id = NEW.source_shipment_batch_id
      AND release_line.release_status = 'active'
      AND (TG_OP = 'INSERT' OR release_line.id <> NEW.id);

    SELECT COALESCE(MAX(allocation_line.allocated_amount), 0)
    INTO v_shipping_limit
    FROM public.shipping_documents shipping_document
    JOIN public.shipping_cost_allocations shipping_allocation
      ON shipping_allocation.shipping_document_id = shipping_document.id
     AND shipping_allocation.active = true
     AND shipping_allocation.allocation_status = 'approved'
    JOIN public.shipping_cost_allocation_lines allocation_line
      ON allocation_line.shipping_cost_allocation_id = shipping_allocation.id
     AND allocation_line.tracking_submission_id = NEW.tracking_submission_id
     AND allocation_line.supplier_invoice_line_id = NEW.supplier_invoice_line_id
    WHERE shipping_document.shipment_batch_id = NEW.source_shipment_batch_id
      AND shipping_document.active = true
      AND shipping_document.review_status = 'accepted_current';

    IF v_shipping + NEW.shipping_amount_gbp > COALESCE(v_shipping_limit, 0) + 0.02 THEN
      RAISE EXCEPTION 'Cumulative release shipping exceeds approved exact shipping allocation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- One-time guarded correction of the known unposted regression draft.
-- It runs only when every exact identity/value/provenance condition is present
-- and the currently approved exact shipping delta is £120.00. It voids the
-- unposted document and reverses its durable membership with audit fields; it
-- never edits the frozen amount/payload and never recreates a document itself.
-- A migration has no authenticated staff identity. The mandatory reversal actor
-- therefore retains the exact original draft creator, while reversal_reason
-- explicitly identifies this as an automated migration correction rather than a
-- manual action by that staff member.
DO $$
DECLARE
  v_invoice_id uuid;
  v_current_shipping numeric := 0;
  v_active_line_count integer := 0;
BEGIN
  SELECT customer_invoice.id
  INTO v_invoice_id
  FROM public.sales_invoices customer_invoice
  JOIN public.orders parent_order
    ON parent_order.id = customer_invoice.order_id
  JOIN public.customer_sales_release_lines release_line
    ON release_line.sales_invoice_id = customer_invoice.id
   AND release_line.release_status = 'active'
  JOIN public.shipper_shipment_batches shipment_batch
    ON shipment_batch.id = release_line.source_shipment_batch_id
  WHERE parent_order.order_ref = 'ORD-1784498556959'
    AND customer_invoice.invoice_type = 'main'
    AND customer_invoice.sage_status = 'draft'
    AND customer_invoice.sage_invoice_id IS NULL
    AND customer_invoice.sage_posted_at IS NULL
    AND ABS(customer_invoice.amount_gbp - 699.97) <= 0.01
  GROUP BY customer_invoice.id, customer_invoice.amount_gbp
  HAVING COUNT(*) = 3
     AND ABS(SUM(release_line.customer_charge_amount_gbp) - 699.97) <= 0.01
     AND ABS(SUM(release_line.goods_amount_gbp) - 699.97) <= 0.01
     AND ABS(SUM(release_line.shipping_amount_gbp)) <= 0.01
     AND COUNT(DISTINCT shipment_batch.booking_ref) = 2
     AND COUNT(*) FILTER (WHERE shipment_batch.booking_ref IN ('J0180726', 'J0210726')) = 3
  LIMIT 1;

  IF v_invoice_id IS NULL THEN
    RETURN;
  END IF;

  SELECT
    COUNT(*),
    ROUND(COALESCE(SUM(COALESCE(current_shipping.allocated_amount, 0)), 0), 2)
  INTO v_active_line_count, v_current_shipping
  FROM public.customer_sales_release_lines release_line
  LEFT JOIN LATERAL (
    SELECT allocation_line.allocated_amount
    FROM public.shipping_documents shipping_document
    JOIN public.shipping_cost_allocations shipping_allocation
      ON shipping_allocation.shipping_document_id = shipping_document.id
     AND shipping_allocation.active = true
     AND shipping_allocation.allocation_status = 'approved'
    JOIN public.shipping_cost_allocation_lines allocation_line
      ON allocation_line.shipping_cost_allocation_id = shipping_allocation.id
     AND allocation_line.tracking_submission_id = release_line.tracking_submission_id
     AND allocation_line.supplier_invoice_line_id = release_line.supplier_invoice_line_id
    WHERE shipping_document.shipment_batch_id = release_line.source_shipment_batch_id
      AND shipping_document.active = true
      AND shipping_document.review_status = 'accepted_current'
    ORDER BY shipping_allocation.approved_at DESC NULLS LAST,
             shipping_allocation.created_at DESC,
             shipping_allocation.id DESC
    LIMIT 1
  ) current_shipping ON true
  WHERE release_line.sales_invoice_id = v_invoice_id
    AND release_line.release_status = 'active';

  IF v_active_line_count <> 3 OR ABS(v_current_shipping - 120.00) > 0.01 THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id = v_invoice_id
      AND release_line.release_status = 'active'
      AND release_line.created_by_staff_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Known unposted draft cannot be corrected safely: release creator provenance is missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot_row
    WHERE snapshot_row.source_table = 'sales_invoices'
      AND snapshot_row.source_id = v_invoice_id
      AND COALESCE(snapshot_row.active, true) = true
      AND COALESCE(snapshot_row.sage_posting_status, 'not_posted') <> 'voided'
  ) THEN
    RAISE EXCEPTION 'Known unposted draft cannot be corrected safely: active Sage snapshot exists';
  END IF;

  UPDATE public.sales_invoices customer_invoice
  SET sage_status = 'void'
  WHERE customer_invoice.id = v_invoice_id
    AND customer_invoice.sage_status = 'draft'
    AND customer_invoice.sage_invoice_id IS NULL
    AND customer_invoice.sage_posted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Known unposted draft changed during guarded correction';
  END IF;

  UPDATE public.customer_sales_release_lines release_line
  SET release_status = 'reversed',
      reversed_at = now(),
      reversed_by_staff_id = release_line.created_by_staff_id,
      reversal_reason = 'automated_migration_correction_v1_original_draft_creator_retained_as_mandatory_actor'
  WHERE release_line.sales_invoice_id = v_invoice_id
    AND release_line.release_status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Known unposted draft had no active membership to reverse';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
