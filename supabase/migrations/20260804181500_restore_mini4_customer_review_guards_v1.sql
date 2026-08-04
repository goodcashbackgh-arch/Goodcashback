BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Emergency corrective migration.
-- Restores the two Mini Build 4 guard bodies exactly to their pre-Phase-1A logic.
-- The new nullable timing columns remain present but dormant and are not read or written by these guards.

DO $preflight$
DECLARE
  v_component_md5 text;
  v_immutable_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure))
  INTO v_component_md5;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure))
  INTO v_immutable_md5;

  IF v_component_md5 IS DISTINCT FROM 'ea1bc4032e31b97afaef23dc910d122e' THEN
    RAISE EXCEPTION 'Unexpected current component guard fingerprint: %', v_component_md5;
  END IF;

  IF v_immutable_md5 IS DISTINCT FROM 'd28328694c5becdb45fb0dca20355d5a' THEN
    RAISE EXCEPTION 'Unexpected current immutable guard fingerprint: %', v_immutable_md5;
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.customer_review_cycle_component_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_allocation public.order_tracking_line_allocations%ROWTYPE;
  v_existing_review_qty numeric;
  v_ratio numeric;
  v_expected_goods numeric;
  v_expected_delivery numeric;
  v_expected_discount numeric;
BEGIN
  SELECT allocation.*
  INTO v_allocation
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id = NEW.tracking_line_allocation_id;

  IF v_allocation.id IS NULL
     OR COALESCE(v_allocation.qty_allocated, 0) <= 0
  THEN
    RAISE EXCEPTION
      'Exact tracking allocation is missing for customer review membership.';
  END IF;

  v_ratio := NEW.review_qty / v_allocation.qty_allocated;
  v_expected_goods := ROUND(
    COALESCE(v_allocation.base_value_gbp, 0)::numeric * v_ratio,
    2
  );
  v_expected_delivery := ROUND(
    COALESCE(v_allocation.retailer_delivery_share_gbp, 0)::numeric * v_ratio,
    2
  );
  v_expected_discount := ROUND(
    COALESCE(v_allocation.discount_share_gbp, 0)::numeric * v_ratio,
    2
  );

  IF ABS(NEW.goods_amount_gbp - v_expected_goods) > 0.01
     OR ABS(NEW.delivery_share_gbp - v_expected_delivery) > 0.01
     OR ABS(NEW.discount_share_gbp - v_expected_discount) > 0.01
  THEN
    RAISE EXCEPTION
      'Customer review membership value components do not match the exact allocation and quantity.';
  END IF;

  SELECT COALESCE(SUM(membership.review_qty), 0)
  INTO v_existing_review_qty
  FROM public.customer_review_cycle_memberships membership
  WHERE membership.tracking_line_allocation_id =
        NEW.tracking_line_allocation_id;

  NEW.membership_fingerprint := md5(concat_ws(
    '|',
    'customer_review_membership_v2',
    NEW.review_link_id,
    NEW.order_id,
    NEW.supplier_invoice_id,
    NEW.supplier_invoice_line_id,
    NEW.tracking_submission_id,
    NEW.tracking_line_allocation_id,
    ROUND(v_existing_review_qty, 3),
    ROUND(NEW.review_qty, 3),
    NEW.goods_amount_gbp,
    NEW.delivery_share_gbp,
    NEW.discount_share_gbp,
    NEW.receipt_recorded_at
  ));

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.customer_review_cycle_membership_immutable_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_link_order_id uuid;
  v_link_expires_at timestamptz;
  v_allocation record;
  v_source_supplier_invoice_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'Customer review source membership is immutable and cannot be deleted.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT link_row.order_id, link_row.expires_at
    INTO v_link_order_id, v_link_expires_at
    FROM public.customer_order_review_links link_row
    WHERE link_row.id = NEW.review_link_id;

    IF v_link_order_id IS NULL
       OR v_link_order_id IS DISTINCT FROM NEW.order_id
       OR v_link_expires_at IS NULL
    THEN
      RAISE EXCEPTION
        'Customer review membership must belong to the exact timed review link and order.';
    END IF;

    IF NEW.receipt_recorded_at >= v_link_expires_at THEN
      RAISE EXCEPTION
        'Customer review membership receipt must precede the fixed cycle deadline.';
    END IF;

    SELECT
      allocation.id,
      allocation.order_id,
      allocation.supplier_invoice_line_id,
      allocation.tracking_submission_id,
      allocation.qty_allocated
    INTO v_allocation
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.id = NEW.tracking_line_allocation_id;

    IF v_allocation.id IS NULL
       OR v_allocation.order_id IS DISTINCT FROM NEW.order_id
       OR v_allocation.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
       OR v_allocation.tracking_submission_id IS DISTINCT FROM NEW.tracking_submission_id
       OR NEW.review_qty > COALESCE(v_allocation.qty_allocated, 0)
    THEN
      RAISE EXCEPTION
        'Customer review membership does not match its exact tracking allocation.';
    END IF;

    SELECT supplier_line.supplier_invoice_id
    INTO v_source_supplier_invoice_id
    FROM public.supplier_invoice_lines supplier_line
    JOIN public.supplier_invoices supplier_invoice
      ON supplier_invoice.id = supplier_line.supplier_invoice_id
     AND supplier_invoice.order_id = NEW.order_id
    WHERE supplier_line.id = NEW.supplier_invoice_line_id;

    IF v_source_supplier_invoice_id IS NULL
       OR v_source_supplier_invoice_id IS DISTINCT FROM NEW.supplier_invoice_id
    THEN
      RAISE EXCEPTION
        'Customer review membership supplier invoice identity is inconsistent.';
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.review_link_id IS DISTINCT FROM OLD.review_link_id
     OR NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.supplier_invoice_id IS DISTINCT FROM OLD.supplier_invoice_id
     OR NEW.supplier_invoice_line_id IS DISTINCT FROM OLD.supplier_invoice_line_id
     OR NEW.tracking_submission_id IS DISTINCT FROM OLD.tracking_submission_id
     OR NEW.tracking_line_allocation_id IS DISTINCT FROM OLD.tracking_line_allocation_id
     OR NEW.review_qty IS DISTINCT FROM OLD.review_qty
     OR NEW.goods_amount_gbp IS DISTINCT FROM OLD.goods_amount_gbp
     OR NEW.delivery_share_gbp IS DISTINCT FROM OLD.delivery_share_gbp
     OR NEW.discount_share_gbp IS DISTINCT FROM OLD.discount_share_gbp
     OR NEW.receipt_recorded_at IS DISTINCT FROM OLD.receipt_recorded_at
     OR NEW.membership_fingerprint IS DISTINCT FROM OLD.membership_fingerprint
     OR NEW.legacy_backfill_yn IS DISTINCT FROM OLD.legacy_backfill_yn
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.created_by_staff_id IS DISTINCT FROM OLD.created_by_staff_id
  THEN
    RAISE EXCEPTION
      'Customer review source membership is immutable; later source must use a later cycle.';
  END IF;

  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status THEN
    IF NOT (
      (OLD.membership_status = 'active'
        AND NEW.membership_status IN ('expired','released','closed'))
      OR (OLD.membership_status = 'expired' AND NEW.membership_status = 'closed')
      OR (OLD.membership_status = 'released' AND NEW.membership_status = 'closed')
    ) THEN
      RAISE EXCEPTION
        'Invalid customer review membership status transition: % -> %',
        OLD.membership_status,
        NEW.membership_status;
    END IF;
    NEW.status_updated_at := COALESCE(NEW.status_updated_at, now());
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.customer_review_cycle_component_guard_v1()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_review_cycle_component_guard_v1()
TO service_role;

REVOKE ALL ON FUNCTION public.customer_review_cycle_membership_immutable_guard_v1()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_review_cycle_membership_immutable_guard_v1()
TO service_role;

DO $verify$
DECLARE
  v_component_md5 text;
  v_immutable_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure))
  INTO v_component_md5;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure))
  INTO v_immutable_md5;

  IF v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
  THEN
    RAISE EXCEPTION
      'Mini 4 guard restoration failed: component %, immutable %.',
      v_component_md5,
      v_immutable_md5;
  END IF;
END
$verify$;

COMMIT;
