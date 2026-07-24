BEGIN;

DO $$
DECLARE
  v_auth_uid uuid;
  v_order_id uuid;
  v_importer_id uuid;
  v_initial record;
  v_position record;
  v_result jsonb;
  v_key uuid;
  v_credit_added numeric := 0;
  v_fx_added numeric := 0;
  v_credit_rows_before integer;
  v_credit_rows_after integer;
  v_action_rows_before integer;
  v_action_rows_after integer;
  v_remaining numeric;
  v_final_credit numeric;
  v_final_fx numeric;
  v_rejected boolean := false;
  v_audience record;
BEGIN
  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin','supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.created_at
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No active admin/supervisor auth user available for settlement scenario regression.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);

  SELECT p.order_id, p.importer_id
  INTO v_order_id, v_importer_id
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_ref = 'ORD-1784498556959'
    AND p.remaining_unresolved_gbp >= 10.00
    AND p.credit_action_allowed_yn
    AND p.fx_action_allowed_yn
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE NOTICE 'Scenario matrix skipped: target order is not currently eligible with at least GBP 10.00 unresolved.';
    RETURN;
  END IF;

  SELECT * INTO v_initial
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  SELECT COUNT(*) INTO v_credit_rows_before
  FROM public.importer_credit_ledger c
  WHERE c.source_entity_type = 'order'
    AND c.source_entity_id = v_order_id
    AND c.source_type = 'settlement_credit';

  SELECT COUNT(*) INTO v_action_rows_before
  FROM public.order_settlement_resolution_actions a
  WHERE a.order_id = v_order_id;

  -- Credit then credit.
  PERFORM public.staff_resolve_order_settlement_v1(
    v_order_id, 0.50, 0.00,
    'Regression credit then credit one',
    'Transactional matrix; rolled back.',
    gen_random_uuid()
  );
  v_credit_added := v_credit_added + 0.50;

  PERFORM public.staff_resolve_order_settlement_v1(
    v_order_id, 0.50, 0.00,
    'Regression credit then credit two',
    'Transactional matrix; rolled back.',
    gen_random_uuid()
  );
  v_credit_added := v_credit_added + 0.50;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ABS(v_position.confirmed_customer_credit_gbp - (v_initial.confirmed_customer_credit_gbp + v_credit_added)) > 0.01 THEN
    RAISE EXCEPTION 'Credit-then-credit total mismatch: %', to_jsonb(v_position);
  END IF;

  -- FX then FX.
  PERFORM public.staff_resolve_order_settlement_v1(
    v_order_id, 0.00, 0.50,
    'Regression FX then FX one',
    'Transactional matrix; rolled back.',
    gen_random_uuid()
  );
  v_fx_added := v_fx_added + 0.50;

  PERFORM public.staff_resolve_order_settlement_v1(
    v_order_id, 0.00, 0.50,
    'Regression FX then FX two',
    'Transactional matrix; rolled back.',
    gen_random_uuid()
  );
  v_fx_added := v_fx_added + 0.50;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ABS(v_position.settlement_fx_card_difference_gbp - (v_initial.settlement_fx_card_difference_gbp + v_fx_added)) > 0.01 THEN
    RAISE EXCEPTION 'FX-then-FX total mismatch: %', to_jsonb(v_position);
  END IF;

  -- One split action.
  PERFORM public.staff_resolve_order_settlement_v1(
    v_order_id, 0.50, 0.50,
    'Regression split credit and FX',
    'Transactional matrix; rolled back.',
    gen_random_uuid()
  );
  v_credit_added := v_credit_added + 0.50;
  v_fx_added := v_fx_added + 0.50;

  -- FX then credit using separate actions.
  PERFORM public.staff_resolve_order_settlement_v1(
    v_order_id, 0.00, 0.25,
    'Regression FX before credit',
    'Transactional matrix; rolled back.',
    gen_random_uuid()
  );
  v_fx_added := v_fx_added + 0.25;

  v_key := gen_random_uuid();
  v_result := public.staff_resolve_order_settlement_v1(
    v_order_id, 0.25, 0.00,
    'Regression credit after FX',
    'Transactional matrix; rolled back.',
    v_key
  );
  v_credit_added := v_credit_added + 0.25;

  -- The exact same key and amounts must be idempotent.
  v_result := public.staff_resolve_order_settlement_v1(
    v_order_id, 0.25, 0.00,
    'Regression credit after FX',
    'Transactional matrix; rolled back.',
    v_key
  );

  IF COALESCE((v_result->>'already_applied')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Duplicate mixed-sequence action was not idempotent: %', v_result;
  END IF;

  IF (SELECT COUNT(*) FROM public.order_settlement_resolution_actions a WHERE a.action_key = v_key) <> 1 THEN
    RAISE EXCEPTION 'Duplicate action key produced more than one action row.';
  END IF;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ABS(v_position.confirmed_customer_credit_gbp - (v_initial.confirmed_customer_credit_gbp + v_credit_added)) > 0.01
     OR ABS(v_position.settlement_fx_card_difference_gbp - (v_initial.settlement_fx_card_difference_gbp + v_fx_added)) > 0.01
     OR ABS(v_position.remaining_unresolved_gbp - (v_initial.remaining_unresolved_gbp - v_credit_added - v_fx_added)) > 0.01
     OR v_position.resolution_status <> 'partially_resolved' THEN
    RAISE EXCEPTION 'Mixed/repeated partial sequence mismatch: %', to_jsonb(v_position);
  END IF;

  -- Resolve the exact remainder with a final split. This proves that any prior
  -- credit/FX sequence converges to one fully resolved canonical position.
  v_remaining := v_position.remaining_unresolved_gbp;
  v_final_credit := ROUND((v_remaining / 2)::numeric, 2);
  v_final_fx := ROUND((v_remaining - v_final_credit)::numeric, 2);

  PERFORM public.staff_resolve_order_settlement_v1(
    v_order_id,
    v_final_credit,
    v_final_fx,
    'Regression exact final split',
    'Transactional matrix; rolled back.',
    gen_random_uuid()
  );
  v_credit_added := v_credit_added + v_final_credit;
  v_fx_added := v_fx_added + v_final_fx;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF v_position.resolution_status <> 'fully_resolved'
     OR ABS(v_position.remaining_unresolved_gbp) > 0.01
     OR ABS(
       v_position.gross_positive_difference_gbp
       - (
           v_position.confirmed_customer_credit_gbp
           + v_position.inbound_fx_receipt_residual_gbp
           + v_position.settlement_fx_card_difference_gbp
         )
     ) > 0.01 THEN
    RAISE EXCEPTION 'Exact final split did not fully resolve the settlement: %', to_jsonb(v_position);
  END IF;

  SELECT COUNT(*) INTO v_credit_rows_after
  FROM public.importer_credit_ledger c
  WHERE c.source_entity_type = 'order'
    AND c.source_entity_id = v_order_id
    AND c.source_type = 'settlement_credit';

  SELECT COUNT(*) INTO v_action_rows_after
  FROM public.order_settlement_resolution_actions a
  WHERE a.order_id = v_order_id;

  IF v_credit_rows_after - v_credit_rows_before <> 4 THEN
    RAISE EXCEPTION 'Expected four new settlement-credit ledger rows, got %.', v_credit_rows_after - v_credit_rows_before;
  END IF;

  IF v_action_rows_after - v_action_rows_before <> 8 THEN
    RAISE EXCEPTION 'Expected eight new unique resolution actions, got %.', v_action_rows_after - v_action_rows_before;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_settlement_resolution_actions a
    WHERE a.order_id = v_order_id
      AND a.status = 'active'
      AND a.fx_card_difference_gbp > 0
      AND a.credit_ledger_id IS NOT NULL
      AND a.customer_credit_gbp = 0
  ) THEN
    RAISE EXCEPTION 'FX-only action incorrectly created a customer-credit ledger row.';
  END IF;

  SELECT * INTO v_audience
  FROM public.order_settlement_audience_v1(v_order_id);

  IF ABS(v_audience.credit_added_to_account_gbp - v_position.confirmed_customer_credit_gbp) > 0.01
     OR ABS(v_audience.other_settlement_adjustment_gbp - (v_position.inbound_fx_receipt_residual_gbp + v_position.settlement_fx_card_difference_gbp)) > 0.01
     OR ABS(v_audience.potential_additional_credit_gbp) > 0.01
     OR v_audience.resolution_status <> 'fully_resolved' THEN
    RAISE EXCEPTION 'Audience projection diverged after mixed/full resolution: %', to_jsonb(v_audience);
  END IF;

  -- A further classification must be rejected once nothing remains.
  BEGIN
    PERFORM public.staff_resolve_order_settlement_v1(
      v_order_id, 0.01, 0.00,
      'Regression excessive final action',
      'This call must fail.',
      gen_random_uuid()
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A positive action was accepted after the settlement was fully resolved.';
  END IF;

  RAISE NOTICE 'PASS: credit-credit, FX-FX, split, FX-credit, idempotency, partial and exact full resolution remain canonical.';
END $$;

ROLLBACK;
