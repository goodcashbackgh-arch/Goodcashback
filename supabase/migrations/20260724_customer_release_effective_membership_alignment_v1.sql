BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- Customer release effective-shipment membership alignment v1
--
-- Reuses the existing immutable shipment-line snapshot as the exact physical
-- source boundary for Mini-build 3 customer billing. This closes the gap where
-- the customer-release resolver reconstructed every allocation on a package and
-- could therefore re-admit a line that shipment creation had deliberately
-- excluded for a customer hold/refund.
--
-- The patch is additive and preserves the existing queue, draft RPC, one-main /
-- repeated-supplementary route, release ledger, AP, Sage, VAT and status spines.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing authoritative effective shipment-line function';
  END IF;
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_sales_release_guard_v1()') IS NULL
     OR to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Customer-release prerequisite function missing';
  END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Customer-release prerequisite relation missing';
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
      batch_row.id AS batch_id,
      batch_row.booking_ref::text AS booking_ref,
      batch_row.importer_id,
      COALESCE(NULLIF(importer_row.trading_name, ''), importer_row.company_name)::text AS importer_name,
      batch_row.shipper_id,
      shipper_row.name::text AS shipper_name,
      effective_line.order_id AS source_order_id,
      CASE
        WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
          THEN order_row.parent_order_id
        ELSE order_row.id
      END AS commercial_parent_order_id,
      parent_order.order_ref::text AS order_ref,
      effective_line.tracking_submission_id,
      tracking_row.tracking_ref::text AS tracking_ref,
      effective_line.tracking_line_allocation_id,
      supplier_line.supplier_invoice_id,
      effective_line.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(supplier_line.description), ''), 'Goods')::text AS item_description,
      COALESCE(effective_line.qty_in_shipment, 0)::numeric AS allocated_qty,
      COALESCE(effective_line.adjusted_net_value_gbp, 0)::numeric AS allocated_goods,
      ROUND(COALESCE(allocation_row.retailer_delivery_share_gbp, 0) * membership_ratio.ratio, 2)::numeric AS allocated_delivery,
      ROUND(COALESCE(allocation_row.discount_share_gbp, 0) * membership_ratio.ratio, 2)::numeric AS allocated_discount,
      supplier_invoice.review_status::text AS review_status,
      COALESCE(supplier_invoice.blocked_from_sage_yn, false) AS blocked_from_sage_yn,
      supplier_line.eligible_for_invoice_yn::text AS eligible_for_invoice_yn,
      receipt.receipt_status::text AS latest_receipt_status,
      COALESCE(shipping.allocated_amount, 0)::numeric AS allocated_shipping,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices existing_main
        WHERE existing_main.order_id = CASE
          WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
            THEN order_row.parent_order_id
          ELSE order_row.id
        END
          AND existing_main.invoice_type = 'main'
          AND existing_main.sage_status <> 'void'
      ) AS has_main,
      EXISTS (
        SELECT 1
        FROM public.sales_invoices existing_draft
        WHERE existing_draft.order_id = CASE
          WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
            THEN order_row.parent_order_id
          ELSE order_row.id
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
          WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
            THEN order_row.parent_order_id
          ELSE order_row.id
        END
          AND legacy_issue.resolved_at IS NULL
      ) AS has_legacy_issue,
      EXISTS (
        SELECT 1
        FROM public.customer_pre_shipment_hold_requests hold_row
        WHERE hold_row.order_id IN (
          order_row.id,
          CASE
            WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
              THEN order_row.parent_order_id
            ELSE order_row.id
          END
        )
          AND hold_row.resolved_at IS NULL
          AND hold_row.status IN ('requested', 'supervisor_approved')
          AND (
            hold_row.requested_scope = 'order'
            OR (
              hold_row.requested_scope = 'tracking'
              AND hold_row.tracking_submission_id = effective_line.tracking_submission_id
            )
            OR (
              hold_row.requested_scope = 'line'
              AND hold_row.supplier_invoice_line_id = effective_line.supplier_invoice_line_id
            )
          )
      ) AS has_hold,
      EXISTS (
        SELECT 1
        FROM public.dispute_lines dispute_line
        JOIN public.disputes dispute_row
          ON dispute_row.id = dispute_line.dispute_id
        WHERE dispute_line.supplier_invoice_line_id = effective_line.supplier_invoice_line_id
          AND dispute_line.resolved_at IS NULL
          AND dispute_row.resolved_at IS NULL
      ) AS has_exception,
      EXISTS (
        SELECT 1
        FROM public.dispute_lines terminal_line
        JOIN public.disputes terminal_dispute
          ON terminal_dispute.id = terminal_line.dispute_id
        WHERE terminal_line.supplier_invoice_line_id = effective_line.supplier_invoice_line_id
          AND terminal_dispute.desired_outcome = 'refund'
          AND terminal_dispute.status = 'refunded'
          AND terminal_dispute.resolved_at IS NOT NULL
      ) AS has_terminal_refund
    FROM public.shipper_shipment_batches batch_row
    JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(batch_row.id) effective_line
      ON true
    JOIN public.order_tracking_line_allocations allocation_row
      ON allocation_row.id = effective_line.tracking_line_allocation_id
     AND allocation_row.order_id = effective_line.order_id
     AND allocation_row.tracking_submission_id = effective_line.tracking_submission_id
     AND allocation_row.supplier_invoice_line_id = effective_line.supplier_invoice_line_id
    JOIN public.order_tracking_submissions tracking_row
      ON tracking_row.id = effective_line.tracking_submission_id
    JOIN public.orders order_row
      ON order_row.id = effective_line.order_id
    JOIN public.orders parent_order
      ON parent_order.id = CASE
        WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
          THEN order_row.parent_order_id
        ELSE order_row.id
      END
    JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = effective_line.supplier_invoice_line_id
    JOIN public.supplier_invoices supplier_invoice
      ON supplier_invoice.id = supplier_line.supplier_invoice_id
    JOIN public.shippers shipper_row
      ON shipper_row.id = batch_row.shipper_id
    LEFT JOIN public.importers importer_row
      ON importer_row.id = batch_row.importer_id
    CROSS JOIN LATERAL (
      SELECT LEAST(
        1::numeric,
        GREATEST(
          0::numeric,
          CASE
            WHEN COALESCE(allocation_row.adjusted_net_value_gbp, 0) > 0
              THEN COALESCE(effective_line.adjusted_net_value_gbp, 0)
                   / allocation_row.adjusted_net_value_gbp
            WHEN COALESCE(allocation_row.qty_allocated, 0) > 0
              THEN COALESCE(effective_line.qty_in_shipment, 0)
                   / allocation_row.qty_allocated
            ELSE 0::numeric
          END
        )
      )::numeric AS ratio
    ) membership_ratio
    LEFT JOIN LATERAL (
      SELECT receipt_row.receipt_status
      FROM public.shipper_package_receipts receipt_row
      WHERE receipt_row.tracking_submission_id = effective_line.tracking_submission_id
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
       AND allocation_line.tracking_submission_id = effective_line.tracking_submission_id
       AND allocation_line.supplier_invoice_line_id = effective_line.supplier_invoice_line_id
      WHERE shipping_document.shipment_batch_id = batch_row.id
        AND shipping_document.active = true
        AND shipping_document.review_status = 'accepted_current'
      ORDER BY shipping_allocation.approved_at DESC NULLS LAST,
               shipping_allocation.created_at DESC,
               shipping_allocation.id DESC
      LIMIT 1
    ) shipping ON true
    WHERE batch_row.id = p_batch_id
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
    GROUP BY release_line.tracking_line_allocation_id,
             release_line.source_shipment_batch_id
  ), calc AS (
    SELECT
      raw_row.*,
      GREATEST(raw_row.allocated_qty - COALESCE(goods_used.released_qty, 0), 0)::numeric AS remaining_qty,
      GREATEST(raw_row.allocated_goods - COALESCE(goods_used.released_goods, 0), 0)::numeric AS remaining_goods,
      GREATEST(raw_row.allocated_delivery - COALESCE(goods_used.released_delivery, 0), 0)::numeric AS remaining_delivery,
      GREATEST(raw_row.allocated_discount - COALESCE(goods_used.released_discount, 0), 0)::numeric AS remaining_discount,
      GREATEST(raw_row.allocated_shipping - COALESCE(shipping_used.released_shipping, 0), 0)::numeric AS remaining_shipping,
      COALESCE(shipping_used.released_shipping, 0) > raw_row.allocated_shipping + 0.02
        AS shipping_released_above_current_approval
    FROM raw raw_row
    LEFT JOIN used_goods goods_used
      ON goods_used.tracking_line_allocation_id = raw_row.tracking_line_allocation_id
    LEFT JOIN used_shipping shipping_used
      ON shipping_used.tracking_line_allocation_id = raw_row.tracking_line_allocation_id
     AND shipping_used.source_shipment_batch_id = raw_row.batch_id
  ), emitted AS (
    SELECT
      calc_row.*,
      CASE WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_qty ELSE 0::numeric END AS emit_qty,
      ROUND(calc_row.remaining_goods, 2)::numeric AS emit_goods,
      ROUND(CASE WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_delivery ELSE 0 END, 2)::numeric AS emit_delivery,
      ROUND(CASE WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_discount ELSE 0 END, 2)::numeric AS emit_discount,
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
    CASE WHEN emitted_row.has_main THEN 'main_sales_invoice_exists' ELSE 'no_main_sales_invoice_found' END::text,
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
      WHEN emitted_row.has_terminal_refund
        THEN 'terminal_refund_line_excluded'
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

CREATE OR REPLACE FUNCTION public.customer_sales_release_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src record;
  v_sales record;
  v_parent uuid;
  v_qty numeric;
  v_goods numeric;
  v_ship numeric;
  v_receipt text;
  v_effective_qty numeric;
  v_effective_goods numeric;
BEGIN
  SELECT
    sales_invoice.id,
    sales_invoice.order_id,
    sales_invoice.invoice_type::text AS invoice_type,
    sales_invoice.sage_status::text AS sage_status,
    sales_invoice.sage_invoice_id,
    sales_invoice.sage_posted_at,
    sales_invoice.amount_gbp
  INTO v_sales
  FROM public.sales_invoices sales_invoice
  WHERE sales_invoice.id = NEW.sales_invoice_id
  FOR UPDATE;

  IF v_sales.id IS NULL THEN
    RAISE EXCEPTION 'Sales invoice not found';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF (to_jsonb(NEW) - ARRAY['release_status','reversed_at','reversed_by_staff_id','reversal_reason'])
       IS DISTINCT FROM
       (to_jsonb(OLD) - ARRAY['release_status','reversed_at','reversed_by_staff_id','reversal_reason'])
    THEN
      RAISE EXCEPTION 'Release provenance is immutable; only audited reversal fields may change';
    END IF;
    IF OLD.release_status = 'reversed' THEN
      RAISE EXCEPTION 'Reversed release membership is immutable';
    END IF;
    IF NEW.release_status = 'reversed' THEN
      IF v_sales.sage_status <> 'void'
         OR v_sales.sage_invoice_id IS NOT NULL
         OR v_sales.sage_posted_at IS NOT NULL
      THEN
        RAISE EXCEPTION 'Release membership may only be reversed after an unposted invoice is void';
      END IF;
      IF EXISTS (
        SELECT 1
        FROM public.sage_posting_snapshots snapshot_row
        WHERE snapshot_row.source_table = 'sales_invoices'
          AND snapshot_row.source_id = NEW.sales_invoice_id
          AND COALESCE(snapshot_row.active, true) = true
          AND COALESCE(snapshot_row.sage_posting_status, 'not_posted') <> 'voided'
      ) THEN
        RAISE EXCEPTION 'Release membership cannot be reversed while an active Sage snapshot exists';
      END IF;
      RETURN NEW;
    END IF;
  END IF;

  IF v_sales.invoice_type IS DISTINCT FROM NEW.sales_invoice_type THEN
    RAISE EXCEPTION 'Release invoice type mismatch';
  END IF;
  IF v_sales.sage_status = 'void' THEN
    RAISE EXCEPTION 'Cannot attach active release membership to a void invoice';
  END IF;

  SELECT
    allocation_row.*,
    supplier_line.supplier_invoice_id,
    supplier_invoice.review_status,
    supplier_invoice.blocked_from_sage_yn,
    order_row.order_type,
    order_row.parent_order_id,
    supplier_line.eligible_for_invoice_yn
  INTO v_src
  FROM public.order_tracking_line_allocations allocation_row
  JOIN public.supplier_invoice_lines supplier_line
    ON supplier_line.id = allocation_row.supplier_invoice_line_id
  JOIN public.supplier_invoices supplier_invoice
    ON supplier_invoice.id = supplier_line.supplier_invoice_id
  JOIN public.orders order_row
    ON order_row.id = allocation_row.order_id
  WHERE allocation_row.id = NEW.tracking_line_allocation_id
  FOR UPDATE OF allocation_row;

  IF v_src.id IS NULL
     OR v_src.order_id IS DISTINCT FROM NEW.order_id
     OR v_src.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
     OR v_src.supplier_invoice_id IS DISTINCT FROM NEW.supplier_invoice_id
     OR v_src.tracking_submission_id IS DISTINCT FROM NEW.tracking_submission_id
  THEN
    RAISE EXCEPTION 'Release source identity does not match the exact tracking allocation';
  END IF;

  v_parent := CASE
    WHEN v_src.order_type = 'replacement_child' AND v_src.parent_order_id IS NOT NULL
      THEN v_src.parent_order_id
    ELSE v_src.order_id
  END;

  IF NEW.commercial_parent_order_id IS DISTINCT FROM v_parent
     OR v_sales.order_id IS DISTINCT FROM v_parent
  THEN
    RAISE EXCEPTION 'Release commercial parent identity mismatch';
  END IF;

  IF COALESCE(v_src.review_status, 'pending_review') NOT IN ('approved_current', 'ref_corrected_approved')
     OR COALESCE(v_src.blocked_from_sage_yn, false) = true
  THEN
    RAISE EXCEPTION 'Supplier invoice is not approved/current for release';
  END IF;
  IF lower(COALESCE(v_src.eligible_for_invoice_yn::text, '')) NOT IN ('y', 'yes', 'true', '1') THEN
    RAISE EXCEPTION 'Supplier invoice line is not progressed for release';
  END IF;

  SELECT receipt_row.receipt_status::text
  INTO v_receipt
  FROM public.shipper_package_receipts receipt_row
  WHERE receipt_row.tracking_submission_id = NEW.tracking_submission_id
  ORDER BY receipt_row.recorded_at DESC,
           receipt_row.created_at DESC,
           receipt_row.id DESC
  LIMIT 1;

  IF v_receipt IS DISTINCT FROM 'received_clean' THEN
    RAISE EXCEPTION 'Package is not currently received clean';
  END IF;

  IF NEW.source_shipment_batch_id IS NOT NULL THEN
    SELECT
      effective_line.qty_in_shipment,
      effective_line.adjusted_net_value_gbp
    INTO v_effective_qty, v_effective_goods
    FROM public.shipper_shipment_batch_effective_lines_v1(NEW.source_shipment_batch_id) effective_line
    WHERE effective_line.tracking_line_allocation_id = NEW.tracking_line_allocation_id
      AND effective_line.order_id = NEW.order_id
      AND effective_line.tracking_submission_id = NEW.tracking_submission_id
      AND effective_line.supplier_invoice_line_id = NEW.supplier_invoice_line_id
    LIMIT 1;

    IF v_effective_qty IS NULL THEN
      RAISE EXCEPTION 'Release source is not an effective line of the stated shipment batch';
    END IF;
  ELSE
    v_effective_qty := COALESCE(v_src.qty_allocated, 0);
    v_effective_goods := COALESCE(v_src.adjusted_net_value_gbp, 0);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests hold_row
    WHERE hold_row.order_id = NEW.order_id
      AND hold_row.resolved_at IS NULL
      AND hold_row.status IN ('requested', 'supervisor_approved')
      AND (
        hold_row.requested_scope = 'order'
        OR (hold_row.requested_scope = 'tracking' AND hold_row.tracking_submission_id = NEW.tracking_submission_id)
        OR (hold_row.requested_scope = 'line' AND hold_row.supplier_invoice_line_id = NEW.supplier_invoice_line_id)
      )
  ) THEN
    RAISE EXCEPTION 'Active customer hold conflicts with release membership';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines dispute_line
    JOIN public.disputes dispute_row ON dispute_row.id = dispute_line.dispute_id
    WHERE dispute_line.supplier_invoice_line_id = NEW.supplier_invoice_line_id
      AND dispute_line.resolved_at IS NULL
      AND dispute_row.resolved_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Unresolved exception conflicts with release membership';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines terminal_line
    JOIN public.disputes terminal_dispute ON terminal_dispute.id = terminal_line.dispute_id
    WHERE terminal_line.supplier_invoice_line_id = NEW.supplier_invoice_line_id
      AND terminal_dispute.desired_outcome = 'refund'
      AND terminal_dispute.status = 'refunded'
      AND terminal_dispute.resolved_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Terminal refunded line cannot be attached to a customer sales release';
  END IF;

  SELECT
    COALESCE(SUM(release_line.released_qty), 0),
    COALESCE(SUM(release_line.goods_amount_gbp), 0),
    COALESCE(SUM(release_line.shipping_amount_gbp), 0)
  INTO v_qty, v_goods, v_ship
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.tracking_line_allocation_id = NEW.tracking_line_allocation_id
    AND release_line.release_status = 'active'
    AND (TG_OP = 'INSERT' OR release_line.id <> NEW.id);

  IF v_qty + NEW.released_qty > COALESCE(v_effective_qty, 0) + 0.001 THEN
    RAISE EXCEPTION 'Release quantity exceeds exact effective shipment membership';
  END IF;
  IF v_goods + NEW.goods_amount_gbp > COALESCE(v_effective_goods, 0) + 0.02 THEN
    RAISE EXCEPTION 'Release goods value exceeds exact effective shipment membership';
  END IF;
  IF NEW.delivery_share_gbp > COALESCE(v_src.retailer_delivery_share_gbp, 0) + 0.02
     OR NEW.discount_share_gbp > COALESCE(v_src.discount_share_gbp, 0) + 0.02
  THEN
    RAISE EXCEPTION 'Release delivery/discount share exceeds exact tracking allocation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid, booking_ref text, importer_id uuid, importer_name text,
  shipper_id uuid, shipper_name text, proposed_invoice_type text,
  proposed_invoice_status text, customer_recharge_route text, sales_invoice_state text,
  vat_code text, proposed_amount_gbp numeric, proposed_goods_amount_gbp numeric,
  proposed_shipping_amount_gbp numeric, line_items_json jsonb, order_id uuid,
  order_ref text, tracking_submission_id uuid, tracking_ref text,
  supplier_invoice_line_id uuid, item_description text, qty_allocated numeric,
  goods_amount_gbp numeric, shipping_amount_gbp numeric, total_line_amount_gbp numeric,
  readiness_status text, blocker text
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
    SELECT * FROM public.internal_customer_sales_release_sources_v1(p_shipment_batch_id)
  ), totals AS (
    SELECT
      COALESCE(SUM(customer_charge_amount_gbp) FILTER (WHERE blocker IS NULL), 0)::numeric AS amount,
      COALESCE(SUM(goods_amount_gbp) FILTER (WHERE blocker IS NULL), 0)::numeric AS goods,
      COALESCE(SUM(shipping_amount_gbp) FILTER (WHERE blocker IS NULL), 0)::numeric AS shipping,
      COALESCE(jsonb_agg(jsonb_build_object(
        'source_order_id', source_order_id,
        'source_commercial_parent_order_id', commercial_parent_order_id,
        'source_shipment_batch_id', shipment_batch_id,
        'source_tracking_submission_id', tracking_submission_id,
        'source_tracking_line_allocation_id', tracking_line_allocation_id,
        'source_supplier_invoice_id', supplier_invoice_id,
        'source_supplier_invoice_line_id', supplier_invoice_line_id,
        'released_qty', release_qty,
        'goods_amount_gbp', goods_amount_gbp,
        'delivery_share_gbp', delivery_share_gbp,
        'discount_share_gbp', discount_share_gbp,
        'shipping_amount_gbp', shipping_amount_gbp,
        'customer_charge_amount_gbp', customer_charge_amount_gbp,
        'membership_fingerprint', membership_fingerprint,
        'description', item_description,
        'quantity', CASE WHEN release_qty > 0 THEN release_qty ELSE 1 END,
        'total_line_amount_gbp', customer_charge_amount_gbp,
        'ledger_account_role', 'export_sale_income',
        'source', 'customer_sales_release_ledger'
      ) ORDER BY order_ref, tracking_ref, item_description) FILTER (WHERE blocker IS NULL), '[]'::jsonb) AS lines
    FROM src
  )
  SELECT
    source_row.shipment_batch_id, source_row.booking_ref, source_row.importer_id,
    source_row.importer_name, source_row.shipper_id, source_row.shipper_name,
    source_row.proposed_invoice_type,
    CASE WHEN source_row.blocker IS NULL THEN 'draft_preview' ELSE 'blocked' END,
    CASE WHEN source_row.proposed_invoice_type = 'main' THEN 'main_customer_release_invoice'
         ELSE 'supplementary_customer_release_invoice' END,
    source_row.sales_invoice_state, 'T0 / GB_ZERO', total_row.amount, total_row.goods,
    total_row.shipping, total_row.lines, source_row.commercial_parent_order_id,
    source_row.order_ref, source_row.tracking_submission_id, source_row.tracking_ref,
    source_row.supplier_invoice_line_id, source_row.item_description, source_row.release_qty,
    source_row.goods_amount_gbp, source_row.shipping_amount_gbp,
    source_row.customer_charge_amount_gbp,
    CASE WHEN source_row.blocker IS NOT NULL THEN 'blocked'
         WHEN source_row.proposed_invoice_type = 'main' THEN 'ready_for_main_invoice_release_preview'
         ELSE 'ready_for_supplementary_invoice_preview' END,
    source_row.blocker
  FROM src source_row
  CROSS JOIN totals total_row
  WHERE source_row.blocker IS NULL
     OR NOT EXISTS (SELECT 1 FROM src ready_source WHERE ready_source.blocker IS NULL)
  ORDER BY source_row.order_ref, source_row.tracking_ref, source_row.item_description;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_remaining_preview_v1(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid, booking_ref text, importer_id uuid, importer_name text,
  shipper_id uuid, shipper_name text, proposed_invoice_type text,
  proposed_invoice_status text, customer_recharge_route text, sales_invoice_state text,
  vat_code text, proposed_amount_gbp numeric, proposed_goods_amount_gbp numeric,
  proposed_shipping_amount_gbp numeric, line_items_json jsonb, order_id uuid,
  order_ref text, tracking_submission_id uuid, tracking_ref text,
  supplier_invoice_line_id uuid, item_description text, qty_allocated numeric,
  goods_amount_gbp numeric, shipping_amount_gbp numeric, total_line_amount_gbp numeric,
  readiness_status text, blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    JOIN public.sales_invoices sales_invoice ON sales_invoice.id = release_line.sales_invoice_id
    WHERE release_line.source_shipment_batch_id = p_shipment_batch_id
      AND release_line.release_status = 'active'
      AND sales_invoice.sage_status <> 'void'
  ) THEN
    RETURN QUERY
    WITH released AS (
      SELECT
        release_line.*,
        sales_invoice.invoice_type::text AS invoice_type,
        sales_invoice.sage_status::text AS sage_status,
        sales_invoice.sage_invoice_id,
        sales_invoice.sage_posted_at,
        sales_invoice.vat_code::text AS invoice_vat_code,
        order_row.order_ref::text AS order_ref,
        tracking_row.tracking_ref::text AS tracking_ref,
        COALESCE(NULLIF(BTRIM(supplier_line.description), ''), 'Goods')::text AS item_description,
        batch_row.booking_ref::text AS booking_ref,
        batch_row.importer_id,
        COALESCE(NULLIF(importer_row.trading_name, ''), importer_row.company_name)::text AS importer_name,
        batch_row.shipper_id,
        shipper_row.name::text AS shipper_name
      FROM public.customer_sales_release_lines release_line
      JOIN public.sales_invoices sales_invoice
        ON sales_invoice.id = release_line.sales_invoice_id
       AND sales_invoice.sage_status <> 'void'
      JOIN public.shipper_shipment_batches batch_row
        ON batch_row.id = release_line.source_shipment_batch_id
      JOIN public.orders order_row
        ON order_row.id = release_line.commercial_parent_order_id
      JOIN public.order_tracking_submissions tracking_row
        ON tracking_row.id = release_line.tracking_submission_id
      JOIN public.supplier_invoice_lines supplier_line
        ON supplier_line.id = release_line.supplier_invoice_line_id
      JOIN public.shippers shipper_row
        ON shipper_row.id = batch_row.shipper_id
      LEFT JOIN public.importers importer_row
        ON importer_row.id = batch_row.importer_id
      WHERE release_line.source_shipment_batch_id = p_shipment_batch_id
        AND release_line.release_status = 'active'
    ), totals AS (
      SELECT
        ROUND(SUM(released.customer_charge_amount_gbp), 2)::numeric AS amount,
        ROUND(SUM(released.goods_amount_gbp), 2)::numeric AS goods,
        ROUND(SUM(released.shipping_amount_gbp), 2)::numeric AS shipping,
        jsonb_agg(jsonb_build_object(
          'source_order_id', released.order_id,
          'source_commercial_parent_order_id', released.commercial_parent_order_id,
          'source_shipment_batch_id', released.source_shipment_batch_id,
          'source_tracking_submission_id', released.tracking_submission_id,
          'source_tracking_line_allocation_id', released.tracking_line_allocation_id,
          'source_supplier_invoice_id', released.supplier_invoice_id,
          'source_supplier_invoice_line_id', released.supplier_invoice_line_id,
          'released_qty', released.released_qty,
          'goods_amount_gbp', released.goods_amount_gbp,
          'delivery_share_gbp', released.delivery_share_gbp,
          'discount_share_gbp', released.discount_share_gbp,
          'shipping_amount_gbp', released.shipping_amount_gbp,
          'customer_charge_amount_gbp', released.customer_charge_amount_gbp,
          'membership_fingerprint', released.membership_fingerprint,
          'description', released.item_description,
          'quantity', CASE WHEN released.released_qty > 0 THEN released.released_qty ELSE 1 END,
          'total_line_amount_gbp', released.customer_charge_amount_gbp,
          'ledger_account_role', 'export_sale_income',
          'source', 'durable_release_membership_authoritative'
        ) ORDER BY released.created_at, released.id) AS lines
      FROM released
    )
    SELECT
      released.source_shipment_batch_id, released.booking_ref, released.importer_id,
      released.importer_name, released.shipper_id, released.shipper_name,
      released.invoice_type, 'released_customer_document'::text,
      'already_bundled_in_main_sales_invoice'::text,
      CASE
        WHEN released.sage_status = 'posted' AND released.sage_invoice_id IS NOT NULL
             AND released.sage_posted_at IS NOT NULL
          THEN 'customer_sales_document_posted_with_sage_confirmation'
        WHEN released.sage_status = 'posted' THEN 'customer_sales_document_internal_posted'
        ELSE 'customer_sales_document_draft_exists'
      END::text,
      COALESCE(NULLIF(released.invoice_vat_code, ''), 'T0 / GB_ZERO')::text,
      totals.amount, totals.goods, totals.shipping, totals.lines,
      released.commercial_parent_order_id, released.order_ref,
      released.tracking_submission_id, released.tracking_ref,
      released.supplier_invoice_line_id, released.item_description,
      released.released_qty, released.goods_amount_gbp, released.shipping_amount_gbp,
      released.customer_charge_amount_gbp,
      'already_bundled_in_main_sales_invoice'::text, NULL::text
    FROM released
    CROSS JOIN totals
    ORDER BY released.order_ref, released.tracking_ref, released.item_description, released.created_at;
    RETURN;
  END IF;

  RETURN QUERY SELECT *
  FROM public.internal_shipping_customer_invoice_remaining_preview_v1(p_shipment_batch_id);
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(
  p_sales_invoice_id uuid DEFAULT NULL
)
RETURNS TABLE (
  sales_invoice_id uuid, order_id uuid, order_ref text, document_lane text,
  document_type text, invoice_type text, counterparty_name text, amount_gbp numeric,
  currency_code text, reference_text text, notes_text text, sage_status text,
  sage_invoice_id text, sage_posted_at timestamptz, commercial_payload jsonb,
  resolved_payload jsonb, mapping_snapshot jsonb, mapping_semantic_fingerprint text,
  payload_status text, blocker text, warning text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required for customer sales Sage payload resolution';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT * FROM public.internal_customer_sales_sage_payload_pre_ledger_v1(p_sales_invoice_id)
  ), ledger AS (
    SELECT
      release_line.sales_invoice_id,
      COUNT(*)::integer AS line_count,
      ROUND(SUM(release_line.customer_charge_amount_gbp), 2)::numeric AS ledger_total,
      jsonb_agg(jsonb_build_object(
        'line_kind', 'customer_sales_from_durable_release_membership',
        'source_order_id', release_line.order_id,
        'source_commercial_parent_order_id', release_line.commercial_parent_order_id,
        'source_shipment_batch_id', release_line.source_shipment_batch_id,
        'source_supplier_invoice_id', release_line.supplier_invoice_id,
        'source_supplier_invoice_line_id', release_line.supplier_invoice_line_id,
        'source_tracking_submission_id', release_line.tracking_submission_id,
        'source_tracking_line_allocation_id', release_line.tracking_line_allocation_id,
        'released_qty', release_line.released_qty,
        'description', COALESCE(NULLIF(supplier_line.description, ''), 'Export sale'),
        'quantity', CASE WHEN release_line.released_qty > 0 THEN release_line.released_qty ELSE 1 END,
        'unit_price_gbp', CASE WHEN release_line.released_qty > 0
          THEN ROUND(release_line.customer_charge_amount_gbp / release_line.released_qty, 2)
          ELSE release_line.customer_charge_amount_gbp END,
        'goods_amount_gbp', release_line.goods_amount_gbp,
        'delivery_share_gbp', release_line.delivery_share_gbp,
        'discount_share_gbp', release_line.discount_share_gbp,
        'shipping_amount_gbp', release_line.shipping_amount_gbp,
        'total_line_amount_gbp', release_line.customer_charge_amount_gbp,
        'ledger_account_role', 'export_sale_income',
        'customer_gl_role', 'export_sale_income',
        'presentation', 'principal_export_sale_from_durable_release_membership',
        'source', 'customer_sales_release_lines'
      ) ORDER BY release_line.created_at, release_line.id) AS ledger_lines
    FROM public.customer_sales_release_lines release_line
    LEFT JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = release_line.supplier_invoice_line_id
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.sales_invoice_id
  ), legacy AS (
    SELECT legacy_issue.sales_invoice_id,
      string_agg(DISTINCT legacy_issue.issue_code, ', ' ORDER BY legacy_issue.issue_code)::text AS issue_codes
    FROM public.customer_sales_release_legacy_issues legacy_issue
    WHERE legacy_issue.resolved_at IS NULL
    GROUP BY legacy_issue.sales_invoice_id
  ), shaped AS (
    SELECT
      base_row.*, ledger_row.line_count, ledger_row.ledger_total, ledger_row.ledger_lines,
      legacy_row.issue_codes,
      CASE
        WHEN base_row.invoice_type NOT IN ('main', 'supplementary') OR base_row.sage_status = 'void'
          THEN base_row.payload_status
        WHEN legacy_row.issue_codes IS NOT NULL THEN 'blocked_customer_sales_release_provenance_unresolved'
        WHEN COALESCE(ledger_row.line_count, 0) = 0 THEN 'blocked_customer_sales_release_provenance_unresolved'
        WHEN ABS(COALESCE(ledger_row.ledger_total, 0) - COALESCE(base_row.amount_gbp, 0)) > 0.02
          THEN 'blocked_customer_sales_release_ledger_amount_mismatch'
        ELSE base_row.payload_status
      END::text AS final_status,
      CASE
        WHEN base_row.invoice_type NOT IN ('main', 'supplementary') OR base_row.sage_status = 'void'
          THEN base_row.blocker
        WHEN legacy_row.issue_codes IS NOT NULL
          THEN 'customer sales release legacy provenance unresolved: ' || legacy_row.issue_codes
        WHEN COALESCE(ledger_row.line_count, 0) = 0
          THEN 'customer sales release durable membership missing'
        WHEN ABS(COALESCE(ledger_row.ledger_total, 0) - COALESCE(base_row.amount_gbp, 0)) > 0.02
          THEN 'customer sales release ledger total does not match sales invoice amount'
        ELSE base_row.blocker
      END::text AS final_blocker
    FROM base base_row
    LEFT JOIN ledger ledger_row ON ledger_row.sales_invoice_id = base_row.sales_invoice_id
    LEFT JOIN legacy legacy_row ON legacy_row.sales_invoice_id = base_row.sales_invoice_id
  )
  SELECT
    shaped_row.sales_invoice_id, shaped_row.order_id, shaped_row.order_ref,
    shaped_row.document_lane, shaped_row.document_type, shaped_row.invoice_type,
    shaped_row.counterparty_name, shaped_row.amount_gbp, shaped_row.currency_code,
    shaped_row.reference_text, shaped_row.notes_text, shaped_row.sage_status,
    shaped_row.sage_invoice_id, shaped_row.sage_posted_at, shaped_row.commercial_payload,
    (
      CASE
        WHEN shaped_row.invoice_type IN ('main', 'supplementary')
             AND shaped_row.sage_status <> 'void'
             AND shaped_row.final_status = shaped_row.payload_status
        THEN jsonb_set(
          jsonb_set(
            shaped_row.resolved_payload,
            '{resolved_lines}',
            COALESCE((
              SELECT jsonb_agg(line.value || jsonb_build_object(
                'sage_tax_rate_id', shaped_row.resolved_payload #>> '{resolved_mappings,ZERO_RATED_EXPORT_TAX_RATE,sage_external_id}',
                'sage_tax_rate_display', shaped_row.resolved_payload #>> '{resolved_mappings,ZERO_RATED_EXPORT_TAX_RATE,sage_display_name}',
                'sage_ledger_account_id', shaped_row.resolved_payload #>> '{resolved_mappings,EXPORT_SALE_INCOME_LEDGER,sage_external_id}',
                'sage_ledger_account_display', shaped_row.resolved_payload #>> '{resolved_mappings,EXPORT_SALE_INCOME_LEDGER,sage_display_name}'
              ) ORDER BY line.ordinality)
              FROM jsonb_array_elements(COALESCE(shaped_row.ledger_lines, '[]'::jsonb))
                WITH ORDINALITY AS line(value, ordinality)
            ), '[]'::jsonb), true
          ),
          '{line_resolution}',
          jsonb_build_object(
            'source', 'durable_release_membership_authoritative',
            'source_line_count', COALESCE(shaped_row.line_count, 0),
            'source_line_total_gbp', COALESCE(shaped_row.ledger_total, 0),
            'sales_invoice_amount_gbp', shaped_row.amount_gbp
          ), true
        )
        ELSE shaped_row.resolved_payload
      END
      || jsonb_build_object(
        'resolver_control',
        COALESCE(shaped_row.resolved_payload -> 'resolver_control', '{}'::jsonb)
          || jsonb_build_object('status', shaped_row.final_status, 'blocker', shaped_row.final_blocker)
      )
    )::jsonb,
    shaped_row.mapping_snapshot, shaped_row.mapping_semantic_fingerprint,
    shaped_row.final_status, shaped_row.final_blocker,
    concat_ws(' | ', NULLIF(shaped_row.warning, ''), CASE
      WHEN shaped_row.invoice_type IN ('main', 'supplementary')
           AND shaped_row.sage_status <> 'void'
           AND shaped_row.final_status = shaped_row.payload_status
        THEN 'durable_release_membership_authoritative' ELSE NULL END)::text
  FROM shaped shaped_row;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO service_role;

DO $$
DECLARE
  v_oid oid;
  v_definition text;
BEGIN
  FOR v_oid IN
    SELECT procedure_row.oid
    FROM pg_proc procedure_row
    JOIN pg_namespace namespace_row ON namespace_row.oid = procedure_row.pronamespace
    WHERE namespace_row.nspname = 'public'
      AND procedure_row.prokind = 'f'
      AND procedure_row.proname NOT IN (
        'internal_resolved_customer_sales_sage_payload_v1',
        'internal_customer_sales_sage_payload_pre_ledger_v1'
      )
      AND procedure_row.prosrc LIKE '%internal_resolved_customer_sales_sage_payload_v1%'
  LOOP
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    EXECUTE v_definition;
  END LOOP;
END $$;

DO $$
DECLARE
  v_invoice_id uuid;
  v_actor uuid;
  v_match_count integer;
BEGIN
  SELECT COUNT(*)::integer
  INTO v_match_count
  FROM public.sales_invoices sales_invoice
  JOIN public.orders order_row ON order_row.id = sales_invoice.order_id
  WHERE order_row.order_ref = 'ORD-1784498556959'
    AND sales_invoice.invoice_type IN ('main', 'supplementary')
    AND sales_invoice.sage_status = 'draft'
    AND sales_invoice.sage_invoice_id IS NULL
    AND sales_invoice.sage_posted_at IS NULL
    AND ABS(COALESCE(sales_invoice.amount_gbp, 0) - 1004.96) <= 0.02
    AND NOT EXISTS (
      SELECT 1 FROM public.sage_posting_snapshots snapshot_row
      WHERE snapshot_row.source_table = 'sales_invoices'
        AND snapshot_row.source_id = sales_invoice.id
        AND COALESCE(snapshot_row.active, true) = true
        AND COALESCE(snapshot_row.sage_posting_status, 'not_posted') <> 'voided'
    )
    AND (
      SELECT COUNT(*) FROM public.customer_sales_release_lines release_line
      WHERE release_line.sales_invoice_id = sales_invoice.id
        AND release_line.release_status = 'active'
    ) = 4
    AND ABS((
      SELECT COALESCE(SUM(release_line.customer_charge_amount_gbp), 0)
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.sales_invoice_id = sales_invoice.id
        AND release_line.release_status = 'active'
    ) - 1004.96) <= 0.02
    AND EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.sales_invoice_id = sales_invoice.id
        AND release_line.release_status = 'active'
        AND release_line.supplier_invoice_line_id = 'd7d42758-4a8d-4632-910e-353c06d2f621'::uuid
        AND release_line.source_shipment_batch_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1
          FROM public.shipper_shipment_batch_effective_lines_v1(release_line.source_shipment_batch_id) effective_line
          WHERE effective_line.tracking_line_allocation_id = release_line.tracking_line_allocation_id
            AND effective_line.order_id = release_line.order_id
            AND effective_line.tracking_submission_id = release_line.tracking_submission_id
            AND effective_line.supplier_invoice_line_id = release_line.supplier_invoice_line_id
        )
    );

  IF v_match_count > 1 THEN
    RAISE EXCEPTION 'Multiple exact invalid £1004.96 customer drafts matched; refusing automated correction';
  END IF;

  IF v_match_count = 1 THEN
    SELECT
      sales_invoice.id,
      (ARRAY_AGG(release_line.created_by_staff_id ORDER BY release_line.created_at, release_line.id))[1]
    INTO v_invoice_id, v_actor
    FROM public.sales_invoices sales_invoice
    JOIN public.orders order_row ON order_row.id = sales_invoice.order_id
    JOIN public.customer_sales_release_lines release_line
      ON release_line.sales_invoice_id = sales_invoice.id
     AND release_line.release_status = 'active'
    WHERE order_row.order_ref = 'ORD-1784498556959'
      AND sales_invoice.invoice_type IN ('main', 'supplementary')
      AND sales_invoice.sage_status = 'draft'
      AND sales_invoice.sage_invoice_id IS NULL
      AND sales_invoice.sage_posted_at IS NULL
      AND ABS(COALESCE(sales_invoice.amount_gbp, 0) - 1004.96) <= 0.02
      AND NOT EXISTS (
        SELECT 1 FROM public.sage_posting_snapshots snapshot_row
        WHERE snapshot_row.source_table = 'sales_invoices'
          AND snapshot_row.source_id = sales_invoice.id
          AND COALESCE(snapshot_row.active, true) = true
          AND COALESCE(snapshot_row.sage_posting_status, 'not_posted') <> 'voided'
      )
      AND (
        SELECT COUNT(*) FROM public.customer_sales_release_lines exact_line
        WHERE exact_line.sales_invoice_id = sales_invoice.id
          AND exact_line.release_status = 'active'
      ) = 4
      AND ABS((
        SELECT COALESCE(SUM(exact_line.customer_charge_amount_gbp), 0)
        FROM public.customer_sales_release_lines exact_line
        WHERE exact_line.sales_invoice_id = sales_invoice.id
          AND exact_line.release_status = 'active'
      ) - 1004.96) <= 0.02
      AND EXISTS (
        SELECT 1
        FROM public.customer_sales_release_lines exact_line
        WHERE exact_line.sales_invoice_id = sales_invoice.id
          AND exact_line.release_status = 'active'
          AND exact_line.supplier_invoice_line_id = 'd7d42758-4a8d-4632-910e-353c06d2f621'::uuid
          AND exact_line.source_shipment_batch_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.shipper_shipment_batch_effective_lines_v1(exact_line.source_shipment_batch_id) effective_line
            WHERE effective_line.tracking_line_allocation_id = exact_line.tracking_line_allocation_id
              AND effective_line.order_id = exact_line.order_id
              AND effective_line.tracking_submission_id = exact_line.tracking_submission_id
              AND effective_line.supplier_invoice_line_id = exact_line.supplier_invoice_line_id
          )
      )
    GROUP BY sales_invoice.id;

    IF v_actor IS NULL THEN
      RAISE EXCEPTION 'Exact invalid customer draft has no release creator; refusing unaudited reversal';
    END IF;

    UPDATE public.sales_invoices sales_invoice
    SET sage_status = 'void'
    WHERE sales_invoice.id = v_invoice_id
      AND sales_invoice.sage_status = 'draft'
      AND sales_invoice.sage_invoice_id IS NULL
      AND sales_invoice.sage_posted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Exact invalid customer draft changed during correction';
    END IF;

    UPDATE public.customer_sales_release_lines release_line
    SET release_status = 'reversed',
        reversed_at = now(),
        reversed_by_staff_id = v_actor,
        reversal_reason = 'Automated migration correction: customer release reconstructed a refunded line outside immutable effective shipment membership.'
    WHERE release_line.sales_invoice_id = v_invoice_id
      AND release_line.release_status = 'active';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Exact invalid customer draft had no active durable membership to reverse';
    END IF;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
