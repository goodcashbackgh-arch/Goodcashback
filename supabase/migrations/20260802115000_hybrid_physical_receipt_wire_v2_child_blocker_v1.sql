BEGIN;

DO $preflight$
BEGIN
  IF to_regprocedure('public.recompute_order_status(uuid)') IS NULL THEN
    RAISE EXCEPTION 'recompute_order_status(uuid) is missing.';
  END IF;

  IF to_regprocedure('public.order_has_open_child_exceptions_v2(uuid)') IS NULL THEN
    RAISE EXCEPTION 'order_has_open_child_exceptions_v2(uuid) is missing.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.recompute_order_status(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_order public.orders%ROWTYPE;
  v_has_tracking boolean := false;
  v_has_invoice boolean := false;
  v_has_progressed boolean := false;
  v_has_open_children boolean := false;
  v_whole_order_cleared boolean := false;
  v_has_booking boolean := false;
  v_has_dispatch boolean := false;
  v_has_delivery boolean := false;
  v_new_status text;
BEGIN
  SELECT *
    INTO v_order
  FROM public.orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_order.status IN ('archived', 'cancelled', 'completed', 'awaiting_financial_closure') THEN
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.order_tracking_submissions ots
    WHERE ots.order_id = p_order_id
      AND ots.superseded_at IS NULL
  ) INTO v_has_tracking;

  SELECT EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.order_id = p_order_id
  ) INTO v_has_invoice;

  SELECT COALESCE(public.order_has_progressed_subset(p_order_id), false)
    INTO v_has_progressed;

  SELECT public.order_has_open_child_exceptions_v2(p_order_id)
    INTO v_has_open_children;

  SELECT COALESCE(orv.whole_order_cleared_yn, false)
    INTO v_whole_order_cleared
  FROM public.order_reconciliation_vw orv
  WHERE orv.order_id = p_order_id;

  SELECT EXISTS (
    SELECT 1
    FROM public.shipping_quote_orders sqo
    JOIN public.shipping_quotes sq ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = p_order_id
      AND sq.status IN ('booked','hub_received','dispatched','in_transit','delivered_ghana','closed')
  ) INTO v_has_booking;

  SELECT EXISTS (
    SELECT 1
    FROM public.shipping_quote_orders sqo
    JOIN public.shipping_quotes sq ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = p_order_id
      AND sq.status IN ('dispatched','in_transit','delivered_ghana','closed')
  ) INTO v_has_dispatch;

  SELECT EXISTS (
    SELECT 1
    FROM public.shipping_quote_orders sqo
    JOIN public.shipping_quotes sq ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = p_order_id
      AND sq.status IN ('delivered_ghana','closed')
  ) INTO v_has_delivery;

  v_new_status := CASE
    WHEN v_order.status = 'discrepancy_open' THEN 'discrepancy_open'
    WHEN v_has_delivery THEN 'awaiting_importer_receipt'
    WHEN v_has_dispatch THEN 'shipment_dispatched'
    WHEN v_has_booking THEN 'shipment_booked'
    WHEN v_order.status = 'ready_for_shipment' THEN 'ready_for_shipment'
    WHEN v_order.status = 'partially_progressed' AND v_has_progressed THEN 'partially_progressed'
    WHEN v_has_progressed AND (v_has_open_children OR NOT v_whole_order_cleared) THEN 'partially_progressed'
    WHEN v_has_progressed AND v_whole_order_cleared THEN 'reconciling'
    WHEN v_has_invoice THEN 'reconciling'
    WHEN v_has_tracking OR v_has_invoice THEN 'evidence_collecting'
    ELSE v_order.status
  END;

  IF v_new_status IS DISTINCT FROM v_order.status THEN
    UPDATE public.orders
    SET status = v_new_status
    WHERE id = p_order_id;
  END IF;
END;
$function$;

DO $postflight$
BEGIN
  IF pg_get_functiondef('public.recompute_order_status(uuid)'::regprocedure)
       NOT ILIKE '%order_has_open_child_exceptions_v2%'
  THEN
    RAISE EXCEPTION 'recompute_order_status(uuid) was not wired to order_has_open_child_exceptions_v2(uuid).';
  END IF;
END
$postflight$;

COMMIT;
