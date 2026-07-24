BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.order_settlement_resolution_actions') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_actions';
  END IF;
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1';
  END IF;
  IF to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing source-lot account-credit resolver';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_reverse_order_settlement_resolution_v1(
  p_action_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_action record;
  v_available_lot_gbp numeric := 0;
  v_reversal_ledger_id uuid;
  v_position record;
  v_reason text := BTRIM(COALESCE(p_reason, ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT s.id, s.role_type
  INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Supervisor/admin required.';
  END IF;

  IF char_length(v_reason) < 8 THEN
    RAISE EXCEPTION 'Reversal reason must contain at least eight characters.';
  END IF;

  SELECT a.*
  INTO v_action
  FROM public.order_settlement_resolution_actions a
  WHERE a.id = p_action_id
  FOR UPDATE;

  IF v_action.id IS NULL THEN
    RAISE EXCEPTION 'Settlement resolution action not found.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_settlement_resolution|' || v_action.order_id::text));

  IF v_action.status = 'reversed' THEN
    SELECT * INTO v_position
    FROM public.order_settlement_resolution_position_v1 p
    WHERE p.order_id = v_action.order_id;

    RETURN jsonb_build_object(
      'ok', true,
      'already_reversed', true,
      'action_id', v_action.id,
      'remaining_unresolved_gbp', v_position.remaining_unresolved_gbp,
      'resolution_status', v_position.resolution_status
    );
  END IF;

  IF v_action.customer_credit_gbp > 0 THEN
    IF v_action.credit_ledger_id IS NULL THEN
      RAISE EXCEPTION 'Linked customer-credit ledger row is missing; manual review required.';
    END IF;

    SELECT COALESCE(MAX(l.available_amount_gbp), 0)
    INTO v_available_lot_gbp
    FROM public.internal_importer_available_account_credit_lots_v1(v_action.importer_id) l
    WHERE l.credit_ledger_id = v_action.credit_ledger_id;

    IF v_available_lot_gbp + 0.005 < v_action.customer_credit_gbp THEN
      RAISE EXCEPTION 'Cannot reverse settlement credit because part or all of the credit has already been used. Available source lot %, required %.', v_available_lot_gbp, v_action.customer_credit_gbp;
    END IF;

    INSERT INTO public.importer_credit_ledger (
      importer_id,
      entry_type,
      source_table,
      source_id,
      linked_order_id,
      linked_dispute_id,
      direction,
      amount_gbp,
      amount_local_ccy,
      local_ccy,
      effective_at,
      source_type,
      source_entity_type,
      source_entity_id,
      applied_to_order_id,
      lock_reason,
      created_by_staff_id,
      notes
    ) VALUES (
      v_action.importer_id,
      'manual_debit',
      'importer_credit_ledger',
      v_action.credit_ledger_id,
      v_action.order_id,
      NULL,
      'debit',
      v_action.customer_credit_gbp,
      v_action.customer_credit_gbp,
      'GBP',
      now(),
      'settlement_credit',
      'order',
      v_action.order_id,
      NULL,
      NULL,
      v_staff.id,
      concat('Settlement resolution credit reversed. Reason: ', v_reason)
    )
    RETURNING id INTO v_reversal_ledger_id;
  END IF;

  UPDATE public.order_settlement_resolution_actions
  SET status = 'reversed',
      reversed_by_staff_id = v_staff.id,
      reversed_at = now(),
      reversal_reason = v_reason
  WHERE id = v_action.id;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_action.order_id;

  RETURN jsonb_build_object(
    'ok', true,
    'already_reversed', false,
    'action_id', v_action.id,
    'credit_reversal_ledger_id', v_reversal_ledger_id,
    'reversed_customer_credit_gbp', v_action.customer_credit_gbp,
    'reversed_fx_card_difference_gbp', v_action.fx_card_difference_gbp,
    'remaining_unresolved_gbp', v_position.remaining_unresolved_gbp,
    'over_resolved_gbp', v_position.over_resolved_gbp,
    'resolution_status', v_position.resolution_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_reverse_order_settlement_resolution_v1(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_reverse_order_settlement_resolution_v1(uuid,text) TO authenticated;

COMMENT ON FUNCTION public.staff_reverse_order_settlement_resolution_v1(uuid,text) IS
'Reverses one incremental settlement classification without deleting history. Credit reversal is allowed only while the linked source credit lot remains unused; FX reversal removes only the active order-level settlement classification.';

NOTIFY pgrst, 'reload schema';
COMMIT;
