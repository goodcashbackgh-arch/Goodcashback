BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Supplier Payment Funding Provenance Governing Addendum v1 — micro implementation 1.
-- Replace only the internals of the existing staff credit RPC.
-- Normal account credit is consumed from deterministic source lots.
-- The importer-credit ledger trigger remains the sole order_funding_events sync path.

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Missing public.orders';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Missing public.staff';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing public.importer_credit_ledger';
  END IF;
  IF to_regclass('public.order_funding_events') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_funding_events';
  END IF;
  IF to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_importer_available_account_credit_lots_v1(uuid)';
  END IF;
  IF to_regprocedure('public.order_funding_gap_gbp(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_funding_gap_gbp(uuid)';
  END IF;
  IF to_regprocedure('public.raise_escalation(text,text,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.raise_escalation(text,text,uuid,jsonb)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_apply_importer_credit_to_order(
  p_importer_id uuid,
  p_order_id uuid,
  p_amount_gbp numeric,
  p_staff_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_order record;
  v_available numeric(18,2) := 0;
  v_gap numeric(18,2) := 0;
  v_requested numeric(18,2) := 0;
  v_remaining_to_apply numeric(18,2) := 0;
  v_take numeric(18,2) := 0;
  v_total_applied numeric(18,2) := 0;
  v_lot record;
  v_debit_id uuid;
  v_first_debit_id uuid;
  v_debit_ids uuid[] := ARRAY[]::uuid[];
  v_requires_admin_review boolean := false;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff credit application requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can apply importer credit. Current role: %', v_staff.role_type;
  END IF;

  IF p_staff_id IS NULL OR p_staff_id IS DISTINCT FROM v_staff.id THEN
    RAISE EXCEPTION 'Staff identity mismatch: supplied staff % does not match authenticated staff %', p_staff_id, v_staff.id;
  END IF;

  v_requested := ROUND(COALESCE(p_amount_gbp, 0)::numeric, 2);
  IF v_requested <= 0 THEN
    RAISE EXCEPTION 'Credit application amount must be greater than zero. Received: %', v_requested;
  END IF;

  SELECT
    o.id,
    o.order_ref,
    o.importer_id,
    COALESCE(o.order_type, 'original') AS order_type,
    o.status,
    o.funded_at
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Target order % not found', p_order_id;
  END IF;

  IF v_order.importer_id IS DISTINCT FROM p_importer_id THEN
    RAISE EXCEPTION 'Importer % cannot apply credit to order % owned by importer %', p_importer_id, p_order_id, v_order.importer_id;
  END IF;

  IF v_order.order_type <> 'original' THEN
    RAISE EXCEPTION 'Credit cannot be applied to non-original order % with order_type %', p_order_id, v_order.order_type;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Credit cannot be applied to order % with status %', p_order_id, v_order.status;
  END IF;

  IF v_order.funded_at IS NOT NULL THEN
    RAISE EXCEPTION 'Order % is already platform-funded', p_order_id;
  END IF;

  -- Serialize all unlocked account-credit rows and existing application debits for
  -- the importer so concurrent staff/customer applications cannot double-spend.
  PERFORM 1
  FROM public.importer_credit_ledger c
  WHERE c.importer_id = p_importer_id
    AND c.lock_reason IS NULL
  ORDER BY c.created_at, c.id
  FOR UPDATE;

  v_gap := ROUND(COALESCE(public.order_funding_gap_gbp(p_order_id), 0)::numeric, 2);
  IF v_gap <= 0 THEN
    RAISE EXCEPTION 'Order % has no remaining funding gap', p_order_id;
  END IF;

  SELECT ROUND(COALESCE(SUM(l.available_amount_gbp), 0)::numeric, 2)
    INTO v_available
  FROM public.internal_importer_available_account_credit_lots_v1(p_importer_id) l;

  IF v_available <= 0 THEN
    RAISE EXCEPTION 'No available normal account credit for importer %', p_importer_id;
  END IF;

  v_remaining_to_apply := ROUND(LEAST(v_requested, v_available, v_gap)::numeric, 2);

  FOR v_lot IN
    SELECT *
    FROM public.internal_importer_available_account_credit_lots_v1(p_importer_id)
    ORDER BY priority, effective_at, created_at, credit_ledger_id
  LOOP
    EXIT WHEN v_remaining_to_apply <= 0;

    v_take := ROUND(LEAST(v_lot.available_amount_gbp, v_remaining_to_apply)::numeric, 2);
    IF v_take <= 0 THEN
      CONTINUE;
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
      p_importer_id,
      'applied_to_order',
      'importer_credit_ledger',
      v_lot.credit_ledger_id,
      p_order_id,
      NULL,
      'debit',
      v_take,
      v_take,
      'GBP',
      now(),
      'credit_application',
      'importer_credit_ledger',
      v_lot.credit_ledger_id,
      p_order_id,
      NULL,
      v_staff.id,
      'Staff-applied normal account credit to order from exact source lot.'
    )
    RETURNING id INTO v_debit_id;

    IF v_first_debit_id IS NULL THEN
      v_first_debit_id := v_debit_id;
    END IF;

    v_debit_ids := array_append(v_debit_ids, v_debit_id);
    v_total_applied := ROUND((v_total_applied + v_take)::numeric, 2);
    v_remaining_to_apply := ROUND((v_remaining_to_apply - v_take)::numeric, 2);
  END LOOP;

  IF v_total_applied <= 0 OR v_remaining_to_apply > 0.01 THEN
    RAISE EXCEPTION 'Source-lot credit application incomplete for order %. Requested capped amount %, applied %, remaining %',
      p_order_id, LEAST(v_requested, v_available, v_gap), v_total_applied, v_remaining_to_apply;
  END IF;

  -- Preserve the existing >£500 escalation rule without inventing an aggregate
  -- debit. The escalation attaches to the first exact source-lot debit and records
  -- the complete application set in its context.
  IF v_total_applied > 500 THEN
    PERFORM public.raise_escalation(
      'CREDIT_AMOUNT',
      'importer_credit',
      v_first_debit_id,
      jsonb_build_object(
        'amount_gbp', v_total_applied,
        'requested_amount_gbp', v_requested,
        'order_id', p_order_id,
        'order_ref', v_order.order_ref,
        'staff_id', v_staff.id,
        'credit_debit_ids', to_jsonb(v_debit_ids),
        'source_lot_count', cardinality(v_debit_ids)
      )
    );
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM unnest(v_debit_ids) AS debit_id
    WHERE public.entity_requires_admin_review('importer_credit', debit_id)
  ) INTO v_requires_admin_review;

  RETURN jsonb_build_object(
    'ok', true,
    'credit_debit_id', v_first_debit_id,
    'credit_debit_ids', to_jsonb(v_debit_ids),
    'source_lot_count', cardinality(v_debit_ids),
    'applied_amount_gbp', v_total_applied,
    'applied_gbp', v_total_applied,
    'available_credit_before_gbp', v_available,
    'remaining_available_gbp', ROUND(GREATEST(v_available - v_total_applied, 0)::numeric, 2),
    'gap_before_gbp', v_gap,
    'remaining_order_gap_gbp', ROUND(GREATEST(public.order_funding_gap_gbp(p_order_id), 0)::numeric, 2),
    'remaining_cash_due_gbp', ROUND(GREATEST(public.order_funding_gap_gbp(p_order_id), 0)::numeric, 2),
    'order_platform_funded', (SELECT o.funded_at IS NOT NULL FROM public.orders o WHERE o.id = p_order_id),
    'requires_admin_review_yn', v_requires_admin_review
  );
END;
$$;

COMMENT ON FUNCTION public.staff_apply_importer_credit_to_order(uuid, uuid, numeric, uuid) IS
'Staff-only source-lot normal account-credit application. Consumes internal_importer_available_account_credit_lots_v1 in deterministic order, creates one debit linked through both importer_credit_ledger source fields per exact credit lot, and relies exclusively on trg_sync_order_funding_event_from_importer_credit_ledger for funding-event synchronisation.';

REVOKE ALL ON FUNCTION public.staff_apply_importer_credit_to_order(uuid, uuid, numeric, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_apply_importer_credit_to_order(uuid, uuid, numeric, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
