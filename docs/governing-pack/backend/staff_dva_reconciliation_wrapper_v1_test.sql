-- =============================================================================
-- staff_dva_reconciliation_wrapper_v1_test.sql
-- Multi Tenant Platform Build — focused regression for staff_reconcile_dva_line_to_order
--
-- Run after:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_final_day6_8_clarified.sql
--   4. closure_v2_seed.sql
--   5. staff_dva_reconciliation_wrapper_v1.sql
--
-- Expected final output:
--   STAFF_DVA_RECONCILIATION_WRAPPER_V1_TEST_PASSED
--
-- This test runs in a transaction and rolls back all smoke-test data.
-- It does not install UI buttons and does not change the locked governing pack.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_auth_uid uuid := gen_random_uuid();
  v_staff_id uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_importer2_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_country_id uuid;

  v_order_partial_id uuid := gen_random_uuid();
  v_order_exact_id uuid := gen_random_uuid();
  v_order_block_overfund_id uuid := gen_random_uuid();
  v_order_allow_overfund_id uuid := gen_random_uuid();
  v_order_mismatch_id uuid := gen_random_uuid();
  v_order_replacement_id uuid := gen_random_uuid();

  v_statement_id uuid := gen_random_uuid();
  v_line_partial_id uuid := gen_random_uuid();
  v_line_exact_id uuid := gen_random_uuid();
  v_line_block_overfund_id uuid := gen_random_uuid();
  v_line_allow_overfund_id uuid := gen_random_uuid();
  v_line_mismatch_id uuid := gen_random_uuid();
  v_line_replacement_id uuid := gen_random_uuid();
  v_match_suggestion_id uuid := gen_random_uuid();

  v_result jsonb;
  v_count int;
  v_credit numeric;
  v_funded_at timestamptz;
  v_blocked boolean;
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preflight: prove the wrapper and governing baseline objects exist.
  -- ---------------------------------------------------------------------------
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: staff_reconcile_dva_line_to_order(uuid, uuid, numeric, boolean, uuid, text) is not installed';
  END IF;

  IF to_regclass('public.match_suggestions') IS NULL THEN
    RAISE EXCEPTION 'FAIL: public.match_suggestions table missing from baseline';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'match_suggestions'
      AND column_name IN (
        'dva_statement_line_id',
        'suggested_match_type',
        'suggested_match_id',
        'accepted_by_staff_id',
        'accepted_at'
      )
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 5
  ) THEN
    RAISE EXCEPTION 'FAIL: match_suggestions required columns missing';
  END IF;

  -- Simulate an authenticated Supabase user for auth.uid().
  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  SELECT id INTO v_country_id
  FROM countries
  WHERE iso_code = 'GHA'
  LIMIT 1;

  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: GHA country seed missing';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 1. Minimal tenant/order/DVA fixture.
  -- ---------------------------------------------------------------------------
  INSERT INTO staff (id, auth_user_id, role_type, full_name, email, active)
  VALUES (
    v_staff_id,
    v_auth_uid,
    'admin',
    'DVA Wrapper Test Admin',
    'dva-wrapper-test-admin-' || left(v_staff_id::text, 8) || '@example.test',
    true
  );

  INSERT INTO shippers (id, name, contact_email, vat_treatment, active)
  VALUES (
    v_shipper_id,
    'DVA Wrapper Test Shipper',
    'dva-wrapper-shipper-' || left(v_shipper_id::text, 8) || '@example.test',
    'outside_scope',
    true
  );

  INSERT INTO hubs (id, shipper_id, name, country_id, full_address, active)
  VALUES (
    v_hub_id,
    v_shipper_id,
    'DVA Wrapper Test Hub',
    v_country_id,
    'DVA Wrapper Test Address',
    true
  );

  UPDATE shippers
  SET primary_hub_id = v_hub_id
  WHERE id = v_shipper_id;

  INSERT INTO retailers (id, name, website_url, global_enabled)
  VALUES (
    v_retailer_id,
    'DVA Wrapper Test Retailer',
    'https://example.test',
    true
  );

  INSERT INTO importers (id, shipper_id, country_id, company_name, trading_name, active)
  VALUES
    (
      v_importer_id,
      v_shipper_id,
      v_country_id,
      'DVA Wrapper Importer Ltd',
      'DVA Importer',
      true
    ),
    (
      v_importer2_id,
      v_shipper_id,
      v_country_id,
      'DVA Wrapper Importer 2 Ltd',
      'DVA Importer 2',
      true
    );

  INSERT INTO operators (id, email, full_name, auth_user_id, active)
  VALUES (
    v_operator_id,
    'dva-wrapper-test-operator-' || left(v_operator_id::text, 8) || '@example.test',
    'DVA Wrapper Test Operator',
    gen_random_uuid(),
    true
  );

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES
    (v_operator_id, v_importer_id, 'sole_owner'),
    (v_operator_id, v_importer2_id, 'sole_owner');

  INSERT INTO orders (
    id,
    order_ref,
    payment_auth_id,
    importer_id,
    operator_id,
    shipper_id,
    retailer_id,
    destination_hub_id,
    order_type,
    order_total_gbp_declared,
    total_qty_declared,
    bundled_quote_gbp,
    quote_fx_rate,
    quote_card_markup_pct,
    quote_total_ghs,
    status,
    sop_version
  )
  VALUES
    (
      v_order_partial_id,
      'DVA-W-PART-' || left(v_order_partial_id::text, 8),
      'AUTH-DVA-PART',
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      1000.00,
      10,
      1000.00,
      1.00000000,
      0.000,
      1000.00,
      'pending_dva_funding',
      'wrapper-v1'
    ),
    (
      v_order_exact_id,
      'DVA-W-EXACT-' || left(v_order_exact_id::text, 8),
      'AUTH-DVA-EXACT',
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      1000.00,
      10,
      1000.00,
      1.00000000,
      0.000,
      1000.00,
      'pending_dva_funding',
      'wrapper-v1'
    ),
    (
      v_order_block_overfund_id,
      'DVA-W-BLOCK-' || left(v_order_block_overfund_id::text, 8),
      'AUTH-DVA-BLOCK',
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      1000.00,
      10,
      1000.00,
      1.00000000,
      0.000,
      1000.00,
      'pending_dva_funding',
      'wrapper-v1'
    ),
    (
      v_order_allow_overfund_id,
      'DVA-W-ALLOW-' || left(v_order_allow_overfund_id::text, 8),
      'AUTH-DVA-ALLOW',
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      1000.00,
      10,
      1000.00,
      1.00000000,
      0.000,
      1000.00,
      'pending_dva_funding',
      'wrapper-v1'
    ),
    (
      v_order_mismatch_id,
      'DVA-W-MISMATCH-' || left(v_order_mismatch_id::text, 8),
      'AUTH-DVA-MISMATCH',
      v_importer2_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      1000.00,
      10,
      1000.00,
      1.00000000,
      0.000,
      1000.00,
      'pending_dva_funding',
      'wrapper-v1'
    ),
    (
      v_order_replacement_id,
      'DVA-W-REPL-' || left(v_order_replacement_id::text, 8),
      'AUTH-DVA-REPL',
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'replacement_child',
      1000.00,
      10,
      1000.00,
      1.00000000,
      0.000,
      1000.00,
      'pending_dva_funding',
      'wrapper-v1'
    );

  INSERT INTO dva_statements (
    id,
    importer_id,
    source_bank,
    uploaded_by_staff_id,
    csv_url,
    statement_period_from,
    statement_period_to,
    parse_status
  )
  VALUES (
    v_statement_id,
    v_importer_id,
    'gcb',
    v_staff_id,
    'smoke://staff-dva-wrapper-v1.csv',
    CURRENT_DATE - 7,
    CURRENT_DATE,
    'parsed'
  );

  INSERT INTO dva_statement_lines (
    id,
    dva_statement_id,
    line_order,
    statement_date,
    reference_raw,
    direction,
    amount_local_ccy,
    local_ccy,
    fx_rate_applied,
    card_markup_pct_applied,
    amount_gbp_equivalent,
    auth_id_ref,
    match_status
  )
  VALUES
    (
      v_line_partial_id,
      v_statement_id,
      1,
      CURRENT_DATE,
      'partial funding',
      'in',
      600.00,
      'GBP',
      1.00000000,
      0.000,
      600.00,
      'AUTH-DVA-PART',
      'suggested'
    ),
    (
      v_line_exact_id,
      v_statement_id,
      2,
      CURRENT_DATE,
      'exact funding',
      'in',
      1000.00,
      'GBP',
      1.00000000,
      0.000,
      1000.00,
      'AUTH-DVA-EXACT',
      'confirmed'
    ),
    (
      v_line_block_overfund_id,
      v_statement_id,
      3,
      CURRENT_DATE,
      'blocked overfunding',
      'in',
      1200.00,
      'GBP',
      1.00000000,
      0.000,
      1200.00,
      'AUTH-DVA-BLOCK',
      'confirmed'
    ),
    (
      v_line_allow_overfund_id,
      v_statement_id,
      4,
      CURRENT_DATE,
      'allowed overfunding',
      'in',
      1200.00,
      'GBP',
      1.00000000,
      0.000,
      1200.00,
      'AUTH-DVA-ALLOW',
      'confirmed'
    ),
    (
      v_line_mismatch_id,
      v_statement_id,
      5,
      CURRENT_DATE,
      'importer mismatch',
      'in',
      500.00,
      'GBP',
      1.00000000,
      0.000,
      500.00,
      'AUTH-DVA-MISMATCH',
      'confirmed'
    ),
    (
      v_line_replacement_id,
      v_statement_id,
      6,
      CURRENT_DATE,
      'replacement child target',
      'in',
      500.00,
      'GBP',
      1.00000000,
      0.000,
      500.00,
      'AUTH-DVA-REPL',
      'confirmed'
    );

  INSERT INTO match_suggestions (
    id,
    dva_statement_line_id,
    suggested_match_type,
    suggested_match_id,
    confidence,
    variance_gbp,
    variance_days
  )
  VALUES (
    v_match_suggestion_id,
    v_line_partial_id,
    'order',
    v_order_partial_id,
    'high',
    0.00,
    0
  );

  -- ---------------------------------------------------------------------------
  -- Scenario 1: partial funding, including match_suggestion acceptance.
  -- ---------------------------------------------------------------------------
  SELECT staff_reconcile_dva_line_to_order(
    v_line_partial_id,
    v_order_partial_id,
    NULL,
    false,
    v_match_suggestion_id,
    'partial funding test with match suggestion'
  ) INTO v_result;

  IF (v_result->>'reconciled_gbp_amount')::numeric <> 600.00
     OR (v_result->>'gap_before_gbp')::numeric <> 1000.00
     OR (v_result->>'funding_total_after_gbp')::numeric <> 600.00
     OR (v_result->>'gap_after_gbp')::numeric <> 400.00
     OR COALESCE((v_result->>'overfunding_credit_expected_yn')::boolean, true) <> false THEN
    RAISE EXCEPTION 'FAIL: partial funding result unexpected: %', v_result;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM order_funding_events
  WHERE order_id = v_order_partial_id
    AND event_type = 'funding_contribution'
    AND source_entity_type = 'dva_reconciliation'
    AND amount_gbp = 600.00;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: partial funding did not create exactly one funding_contribution event; count=%', v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM match_suggestions
    WHERE id = v_match_suggestion_id
      AND accepted_by_staff_id = v_staff_id
      AND accepted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: match suggestion was not accepted/stamped by wrapper';
  END IF;

  SELECT funded_at INTO v_funded_at
  FROM orders
  WHERE id = v_order_partial_id;

  IF v_funded_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: partial funding stamped funded_at unexpectedly: %', v_funded_at;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Scenario 2: exact funding.
  -- ---------------------------------------------------------------------------
  SELECT staff_reconcile_dva_line_to_order(
    v_line_exact_id,
    v_order_exact_id,
    NULL,
    false,
    NULL,
    'exact funding test'
  ) INTO v_result;

  IF (v_result->>'funding_total_after_gbp')::numeric <> 1000.00
     OR (v_result->>'gap_after_gbp')::numeric <> 0.00
     OR (v_result->>'overfunding_gbp')::numeric <> 0.00 THEN
    RAISE EXCEPTION 'FAIL: exact funding result unexpected: %', v_result;
  END IF;

  SELECT funded_at INTO v_funded_at
  FROM orders
  WHERE id = v_order_exact_id;

  IF v_funded_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: exact funding did not stamp funded_at';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Scenario 3: overfunding blocked without explicit flag.
  -- ---------------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    PERFORM staff_reconcile_dva_line_to_order(
      v_line_block_overfund_id,
      v_order_block_overfund_id,
      NULL,
      false,
      NULL,
      'blocked overfunding test'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: overfunding without flag was not blocked';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM dva_reconciliation
  WHERE dva_statement_line_id = v_line_block_overfund_id;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: blocked overfunding inserted a dva_reconciliation row';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Scenario 4: overfunding allowed with explicit flag.
  -- ---------------------------------------------------------------------------
  SELECT staff_reconcile_dva_line_to_order(
    v_line_allow_overfund_id,
    v_order_allow_overfund_id,
    NULL,
    true,
    NULL,
    'allowed overfunding test'
  ) INTO v_result;

  IF (v_result->>'funding_total_after_gbp')::numeric <> 1200.00
     OR (v_result->>'gap_after_gbp')::numeric <> 0.00
     OR (v_result->>'overfunding_gbp')::numeric <> 200.00
     OR COALESCE((v_result->>'overfunding_credit_expected_yn')::boolean, false) <> true THEN
    RAISE EXCEPTION 'FAIL: explicit overfunding result unexpected: %', v_result;
  END IF;

  SELECT COALESCE(SUM(ABS(amount_gbp)), 0)
    INTO v_credit
  FROM importer_credit_ledger
  WHERE importer_id = v_importer_id
    AND direction = 'credit'
    AND source_type = 'overfunding'
    AND source_entity_type = 'order'
    AND source_entity_id = v_order_allow_overfund_id
    AND linked_order_id = v_order_allow_overfund_id;

  IF v_credit <> 200.00 THEN
    RAISE EXCEPTION 'FAIL: explicit overfunding credit = %, expected 200.00', v_credit;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Scenario 5: importer mismatch blocked.
  -- ---------------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    PERFORM staff_reconcile_dva_line_to_order(
      v_line_mismatch_id,
      v_order_mismatch_id,
      NULL,
      false,
      NULL,
      'importer mismatch test'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: importer mismatch was not blocked';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM dva_reconciliation
  WHERE dva_statement_line_id = v_line_mismatch_id;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: importer mismatch inserted a dva_reconciliation row';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Scenario 6: replacement_child target blocked.
  -- ---------------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    PERFORM staff_reconcile_dva_line_to_order(
      v_line_replacement_id,
      v_order_replacement_id,
      NULL,
      true,
      NULL,
      'replacement child block test'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: replacement_child target was not blocked';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM dva_reconciliation
  WHERE dva_statement_line_id = v_line_replacement_id;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: replacement_child target inserted a dva_reconciliation row';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Final invariant: every accepted order_funding reconciliation in this test has
  -- a matching funding_contribution event from the trigger path.
  -- ---------------------------------------------------------------------------
  SELECT COUNT(*) INTO v_count
  FROM dva_reconciliation dr
  LEFT JOIN order_funding_events ofe
    ON ofe.event_type = 'funding_contribution'
   AND ofe.source_entity_type = 'dva_reconciliation'
   AND ofe.source_entity_id = dr.id
  WHERE dr.reconciliation_type = 'order_funding'
    AND dr.reconciled_by_staff_id = v_staff_id
    AND ofe.id IS NULL;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % accepted DVA reconciliations are missing funding events', v_count;
  END IF;

  RAISE NOTICE 'STAFF_DVA_RECONCILIATION_WRAPPER_V1_TEST_PASSED';
END $$;

ROLLBACK;

SELECT 'STAFF_DVA_RECONCILIATION_WRAPPER_V1_TEST_PASSED' AS result;
