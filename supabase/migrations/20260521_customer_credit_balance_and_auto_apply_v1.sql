BEGIN;

CREATE OR REPLACE FUNCTION public.customer_importer_credit_balance_v1()
RETURNS TABLE(importer_id uuid, available_credit_gbp numeric)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH current_importer AS (
    SELECT oi.importer_id
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id = op.id AND oi.revoked_at IS NULL
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
    ORDER BY oi.created_at DESC NULLS LAST, oi.id DESC
    LIMIT 1
  )
  SELECT
    ci.importer_id,
    ROUND(COALESCE(SUM(CASE WHEN icl.direction = 'credit' THEN ABS(icl.amount_gbp) ELSE -ABS(icl.amount_gbp) END),0)::numeric,2) AS available_credit_gbp
  FROM current_importer ci
  LEFT JOIN public.importer_credit_ledger icl
    ON icl.importer_id = ci.importer_id
   AND icl.lock_reason IS NULL
  GROUP BY ci.importer_id;
$$;

CREATE OR REPLACE FUNCTION public.customer_apply_available_credit_to_order_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator record;
  v_order record;
  v_available numeric := 0;
  v_existing_applied numeric := 0;
  v_cash_funded numeric := 0;
  v_gap numeric := 0;
  v_apply numeric := 0;
  v_credit_ledger_id uuid;
  v_funding_event_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT op.id AS operator_id, oi.importer_id
  INTO v_operator
  FROM public.operators op
  JOIN public.operator_importers oi ON oi.operator_id = op.id AND oi.revoked_at IS NULL
  WHERE op.auth_user_id = auth.uid()
    AND COALESCE(op.active, true) = true
  ORDER BY oi.created_at DESC NULLS LAST, oi.id DESC
  LIMIT 1;

  IF v_operator.operator_id IS NULL THEN
    RAISE EXCEPTION 'Active customer/operator assignment not found.';
  END IF;

  SELECT o.id, o.importer_id, o.operator_id, COALESCE(o.order_total_gbp_declared,0)::numeric AS order_total_gbp_declared, COALESCE(o.order_type,'original') AS order_type, o.status
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_order.importer_id IS DISTINCT FROM v_operator.importer_id THEN RAISE EXCEPTION 'Order/importer mismatch.'; END IF;
  IF v_order.operator_id IS DISTINCT FROM v_operator.operator_id THEN RAISE EXCEPTION 'Order/operator mismatch.'; END IF;
  IF v_order.order_type <> 'original' THEN RAISE EXCEPTION 'Credit can only auto-apply to original orders.'; END IF;
  IF v_order.status IN ('archived','cancelled') THEN RAISE EXCEPTION 'Cannot apply credit to order status %.', v_order.status; END IF;

  SELECT ROUND(COALESCE(SUM(CASE WHEN direction='credit' THEN ABS(amount_gbp) ELSE -ABS(amount_gbp) END),0)::numeric,2)
  INTO v_available
  FROM public.importer_credit_ledger
  WHERE importer_id = v_order.importer_id
    AND lock_reason IS NULL;

  SELECT ROUND(COALESCE(SUM(amount_gbp) FILTER (WHERE event_type = 'credit_applied'),0)::numeric,2),
         ROUND(COALESCE(SUM(amount_gbp) FILTER (WHERE event_type IN ('funding_contribution','manual_adjustment')),0)::numeric,2)
  INTO v_existing_applied, v_cash_funded
  FROM public.order_funding_events
  WHERE order_id = p_order_id;

  v_gap := ROUND(GREATEST(v_order.order_total_gbp_declared - COALESCE(v_existing_applied,0) - COALESCE(v_cash_funded,0),0)::numeric,2);
  v_apply := ROUND(LEAST(COALESCE(v_available,0), v_gap)::numeric,2);

  IF v_apply <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'applied_gbp', 0, 'available_credit_gbp', v_available, 'gap_gbp', v_gap);
  END IF;

  INSERT INTO public.importer_credit_ledger(
    importer_id, entry_type, source_table, source_id, linked_order_id, linked_dispute_id,
    direction, amount_gbp, amount_local_ccy, local_ccy, effective_at,
    source_type, source_entity_type, source_entity_id, applied_to_order_id,
    notes
  ) VALUES (
    v_order.importer_id, 'applied_to_order', 'orders', p_order_id, p_order_id, NULL,
    'debit', v_apply, v_apply, 'GBP', now(),
    'credit_application', 'order', p_order_id, p_order_id,
    'Auto-applied confirmed customer credit at order creation.'
  ) RETURNING id INTO v_credit_ledger_id;

  INSERT INTO public.order_funding_events(
    order_id, event_type, amount_gbp, source_ref, source_entity_type, source_entity_id, created_at, notes
  ) VALUES (
    p_order_id, 'credit_applied', v_apply, CONCAT('importer_credit_ledger:', v_credit_ledger_id::text), 'importer_credit_ledger', v_credit_ledger_id, now(), 'Auto-applied confirmed customer credit at order creation.'
  ) RETURNING id INTO v_funding_event_id;

  RETURN jsonb_build_object('ok', true, 'applied_gbp', v_apply, 'credit_ledger_id', v_credit_ledger_id, 'funding_event_id', v_funding_event_id);
END;
$$;

REVOKE ALL ON FUNCTION public.customer_importer_credit_balance_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_apply_available_credit_to_order_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_importer_credit_balance_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_apply_available_credit_to_order_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
