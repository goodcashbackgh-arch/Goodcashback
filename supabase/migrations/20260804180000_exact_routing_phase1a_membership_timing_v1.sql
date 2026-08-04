BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governed by HYBRID_PHYSICAL_RECEIPT_EXACT_ROUTING_AND_SHIPMENT_CONTINUATION_CORRECTION_ADDENDUM_v1
-- Phase 1A only: additive per-membership review timing and timing-aware guards.
-- No candidate, materialiser, shipment, UI or supervisor RPC change is made here.

DO $preflight$
DECLARE
  v_component_md5 text;
  v_immutable_md5 text;
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regclass('public.customer_order_review_links') IS NULL
  THEN
    RAISE EXCEPTION 'Phase 1A prerequisites are missing.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'customer_review_cycle_memberships'
      AND column_name IN ('review_eligible_at','review_expires_at')
  ) THEN
    RAISE EXCEPTION 'Phase 1A timing columns already exist; inspect target instead of guessing.';
  END IF;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure))
  INTO v_component_md5;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure))
  INTO v_immutable_md5;

  IF v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a' THEN
    RAISE EXCEPTION 'Component guard fingerprint mismatch: %', v_component_md5;
  END IF;

  IF v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90' THEN
    RAISE EXCEPTION 'Membership immutability guard fingerprint mismatch: %', v_immutable_md5;
  END IF;
END
$preflight$;

ALTER TABLE public.customer_review_cycle_memberships
  ADD COLUMN review_eligible_at timestamptz,
  ADD COLUMN review_expires_at timestamptz;

UPDATE public.customer_review_cycle_memberships membership
SET review_eligible_at = membership.receipt_recorded_at,
    review_expires_at = link_row.expires_at
FROM public.customer_order_review_links link_row
WHERE link_row.id = membership.review_link_id
  AND link_row.expires_at IS NOT NULL;

ALTER TABLE public.customer_review_cycle_memberships
  ADD CONSTRAINT customer_review_cycle_membership_timing_pair_v1
  CHECK (
    (review_eligible_at IS NULL AND review_expires_at IS NULL)
    OR (
      review_eligible_at IS NOT NULL
      AND review_expires_at IS NOT NULL
      AND review_expires_at > review_eligible_at
    )
  );

CREATE INDEX customer_review_cycle_membership_active_expiry_v1
  ON public.customer_review_cycle_memberships (
    order_id,
    review_expires_at,
    tracking_line_allocation_id
  )
  WHERE membership_status = 'active'
    AND review_expires_at IS NOT NULL;

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

  IF (NEW.review_eligible_at IS NULL) <> (NEW.review_expires_at IS NULL)
     OR (
       NEW.review_eligible_at IS NOT NULL
       AND NEW.review_expires_at <= NEW.review_eligible_at
     )
  THEN
    RAISE EXCEPTION
      'Customer review membership timing must be wholly null or a positive exact review period.';
  END IF;

  SELECT COALESCE(SUM(membership.review_qty), 0)
  INTO v_existing_review_qty
  FROM public.customer_review_cycle_memberships membership
  WHERE membership.tracking_line_allocation_id =
        NEW.tracking_line_allocation_id;

  NEW.membership_fingerprint := md5(concat_ws(
    '|',
    'customer_review_membership_v3',
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
    NEW.receipt_recorded_at,
    NEW.review_eligible_at,
    NEW.review_expires_at
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

    IF NEW.review_eligible_at IS NULL THEN
      IF NEW.receipt_recorded_at >= v_link_expires_at THEN
        RAISE EXCEPTION
          'Legacy customer review membership receipt must precede the fixed cycle deadline.';
      END IF;
    ELSE
      IF NEW.review_expires_at IS NULL
         OR NEW.review_expires_at <= NEW.review_eligible_at
      THEN
        RAISE EXCEPTION
          'Timed customer review membership requires a positive exact review period.';
      END IF;
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
     OR NEW.review_eligible_at IS DISTINCT FROM OLD.review_eligible_at
     OR NEW.review_expires_at IS DISTINCT FROM OLD.review_expires_at
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
  v_bad_pair_count integer;
  v_unbackfilled_timed_count integer;
BEGIN
  SELECT COUNT(*)::integer
  INTO v_bad_pair_count
  FROM public.customer_review_cycle_memberships
  WHERE (review_eligible_at IS NULL) <> (review_expires_at IS NULL)
     OR (
       review_eligible_at IS NOT NULL
       AND review_expires_at <= review_eligible_at
     );

  SELECT COUNT(*)::integer
  INTO v_unbackfilled_timed_count
  FROM public.customer_review_cycle_memberships membership
  JOIN public.customer_order_review_links link_row
    ON link_row.id = membership.review_link_id
  WHERE link_row.expires_at IS NOT NULL
    AND (
      membership.review_eligible_at IS DISTINCT FROM membership.receipt_recorded_at
      OR membership.review_expires_at IS DISTINCT FROM link_row.expires_at
    );

  IF v_bad_pair_count <> 0 OR v_unbackfilled_timed_count <> 0 THEN
    RAISE EXCEPTION
      'Phase 1A verification failed: bad timing pairs %, unbackfilled timed memberships %.',
      v_bad_pair_count,
      v_unbackfilled_timed_count;
  END IF;
END
$verify$;

COMMIT;
