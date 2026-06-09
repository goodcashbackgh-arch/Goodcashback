BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Replaces final-balance allocation RPC so it reads settlement v2, which includes
-- previously confirmed final_balance_payment allocations. This is required for
-- multi-payment final-balance settlement.

CREATE OR REPLACE FUNCTION public.staff_allocate_statement_line_to_final_balance_payment_v1(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_classify_fx_excess boolean DEFAULT true,
  p_notes text DEFAULT null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_line record;
  v_order record;
  v_settlement record;
  v_existing_id uuid;
  v_confirmed_before numeric(12,2);
  v_confirmed_after numeric(12,2);
  v_line_remaining_before numeric(12,2);
  v_line_remaining_after numeric(12,2);
  v_balance_due_before numeric(12,2);
  v_balance_due_after numeric(12,2);
  v_to_balance numeric(12,2);
  v_fx_excess numeric(12,2);
  v_fx_allocated numeric(12,2) := 0;
  v_final_alloc_id uuid;
  v_fx_alloc_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: final-balance allocation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can allocate final-balance payments. Current role: %', v_staff.role_type;
  END IF;

  SELECT dsl.id, dsl.direction, dsl.amount_gbp_equivalent, dsl.fx_rate_applied,
         dsl.card_markup_pct_applied, ds.importer_id
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'DVA/card statement line not found: %', p_dva_statement_line_id;
  END IF;

  IF v_line.direction <> 'in' THEN
    RAISE EXCEPTION 'Final-balance payment allocation requires an IN statement line. Line % has direction %', p_dva_statement_line_id, v_line.direction;
  END IF;

  IF COALESCE(v_line.amount_gbp_equivalent, 0) <= 0 THEN
    RAISE EXCEPTION 'Statement line % has invalid GBP equivalent %', p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, o.status
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Importer mismatch: statement importer % cannot allocate to order % importer %',
      v_line.importer_id, p_order_id, v_order.importer_id;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot allocate to final balance on order % with status %', p_order_id, v_order.status;
  END IF;

  SELECT a.id INTO v_existing_id
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.order_id = p_order_id
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status <> 'reversed'
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RAISE EXCEPTION 'Active final-balance allocation already exists for statement line % and order %: %',
      p_dva_statement_line_id, p_order_id, v_existing_id;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
  INTO v_confirmed_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  v_line_remaining_before := ROUND((v_line.amount_gbp_equivalent - v_confirmed_before)::numeric, 2);

  IF v_line_remaining_before <= 0 THEN
    RAISE EXCEPTION 'Statement line % has no remaining GBP to allocate', p_dva_statement_line_id;
  END IF;

  SELECT * INTO v_settlement
  FROM public.internal_order_final_sale_settlement_v2(p_order_id)
  LIMIT 1;

  IF v_settlement.order_id IS NULL THEN
    RAISE EXCEPTION 'Final-sale settlement row not found for order %', p_order_id;
  END IF;

  IF COALESCE(v_settlement.final_sale_value_exists, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Cannot allocate final-balance payment before posted final sale value exists for order %', p_order_id;
  END IF;

  v_balance_due_before := ROUND(COALESCE(v_settlement.final_balance_due_gbp, 0)::numeric, 2);

  IF v_balance_due_before <= 0 THEN
    RAISE EXCEPTION 'Order % has no final balance due. Current state: %', p_order_id, v_settlement.final_settlement_state;
  END IF;

  v_to_balance := LEAST(v_line_remaining_before, v_balance_due_before);
  v_fx_excess := GREATEST(v_line_remaining_before - v_balance_due_before, 0);
  v_balance_due_after := ROUND(GREATEST(v_balance_due_before - v_to_balance, 0)::numeric, 2);

  INSERT INTO public.dva_statement_line_allocations (
    dva_statement_line_id, allocation_type, supplier_invoice_id, dispute_id, order_id,
    allocated_gbp_amount, allocation_status, fx_rate_applied, card_markup_pct_applied,
    notes, created_by_staff_id, created_at, confirmed_by_staff_id, confirmed_at
  ) VALUES (
    p_dva_statement_line_id, 'final_balance_payment', null, null, p_order_id,
    v_to_balance, 'confirmed', v_line.fx_rate_applied, v_line.card_markup_pct_applied,
    p_notes, v_staff.id, now(), v_staff.id, now()
  ) RETURNING id INTO v_final_alloc_id;

  IF p_classify_fx_excess IS TRUE AND v_fx_excess > 0 THEN
    INSERT INTO public.dva_statement_line_allocations (
      dva_statement_line_id, allocation_type, supplier_invoice_id, dispute_id, order_id,
      allocated_gbp_amount, allocation_status, fx_rate_applied, card_markup_pct_applied,
      fx_or_card_diff_gbp, notes, created_by_staff_id, created_at, confirmed_by_staff_id, confirmed_at
    ) VALUES (
      p_dva_statement_line_id, 'fx_card_difference', null, null, p_order_id,
      v_fx_excess, 'confirmed', v_line.fx_rate_applied, v_line.card_markup_pct_applied,
      v_fx_excess,
      COALESCE(p_notes || E'\n', '') || 'Residual classified only after final balance reached zero.',
      v_staff.id, now(), v_staff.id, now()
    ) RETURNING id INTO v_fx_alloc_id;
    v_fx_allocated := v_fx_excess;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
  INTO v_confirmed_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  v_line_remaining_after := ROUND((v_line.amount_gbp_equivalent - v_confirmed_after)::numeric, 2);

  RETURN jsonb_build_object(
    'ok', true,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'final_balance_allocation_id', v_final_alloc_id,
    'fx_allocation_id', v_fx_alloc_id,
    'statement_gbp_amount', ROUND(v_line.amount_gbp_equivalent::numeric, 2),
    'statement_remaining_before_gbp', v_line_remaining_before,
    'statement_remaining_after_gbp', v_line_remaining_after,
    'confirmed_allocated_before_gbp', v_confirmed_before,
    'confirmed_allocated_after_gbp', v_confirmed_after,
    'final_balance_due_before_gbp', v_balance_due_before,
    'amount_to_final_balance_gbp', v_to_balance,
    'final_balance_due_after_gbp', v_balance_due_after,
    'fx_excess_gbp', v_fx_excess,
    'fx_excess_classified_gbp', v_fx_allocated,
    'balanced_yn', ABS(v_line_remaining_after) < 0.01,
    'needs_residual_classification_yn', ABS(v_line_remaining_after) >= 0.01
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid, uuid, boolean, text) IS
'Staff/supervisor RPC to allocate one IN DVA/card statement line to an order final-balance payment target. Uses settlement v2 so prior final-balance payments reduce remaining balance. Does not use accepted-estimate funding reconciliation, create importer credit, or post to Sage.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid, uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid, uuid, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
