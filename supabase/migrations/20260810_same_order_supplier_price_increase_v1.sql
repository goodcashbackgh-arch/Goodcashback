BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governed by:
-- docs/governing-pack/architecture/SAME_ORDER_SUPPLIER_PRICE_INCREASE_ADDENDUM_v1.md
--
-- Narrow scope only:
-- 1) keep the existing order_bundle_limit_breach open while the existing
--    financial-summary bundle still breaches the order value;
-- 2) prevent the existing supplier-approval transaction from committing while
--    that same live breach remains;
-- 3) close only the proven financial-summary UPDATE breach hole;
-- 4) add one supervisor/admin same-order price-increase RPC deriving the new
--    order value server-side from the existing bundle arithmetic.

DO $preflight$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_financial_summary') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.order_funding_events') IS NULL
     OR to_regclass('public.order_funding_position_vw') IS NULL
     OR to_regclass('public.importer_credit_ledger') IS NULL
     OR to_regclass('public.order_pending_funding_surplus') IS NULL
     OR to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Same-order supplier price-increase prerequisite relation/view is missing.';
  END IF;

  IF to_regprocedure('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)') IS NULL
     OR to_regprocedure('public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)') IS NULL
     OR to_regprocedure('public.flag_order_bundle_limit_after_summary_v1()') IS NULL
     OR to_regprocedure('public.enforce_order_locks()') IS NULL
     OR to_regprocedure('public.order_funding_total_gbp(uuid)') IS NULL
     OR to_regprocedure('public.order_funding_gap_gbp(uuid)') IS NULL
     OR to_regprocedure('public.recompute_order_platform_funded(uuid)') IS NULL
     OR to_regprocedure('public.sync_order_overfunding_credit(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Expected established supplier/funding/order authority is missing.';
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------
-- 1. Preserve the existing bundle breach, and hard-stop approval if the
--    canonical approval transaction attempts to resolve it while still live.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_order_bundle_limit_breach_resolution_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_order_total numeric(12,2);
  v_active_total numeric(12,2);
  v_invoice_status text;
  v_blocked_from_sage boolean;
BEGIN
  IF OLD.flag_type IS DISTINCT FROM 'order_bundle_limit_breach'
     OR OLD.status NOT IN ('open','under_review')
     OR NEW.status IS DISTINCT FROM 'resolved' THEN
    RETURN NEW;
  END IF;

  v_order_id := OLD.order_id;
  IF v_order_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Shared with the established bundle INSERT trigger and the UPDATE companion
  -- below. This serialises Save-vs-summary-update decisions so a live breach
  -- cannot be lost between concurrent transactions.
  PERFORM pg_advisory_xact_lock(hashtext('order_bundle_limit:' || v_order_id::text));

  SELECT round(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2)
  INTO v_order_total
  FROM public.orders o
  WHERE o.id = v_order_id;

  IF v_order_total IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2)
  INTO v_active_total
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = v_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    );

  IF v_active_total > v_order_total + 0.01 THEN
    SELECT si.review_status::text, COALESCE(si.blocked_from_sage_yn, true)
    INTO v_invoice_status, v_blocked_from_sage
    FROM public.supplier_invoices si
    WHERE si.id = OLD.supplier_invoice_id;

    -- Save correction leaves the invoice pending/blocked, so it is allowed and
    -- only this flag stays open. The canonical supplier-approval RPC changes the
    -- invoice to approved/current and unblocks Sage before resolving flags. In
    -- that context raise, rolling the entire approval transaction back without
    -- modifying the approval RPC itself.
    IF v_invoice_status IN ('approved_current','ref_corrected_approved')
       OR v_blocked_from_sage IS FALSE THEN
      RAISE EXCEPTION
        'Cannot approve supplier invoice while active supplier invoices exceed the accepted order value. Approve the order price increase first.';
    END IF;

    NEW.status := OLD.status;
    NEW.resolved_by_staff_id := OLD.resolved_by_staff_id;
    NEW.resolved_at := OLD.resolved_at;
    NEW.resolution_notes := OLD.resolution_notes;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_order_bundle_limit_breach_resolution_v1
  ON public.supplier_invoice_review_flags;
CREATE TRIGGER trg_protect_order_bundle_limit_breach_resolution_v1
BEFORE UPDATE OF status, resolved_by_staff_id, resolved_at, resolution_notes
ON public.supplier_invoice_review_flags
FOR EACH ROW
EXECUTE FUNCTION public.protect_order_bundle_limit_breach_resolution_v1();

REVOKE ALL ON FUNCTION public.protect_order_bundle_limit_breach_resolution_v1()
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Existing operator-upload INSERT trigger remains untouched. Cover only the
--    established later UPDATE of invoice_total_gbp on the unique summary row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.flag_order_bundle_limit_after_summary_update_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_order_type text;
  v_order_total numeric(12,2);
  v_active_total numeric(12,2);
  v_breach numeric(12,2);
  v_invoice_ref text;
  v_invoice_review_status text;
  v_raised_by_operator_id uuid;
BEGIN
  IF NEW.invoice_total_gbp IS NOT DISTINCT FROM OLD.invoice_total_gbp THEN
    RETURN NEW;
  END IF;

  SELECT
    si.order_id,
    si.invoice_ref,
    si.review_status::text,
    o.order_type::text,
    round(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2)
  INTO
    v_order_id,
    v_invoice_ref,
    v_invoice_review_status,
    v_order_type,
    v_order_total
  FROM public.supplier_invoices si
  JOIN public.orders o ON o.id = si.order_id
  WHERE si.id = NEW.supplier_invoice_id;

  IF v_order_id IS NULL
     OR v_order_type IS DISTINCT FROM 'original'
     OR v_order_total <= 0
     OR COALESCE(v_invoice_review_status, 'pending_review') IN (
       'rejected_resubmit_required','duplicate_blocked','superseded'
     ) THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_bundle_limit:' || v_order_id::text));

  SELECT round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2)
  INTO v_active_total
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = v_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    );

  v_breach := round((v_active_total - v_order_total)::numeric, 2);

  IF v_breach > 0.01
     AND NOT EXISTS (
       SELECT 1
       FROM public.supplier_invoice_review_flags f
       WHERE f.supplier_invoice_id = NEW.supplier_invoice_id
         AND f.order_id = v_order_id
         AND f.flag_type = 'order_bundle_limit_breach'
         AND f.status IN ('open','under_review')
     ) THEN

    -- Normal current workflow created this unique summary row during operator
    -- upload, so the later supervisor upsert retains the real operator id. Use
    -- existing provenance only; never attribute staff as the operator raiser.
    v_raised_by_operator_id := COALESCE(NEW.entered_by_operator_id, OLD.entered_by_operator_id);

    IF v_raised_by_operator_id IS NULL THEN
      SELECT f.raised_by_operator_id
      INTO v_raised_by_operator_id
      FROM public.supplier_invoice_review_flags f
      WHERE f.supplier_invoice_id = NEW.supplier_invoice_id
        AND f.order_id = v_order_id
        AND f.raised_by_operator_id IS NOT NULL
      ORDER BY
        (f.flag_type = 'order_bundle_limit_breach') DESC,
        f.created_at DESC,
        f.id DESC
      LIMIT 1;
    END IF;

    IF v_raised_by_operator_id IS NULL THEN
      RAISE EXCEPTION
        'Supplier invoice total update would create an order bundle limit breach, but genuine operator provenance is missing. Update rolled back.';
    END IF;

    INSERT INTO public.supplier_invoice_review_flags (
      order_id,
      supplier_invoice_id,
      flag_type,
      message,
      status,
      raised_by_operator_id
    ) VALUES (
      v_order_id,
      NEW.supplier_invoice_id,
      'order_bundle_limit_breach',
      format(
        'Updating %s takes active gross supplier invoices to GBP %s against the accepted estimate of GBP %s. The order exceeds the accepted estimate by GBP %s and requires supervisor review.',
        COALESCE(v_invoice_ref, NEW.supplier_invoice_id::text),
        to_char(v_active_total, 'FM999999990.00'),
        to_char(v_order_total, 'FM999999990.00'),
        to_char(v_breach, 'FM999999990.00')
      ),
      'open',
      v_raised_by_operator_id
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_flag_order_bundle_limit_after_summary_update_v1
  ON public.supplier_invoice_financial_summary;
CREATE TRIGGER trg_flag_order_bundle_limit_after_summary_update_v1
AFTER UPDATE OF invoice_total_gbp
ON public.supplier_invoice_financial_summary
FOR EACH ROW
EXECUTE FUNCTION public.flag_order_bundle_limit_after_summary_update_v1();

REVOKE ALL ON FUNCTION public.flag_order_bundle_limit_after_summary_update_v1()
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Dedicated same-order amendment. No client monetary parameter exists.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.staff_approve_order_supplier_price_increase_v1(
  p_order_id uuid,
  p_supplier_invoice_id uuid,
  p_review_notes text DEFAULT NULL
)
RETURNS TABLE(
  order_id uuid,
  old_order_value_gbp numeric,
  new_order_value_gbp numeric,
  increase_gbp numeric,
  funding_total_gbp numeric,
  funding_gap_gbp numeric,
  funded_at timestamptz,
  quote_total_ghs numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_order public.orders%ROWTYPE;
  v_funding_before record;
  v_funding_after record;
  v_old_total numeric(12,2);
  v_new_total numeric(12,2);
  v_increase numeric(12,2);
  v_event_total numeric(12,2);
  v_event_gap_before numeric(12,2);
  v_expected_gap_after numeric(12,2);
  v_new_quote_total_ghs numeric;
  v_event_count_before bigint;
  v_event_count_after bigint;
  v_expected_threshold_before boolean;
  v_expected_threshold_after boolean;
  v_notes text := NULLIF(btrim(COALESCE(p_review_notes, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT s.id, s.role_type::text
  INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can approve an order price increase.';
  END IF;

  IF p_order_id IS NULL OR p_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Order and supplier invoice are required.';
  END IF;

  -- Serialize the existing supplier bundle deterministically before deriving a
  -- new order value. This does not lock funding rows; if funding changes during
  -- this transaction the before/after postconditions fail and the amendment is
  -- safely retried rather than risking a DVA lock-order conflict.
  PERFORM 1
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = p_order_id
  ORDER BY fs.id
  FOR UPDATE OF fs;

  PERFORM 1
  FROM public.supplier_invoices si
  WHERE si.order_id = p_order_id
  ORDER BY si.id
  FOR UPDATE OF si;

  PERFORM pg_advisory_xact_lock(hashtext('order_bundle_limit:' || p_order_id::text));

  SELECT *
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;
  IF v_order.order_type IS DISTINCT FROM 'original' THEN
    RAISE EXCEPTION 'Same-order supplier price increase is only available for original orders.';
  END IF;
  IF v_order.content_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Order content is locked. Price increase not applied.';
  END IF;
  IF COALESCE(v_order.status::text, '') IN ('archived','cancelled','completed')
     OR v_order.completed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot increase the price of a completed or terminal order.';
  END IF;
  IF v_order.accounting_release_ready_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot increase the order price after accounting release is ready.';
  END IF;
  IF v_order.vat_release_approved_at IS NOT NULL
     OR v_order.vat_return_period IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot increase the order price after VAT release/reporting has been approved.';
  END IF;
  IF ABS(COALESCE(v_order.markup_applied_gbp, 0)) > 0.005 THEN
    RAISE EXCEPTION 'Price increase v1 requires zero order markup.';
  END IF;

  PERFORM 1
  FROM public.supplier_invoice_review_flags f
  WHERE f.order_id = p_order_id
    AND f.supplier_invoice_id = p_supplier_invoice_id
    AND f.flag_type = 'order_bundle_limit_breach'
    AND f.status IN ('open','under_review')
  FOR UPDATE OF f;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No open order bundle limit breach exists for this supplier invoice.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.id = p_supplier_invoice_id
      AND si.order_id = p_order_id
      AND COALESCE(si.review_status, 'pending_review') NOT IN (
        'rejected_resubmit_required','duplicate_blocked','superseded'
      )
  ) THEN
    RAISE EXCEPTION 'The breach supplier invoice is not an active invoice on this order.';
  END IF;

  SELECT round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2)
  INTO v_new_total
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    );

  v_old_total := round(COALESCE(v_order.order_total_gbp_declared, 0)::numeric, 2);
  v_increase := round((v_new_total - v_old_total)::numeric, 2);

  IF v_new_total <= v_old_total + 0.01 OR v_increase <= 0.01 THEN
    RAISE EXCEPTION 'No active supplier bundle price increase is currently required.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'funding_reversed'
  ) THEN
    RAISE EXCEPTION 'Price increase v1 is blocked for orders with funding-reversal history.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.importer_credit_ledger icl
    WHERE icl.source_type = 'overfunding'
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id = p_order_id
  ) THEN
    RAISE EXCEPTION 'Price increase blocked: existing order-sourced overfunding credit must be resolved separately.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_pending_funding_surplus ps
    WHERE ps.order_id = p_order_id
      AND ps.status IN ('pending_evidence','credit_confirmed')
  ) THEN
    RAISE EXCEPTION 'Price increase blocked: this order has an active funding-surplus position.';
  END IF;

  v_event_total := round(COALESCE(public.order_funding_total_gbp(p_order_id), 0)::numeric, 2);
  v_event_gap_before := round(GREATEST(v_old_total - v_event_total, 0)::numeric, 2);
  v_expected_threshold_before := v_event_total >= v_old_total - 0.01;

  IF v_event_total > v_old_total + 0.01 THEN
    RAISE EXCEPTION 'Price increase blocked: funding already exceeds the current order value.';
  END IF;

  SELECT f.*
  INTO v_funding_before
  FROM public.order_funding_position_vw f
  WHERE f.order_id = p_order_id;

  IF v_funding_before.order_id IS NULL THEN
    RAISE EXCEPTION 'Price increase blocked: live funding position is missing.';
  END IF;

  IF ABS(COALESCE(v_funding_before.funded_total_gbp, 0) - v_event_total) > 0.01
     OR ABS(COALESCE(v_funding_before.gap_remaining_gbp, 0) - v_event_gap_before) > 0.01
     OR v_funding_before.threshold_met_yn IS DISTINCT FROM v_expected_threshold_before
     OR v_funding_before.already_funded_yn IS DISTINCT FROM (v_order.funded_at IS NOT NULL)
     OR (v_order.funded_at IS NOT NULL) IS DISTINCT FROM v_expected_threshold_before THEN
    RAISE EXCEPTION 'Price increase blocked: target order funding authorities disagree.';
  END IF;

  SELECT count(*)
  INTO v_event_count_before
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id;

  v_new_quote_total_ghs := v_order.quote_total_ghs;
  IF v_old_total > 0 AND COALESCE(v_order.quote_total_ghs, 0) > 0 THEN
    v_new_quote_total_ghs := round(
      (v_order.quote_total_ghs / v_old_total) * v_new_total,
      2
    );
  END IF;

  UPDATE public.orders o
  SET
    order_total_gbp_declared = v_new_total,
    quote_total_ghs = v_new_quote_total_ghs,
    updated_at = now()
  WHERE o.id = p_order_id;

  PERFORM public.recompute_order_platform_funded(p_order_id);
  PERFORM public.sync_order_overfunding_credit(p_order_id);

  v_expected_gap_after := round(GREATEST(v_new_total - v_event_total, 0)::numeric, 2);
  v_expected_threshold_after := v_event_total >= v_new_total - 0.01;

  SELECT f.*
  INTO v_funding_after
  FROM public.order_funding_position_vw f
  WHERE f.order_id = p_order_id;

  SELECT count(*)
  INTO v_event_count_after
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id;

  IF v_event_count_after <> v_event_count_before THEN
    RAISE EXCEPTION 'Funding changed during price approval. Price amendment rolled back; retry.';
  END IF;

  IF ABS(COALESCE(v_funding_after.funded_total_gbp, 0) - v_event_total) > 0.01
     OR ABS(COALESCE(v_funding_after.gap_remaining_gbp, 0) - v_expected_gap_after) > 0.01
     OR v_funding_after.threshold_met_yn IS DISTINCT FROM v_expected_threshold_after
     OR v_funding_after.already_funded_yn IS DISTINCT FROM v_expected_threshold_after THEN
    RAISE EXCEPTION 'Price amendment funding postcondition failed. Transaction rolled back.';
  END IF;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff.id,
    resolved_at = now(),
    resolution_notes = COALESCE(
      v_notes,
      format('Order price increased from GBP %s to GBP %s after supervisor approval.', v_old_total, v_new_total)
    ),
    updated_at = now()
  WHERE f.order_id = p_order_id
    AND f.flag_type = 'order_bundle_limit_breach'
    AND f.status IN ('open','under_review');

  RETURN QUERY
  SELECT
    p_order_id,
    v_old_total::numeric,
    v_new_total::numeric,
    v_increase::numeric,
    v_event_total::numeric,
    v_expected_gap_after::numeric,
    (SELECT o.funded_at FROM public.orders o WHERE o.id = p_order_id),
    v_new_quote_total_ghs::numeric;
END;
$$;

COMMENT ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, uuid, text) IS
'Admin/supervisor-only same-order supplier price increase for original orders with a genuine open order_bundle_limit_breach. New total is derived server-side from the existing active supplier financial-summary bundle; no client amount is accepted.';

REVOKE ALL ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, uuid, text)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, uuid, text)
TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
