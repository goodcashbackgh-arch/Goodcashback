BEGIN;

DO $$
DECLARE
  v_auth_uid uuid;
  v_order_id uuid;
  v_initial record;
  v_after_credit record;
  v_after_fx record;
  v_after_fx_reversal record;
  v_audience record;
  v_credit_key uuid := gen_random_uuid();
  v_fx_key uuid := gen_random_uuid();
  v_credit_result jsonb;
  v_duplicate_result jsonb;
  v_fx_result jsonb;
  v_reverse_result jsonb;
  v_fx_action_id uuid;
BEGIN
  IF to_regprocedure('public.staff_resolve_order_settlement_v1(uuid,numeric,numeric,text,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_resolve_order_settlement_v1';
  END IF;
  IF to_regprocedure('public.staff_reverse_order_settlement_resolution_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_reverse_order_settlement_resolution_v1';
  END IF;

  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin','supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.created_at
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No active admin/supervisor auth user available for regression.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);

  SELECT p.order_id
  INTO v_order_id
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_ref = 'ORD-1784498556959'
    AND p.remaining_unresolved_gbp >= 2.00
    AND p.credit_action_allowed_yn
    AND p.fx_action_allowed_yn
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE NOTICE 'Write regression skipped: target order is no longer eligible with at least GBP 2.00 unresolved.';
    RETURN;
  END IF;

  SELECT * INTO v_initial
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  v_credit_result := public.staff_resolve_order_settlement_v1(
    v_order_id,
    1.00,
    0.00,
    'Regression credit classification',
    'Transactional test; rolled back.',
    v_credit_key
  );

  v_duplicate_result := public.staff_resolve_order_settlement_v1(
    v_order_id,
    1.00,
    0.00,
    'Regression credit classification',
    'Transactional test; rolled back.',
    v_credit_key
  );

  IF COALESCE((v_duplicate_result->>'already_applied')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Idempotent duplicate action was not recognised: %', v_duplicate_result;
  END IF;

  IF (
    SELECT COUNT(*)
    FROM public.order_settlement_resolution_actions a
    WHERE a.action_key = v_credit_key
  ) <> 1 THEN
    RAISE EXCEPTION 'Duplicate action key created more than one action row.';
  END IF;

  SELECT * INTO v_after_credit
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ABS(v_after_credit.confirmed_customer_credit_gbp - (v_initial.confirmed_customer_credit_gbp + 1.00)) > 0.01
     OR ABS(v_after_credit.remaining_unresolved_gbp - (v_initial.remaining_unresolved_gbp - 1.00)) > 0.01 THEN
    RAISE EXCEPTION 'Incremental credit result mismatch. Initial %, after %', to_jsonb(v_initial), to_jsonb(v_after_credit);
  END IF;

  v_fx_result := public.staff_resolve_order_settlement_v1(
    v_order_id,
    0.00,
    1.00,
    'Regression FX classification',
    'Transactional test; rolled back.',
    v_fx_key
  );
  v_fx_action_id := (v_fx_result->>'action_id')::uuid;

  SELECT * INTO v_after_fx
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ABS(v_after_fx.settlement_fx_card_difference_gbp - (v_initial.settlement_fx_card_difference_gbp + 1.00)) > 0.01
     OR ABS(v_after_fx.remaining_unresolved_gbp - (v_initial.remaining_unresolved_gbp - 2.00)) > 0.01 THEN
    RAISE EXCEPTION 'Incremental FX result mismatch. Initial %, after %', to_jsonb(v_initial), to_jsonb(v_after_fx);
  END IF;

  SELECT * INTO v_audience
  FROM public.order_settlement_audience_v1(v_order_id);

  IF ABS(v_audience.credit_added_to_account_gbp - v_after_fx.confirmed_customer_credit_gbp) > 0.01
     OR ABS(v_audience.other_settlement_adjustment_gbp - (v_after_fx.inbound_fx_receipt_residual_gbp + v_after_fx.settlement_fx_card_difference_gbp)) > 0.01
     OR ABS(v_audience.potential_additional_credit_gbp - v_after_fx.remaining_unresolved_gbp) > 0.01 THEN
    RAISE EXCEPTION 'Audience projection does not match canonical position.';
  END IF;

  v_reverse_result := public.staff_reverse_order_settlement_resolution_v1(
    v_fx_action_id,
    'Regression reversal of FX action'
  );

  SELECT * INTO v_after_fx_reversal
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ABS(v_after_fx_reversal.settlement_fx_card_difference_gbp - v_initial.settlement_fx_card_difference_gbp) > 0.01
     OR ABS(v_after_fx_reversal.remaining_unresolved_gbp - (v_initial.remaining_unresolved_gbp - 1.00)) > 0.01 THEN
    RAISE EXCEPTION 'FX reversal result mismatch. Initial %, after %', to_jsonb(v_initial), to_jsonb(v_after_fx_reversal);
  END IF;

  RAISE NOTICE 'PASS: incremental credit, duplicate idempotency, FX classification, audience projection and FX reversal.';
END $$;

ROLLBACK;
