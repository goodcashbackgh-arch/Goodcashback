BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Mini-build 4 integrity hardening.
-- This file corrects only review-cycle/hold provenance safeguards and restores
-- the exact pre-Mini-4 dynamic filter for preserved untimed legacy links.

DO $prerequisites$
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regclass('public.customer_hold_review_memberships') IS NULL
     OR to_regclass('public.customer_order_review_links') IS NULL
  THEN
    RAISE EXCEPTION 'Mini 4 integrity prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_review_cycle_membership_immutable_guard_v1()') IS NULL
     OR to_regprocedure('public.customer_hold_review_membership_guard_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'Mini 4 integrity prerequisite functions are missing.';
  END IF;
END
$prerequisites$;

ALTER TABLE public.customer_review_cycle_memberships
  ADD CONSTRAINT customer_review_cycle_membership_net_nonnegative_chk
  CHECK (goods_amount_gbp + delivery_share_gbp >= discount_share_gbp);

CREATE OR REPLACE FUNCTION public.customer_review_cycle_membership_immutable_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
$$;

DROP TRIGGER trg_customer_review_cycle_membership_immutable_v1
  ON public.customer_review_cycle_memberships;
CREATE TRIGGER trg_customer_review_cycle_membership_immutable_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.customer_review_cycle_memberships
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_cycle_membership_immutable_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_hold_review_membership_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hold public.customer_pre_shipment_hold_requests%ROWTYPE;
  v_membership public.customer_review_cycle_memberships%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'Customer hold review provenance is immutable and cannot be deleted.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT * INTO v_hold
    FROM public.customer_pre_shipment_hold_requests hold_row
    WHERE hold_row.id = NEW.hold_request_id;

    SELECT * INTO v_membership
    FROM public.customer_review_cycle_memberships membership
    WHERE membership.id = NEW.review_membership_id;

    IF v_hold.id IS NULL
       OR v_membership.id IS NULL
       OR v_hold.review_link_id IS DISTINCT FROM v_membership.review_link_id
       OR v_hold.order_id IS DISTINCT FROM v_membership.order_id
    THEN
      RAISE EXCEPTION
        'Customer hold provenance does not match its exact review cycle.';
    END IF;

    IF NOT (
      v_hold.requested_scope = 'order'
      OR (
        v_hold.requested_scope = 'tracking'
        AND v_hold.tracking_submission_id = v_membership.tracking_submission_id
      )
      OR (
        v_hold.requested_scope = 'line'
        AND v_hold.supplier_invoice_line_id = v_membership.supplier_invoice_line_id
        AND (
          v_hold.tracking_submission_id IS NULL
          OR v_hold.tracking_submission_id = v_membership.tracking_submission_id
        )
      )
    ) THEN
      RAISE EXCEPTION
        'Customer hold provenance is outside the requested hold scope.';
    END IF;

    IF NEW.affected_qty IS DISTINCT FROM v_membership.review_qty
       OR NEW.affected_goods_amount_gbp IS DISTINCT FROM v_membership.goods_amount_gbp
       OR NEW.affected_delivery_share_gbp IS DISTINCT FROM v_membership.delivery_share_gbp
       OR NEW.affected_discount_share_gbp IS DISTINCT FROM v_membership.discount_share_gbp
    THEN
      RAISE EXCEPTION
        'Customer hold provenance values must equal the immutable review membership.';
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.hold_request_id IS DISTINCT FROM OLD.hold_request_id
     OR NEW.review_membership_id IS DISTINCT FROM OLD.review_membership_id
     OR NEW.affected_qty IS DISTINCT FROM OLD.affected_qty
     OR NEW.affected_goods_amount_gbp IS DISTINCT FROM OLD.affected_goods_amount_gbp
     OR NEW.affected_delivery_share_gbp IS DISTINCT FROM OLD.affected_delivery_share_gbp
     OR NEW.affected_discount_share_gbp IS DISTINCT FROM OLD.affected_discount_share_gbp
     OR NEW.membership_fingerprint IS DISTINCT FROM OLD.membership_fingerprint
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'Customer hold review provenance is immutable.';
  END IF;

  IF OLD.membership_status = 'closed'
     AND NEW.membership_status IS DISTINCT FROM OLD.membership_status
  THEN
    RAISE EXCEPTION
      'Closed customer hold review provenance cannot be reopened.';
  END IF;

  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status THEN
    IF NEW.membership_status <> 'closed' THEN
      RAISE EXCEPTION
        'Customer hold review provenance may only transition to closed.';
    END IF;
    NEW.status_updated_at := COALESCE(NEW.status_updated_at, now());
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER trg_customer_hold_review_membership_guard_v1
  ON public.customer_hold_review_memberships;
CREATE TRIGGER trg_customer_hold_review_membership_guard_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.customer_hold_review_memberships
FOR EACH ROW
EXECUTE FUNCTION public.customer_hold_review_membership_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_review_link_fixed_deadline_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.expires_at IS NULL THEN
      RAISE EXCEPTION
        'New customer review links require a fixed deadline.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
    RAISE EXCEPTION
      'Customer review cycle deadline is immutable.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_review_link_fixed_deadline_guard_v1
BEFORE INSERT OR UPDATE OF expires_at
ON public.customer_order_review_links
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_link_fixed_deadline_guard_v1();

-- Timed cycles read immutable membership. Preserved untimed legacy links retain
-- the exact prior dynamic received-clean, 24-hour and not-yet-shipped filter.
CREATE OR REPLACE FUNCTION public.customer_review_ready_line_ids_v1(p_order_id uuid)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH timed_membership AS (
    SELECT DISTINCT
      membership.supplier_invoice_line_id,
      membership.tracking_submission_id
    FROM public.customer_review_cycle_memberships membership
    JOIN public.customer_order_review_links link_row
      ON link_row.id = membership.review_link_id
    WHERE membership.order_id = p_order_id
      AND membership.membership_status = 'active'
      AND link_row.is_active = true
      AND link_row.expires_at IS NOT NULL
      AND link_row.expires_at > now()
  ),
  legacy_link AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.customer_order_review_links link_row
      WHERE link_row.order_id = p_order_id
        AND link_row.is_active = true
        AND link_row.expires_at IS NULL
    ) AS enabled
  ),
  legacy_tracking_scope AS (
    SELECT
      tracking_row.id AS tracking_submission_id,
      tracking_row.order_id
    FROM public.order_tracking_submissions tracking_row
    JOIN LATERAL (
      SELECT receipt.receipt_status, receipt.recorded_at
      FROM public.shipper_package_receipts receipt
      WHERE receipt.tracking_submission_id = tracking_row.id
      ORDER BY receipt.created_at DESC, receipt.id DESC
      LIMIT 1
    ) latest_receipt ON true
    CROSS JOIN legacy_link
    WHERE legacy_link.enabled = true
      AND tracking_row.order_id = p_order_id
      AND tracking_row.superseded_at IS NULL
      AND latest_receipt.receipt_status = 'received_clean'
      AND now() >= latest_receipt.recorded_at
      AND now() < latest_receipt.recorded_at + interval '24 hours'
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages package_row
        WHERE package_row.tracking_submission_id = tracking_row.id
          AND package_row.active = true
      )
  ),
  legacy_dynamic AS (
    SELECT DISTINCT
      allocation.supplier_invoice_line_id,
      scope.tracking_submission_id
    FROM legacy_tracking_scope scope
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.order_id = scope.order_id
     AND allocation.tracking_submission_id = scope.tracking_submission_id
     AND allocation.supplier_invoice_line_id IS NOT NULL
     AND COALESCE(allocation.qty_allocated, 0) > 0
    JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = allocation.supplier_invoice_line_id
    JOIN public.supplier_invoices supplier_invoice
      ON supplier_invoice.id = supplier_line.supplier_invoice_id
     AND supplier_invoice.order_id = scope.order_id
    WHERE COALESCE(supplier_invoice.review_status, '') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  )
  SELECT * FROM timed_membership
  UNION
  SELECT * FROM legacy_dynamic;
$$;

REVOKE ALL ON FUNCTION public.customer_review_ready_line_ids_v1(uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_review_ready_line_ids_v1(uuid)
  TO anon, authenticated;

DO $proof$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_order_review_links'::regclass
      AND trigger_row.tgname =
        'trg_customer_review_link_fixed_deadline_guard_v1'
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'Fixed-deadline guard was not installed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_review_cycle_memberships'::regclass
      AND trigger_row.tgname =
        'trg_customer_review_cycle_membership_immutable_v1'
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'Review membership immutability guard is not enabled.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_hold_review_memberships'::regclass
      AND trigger_row.tgname =
        'trg_customer_hold_review_membership_guard_v1'
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'Hold membership immutability guard is not enabled.';
  END IF;
END
$proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
