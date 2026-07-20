BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.assert_current_operator_can_reconcile_order(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.assert_current_operator_can_reconcile_order(uuid)';
  END IF;

  IF to_regprocedure('public.order_has_progressed_subset(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_has_progressed_subset(uuid)';
  END IF;

  IF to_regprocedure('public.order_has_open_child_exceptions(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_has_open_child_exceptions(uuid)';
  END IF;

  IF to_regclass('public.order_reconciliation_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_reconciliation_vw';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
END $$;

-- Keep the current lifecycle direction. Once an order is partially progressed,
-- later reconciliation updates must not send it backwards to reconciling. It
-- remains partially_progressed until the existing explicit supervisor/admin
-- handoff advances it to ready_for_shipment.
CREATE OR REPLACE FUNCTION public.recompute_order_status(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
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

  SELECT public.order_has_open_child_exceptions(p_order_id)
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

    -- Preserve the existing explicit lifecycle boundary. Reconciliation may add
    -- further progressed lines, but it cannot reverse partially_progressed back
    -- to reconciling. The current supervisor/admin handoff remains unchanged.
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
$$;

COMMENT ON FUNCTION public.recompute_order_status(uuid) IS
'Best-effort parent-order status recompute. Preserves partially_progressed during further line progression and leaves the existing explicit supervisor/admin ready_for_shipment handoff unchanged.';

CREATE OR REPLACE FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(
  p_order_id uuid,
  p_line_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_requested_count integer := 0;
  v_valid_count integer := 0;
  v_updated_count integer := 0;
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required';
  END IF;

  IF p_line_ids IS NULL OR cardinality(p_line_ids) = 0 THEN
    RAISE EXCEPTION 'Select at least one invoice line to progress';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_line_ids) AS requested(line_id)
    WHERE requested.line_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Selected invoice lines cannot contain a blank line id';
  END IF;

  PERFORM public.assert_current_operator_can_reconcile_order(p_order_id);

  SELECT COUNT(*)::integer
    INTO v_requested_count
  FROM (
    SELECT DISTINCT requested.line_id
    FROM unnest(p_line_ids) AS requested(line_id)
  ) selected;

  SELECT COUNT(*)::integer
    INTO v_valid_count
  FROM (
    SELECT DISTINCT requested.line_id
    FROM unnest(p_line_ids) AS requested(line_id)
  ) selected
  JOIN public.supplier_invoice_lines sil ON sil.id = selected.line_id
  JOIN public.supplier_invoices si
    ON si.id = sil.supplier_invoice_id
   AND si.order_id = p_order_id;

  IF v_valid_count <> v_requested_count THEN
    RAISE EXCEPTION 'One or more selected supplier invoice lines do not belong to this order';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT requested.line_id
      FROM unnest(p_line_ids) AS requested(line_id)
    ) selected
    JOIN public.supplier_invoice_lines sil ON sil.id = selected.line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = p_order_id
    WHERE sil.qty IS NULL
       OR sil.qty < 0
       OR sil.amount_inc_vat_gbp IS NULL
       OR sil.amount_inc_vat_gbp < 0
  ) THEN
    RAISE EXCEPTION 'Selected lines require non-negative quantity and amount before progression';
  END IF;

  WITH selected AS (
    SELECT DISTINCT requested.line_id
    FROM unnest(p_line_ids) AS requested(line_id)
  )
  UPDATE public.supplier_invoice_lines sil
  SET qty_confirmed = sil.qty,
      amount_confirmed = sil.amount_inc_vat_gbp,
      eligible_for_invoice_yn = 'Y',
      updated_at = now()
  FROM selected,
       public.supplier_invoices si
  WHERE sil.id = selected.line_id
    AND si.id = sil.supplier_invoice_id
    AND si.order_id = p_order_id;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  IF v_updated_count <> v_requested_count THEN
    RAISE EXCEPTION 'Bulk progression did not update every selected supplier invoice line';
  END IF;

  RETURN v_updated_count;
END;
$$;

COMMENT ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) IS
'Atomically validates and progresses selected operator-owned supplier invoice lines in one set-based UPDATE. Existing lifecycle, exception, funding, shipping, accounting, VAT, Sage and evidence controls remain unchanged.';

REVOKE ALL ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
