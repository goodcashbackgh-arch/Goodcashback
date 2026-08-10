BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final boundary alignment for the new price-increase RPC only. Do not treat an
-- initial funding VAT tax point as terminal: the business case deliberately starts
-- from an already-funded order. Later VAT/accounting release and completion are
-- hard stops.

CREATE OR REPLACE FUNCTION public.staff_approve_order_supplier_price_increase_v1(
  p_order_id uuid,
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
  v_position record;
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

  PERFORM pg_advisory_xact_lock(hashtext('order_bundle_limit:' || p_order_id::text));

  PERFORM 1
  FROM public.supplier_invoices si
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required','duplicate_blocked','superseded'
    )
  ORDER BY si.id
  FOR UPDATE;

  PERFORM 1
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required','duplicate_blocked','superseded'
    )
  ORDER BY fs.id
  FOR UPDATE OF fs;

  SELECT *
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;
  IF COALESCE(v_order.order_type, 'original') <> 'original' THEN
    RAISE EXCEPTION 'Same-order supplier price increase is only available for original orders.';
  END IF;
  IF v_order.content_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Order content is locked (content_locked_at set). Price increase not applied.';
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
    RAISE EXCEPTION 'Price increase v1 requires zero order markup because live funding authorities use different markup thresholds.';
  END IF;

  -- The established DVA funding wrappers lock the order before inserting their
  -- funding event. Holding the order row here serialises a concurrent top-up.
  PERFORM 1
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id
  ORDER BY ofe.created_at, ofe.id
  FOR UPDATE;

  PERFORM 1
  FROM public.importer_credit_ledger icl
  WHERE icl.importer_id = v_order.importer_id
    AND (
      icl.linked_order_id = p_order_id
      OR icl.applied_to_order_id = p_order_id
      OR (
        icl.source_type = 'overfunding'
        AND icl.source_entity_type = 'order'
        AND icl.source_entity_id = p_order_id
      )
    )
  ORDER BY icl.id
  FOR UPDATE;

  PERFORM 1
  FROM public.order_pending_funding_surplus ps
  WHERE ps.order_id = p_order_id
    AND ps.status IN ('pending_evidence','credit_confirmed')
  ORDER BY ps.created_at, ps.id
  FOR UPDATE;

  SELECT p.*
  INTO v_position
  FROM public.order_supplier_price_position_v1 p
  WHERE p.order_id = p_order_id;

  IF v_position.order_id IS NULL OR COALESCE(v_position.active_invoice_count, 0) = 0 THEN
    RAISE EXCEPTION 'No live supplier invoice bundle exists for this order.';
  END IF;
  IF v_position.review_anchor_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Price increase v1 requires a live pending supplier invoice review anchor.';
  END IF;
  IF COALESCE(v_position.missing_accepted_total_count, 0) <> 0 THEN
    RAISE EXCEPTION 'Price increase blocked: % live supplier invoice(s) have no accepted gross total.', v_position.missing_accepted_total_count;
  END IF;
  IF COALESCE(v_position.unverified_invoice_count, 0) <> 0 THEN
    RAISE EXCEPTION 'Price increase blocked: % live supplier invoice(s) still need ordinary document/adjustment verification.', v_position.unverified_invoice_count;
  END IF;

  v_old_total := ROUND(COALESCE(v_order.order_total_gbp_declared, 0)::numeric, 2);
  v_new_total := ROUND(COALESCE(v_position.accepted_supplier_bundle_gbp, 0)::numeric, 2);
  v_increase := ROUND((v_new_total - v_old_total)::numeric, 2);

  IF v_new_total <= v_old_total + 0.01 OR v_increase <= 0.01 THEN
    RAISE EXCEPTION 'No live supplier price increase is currently required. Order GBP %, live bundle GBP %.', v_old_total, v_new_total;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'funding_reversed'
  ) THEN
    RAISE EXCEPTION 'Price increase v1 is blocked for orders with funding-reversal history. No funding authority was changed.';
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
    RAISE EXCEPTION 'Price increase blocked: this order has an active pending/confirmed funding-surplus position.';
  END IF;

  v_event_total := ROUND(COALESCE(public.order_funding_total_gbp(p_order_id), 0)::numeric, 2);
  v_event_gap_before := ROUND(GREATEST(v_old_total - v_event_total, 0)::numeric, 2);
  v_expected_threshold_before := v_event_total >= v_old_total - 0.01;

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
    RAISE EXCEPTION
      'Price increase blocked: target order funding authorities disagree (event total %, view total %, event gap %, view gap %, funded_at %, threshold_met %).',
      v_event_total,
      v_funding_before.funded_total_gbp,
      v_event_gap_before,
      v_funding_before.gap_remaining_gbp,
      (v_order.funded_at IS NOT NULL),
      v_funding_before.threshold_met_yn;
  END IF;

  IF v_event_total > v_old_total + 0.01 THEN
    RAISE EXCEPTION 'Price increase blocked: funding already exceeds the current order value and must be resolved through existing overfunding controls first.';
  END IF;

  SELECT COUNT(*)
  INTO v_event_count_before
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id;

  v_new_quote_total_ghs := v_order.quote_total_ghs;
  IF v_old_total > 0
     AND COALESCE(v_order.quote_total_ghs, 0) > 0 THEN
    v_new_quote_total_ghs := ROUND(
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

  v_expected_gap_after := ROUND(GREATEST(v_new_total - v_event_total, 0)::numeric, 2);
  v_expected_threshold_after := v_event_total >= v_new_total - 0.01;

  SELECT f.*
  INTO v_funding_after
  FROM public.order_funding_position_vw f
  WHERE f.order_id = p_order_id;

  SELECT COUNT(*)
  INTO v_event_count_after
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id;

  IF v_event_count_after <> v_event_count_before THEN
    RAISE EXCEPTION 'Price amendment unexpectedly created or removed an order funding event. Transaction rolled back.';
  END IF;

  IF ABS(COALESCE(v_funding_after.funded_total_gbp, 0) - v_event_total) > 0.01
     OR ABS(COALESCE(v_funding_after.gap_remaining_gbp, 0) - v_expected_gap_after) > 0.01
     OR v_funding_after.threshold_met_yn IS DISTINCT FROM v_expected_threshold_after
     OR v_funding_after.already_funded_yn IS DISTINCT FROM v_expected_threshold_after THEN
    RAISE EXCEPTION
      'Price amendment postcondition failed (expected gap %, view gap %, threshold expected %, threshold actual %, funded actual %). Transaction rolled back.',
      v_expected_gap_after,
      v_funding_after.gap_remaining_gbp,
      v_expected_threshold_after,
      v_funding_after.threshold_met_yn,
      v_funding_after.already_funded_yn;
  END IF;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff.id,
    resolved_at = now(),
    resolution_notes = COALESCE(
      v_notes,
      format('Order price increased from GBP %s to GBP %s after live accepted supplier-bundle verification.', v_old_total, v_new_total)
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

COMMENT ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, text) IS
'Admin/supervisor-only same-order supplier price increase for original orders. New total is server-derived from the verified live accepted supplier bundle; no client amount is accepted. Existing header review, supplier approval, funding, payment and reconciliation authorities remain unchanged.';

REVOKE ALL ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, text) TO authenticated;

COMMIT;
