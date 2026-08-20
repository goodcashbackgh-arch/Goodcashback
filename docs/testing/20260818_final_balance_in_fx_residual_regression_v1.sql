BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE _final_balance_in_fx_regression_result (
  regression_result text NOT NULL,
  details text NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE _final_balance_in_fx_frozen (
  object_type text NOT NULL,
  object_name text NOT NULL,
  expected_md5 text NOT NULL
) ON COMMIT DROP;

INSERT INTO _final_balance_in_fx_frozen(object_type, object_name, expected_md5)
VALUES
  ('function', 'public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)', 'c8ef31c0e5ef974624d261b3fd2d200b'),
  ('function', 'public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)', 'ab9a0a7db133fced0ab2995c6ee35ee2'),
  ('function', 'public.staff_allocate_statement_line_to_fx_card_or_fee(uuid,character varying,numeric,text)', 'f36e0e0fdc35a15bcd4b80f16b33a21b'),
  ('function', 'public.internal_order_final_sale_settlement_v2(uuid)', 'f952daa5eafc87279c446ec09aa5a692'),
  ('view', 'public.order_settlement_resolution_position_v1', '9fdcf4597e682b1d29f88320700c8856'),
  ('function', 'public.internal_freeze_cash_control_rows_v1(text[],text)', 'be6bbe8b164556976215af6ff598290b'),
  ('function', 'public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)', 'bcd232d99015ac20b2f2c22795989fc6'),
  ('function', 'public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)', '3d888918bff171d132049104b5692937'),
  ('function', 'public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)', '93d34501d77c71d4c3ace0424f1d29b5'),
  ('function', 'public.internal_statement_line_control_resolver_v2(uuid)', 'eb9bfa5ea572335272217c372fa02f53'),
  ('view', 'public.statement_line_control_position_v1', 'fe6ee2fc8909e383b8d584995b30cc78'),
  ('view', 'public.statement_line_control_usage_v1', '581d367a31ab0f689f3d31b46df5922e');

DO $regression$
DECLARE
  r record;
  v_actual text;
  v_def text;
  v_compat_before text;
  v_compat_after text;
  v_compat_def text;
  v_staff_id uuid;
  v_staff_auth_uid uuid;
  v_target_line constant uuid := 'f36b93f8-16aa-46f0-a92d-bebdd4b919c0'::uuid;
  v_target_order constant uuid := '6f41a088-8e4a-44e3-80f3-f4631b3d0002'::uuid;
  v_target_order_ref text;
  v_target_importer uuid;
  v_target_final_alloc uuid;
  v_target_position record;
  v_target_settlement record;
  v_target_canonical record;
  v_inbound_fx_before numeric;
  v_gross_before numeric;
  v_classified_before numeric;
  v_existing_in_fx_fingerprint text;
  v_existing_in_fx_fingerprint_after text;
  v_new_fx_alloc uuid;
  v_result jsonb;
  v_rejected boolean;
  v_count_before integer;
  v_count_after integer;
  v_out_line uuid;
  v_statement_id uuid;
  v_test_line_id uuid;
  v_open_order uuid;
  v_open_importer uuid;
  v_open_due numeric;
  v_open_after numeric;
  v_fixture_count integer;
  v_cash_count integer;
  v_fb_cash_count integer;
  v_block_reasons text[] := ARRAY[]::text[];
BEGIN
  FOR r IN SELECT * FROM _final_balance_in_fx_frozen ORDER BY object_name
  LOOP
    IF r.object_type = 'view' THEN
      IF to_regclass(r.object_name) IS NULL THEN
        RAISE EXCEPTION 'FAIL: frozen view missing: %', r.object_name;
      END IF;
      EXECUTE format('SELECT md5(pg_get_viewdef(%L::regclass, true))', r.object_name)
        INTO v_actual;
    ELSE
      IF to_regprocedure(r.object_name) IS NULL THEN
        RAISE EXCEPTION 'FAIL: frozen function missing: %', r.object_name;
      END IF;
      EXECUTE format('SELECT md5(pg_get_functiondef(%L::regprocedure))', r.object_name)
        INTO v_actual;
    END IF;
    IF v_actual IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION 'FAIL: frozen % changed before regression. expected %, actual %',
        r.object_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;

  IF to_regclass('public.dva_statement_line_allocation_summary_vw') IS NULL THEN
    RAISE EXCEPTION 'FAIL: compatibility view public.dva_statement_line_allocation_summary_vw is missing';
  END IF;

  SELECT
    md5(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)),
    lower(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true))
  INTO v_compat_before, v_compat_def;

  IF position('dva_reconciliation' IN v_compat_def) = 0
     OR position('order_funding' IN v_compat_def) = 0
     OR position('loyalty_internal_transfer_out_gbp' IN v_compat_def) = 0
     OR position('loyalty_internal_transfer_in_gbp' IN v_compat_def) = 0
     OR position('loyalty_internal_transfer_in_count' IN v_compat_def) = 0
     OR position('dva_statement_line_import_links' IN v_compat_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: compatibility view lost an August governed calculation/preservation seam';
  END IF;

  IF to_regprocedure('public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: new final-balance IN FX residual writer is not installed';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)'::regprocedure
  )) INTO v_def;

  IF position('security definer' in v_def) = 0
     OR position('set search_path to ''public'', ''pg_temp''' in v_def) = 0
     OR position('statement_line_control_position_v1' in v_def) = 0
     OR position('internal_order_final_sale_settlement_v2' in v_def) = 0
     OR position('p_expected_residual_gbp' in v_def) = 0
     OR position('''fx_card_difference''' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: new writer definition lost a governed seam';
  END IF;

  IF has_function_privilege('anon','public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)','EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon can execute new writer';
  END IF;

  IF NOT has_function_privilege('authenticated','public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)','EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated execute grant missing';
  END IF;

  SELECT s.id, s.auth_user_id
    INTO v_staff_id, v_staff_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin', 'supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.id
  LIMIT 1;

  IF v_staff_id IS NULL OR v_staff_auth_uid IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'no active admin/supervisor auth user');
  ELSE
    PERFORM set_config('request.jwt.claim.sub', v_staff_auth_uid::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_staff_auth_uid::text, 'role', 'authenticated')::text, true);
    IF auth.uid() IS DISTINCT FROM v_staff_auth_uid THEN
      RAISE EXCEPTION 'FAIL: unable to establish active staff auth context';
    END IF;
  END IF;

  SELECT o.order_ref, o.importer_id
    INTO v_target_order_ref, v_target_importer
  FROM public.orders o
  WHERE o.id = v_target_order;

  IF v_target_order_ref IS NULL OR v_target_importer IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'controlled target order missing');
  END IF;

  SELECT p.* INTO v_target_position
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = v_target_line;

  IF v_target_position.statement_line_id IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'controlled £20.19 statement line missing from canonical control');
  ELSE
    IF ROUND(COALESCE(v_target_position.statement_gbp_amount, 0)::numeric, 2) <> 20.19
       OR ROUND(COALESCE(v_target_position.active_consumed_gbp, 0)::numeric, 2) <> 19.99
       OR ROUND(COALESCE(v_target_position.remaining_unconsumed_gbp, 0)::numeric, 2) <> 0.20
       OR ABS(COALESCE(v_target_position.overconsumed_gbp, 0)) > 0.005
       OR COALESCE(v_target_position.principal_lane_count, 0) <> 1 THEN
      v_block_reasons := array_append(v_block_reasons, 'controlled £20.19/£19.99/£0.20 canonical state drifted');
    END IF;
  END IF;

  SELECT a.id INTO v_target_final_alloc
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_target_line
    AND a.order_id = v_target_order
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed'
  LIMIT 1;

  IF v_target_final_alloc IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'controlled final-balance allocation missing');
  END IF;

  SELECT COUNT(*)::integer INTO v_count_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_target_line
    AND a.allocation_type = 'fx_card_difference'
    AND a.allocation_status <> 'reversed';

  IF v_count_before <> 0 THEN
    v_block_reasons := array_append(v_block_reasons, 'controlled line already has active FX classification');
  END IF;

  IF v_staff_auth_uid IS NOT NULL THEN
    SELECT * INTO v_target_settlement
    FROM public.internal_order_final_sale_settlement_v2(v_target_order)
    LIMIT 1;

    IF v_target_settlement.order_id IS NULL
       OR ROUND(COALESCE(v_target_settlement.amount_received_gbp, 0)::numeric, 2) <> 772.98
       OR ROUND(COALESCE(v_target_settlement.signed_final_sale_value_gbp, 0)::numeric, 2) <> 772.98
       OR ROUND(COALESCE(v_target_settlement.final_balance_due_gbp, 0)::numeric, 2) <> 0.00 THEN
      v_block_reasons := array_append(v_block_reasons, 'controlled settlement-v2 state drifted');
    END IF;
  END IF;

  SELECT * INTO v_target_canonical
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_target_order;

  IF v_target_canonical.order_id IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'controlled canonical order settlement missing');
  ELSE
    v_inbound_fx_before := ROUND(COALESCE(v_target_canonical.inbound_fx_receipt_residual_gbp, 0)::numeric, 2);
    v_gross_before := ROUND(COALESCE(v_target_canonical.gross_positive_difference_gbp, 0)::numeric, 2);
    v_classified_before := ROUND(COALESCE(v_target_canonical.total_classified_gbp, 0)::numeric, 2);
    IF v_inbound_fx_before <> 7.53
       OR ROUND(COALESCE(v_target_canonical.remaining_unresolved_gbp, 0)::numeric, 2) <> 0.00
       OR ROUND(COALESCE(v_target_canonical.over_resolved_gbp, 0)::numeric, 2) <> 0.00 THEN
      v_block_reasons := array_append(v_block_reasons, 'controlled canonical £7.53 inbound-FX state drifted');
    END IF;
  END IF;

  SELECT md5(COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.id)::text, '[]'))
    INTO v_existing_in_fx_fingerprint
  FROM (
    SELECT a.*
    FROM public.dva_statement_line_allocations a
    JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
    WHERE a.order_id = v_target_order
      AND a.allocation_type = 'fx_card_difference'
      AND a.allocation_status = 'confirmed'
      AND l.direction = 'in'
      AND a.dva_statement_line_id <> v_target_line
    ORDER BY a.id
  ) x;

  SELECT l.id INTO v_out_line
  FROM public.dva_statement_lines l
  WHERE l.direction = 'out'
  ORDER BY l.statement_date DESC NULLS LAST, l.id
  LIMIT 1;

  IF v_out_line IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'no OUT statement line for wrong-direction rejection');
  END IF;

  IF v_staff_auth_uid IS NOT NULL THEN
    SELECT s.order_id, s.importer_id, ROUND(s.final_balance_due_gbp::numeric, 2)
      INTO v_open_order, v_open_importer, v_open_due
    FROM public.internal_order_final_sale_settlement_v2(NULL) s
    JOIN public.orders o ON o.id = s.order_id
    WHERE COALESCE(s.final_sale_value_exists, false) = true
      AND COALESCE(s.final_balance_due_gbp, 0) > 0.20
      AND s.importer_id IS NOT NULL
      AND o.status NOT IN ('archived', 'cancelled')
    ORDER BY s.final_balance_due_gbp, s.order_id
    LIMIT 1;

    IF v_open_order IS NULL OR v_open_importer IS NULL THEN
      v_block_reasons := array_append(v_block_reasons, 'no open-final-balance order for rejection exercise');
    END IF;
  END IF;

  IF cardinality(v_block_reasons) > 0 THEN
    INSERT INTO _final_balance_in_fx_regression_result(regression_result, details)
    VALUES ('BLOCKED_PREREQUISITE','No behavioural writer exercise was run: ' || array_to_string(v_block_reasons, '; '));
    RETURN;
  END IF;

  BEGIN
    SELECT public.staff_classify_final_balance_in_fx_residual_v1(v_target_line,0.20,'[REGRESSION_ONLY] exact controlled final-balance IN FX residual') INTO v_result;

    IF COALESCE((v_result ->> 'ok')::boolean, false) IS NOT TRUE
       OR ROUND(COALESCE((v_result ->> 'allocated_gbp_amount')::numeric, 0), 2) <> 0.20
       OR ROUND(COALESCE((v_result ->> 'canonical_remaining_after_gbp')::numeric, 999999), 2) <> 0.00
       OR ROUND(COALESCE((v_result ->> 'canonical_overconsumed_after_gbp')::numeric, 999999), 2) <> 0.00
       OR COALESCE((v_result ->> 'principal_lane_count_after')::integer, 0) <> 1 THEN
      RAISE EXCEPTION 'FAIL: controlled success result contract unexpected: %', v_result;
    END IF;

    v_new_fx_alloc := (v_result ->> 'allocation_id')::uuid;

    SELECT p.* INTO v_target_position FROM public.statement_line_control_position_v1 p WHERE p.statement_line_id = v_target_line;
    IF ROUND(COALESCE(v_target_position.active_consumed_gbp, 0)::numeric, 2) <> 20.19
       OR ROUND(COALESCE(v_target_position.remaining_unconsumed_gbp, 0)::numeric, 2) <> 0.00
       OR ROUND(COALESCE(v_target_position.overconsumed_gbp, 0)::numeric, 2) <> 0.00
       OR COALESCE(v_target_position.principal_lane_count, 0) <> 1 THEN
      RAISE EXCEPTION 'FAIL: controlled success canonical statement position wrong';
    END IF;

    SELECT * INTO v_target_settlement FROM public.internal_order_final_sale_settlement_v2(v_target_order) LIMIT 1;
    IF ROUND(COALESCE(v_target_settlement.amount_received_gbp, 0)::numeric, 2) <> 772.98
       OR ROUND(COALESCE(v_target_settlement.signed_final_sale_value_gbp, 0)::numeric, 2) <> 772.98
       OR ROUND(COALESCE(v_target_settlement.final_balance_due_gbp, 0)::numeric, 2) <> 0.00
       OR v_target_settlement.final_settlement_state <> 'settled_nil'
       OR v_target_settlement.completion_state <> 'complete' THEN
      RAISE EXCEPTION 'FAIL: settlement v2 changed after FX-only residual classification';
    END IF;

    SELECT * INTO v_target_canonical FROM public.order_settlement_resolution_position_v1 p WHERE p.order_id = v_target_order;
    IF ROUND(COALESCE(v_target_canonical.inbound_fx_receipt_residual_gbp, 0)::numeric, 2) <> ROUND(v_inbound_fx_before + 0.20, 2)
       OR ROUND(COALESCE(v_target_canonical.gross_positive_difference_gbp, 0)::numeric, 2) <> ROUND(v_gross_before + 0.20, 2)
       OR ROUND(COALESCE(v_target_canonical.total_classified_gbp, 0)::numeric, 2) <> ROUND(v_classified_before + 0.20, 2)
       OR ROUND(COALESCE(v_target_canonical.remaining_unresolved_gbp, 0)::numeric, 2) <> 0.00
       OR ROUND(COALESCE(v_target_canonical.over_resolved_gbp, 0)::numeric, 2) <> 0.00
       OR v_target_canonical.resolution_status <> 'fully_resolved' THEN
      RAISE EXCEPTION 'FAIL: canonical order settlement did not absorb the new £0.20 as classified inbound FX only';
    END IF;

    SELECT md5(COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.id)::text, '[]')) INTO v_existing_in_fx_fingerprint_after
    FROM (
      SELECT a.* FROM public.dva_statement_line_allocations a
      JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
      WHERE a.order_id = v_target_order AND a.allocation_type = 'fx_card_difference'
        AND a.allocation_status = 'confirmed' AND l.direction = 'in'
        AND a.dva_statement_line_id <> v_target_line ORDER BY a.id
    ) x;

    IF v_existing_in_fx_fingerprint_after IS DISTINCT FROM v_existing_in_fx_fingerprint THEN
      RAISE EXCEPTION 'FAIL: pre-existing inbound FX rows changed during controlled classification';
    END IF;

    SELECT COUNT(*)::integer INTO v_cash_count
    FROM public.internal_cash_posting_workbench_rows_v1('in','fx_card_difference','all',v_target_order_ref,300,0) w
    WHERE w.source_id = v_new_fx_alloc AND w.direction = 'in' AND w.category = 'fx_card_difference'
      AND ROUND(COALESCE(w.amount_gbp, 0)::numeric, 2) = 0.20;
    IF v_cash_count <> 1 THEN RAISE EXCEPTION 'FAIL: new IN FX allocation did not appear exactly once in existing cash workbench'; END IF;

    SELECT COUNT(*)::integer INTO v_fb_cash_count
    FROM public.internal_cash_posting_workbench_rows_v1('in','customer_receipt_on_account','all',v_target_order_ref,300,0) w
    WHERE w.source_id = v_target_final_alloc AND w.source_type = 'dva_final_balance_allocation'
      AND ROUND(COALESCE(w.amount_gbp, 0)::numeric, 2) = 19.99;
    IF v_fb_cash_count <> 1 THEN RAISE EXCEPTION 'FAIL: existing final-balance cash bridge no longer exposes exactly £19.99'; END IF;

    RAISE EXCEPTION 'REGRESSION_ROLLBACK_CONTROLLED_SUCCESS';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'REGRESSION_ROLLBACK_CONTROLLED_SUCCESS' THEN RAISE; END IF;
  END;

  SELECT p.* INTO v_target_position FROM public.statement_line_control_position_v1 p WHERE p.statement_line_id = v_target_line;
  SELECT COUNT(*)::integer INTO v_count_after FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_target_line AND a.allocation_type = 'fx_card_difference' AND a.allocation_status <> 'reversed';
  IF ROUND(COALESCE(v_target_position.active_consumed_gbp, 0)::numeric, 2) <> 19.99
     OR ROUND(COALESCE(v_target_position.remaining_unconsumed_gbp, 0)::numeric, 2) <> 0.20
     OR v_count_after <> 0 THEN RAISE EXCEPTION 'FAIL: controlled success rollback left residue on live target'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.staff_classify_final_balance_in_fx_residual_v1(v_target_line,0.19,'[REGRESSION_ONLY] amount mismatch rejection');
  EXCEPTION WHEN OTHERS THEN
    v_rejected := position('does not equal canonical remaining' in lower(SQLERRM)) > 0;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'FAIL: amount mismatch was not rejected by canonical residual guard'; END IF;

  SELECT COUNT(*)::integer INTO v_count_before FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_out_line AND a.allocation_status <> 'reversed';
  v_rejected := false;
  BEGIN
    PERFORM public.staff_classify_final_balance_in_fx_residual_v1(v_out_line,0.01,'[REGRESSION_ONLY] wrong direction rejection');
  EXCEPTION WHEN OTHERS THEN
    v_rejected := position('requires an in statement line' in lower(SQLERRM)) > 0;
  END;
  SELECT COUNT(*)::integer INTO v_count_after FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_out_line AND a.allocation_status <> 'reversed';
  IF NOT v_rejected OR v_count_after <> v_count_before THEN RAISE EXCEPTION 'FAIL: wrong-direction rejection failed or changed allocation count'; END IF;

  v_statement_id := gen_random_uuid();
  v_test_line_id := gen_random_uuid();
  BEGIN
    INSERT INTO public.dva_statements(id,importer_id,statement_account_context,statement_account_key,statement_account_label,source_bank,uploaded_by_staff_id,csv_url,statement_period_from,statement_period_to,parse_status)
    VALUES (v_statement_id,v_target_importer,'importer_dva_card_account',v_target_importer::text,'Regression no-final-balance line','gcb',v_staff_id,'regression://no-final-balance-' || v_statement_id::text,CURRENT_DATE,CURRENT_DATE,'parsed');
    INSERT INTO public.dva_statement_lines(id,dva_statement_id,line_order,statement_date,reference_raw,direction,amount_local_ccy,local_ccy,fx_rate_applied,card_markup_pct_applied,amount_gbp_equivalent,auth_id_ref,retailer_name_ref,match_status)
    VALUES (v_test_line_id,v_statement_id,1,CURRENT_DATE,'REGRESSION no final-balance allocation','in',0.20,'GBP',1,0,0.20,'REG-NO-FB-' || left(v_test_line_id::text, 8),'Regression only','unmatched');
    v_rejected := false;
    BEGIN
      PERFORM public.staff_classify_final_balance_in_fx_residual_v1(v_test_line_id,0.20,'[REGRESSION_ONLY] no final balance rejection');
    EXCEPTION WHEN OTHERS THEN
      v_rejected := position('principal lane' in lower(SQLERRM)) > 0 OR position('final_balance_payment' in lower(SQLERRM)) > 0;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'FAIL: line without final-balance allocation was not rejected'; END IF;
    RAISE EXCEPTION 'REGRESSION_ROLLBACK_NO_FINAL_BALANCE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'REGRESSION_ROLLBACK_NO_FINAL_BALANCE' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_test_line_id)
     OR EXISTS (SELECT 1 FROM public.dva_statements WHERE id = v_statement_id) THEN RAISE EXCEPTION 'FAIL: no-final-balance fixture left residue'; END IF;

  v_statement_id := gen_random_uuid();
  v_test_line_id := gen_random_uuid();
  BEGIN
    INSERT INTO public.dva_statements(id,importer_id,statement_account_context,statement_account_key,statement_account_label,source_bank,uploaded_by_staff_id,csv_url,statement_period_from,statement_period_to,parse_status)
    VALUES (v_statement_id,v_open_importer,'importer_dva_card_account',v_open_importer::text,'Regression open-final-balance line','gcb',v_staff_id,'regression://open-final-balance-' || v_statement_id::text,CURRENT_DATE,CURRENT_DATE,'parsed');
    INSERT INTO public.dva_statement_lines(id,dva_statement_id,line_order,statement_date,reference_raw,direction,amount_local_ccy,local_ccy,fx_rate_applied,card_markup_pct_applied,amount_gbp_equivalent,auth_id_ref,retailer_name_ref,match_status)
    VALUES (v_test_line_id,v_statement_id,1,CURRENT_DATE,'REGRESSION open final balance','in',0.20,'GBP',1,0,0.20,'REG-OPEN-FB-' || left(v_test_line_id::text, 8),'Regression only','unmatched');
    INSERT INTO public.dva_statement_line_allocations(dva_statement_line_id,allocation_type,supplier_invoice_id,dispute_id,order_id,allocated_gbp_amount,allocation_status,fx_rate_applied,card_markup_pct_applied,notes,created_by_staff_id,created_at,confirmed_by_staff_id,confirmed_at)
    VALUES (v_test_line_id,'final_balance_payment',NULL,NULL,v_open_order,0.10,'confirmed',1,0,'[REGRESSION_ONLY] synthetic partial final-balance evidence',v_staff_id,now(),v_staff_id,now());
    SELECT ROUND(COALESCE(s.final_balance_due_gbp, 0)::numeric, 2) INTO v_open_after FROM public.internal_order_final_sale_settlement_v2(v_open_order) s LIMIT 1;
    IF v_open_after <= 0.005 THEN RAISE EXCEPTION 'FAIL: open-final-balance fixture unexpectedly closed the balance'; END IF;
    v_rejected := false;
    BEGIN
      PERFORM public.staff_classify_final_balance_in_fx_residual_v1(v_test_line_id,0.10,'[REGRESSION_ONLY] open balance rejection');
    EXCEPTION WHEN OTHERS THEN
      v_rejected := position('still has final balance due' in lower(SQLERRM)) > 0;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'FAIL: open final balance was not rejected'; END IF;
    RAISE EXCEPTION 'REGRESSION_ROLLBACK_OPEN_FINAL_BALANCE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'REGRESSION_ROLLBACK_OPEN_FINAL_BALANCE' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_test_line_id)
     OR EXISTS (SELECT 1 FROM public.dva_statements WHERE id = v_statement_id) THEN RAISE EXCEPTION 'FAIL: open-final-balance fixture left residue'; END IF;

  BEGIN
    SELECT public.staff_classify_final_balance_in_fx_residual_v1(v_target_line,0.20,'[REGRESSION_ONLY] first duplicate exercise allocation') INTO v_result;
    SELECT COUNT(*)::integer INTO v_count_before FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = v_target_line AND a.allocation_type = 'fx_card_difference' AND a.allocation_status <> 'reversed';
    IF v_count_before <> 1 THEN RAISE EXCEPTION 'FAIL: duplicate exercise first classification did not create exactly one FX row'; END IF;
    v_rejected := false;
    BEGIN
      PERFORM public.staff_classify_final_balance_in_fx_residual_v1(v_target_line,0.20,'[REGRESSION_ONLY] duplicate rejection');
    EXCEPTION WHEN OTHERS THEN
      v_rejected := position('no canonical residual remaining' in lower(SQLERRM)) > 0 OR position('already has an active fx/card difference' in lower(SQLERRM)) > 0;
    END;
    SELECT COUNT(*)::integer INTO v_count_after FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = v_target_line AND a.allocation_type = 'fx_card_difference' AND a.allocation_status <> 'reversed';
    IF NOT v_rejected OR v_count_after <> 1 THEN RAISE EXCEPTION 'FAIL: duplicate classification was not rejected cleanly'; END IF;
    RAISE EXCEPTION 'REGRESSION_ROLLBACK_DUPLICATE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'REGRESSION_ROLLBACK_DUPLICATE' THEN RAISE; END IF;
  END;

  SELECT COUNT(*)::integer INTO v_count_after FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_target_line AND a.allocation_type = 'fx_card_difference' AND a.allocation_status <> 'reversed';
  IF v_count_after <> 0 THEN RAISE EXCEPTION 'FAIL: duplicate exercise rollback left FX residue on controlled line'; END IF;

  FOR r IN SELECT * FROM _final_balance_in_fx_frozen ORDER BY object_name
  LOOP
    IF r.object_type = 'view' THEN
      EXECUTE format('SELECT md5(pg_get_viewdef(%L::regclass, true))', r.object_name) INTO v_actual;
    ELSE
      EXECUTE format('SELECT md5(pg_get_functiondef(%L::regprocedure))', r.object_name) INTO v_actual;
    END IF;
    IF v_actual IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION 'FAIL: frozen % changed after regression. expected %, actual %',r.object_name,r.expected_md5,v_actual;
    END IF;
  END LOOP;

  SELECT md5(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)) INTO v_compat_after;
  IF v_compat_after IS DISTINCT FROM v_compat_before THEN
    RAISE EXCEPTION 'FAIL: compatibility view changed during rollback regression. before %, after %',v_compat_before,v_compat_after;
  END IF;

  SELECT md5(COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.id)::text, '[]')) INTO v_existing_in_fx_fingerprint_after
  FROM (
    SELECT a.* FROM public.dva_statement_line_allocations a
    JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
    WHERE a.order_id = v_target_order AND a.allocation_type = 'fx_card_difference'
      AND a.allocation_status = 'confirmed' AND l.direction = 'in'
      AND a.dva_statement_line_id <> v_target_line ORDER BY a.id
  ) x;

  IF v_existing_in_fx_fingerprint_after IS DISTINCT FROM v_existing_in_fx_fingerprint THEN
    RAISE EXCEPTION 'FAIL: existing order inbound-FX evidence changed after rollback exercises';
  END IF;

  INSERT INTO _final_balance_in_fx_regression_result(regression_result, details)
  VALUES ('PASS','Frozen June/July/August treasury authorities and the August compatibility-view routing contract remained unchanged; exact live £20.19/£19.99/£0.20 path classified only £0.20 as inbound FX inside rollback; settlement v2 stayed £772.98/£772.98/£0 due/complete; canonical order settlement absorbed exactly +£0.20 as classified inbound FX with zero unresolved/over-resolved; existing £7.53 IN FX stayed unchanged; existing final-balance cash bridge remained £19.99; wrong-direction, amount-mismatch, no-final-balance, open-final-balance and duplicate attempts were rejected; all behavioural changes rolled back without residue.');
END
$regression$;

SELECT regression_result, details
FROM _final_balance_in_fx_regression_result;

ROLLBACK;