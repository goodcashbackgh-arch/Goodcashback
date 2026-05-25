BEGIN;

-- Customer/local-currency IN surplus treatment.
-- Additive wrapper only: keeps the proven staff_reconcile_dva_line_to_order path,
-- but prevents normal quoted customer markup from becoming importer credit.
--
-- Behaviour:
--   DVA/customer IN <= order funding gap: use existing funding RPC unchanged.
--   DVA/customer IN  > order funding gap: fund only the gap and create a confirmed
--   fx_card_difference allocation for the surplus. The existing overfunding-credit
--   trigger is therefore not invoked.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.staff_reconcile_dva_line_to_order wrapper';
  END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_line_allocations';
  END IF;
  IF to_regprocedure('public.order_funding_gap_gbp(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_funding_gap_gbp(uuid)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reconciled_gbp_amount numeric,
  p_match_suggestion_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
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
  v_requested_amount numeric(12,2);
  v_gap_before numeric(12,2);
  v_funding_amount numeric(12,2);
  v_fx_gain_amount numeric(12,2);
  v_result jsonb;
  v_allocation_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found.';
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can reconcile DVA funding lines. Current role: %', v_staff.role_type;
  END IF;

  SELECT dsl.id, dsl.direction, ds.importer_id
    INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'DVA statement line not found: %', p_dva_statement_line_id;
  END IF;

  IF v_line.direction <> 'in' THEN
    RAISE EXCEPTION 'Customer FX gain wrapper only supports inbound customer/importer money. Line direction is %', v_line.direction;
  END IF;

  SELECT o.id, o.importer_id, COALESCE(o.order_type, 'original') AS order_type, o.status, o.order_ref
    INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Importer mismatch: DVA line importer % cannot fund order % importer %', v_line.importer_id, p_order_id, v_order.importer_id;
  END IF;

  IF v_order.order_type <> 'original' THEN
    RAISE EXCEPTION 'DVA funding can only target original orders. Order % has order_type %', p_order_id, v_order.order_type;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'DVA funding cannot target order % with status %', p_order_id, v_order.status;
  END IF;

  v_requested_amount := ROUND(COALESCE(p_reconciled_gbp_amount, 0)::numeric, 2);
  IF v_requested_amount <= 0 THEN
    RAISE EXCEPTION 'Reconciled GBP amount must be greater than zero. Received: %', v_requested_amount;
  END IF;

  v_gap_before := ROUND(COALESCE(public.order_funding_gap_gbp(p_order_id), 0)::numeric, 2);

  IF v_requested_amount <= v_gap_before THEN
    RETURN public.staff_reconcile_dva_line_to_order(
      p_dva_statement_line_id,
      p_order_id,
      v_requested_amount,
      false,
      p_match_suggestion_id,
      p_notes
    );
  END IF;

  IF v_gap_before <= 0 THEN
    RAISE EXCEPTION 'Order % has no funding gap. Customer FX gain cannot be created without funding an order gap.', p_order_id;
  END IF;

  v_funding_amount := v_gap_before;
  v_fx_gain_amount := ROUND(v_requested_amount - v_gap_before, 2);

  v_result := public.staff_reconcile_dva_line_to_order(
    p_dva_statement_line_id,
    p_order_id,
    v_funding_amount,
    false,
    p_match_suggestion_id,
    concat_ws(E'\n', p_notes, 'Customer/local-currency surplus routed to FX gain, not importer credit.')
  );

  INSERT INTO public.dva_statement_line_allocations (
    dva_statement_line_id,
    allocation_type,
    supplier_invoice_id,
    dispute_id,
    order_id,
    allocated_gbp_amount,
    allocation_status,
    fx_or_card_diff_gbp,
    notes,
    created_by_staff_id,
    confirmed_by_staff_id,
    confirmed_at
  )
  VALUES (
    p_dva_statement_line_id,
    'fx_card_difference',
    NULL,
    NULL,
    p_order_id,
    v_fx_gain_amount,
    'confirmed',
    v_fx_gain_amount,
    concat('Customer IN surplus over order funding gap recognised as FX gain. Requested receipt £', v_requested_amount::text, '; funded order gap £', v_funding_amount::text, '; FX gain £', v_fx_gain_amount::text, '.'),
    v_staff.id,
    v_staff.id,
    now()
  )
  RETURNING id INTO v_allocation_id;

  RETURN v_result || jsonb_build_object(
    'customer_fx_gain_routed_yn', true,
    'funding_amount_gbp', v_funding_amount,
    'fx_gain_gbp', v_fx_gain_amount,
    'fx_gain_allocation_id', v_allocation_id,
    'credit_created_yn', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid, uuid, numeric, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid, uuid, numeric, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid, uuid, numeric, uuid, text) IS
'Customer/importer IN funding wrapper: caps order funding at the funding gap and routes any inbound surplus to confirmed fx_card_difference allocation, avoiding importer credit creation for normal quoted local-currency markup.';

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Smoke checks after applying as supervisor/admin:
-- select public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1('<dva_line>'::uuid, '<order>'::uuid, 110.00, null, 'smoke');
-- select * from public.dva_statement_line_allocations where allocation_type='fx_card_difference' order by created_at desc limit 5;
