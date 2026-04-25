-- day2_to_day9_plus_day6_8_final_regression_smoke_test.sql
-- Multi Tenant Platform Build — final combined regression.
-- Run after a fresh install of:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_final_day6_8_clarified.sql
--   4. closure_v2_seed.sql
-- If any check fails, execution stops at the first error.
-- This file combines the Day 2-9 regression plus the Day 6/8 VAT reporting clarification checks.

-- day2_to_day8_combined_regression_smoke_test.sql
-- Multi Tenant Platform Build — combined clean regression for Days 2 through 8.
-- Run after a fresh install of:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2_final_progressive_release.sql
--   4. closure_v2_seed.sql
-- If any check fails, execution stops at the first error.
-- The final SELECT returns the complete Day 2-8 pass list.


-- ============================================================================
-- BEGIN INCLUDED TEST: day2_to_day5_combined_regression_smoke_test.sql
-- ============================================================================

-- day2_to_day5_combined_regression_smoke_test.sql
-- Combined backend regression for Days 2, 3, 4, and 5.
-- Run after, in a fresh project:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql
--   4. closure_v2_seed.sql
--
-- If any check fails, execution stops with the first error.
-- If everything passes, this returns one final result set with all Day 2-5 pass markers.

-- ============================================================================
-- BEGIN INCLUDED TEST: day2_final_funding_regression_smoke_test_v2.sql
-- ============================================================================
-- =============================================================================
-- day2_final_funding_regression_smoke_test.sql
-- Multi Tenant Platform Build — Day 2 final regression smoke test
--
-- Run only after a fresh install of:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql
--   4. closure_v2_seed.sql
--
-- This file combines:
--   A. Core Day 2 funding flow smoke test
--   B. Overfunding-to-importer-credit smoke test
--
-- Both sections rollback their inserted smoke-test data.
-- Expected final output: one final result set with two rows:
--   DAY2_SMOKE_TEST_CORE_PASSED
--   DAY2_OVERFUNDING_CREDIT_SMOKE_TEST_PASSED
--
-- Supabase SQL Editor usually displays only the last SELECT result set, so this
-- file deliberately emits one combined final SELECT at the very end.
-- =============================================================================

-- =============================================================================
-- day2_funding_smoke_test_core.sql
-- Multi Tenant Platform Build — Day 2 funding smoke test
--
-- Expected preconditions already installed in this fresh Supabase test project:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql
--   4. closure_v2_seed.sql
--
-- What this proves:
--   A. Order funding gap starts correctly.
--   B. DVA reconciliation creates/updates order_funding_events.
--   C. funded_at is stamped only when threshold is reached.
--   D. importer_balance_vw remains baseline-compatible and usable.
--   E. apply_importer_credit_to_order() closes a funding gap through credit.
--   F. credit applications over GBP 500 surface requires_admin_review_yn.
--
-- This test rolls back all inserted smoke-test data.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_staff_id uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_markup_category_id uuid := gen_random_uuid();
  v_country_id uuid;

  v_order_id uuid := gen_random_uuid();
  v_order2_id uuid := gen_random_uuid();
  v_statement_id uuid := gen_random_uuid();
  v_line_id uuid := gen_random_uuid();
  v_reconciliation_id uuid := gen_random_uuid();
  v_credit_source_id uuid := gen_random_uuid();
  v_credit_source2_id uuid := gen_random_uuid();
  v_credit_result jsonb;
  v_credit_result2 jsonb;
  v_credit_debit2_id uuid;

  v_count int;
  v_total numeric;
  v_gap numeric;
  v_available numeric;
  v_funded_at timestamptz;
  v_cols text;
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preflight checks: prove the right pack shape is installed.
  -- ---------------------------------------------------------------------------
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'importer_balance_vw';

  IF v_cols IS DISTINCT FROM 'importer_id,available_credit_gbp,pending_refund_gbp,active_order_funding_gbp,payout_in_progress_gbp,last_refreshed_at' THEN
    RAISE EXCEPTION 'FAIL: importer_balance_vw shape is %, expected baseline-compatible shape', v_cols;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM escalation_rules WHERE rule_code = 'CREDIT_AMOUNT' AND active = true) THEN
    RAISE EXCEPTION 'FAIL: closure_v2_seed.sql does not appear to be installed: active CREDIT_AMOUNT rule missing';
  END IF;

  IF to_regclass('public.order_funding_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: order_funding_events table missing';
  END IF;

  SELECT id INTO v_country_id FROM countries WHERE iso_code = 'GHA' LIMIT 1;
  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: GHA country seed missing. Baseline should seed ISO code GHA.';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 1. Minimal tenant/order fixture.
  -- ---------------------------------------------------------------------------
  INSERT INTO staff (id, auth_user_id, role_type, full_name, email, active)
  VALUES (v_staff_id, gen_random_uuid(), 'admin', 'Smoke Test Admin', 'smoke-admin-' || left(v_staff_id::text, 8) || '@example.test', true);

  INSERT INTO shippers (id, name, contact_email, vat_treatment, active)
  VALUES (v_shipper_id, 'Smoke Test Shipper', 'shipper-' || left(v_shipper_id::text, 8) || '@example.test', 'outside_scope', true);

  INSERT INTO hubs (id, shipper_id, name, country_id, full_address, active)
  VALUES (v_hub_id, v_shipper_id, 'Smoke Test Hub', v_country_id, 'Smoke Test Address', true);

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO retailers (id, name, website_url, global_enabled)
  VALUES (v_retailer_id, 'Smoke Test Retailer', 'https://example.test', true);

  INSERT INTO markup_categories (id, shipper_id, category_name, default_markup_pct, active)
  VALUES (v_markup_category_id, v_shipper_id, 'Smoke Category', 0.000, true);

  INSERT INTO importers (id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_importer_id, v_shipper_id, v_country_id, 'Smoke Importer Ltd', 'Smoke Importer', true);

  INSERT INTO operators (id, email, full_name, auth_user_id, active)
  VALUES (v_operator_id, 'smoke-operator-' || left(v_operator_id::text, 8) || '@example.test', 'Smoke Operator', gen_random_uuid(), true);

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO orders (
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared, total_qty_declared,
    bundled_quote_gbp, quote_fx_rate, quote_card_markup_pct, quote_total_ghs,
    status, sop_version
  )
  VALUES (
    v_order_id, 'SMOKE-D2-' || left(v_order_id::text, 8), 'AUTH-SMOKE-001', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id,
    v_hub_id, 'original', 1000.00, 10,
    1000.00, 1.00000000, 0.000, 1000.00,
    'pending_dva_funding', 'smoke-v1'
  );

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES (v_order_id, v_markup_category_id, 10, 1000.00, 0.000, 0.00);

  SELECT order_funding_gap_gbp(v_order_id) INTO v_gap;
  IF v_gap <> 1000.00 THEN
    RAISE EXCEPTION 'FAIL: initial funding gap = %, expected 1000.00', v_gap;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2. DVA reconciliation creates funding event but does not prematurely fund.
  -- ---------------------------------------------------------------------------
  INSERT INTO dva_statements (
    id, importer_id, source_bank, uploaded_by_staff_id, csv_url,
    statement_period_from, statement_period_to, parse_status
  )
  VALUES (
    v_statement_id, v_importer_id, 'gcb', v_staff_id, 'smoke://dva.csv',
    CURRENT_DATE - 7, CURRENT_DATE, 'parsed'
  );

  INSERT INTO dva_statement_lines (
    id, dva_statement_id, line_order, statement_date, reference_raw, direction,
    amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied,
    amount_gbp_equivalent, auth_id_ref, match_status
  )
  VALUES (
    v_line_id, v_statement_id, 1, CURRENT_DATE, 'AUTH-SMOKE-001 partial funding', 'in',
    600.00, 'GBP', 1.00000000, 0.000,
    600.00, 'AUTH-SMOKE-001', 'confirmed'
  );

  INSERT INTO dva_reconciliation (
    id, dva_statement_line_id, reconciliation_type, order_id,
    reconciled_gbp_amount, reconciled_by_staff_id, reconciled_at, notes
  )
  VALUES (
    v_reconciliation_id, v_line_id, 'order_funding', v_order_id,
    600.00, v_staff_id, now(), 'Smoke partial DVA funding'
  );

  SELECT COUNT(*) INTO v_count
  FROM order_funding_events
  WHERE order_id = v_order_id
    AND event_type = 'funding_contribution'
    AND source_entity_type = 'dva_reconciliation'
    AND source_entity_id = v_reconciliation_id
    AND amount_gbp = 600.00;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: DVA reconciliation did not create exactly one 600.00 funding event; count=%', v_count;
  END IF;

  SELECT order_funding_total_gbp(v_order_id), order_funding_gap_gbp(v_order_id), funded_at
    INTO v_total, v_gap, v_funded_at
  FROM orders
  WHERE id = v_order_id;

  IF v_total <> 600.00 OR v_gap <> 400.00 OR v_funded_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: after partial DVA total=%, gap=%, funded_at=%; expected 600, 400, NULL', v_total, v_gap, v_funded_at;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 3. Updating DVA reconciliation must update the funding event and funded_at.
  -- ---------------------------------------------------------------------------
  UPDATE dva_reconciliation
  SET reconciled_gbp_amount = 700.00
  WHERE id = v_reconciliation_id;

  SELECT order_funding_total_gbp(v_order_id), order_funding_gap_gbp(v_order_id), funded_at
    INTO v_total, v_gap, v_funded_at
  FROM orders
  WHERE id = v_order_id;

  IF v_total <> 700.00 OR v_gap <> 300.00 OR v_funded_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: after DVA update total=%, gap=%, funded_at=%; expected 700, 300, NULL', v_total, v_gap, v_funded_at;
  END IF;

  UPDATE dva_reconciliation
  SET reconciled_gbp_amount = 600.00
  WHERE id = v_reconciliation_id;

  -- ---------------------------------------------------------------------------
  -- 4. Importer credit closes the remaining funding gap and writes funding event.
  -- ---------------------------------------------------------------------------
  INSERT INTO importer_credit_ledger (
    importer_id, entry_type, source_table, source_id, linked_order_id, linked_dispute_id,
    direction, amount_gbp, amount_local_ccy, local_ccy, created_by_staff_id, effective_at,
    source_type, source_entity_type, source_entity_id, lock_reason, notes
  )
  VALUES (
    v_importer_id, 'manual_credit', 'smoke_test', v_credit_source_id, NULL, NULL,
    'credit', 500.00, 500.00, 'GBP', v_staff_id, now(),
    'manual', 'smoke_test', v_credit_source_id, NULL, 'Smoke available credit source'
  );

  SELECT available_credit_gbp INTO v_available
  FROM importer_balance_vw
  WHERE importer_id = v_importer_id;

  IF v_available <> 500.00 THEN
    RAISE EXCEPTION 'FAIL: available credit before application = %, expected 500.00', v_available;
  END IF;

  SELECT apply_importer_credit_to_order(v_importer_id, v_order_id, 400.00, v_staff_id)
    INTO v_credit_result;

  IF (v_credit_result->>'applied_gbp')::numeric <> 400.00 THEN
    RAISE EXCEPTION 'FAIL: credit applied result = %, expected applied_gbp 400.00', v_credit_result;
  END IF;

  SELECT order_funding_total_gbp(v_order_id), order_funding_gap_gbp(v_order_id), funded_at
    INTO v_total, v_gap, v_funded_at
  FROM orders
  WHERE id = v_order_id;

  IF v_total <> 1000.00 OR v_gap <> 0.00 OR v_funded_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: after credit close total=%, gap=%, funded_at=%; expected 1000, 0, NOT NULL', v_total, v_gap, v_funded_at;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM order_funding_events
  WHERE order_id = v_order_id
    AND event_type = 'credit_applied'
    AND source_entity_type = 'importer_credit_ledger'
    AND amount_gbp = 400.00;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: credit application did not create exactly one 400.00 credit_applied funding event; count=%', v_count;
  END IF;

  SELECT available_credit_gbp INTO v_available
  FROM importer_balance_vw
  WHERE importer_id = v_importer_id;

  IF v_available <> 100.00 THEN
    RAISE EXCEPTION 'FAIL: available credit after 400 application = %, expected 100.00', v_available;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 5. Credit application over GBP 500 must surface admin review flag.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared, total_qty_declared,
    bundled_quote_gbp, quote_fx_rate, quote_card_markup_pct, quote_total_ghs,
    status, sop_version
  )
  VALUES (
    v_order2_id, 'SMOKE-D2-' || left(v_order2_id::text, 8), 'AUTH-SMOKE-002', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id,
    v_hub_id, 'original', 1000.00, 10,
    1000.00, 1.00000000, 0.000, 1000.00,
    'pending_dva_funding', 'smoke-v1'
  );

  INSERT INTO importer_credit_ledger (
    importer_id, entry_type, source_table, source_id, linked_order_id, linked_dispute_id,
    direction, amount_gbp, amount_local_ccy, local_ccy, created_by_staff_id, effective_at,
    source_type, source_entity_type, source_entity_id, lock_reason, notes
  )
  VALUES (
    v_importer_id, 'manual_credit', 'smoke_test', v_credit_source2_id, NULL, NULL,
    'credit', 700.00, 700.00, 'GBP', v_staff_id, now(),
    'manual', 'smoke_test', v_credit_source2_id, NULL, 'Smoke available credit source for admin threshold'
  );

  SELECT apply_importer_credit_to_order(v_importer_id, v_order2_id, 600.00, v_staff_id)
    INTO v_credit_result2;

  v_credit_debit2_id := (v_credit_result2->>'credit_debit_id')::uuid;

  IF (v_credit_result2->>'applied_gbp')::numeric <> 600.00 THEN
    RAISE EXCEPTION 'FAIL: second credit result = %, expected applied_gbp 600.00', v_credit_result2;
  END IF;

  IF COALESCE((v_credit_result2->>'requires_admin_review_yn')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: second credit result did not return requires_admin_review_yn=true: %', v_credit_result2;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM importer_credit_admin_review_vw
    WHERE importer_credit_ledger_id = v_credit_debit2_id
      AND requires_admin_review_yn = true
      AND 'CREDIT_AMOUNT' = ANY(open_rule_codes)
  ) THEN
    RAISE EXCEPTION 'FAIL: importer_credit_admin_review_vw did not surface CREDIT_AMOUNT for debit %', v_credit_debit2_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM admin_escalation_queue_vw
    WHERE entity_type = 'importer_credit'
      AND entity_id = v_credit_debit2_id
      AND rule_code = 'CREDIT_AMOUNT'
  ) THEN
    RAISE EXCEPTION 'FAIL: admin_escalation_queue_vw missing CREDIT_AMOUNT for debit %', v_credit_debit2_id;
  END IF;

  RAISE NOTICE 'DAY2_SMOKE_TEST_CORE_PASSED: DVA funding, funding-event sync, credit application, funded_at threshold, and admin review flags all passed.';
END $$;

ROLLBACK;

-- Core test passed if execution reaches here. Final combined SELECT is emitted at the end.


-- =============================================================================
-- SECTION B: OVERFUNDING CREDIT REGRESSION
-- =============================================================================

-- =============================================================================
-- day2_overfunding_credit_smoke_test.sql
-- Strict Day 2 overfunding-credit smoke test.
--
-- What this proves:
--   A. DVA funding above order total stamps funded_at.
--   B. Excess funding is surfaced as available importer credit.
--
-- Note: based on static review of closure_v2_functions_v2.sql, this test may fail
-- at the overfunding-credit assertion. If it fails there, the functions pack needs
-- an overfunding-credit sync helper/trigger; the baseline install itself is still OK.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_staff_id uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_country_id uuid;
  v_order_id uuid := gen_random_uuid();
  v_statement_id uuid := gen_random_uuid();
  v_line_id uuid := gen_random_uuid();
  v_reconciliation_id uuid := gen_random_uuid();
  v_total numeric;
  v_gap numeric;
  v_available numeric;
  v_excess_credit numeric;
  v_funded_at timestamptz;
BEGIN
  SELECT id INTO v_country_id FROM countries WHERE iso_code = 'GHA' LIMIT 1;
  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: GHA country seed missing';
  END IF;

  INSERT INTO staff (id, auth_user_id, role_type, full_name, email, active)
  VALUES (v_staff_id, gen_random_uuid(), 'admin', 'Smoke Test Admin', 'smoke-overfund-admin-' || left(v_staff_id::text, 8) || '@example.test', true);

  INSERT INTO shippers (id, name, contact_email, vat_treatment, active)
  VALUES (v_shipper_id, 'Smoke Overfund Shipper', 'shipper-' || left(v_shipper_id::text, 8) || '@example.test', 'outside_scope', true);

  INSERT INTO hubs (id, shipper_id, name, country_id, full_address, active)
  VALUES (v_hub_id, v_shipper_id, 'Smoke Overfund Hub', v_country_id, 'Smoke Test Address', true);

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO retailers (id, name, website_url, global_enabled)
  VALUES (v_retailer_id, 'Smoke Overfund Retailer', 'https://example.test', true);

  INSERT INTO importers (id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_importer_id, v_shipper_id, v_country_id, 'Smoke Overfund Importer Ltd', 'Smoke Importer', true);

  INSERT INTO operators (id, email, full_name, auth_user_id, active)
  VALUES (v_operator_id, 'smoke-overfund-operator-' || left(v_operator_id::text, 8) || '@example.test', 'Smoke Operator', gen_random_uuid(), true);

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO orders (
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared, total_qty_declared,
    bundled_quote_gbp, quote_fx_rate, quote_card_markup_pct, quote_total_ghs,
    status, sop_version
  )
  VALUES (
    v_order_id, 'SMOKE-OF-' || left(v_order_id::text, 8), 'AUTH-SMOKE-OF-001', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id,
    v_hub_id, 'original', 1000.00, 10,
    1000.00, 1.00000000, 0.000, 1000.00,
    'pending_dva_funding', 'smoke-v1'
  );

  INSERT INTO dva_statements (
    id, importer_id, source_bank, uploaded_by_staff_id, csv_url,
    statement_period_from, statement_period_to, parse_status
  )
  VALUES (
    v_statement_id, v_importer_id, 'gcb', v_staff_id, 'smoke://overfund-dva.csv',
    CURRENT_DATE - 7, CURRENT_DATE, 'parsed'
  );

  INSERT INTO dva_statement_lines (
    id, dva_statement_id, line_order, statement_date, reference_raw, direction,
    amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied,
    amount_gbp_equivalent, auth_id_ref, match_status
  )
  VALUES (
    v_line_id, v_statement_id, 1, CURRENT_DATE, 'AUTH-SMOKE-OF-001 overfunding', 'in',
    1200.00, 'GBP', 1.00000000, 0.000,
    1200.00, 'AUTH-SMOKE-OF-001', 'confirmed'
  );

  INSERT INTO dva_reconciliation (
    id, dva_statement_line_id, reconciliation_type, order_id,
    reconciled_gbp_amount, reconciled_by_staff_id, reconciled_at, notes
  )
  VALUES (
    v_reconciliation_id, v_line_id, 'order_funding', v_order_id,
    1200.00, v_staff_id, now(), 'Smoke DVA overfunding'
  );

  SELECT order_funding_total_gbp(v_order_id), order_funding_gap_gbp(v_order_id), funded_at
    INTO v_total, v_gap, v_funded_at
  FROM orders
  WHERE id = v_order_id;

  IF v_total <> 1200.00 OR v_gap <> 0.00 OR v_funded_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: overfunded order funding state total=%, gap=%, funded_at=%; expected 1200, 0, NOT NULL', v_total, v_gap, v_funded_at;
  END IF;

  SELECT COALESCE(SUM(amount_gbp), 0)
    INTO v_excess_credit
  FROM importer_credit_ledger
  WHERE importer_id = v_importer_id
    AND direction = 'credit'
    AND source_type = 'overfunding'
    AND COALESCE(linked_order_id, applied_to_order_id) = v_order_id;

  IF v_excess_credit <> 200.00 THEN
    RAISE EXCEPTION 'FAIL: overfunding credit = %, expected 200.00. This means excess DVA funding is not being mirrored to importer_credit_ledger.', v_excess_credit;
  END IF;

  SELECT available_credit_gbp INTO v_available
  FROM importer_balance_vw
  WHERE importer_id = v_importer_id;

  IF v_available <> 200.00 THEN
    RAISE EXCEPTION 'FAIL: importer_balance_vw available credit = %, expected 200.00 from overfunding credit', v_available;
  END IF;

  RAISE NOTICE 'DAY2_OVERFUNDING_CREDIT_SMOKE_TEST_PASSED';
END $$;

ROLLBACK;

-- Overfunding test passed if execution reaches here.

-- ============================================================================
-- BEGIN INCLUDED TEST: day3_evidence_ocr_smoke_test.sql
-- ============================================================================
-- =============================================================================
-- day3_evidence_ocr_smoke_test.sql
-- Multi Tenant Platform Build — Day 3 evidence / OCR / progressed subset smoke test
--
-- Run after:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql
--   4. closure_v2_seed.sql
--
-- Purpose:
--   Proves the Day 3 backend controls required by the authority stack + role matrices:
--   - tracking-first path is allowed and status moves to evidence_collecting
--   - invoice-first path is allowed and status moves to reconciling
--   - OCR/progressed subset uses eligible_for_invoice_yn via order_reconciliation_vw
--   - progressed subset + open child exception leaves parent partially_progressed
--   - manual invoice lines are deletable
--   - OCR-source invoice lines are NOT deletable
--
-- This test intentionally rolls back all data.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_suffix text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_currency_id uuid;
  v_country_id uuid;
  v_staff_id uuid;
  v_shipper_id uuid;
  v_hub_id uuid;
  v_retailer_id uuid;
  v_retailer_account_id uuid;
  v_operator_id uuid;
  v_importer_id uuid;
  v_courier_id uuid;

  v_order_tracking_first uuid;
  v_order_invoice_first uuid;
  v_order_partial uuid;

  v_invoice_tracking_first uuid;
  v_invoice_invoice_first uuid;
  v_invoice_partial uuid;

  v_ocr_line_progressed uuid;
  v_manual_line_delete_test uuid;
  v_ocr_line_delete_test uuid;
  v_dispute_id uuid;
  v_dispute_line_id uuid;

  v_status text;
  v_bool boolean;
  v_qty_unresolved numeric;
  v_amount_unresolved numeric;
  v_ocr_delete_blocked boolean := false;
BEGIN
  -- ---------------------------------------------------------------------------
  -- Minimal tenant/reference setup. Random suffix avoids collisions if a prior
  -- failed test left residue outside rollback.
  -- ---------------------------------------------------------------------------
  INSERT INTO currencies (code, symbol)
  VALUES ('X' || upper(substr(v_suffix, 1, 2)), '¤')
  RETURNING id INTO v_currency_id;

  INSERT INTO countries (name, iso_code, currency_id)
  VALUES ('Day3 Test Country ' || v_suffix, 'Z' || upper(substr(v_suffix, 3, 2)), v_currency_id)
  RETURNING id INTO v_country_id;

  INSERT INTO staff (auth_user_id, role_type, full_name, email, active)
  VALUES (gen_random_uuid(), 'supervisor', 'Day3 Supervisor', 'day3.supervisor.' || v_suffix || '@example.test', true)
  RETURNING id INTO v_staff_id;

  INSERT INTO shippers (name, contact_email, vat_treatment, active)
  VALUES ('Day3 Test Shipper ' || v_suffix, 'shipper.' || v_suffix || '@example.test', 'outside_scope', true)
  RETURNING id INTO v_shipper_id;

  INSERT INTO hubs (shipper_id, name, country_id, full_address, postcode, active)
  VALUES (v_shipper_id, 'Day3 Test Hub', v_country_id, '1 Test Street', 'T3 3ST', true)
  RETURNING id INTO v_hub_id;

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO retailers (name, website_url, global_enabled)
  VALUES ('Day3 Test Retailer ' || v_suffix, 'https://retailer.example.test', true)
  RETURNING id INTO v_retailer_id;

  INSERT INTO retailer_accounts (
    retailer_id, shipper_id, account_email, account_username,
    credential_delivery_method, delivery_address_locked_to_hub_id, status
  )
  VALUES (
    v_retailer_id, v_shipper_id, 'retailer.account.' || v_suffix || '@example.test',
    'day3_' || v_suffix, 'pending_vault_upgrade', v_hub_id, 'active'
  )
  RETURNING id INTO v_retailer_account_id;

  INSERT INTO operators (email, phone, full_name, auth_user_id, active)
  VALUES ('operator.' || v_suffix || '@example.test', '+440000000000', 'Day3 Operator', gen_random_uuid(), true)
  RETURNING id INTO v_operator_id;

  INSERT INTO importers (shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_shipper_id, v_country_id, 'Day3 Importer Ltd ' || v_suffix, 'Day3 Importer', true)
  RETURNING id INTO v_importer_id;

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO couriers (name, tracking_url_template, added_by_staff_id, active)
  VALUES ('Day3 Courier ' || v_suffix, 'https://courier.example.test/track/{tracking_ref}', v_staff_id, true)
  RETURNING id INTO v_courier_id;

  -- ---------------------------------------------------------------------------
  -- A. Tracking-first path: tracking before invoice is valid and must not need
  -- platform funding match.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared, sop_version, status
  )
  VALUES (
    'DAY3-TF-' || v_suffix, 'AUTH-TF-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 100.00, 1, 'DAY3', 'pending_dva_funding'
  )
  RETURNING id INTO v_order_tracking_first;

  INSERT INTO order_tracking_submissions (
    order_id, courier_id, tracking_ref, tracking_date, submitted_by_operator_id
  )
  VALUES (v_order_tracking_first, v_courier_id, 'TRK-TF-' || v_suffix, current_date, v_operator_id);

  SELECT status INTO v_status FROM orders WHERE id = v_order_tracking_first;
  IF v_status <> 'evidence_collecting' THEN
    RAISE EXCEPTION 'FAIL: tracking-first status = %, expected evidence_collecting', v_status;
  END IF;

  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_order_tracking_first, v_retailer_id, v_retailer_account_id,
    'INV-TF-' || v_suffix, 'https://storage.example.test/inv-tf.pdf',
    v_operator_id, 'mindee'
  )
  RETURNING id INTO v_invoice_tracking_first;

  SELECT status INTO v_status FROM orders WHERE id = v_order_tracking_first;
  IF v_status <> 'reconciling' THEN
    RAISE EXCEPTION 'FAIL: tracking-first after invoice status = %, expected reconciling', v_status;
  END IF;

  -- ---------------------------------------------------------------------------
  -- B. Invoice-first path: invoice before tracking is valid and must move the
  -- order into reconciliation.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared, sop_version, status
  )
  VALUES (
    'DAY3-IF-' || v_suffix, 'AUTH-IF-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 120.00, 2, 'DAY3', 'pending_dva_funding'
  )
  RETURNING id INTO v_order_invoice_first;

  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_order_invoice_first, v_retailer_id, v_retailer_account_id,
    'INV-IF-' || v_suffix, 'https://storage.example.test/inv-if.pdf',
    v_operator_id, 'mindee'
  )
  RETURNING id INTO v_invoice_invoice_first;

  SELECT status INTO v_status FROM orders WHERE id = v_order_invoice_first;
  IF v_status <> 'reconciling' THEN
    RAISE EXCEPTION 'FAIL: invoice-first status = %, expected reconciling', v_status;
  END IF;

  INSERT INTO order_tracking_submissions (
    order_id, courier_id, tracking_ref, tracking_date, submitted_by_operator_id
  )
  VALUES (v_order_invoice_first, v_courier_id, 'TRK-IF-' || v_suffix, current_date, v_operator_id);

  SELECT status INTO v_status FROM orders WHERE id = v_order_invoice_first;
  IF v_status <> 'reconciling' THEN
    RAISE EXCEPTION 'FAIL: invoice-first after tracking status = %, expected still reconciling', v_status;
  END IF;

  -- ---------------------------------------------------------------------------
  -- C. Partial progressed subset with unresolved child exception.
  -- Declared: 5 items / £500. Progressed: 4 items / £400. Child exception: 1 / £100.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared, sop_version, status
  )
  VALUES (
    'DAY3-PART-' || v_suffix, 'AUTH-PART-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 500.00, 5, 'DAY3', 'pending_dva_funding'
  )
  RETURNING id INTO v_order_partial;

  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_order_partial, v_retailer_id, v_retailer_account_id,
    'INV-PART-' || v_suffix, 'https://storage.example.test/inv-part.pdf',
    v_operator_id, 'mindee'
  )
  RETURNING id INTO v_invoice_partial;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_invoice_partial, 1, 'SKU-GOOD', 'Four good items', 4, 'mixed',
    400.00, 'ocr_extracted', 4, 400.00, 'Y'
  )
  RETURNING id INTO v_ocr_line_progressed;

  -- Manual exception placeholder for the missing line.
  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_invoice_partial, 2, 'SKU-MISSING', 'Missing item manual exception', 1, 'mixed',
    100.00, 'manually_added', 0, 0.00, 'N'
  )
  RETURNING id INTO v_manual_line_delete_test;

  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome,
    liable_party, stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_order_partial, v_operator_id, 'missing', 'refund',
    'retailer', 'at_reconciliation', 100.00, 'Day 3 missing line child exception', 'raised', 'DAY3'
  )
  RETURNING id INTO v_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_dispute_id, v_manual_line_delete_test, 1, 100.00,
    'affected', 'refund_pending_approval', 'refund'
  )
  RETURNING id INTO v_dispute_line_id;

  PERFORM recompute_order_status(v_order_partial);

  SELECT status INTO v_status FROM orders WHERE id = v_order_partial;
  IF v_status <> 'partially_progressed' THEN
    RAISE EXCEPTION 'FAIL: partial order status = %, expected partially_progressed', v_status;
  END IF;

  SELECT order_has_progressed_subset(v_order_partial) INTO v_bool;
  IF v_bool IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: order_has_progressed_subset returned %, expected true', v_bool;
  END IF;

  SELECT qty_unresolved, amount_unresolved_gbp
    INTO v_qty_unresolved, v_amount_unresolved
  FROM order_reconciliation_vw
  WHERE order_id = v_order_partial;

  IF v_qty_unresolved <> 1 OR v_amount_unresolved <> 100.00 THEN
    RAISE EXCEPTION 'FAIL: unresolved qty/amount = % / %, expected 1 / 100.00', v_qty_unresolved, v_amount_unresolved;
  END IF;

  -- ---------------------------------------------------------------------------
  -- D. Manual lines must be deletable when no child record depends on them.
  -- ---------------------------------------------------------------------------
  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_invoice_partial, 3, 'SKU-MANUAL-DELETE', 'Manual line delete test', 1, 'mixed',
    10.00, 'manually_added', 0, 0.00, 'N'
  )
  RETURNING id INTO v_manual_line_delete_test;

  DELETE FROM supplier_invoice_lines WHERE id = v_manual_line_delete_test;

  IF EXISTS (SELECT 1 FROM supplier_invoice_lines WHERE id = v_manual_line_delete_test) THEN
    RAISE EXCEPTION 'FAIL: manual line was not deleted, expected manual lines to be deletable';
  END IF;

  -- ---------------------------------------------------------------------------
  -- E. OCR-source lines must NOT be deletable. This should be DB-enforced, not
  -- only UI-enforced. The line is intentionally not referenced by dispute_lines
  -- so FK constraints cannot mask a missing OCR-delete guard.
  -- ---------------------------------------------------------------------------
  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_invoice_partial, 4, 'SKU-OCR-DELETE', 'OCR delete protection test', 1, 'mixed',
    10.00, 'ocr_extracted', 1, 10.00, 'N'
  )
  RETURNING id INTO v_ocr_line_delete_test;

  BEGIN
    DELETE FROM supplier_invoice_lines WHERE id = v_ocr_line_delete_test;
  EXCEPTION WHEN OTHERS THEN
    v_ocr_delete_blocked := true;
  END;

  IF v_ocr_delete_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: OCR source line was deletable. Add DB trigger to block DELETE where line_source = ocr_extracted.';
  END IF;
END $$;
ROLLBACK;

-- ============================================================================
-- BEGIN INCLUDED TEST: day4_child_exception_refund_replacement_smoke_test.sql
-- ============================================================================
-- =============================================================================
-- day4_child_exception_refund_replacement_smoke_test.sql
-- Multi Tenant Platform Build — Day 4 child exception / refund gate / replacement child smoke test
--
-- Run after Day 3 passed in the same fresh test project, or after:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql
--   4. closure_v2_seed.sql
--   5. day2_final_funding_regression_smoke_test_v2.sql
--   6. day3_evidence_ocr_smoke_test.sql
--
-- Purpose:
--   Proves the Day 4 backend controls required by the authority stack + role matrices:
--   - replacement child order can be created from a linked dispute line
--   - replacement child is linked to parent + dispute + dispute line
--   - replacement child does not become a fresh DVA-funded order
--   - duplicate replacement child creation is blocked
--   - replacement-of-replacement is blocked
--   - replacement invoice can attach to the replacement child order, not the parent
--   - refund path cannot move to retailer_draft_ready before supervisor/admin approval
--   - refund path can move to retailer_draft_ready after approval
--
-- This test intentionally rolls back all data.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_suffix text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_currency_id uuid;
  v_country_id uuid;
  v_staff_id uuid;
  v_shipper_id uuid;
  v_hub_id uuid;
  v_retailer_id uuid;
  v_retailer_account_id uuid;
  v_operator_id uuid;
  v_importer_id uuid;
  v_markup_category_id uuid;

  v_parent_order_id uuid;
  v_parent_invoice_id uuid;
  v_progressed_line_id uuid;
  v_replacement_line_id uuid;
  v_refund_line_id uuid;

  v_replacement_dispute_id uuid;
  v_replacement_dispute_line_id uuid;
  v_refund_dispute_id uuid;
  v_refund_dispute_line_id uuid;

  v_child_order_id uuid;
  v_child_invoice_id uuid;
  v_status text;
  v_text text;
  v_count int;
  v_bool boolean;
  v_blocked boolean := false;
BEGIN
  -- ---------------------------------------------------------------------------
  -- Minimal tenant/reference setup. Random suffix avoids collisions if a prior
  -- failed test left residue outside rollback.
  -- ---------------------------------------------------------------------------
  INSERT INTO currencies (code, symbol)
  VALUES ('Y' || upper(substr(v_suffix, 1, 2)), '¤')
  RETURNING id INTO v_currency_id;

  INSERT INTO countries (name, iso_code, currency_id)
  VALUES ('Day4 Test Country ' || v_suffix, 'Y' || upper(substr(v_suffix, 3, 2)), v_currency_id)
  RETURNING id INTO v_country_id;

  INSERT INTO staff (auth_user_id, role_type, full_name, email, active)
  VALUES (gen_random_uuid(), 'supervisor', 'Day4 Supervisor', 'day4.supervisor.' || v_suffix || '@example.test', true)
  RETURNING id INTO v_staff_id;

  INSERT INTO shippers (name, contact_email, vat_treatment, active)
  VALUES ('Day4 Test Shipper ' || v_suffix, 'shipper.' || v_suffix || '@example.test', 'outside_scope', true)
  RETURNING id INTO v_shipper_id;

  INSERT INTO hubs (shipper_id, name, country_id, full_address, postcode, active)
  VALUES (v_shipper_id, 'Day4 Test Hub', v_country_id, '1 Test Street', 'T4 4ST', true)
  RETURNING id INTO v_hub_id;

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO markup_categories (shipper_id, category_name, default_markup_pct, active)
  VALUES (v_shipper_id, 'Day4 Test Category ' || v_suffix, 0.000, true)
  RETURNING id INTO v_markup_category_id;

  INSERT INTO retailers (name, website_url, global_enabled)
  VALUES ('Day4 Test Retailer ' || v_suffix, 'https://retailer.example.test', true)
  RETURNING id INTO v_retailer_id;

  INSERT INTO retailer_accounts (
    retailer_id, shipper_id, account_email, account_username,
    credential_delivery_method, delivery_address_locked_to_hub_id, status
  )
  VALUES (
    v_retailer_id, v_shipper_id, 'retailer.account.' || v_suffix || '@example.test',
    'day4_' || v_suffix, 'pending_vault_upgrade', v_hub_id, 'active'
  )
  RETURNING id INTO v_retailer_account_id;

  INSERT INTO operators (email, phone, full_name, auth_user_id, active)
  VALUES ('operator.' || v_suffix || '@example.test', '+440000000000', 'Day4 Operator', gen_random_uuid(), true)
  RETURNING id INTO v_operator_id;

  INSERT INTO importers (shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_shipper_id, v_country_id, 'Day4 Importer Ltd ' || v_suffix, 'Day4 Importer', true)
  RETURNING id INTO v_importer_id;

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  -- ---------------------------------------------------------------------------
  -- Parent order: 5 declared items / £500. 3 progress cleanly; 1 replacement
  -- child exception; 1 refund child exception.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  )
  VALUES (
    'DAY4-PARENT-' || v_suffix, 'AUTH-DAY4-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 500.00, 5,
    'DAY4', 'pending_dva_funding', now()
  )
  RETURNING id INTO v_parent_order_id;

  INSERT INTO order_category_lines (
    order_id, markup_category_id, qty, amount_inc_vat_gbp,
    markup_pct_applied, markup_gbp_calculated
  )
  VALUES (v_parent_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00);

  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_parent_order_id, v_retailer_id, v_retailer_account_id,
    'INV-DAY4-PARENT-' || v_suffix, 'https://storage.example.test/day4-parent.pdf',
    v_operator_id, 'mindee'
  )
  RETURNING id INTO v_parent_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_parent_invoice_id, 1, 'SKU-GOOD', 'Three good items', 3, 'mixed',
    300.00, 'ocr_extracted', 3, 300.00, 'Y'
  )
  RETURNING id INTO v_progressed_line_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_parent_invoice_id, 2, 'SKU-REPLACE', 'Replacement needed', 1, 'mixed',
    100.00, 'manually_added', 0, 0.00, 'N'
  )
  RETURNING id INTO v_replacement_line_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_parent_invoice_id, 3, 'SKU-REFUND', 'Refund needed', 1, 'mixed',
    100.00, 'manually_added', 0, 0.00, 'N'
  )
  RETURNING id INTO v_refund_line_id;

  -- Replacement child exception.
  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome,
    liable_party, stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_parent_order_id, v_operator_id, 'missing', 'replacement',
    'retailer', 'at_reconciliation', 100.00, 'Day4 replacement child exception', 'raised', 'DAY4'
  )
  RETURNING id INTO v_replacement_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_replacement_dispute_id, v_replacement_line_id, 1, 100.00,
    'affected', 'remedy_selected', 'replacement'
  )
  RETURNING id INTO v_replacement_dispute_line_id;

  -- Refund child exception.
  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome,
    liable_party, stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_parent_order_id, v_operator_id, 'missing', 'refund',
    'retailer', 'at_reconciliation', 100.00, 'Day4 refund child exception', 'raised', 'DAY4'
  )
  RETURNING id INTO v_refund_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_refund_dispute_id, v_refund_line_id, 1, 100.00,
    'affected', 'refund_pending_approval', 'refund'
  )
  RETURNING id INTO v_refund_dispute_line_id;

  PERFORM recompute_order_status(v_parent_order_id);

  SELECT status INTO v_status FROM orders WHERE id = v_parent_order_id;
  IF v_status <> 'partially_progressed' THEN
    RAISE EXCEPTION 'FAIL: parent status = %, expected partially_progressed before child resolution', v_status;
  END IF;

  -- ---------------------------------------------------------------------------
  -- A. Replacement child creation.
  -- ---------------------------------------------------------------------------
  v_child_order_id := create_replacement_child_order(
    v_parent_order_id,
    v_replacement_dispute_line_id,
    v_staff_id,
    'Day4 smoke test replacement child'
  );

  SELECT order_type, status
    INTO v_text, v_status
  FROM orders
  WHERE id = v_child_order_id
    AND parent_order_id = v_parent_order_id
    AND replacement_source_dispute_line_id = v_replacement_dispute_line_id;

  IF v_text IS DISTINCT FROM 'replacement_child' THEN
    RAISE EXCEPTION 'FAIL: replacement child order_type = %, expected replacement_child', v_text;
  END IF;

  IF EXISTS (SELECT 1 FROM orders WHERE id = v_child_order_id AND funded_at IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL: replacement child has funded_at stamped. Replacement child should not be a fresh DVA-funded order.';
  END IF;

  IF EXISTS (SELECT 1 FROM order_funding_events WHERE order_id = v_child_order_id) THEN
    RAISE EXCEPTION 'FAIL: replacement child has order_funding_events. Replacement child should not create fresh funding events.';
  END IF;

  SELECT replacement_child_order_id INTO v_child_order_id
  FROM disputes
  WHERE id = v_replacement_dispute_id;

  IF v_child_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: disputes.replacement_child_order_id was not set';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM dispute_lines
    WHERE id = v_replacement_dispute_line_id
      AND resolved_via_child_order_id = v_child_order_id
      AND conversation_status = 'resolved_replacement'
      AND resolution_method = 'replacement'
      AND resolved_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: dispute line was not resolved through the replacement child order';
  END IF;

  SELECT entity_requires_admin_review('order', v_child_order_id) INTO v_bool;
  IF v_bool IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: replacement child did not surface admin review';
  END IF;

  BEGIN
    PERFORM create_replacement_child_order(
      v_parent_order_id,
      v_replacement_dispute_line_id,
      v_staff_id,
      'duplicate replacement should fail'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: duplicate replacement child creation was allowed';
  END IF;

  v_blocked := false;
  BEGIN
    PERFORM create_replacement_child_order(
      v_child_order_id,
      v_replacement_dispute_line_id,
      v_staff_id,
      'replacement of replacement should fail'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: replacement-of-replacement was allowed';
  END IF;

  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_child_order_id, v_retailer_id, v_retailer_account_id,
    'INV-DAY4-CHILD-' || v_suffix, 'https://storage.example.test/day4-child.pdf',
    v_operator_id, 'mindee'
  )
  RETURNING id INTO v_child_invoice_id;

  IF NOT EXISTS (
    SELECT 1 FROM supplier_invoices WHERE id = v_child_invoice_id AND order_id = v_child_order_id
  ) THEN
    RAISE EXCEPTION 'FAIL: replacement invoice was not attached to the replacement child order';
  END IF;

  -- ---------------------------------------------------------------------------
  -- B. Refund gate enforcement.
  -- A refund child must not move to retailer_draft_ready before staff approval.
  -- This must be backend-enforced, not just UI-intended.
  -- ---------------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    UPDATE dispute_lines
    SET conversation_status = 'retailer_draft_ready'
    WHERE id = v_refund_dispute_line_id;
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: refund gate not enforced. Refund child moved to retailer_draft_ready before refund_approved_by_staff_id/refund_approved_at existed.';
  END IF;

  UPDATE disputes
  SET refund_approved_by_staff_id = v_staff_id,
      refund_approved_at = now()
  WHERE id = v_refund_dispute_id;

  UPDATE dispute_lines
  SET conversation_status = 'retailer_draft_ready'
  WHERE id = v_refund_dispute_line_id;

  SELECT conversation_status INTO v_status
  FROM dispute_lines
  WHERE id = v_refund_dispute_line_id;

  IF v_status <> 'retailer_draft_ready' THEN
    RAISE EXCEPTION 'FAIL: approved refund child status = %, expected retailer_draft_ready', v_status;
  END IF;
END $$;
ROLLBACK;

-- ============================================================================
-- BEGIN INCLUDED TEST: day5_shipping_handoff_smoke_test.sql
-- ============================================================================
-- =============================================================================
-- day5_shipping_handoff_smoke_test.sql
-- Multi Tenant Platform Build — Day 5 ready-for-shipment / shipping quote smoke test
--
-- Run after Day 4 passed in the same fresh test project, or after:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql
--   4. closure_v2_seed.sql
--   5. day2_final_funding_regression_smoke_test_v2.sql
--   6. day3_evidence_ocr_smoke_test.sql
--   7. day4_child_exception_refund_replacement_smoke_test.sql
--
-- Purpose:
--   Proves the Day 5 backend controls required by the authority stack + role matrices:
--   - draft shipping quote is not shipper-bookable
--   - confirmed_ready_for_booking is the explicit supervisor/admin handoff
--   - only progressed subset should be confirmable into the shipper lane
--   - unresolved child exception value must not contaminate shipment scope
--   - booking a confirmed quote moves the order to shipment_booked
--   - a multi-order quote must update every linked order, not only the first
--
-- This test intentionally rolls back all data.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_suffix text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_currency_id uuid;
  v_country_id uuid;
  v_staff_id uuid;
  v_shipper_id uuid;
  v_hub_id uuid;
  v_retailer_id uuid;
  v_retailer_account_id uuid;
  v_operator_id uuid;
  v_importer_id uuid;
  v_markup_category_id uuid;
  v_courier_id uuid;

  v_valid_order_id uuid;
  v_valid_invoice_id uuid;
  v_valid_good_line_id uuid;
  v_valid_exception_line_id uuid;
  v_valid_dispute_id uuid;
  v_valid_dispute_line_id uuid;
  v_valid_quote_id uuid;

  v_bad_order_id uuid;
  v_bad_invoice_id uuid;
  v_bad_line_id uuid;
  v_bad_quote_id uuid;

  v_overscope_order_id uuid;
  v_overscope_invoice_id uuid;
  v_overscope_good_line_id uuid;
  v_overscope_exception_line_id uuid;
  v_overscope_dispute_id uuid;
  v_overscope_dispute_line_id uuid;
  v_overscope_quote_id uuid;

  v_multi_order_1 uuid;
  v_multi_order_2 uuid;
  v_multi_invoice_1 uuid;
  v_multi_invoice_2 uuid;
  v_multi_quote_id uuid;

  v_status text;
  v_status_1 text;
  v_status_2 text;
  v_blocked boolean;
BEGIN
  -- ---------------------------------------------------------------------------
  -- Minimal tenant/reference setup. Random suffix avoids collisions if a prior
  -- failed test left residue outside rollback.
  -- ---------------------------------------------------------------------------
  INSERT INTO currencies (code, symbol)
  VALUES ('Z' || upper(substr(v_suffix, 1, 2)), '¤')
  RETURNING id INTO v_currency_id;

  INSERT INTO countries (name, iso_code, currency_id)
  VALUES ('Day5 Test Country ' || v_suffix, 'Z' || upper(substr(v_suffix, 3, 2)), v_currency_id)
  RETURNING id INTO v_country_id;

  INSERT INTO staff (auth_user_id, role_type, full_name, email, active)
  VALUES (gen_random_uuid(), 'supervisor', 'Day5 Supervisor', 'day5.supervisor.' || v_suffix || '@example.test', true)
  RETURNING id INTO v_staff_id;

  INSERT INTO shippers (name, contact_email, vat_treatment, active)
  VALUES ('Day5 Test Shipper ' || v_suffix, 'shipper.' || v_suffix || '@example.test', 'outside_scope', true)
  RETURNING id INTO v_shipper_id;

  INSERT INTO hubs (shipper_id, name, country_id, full_address, postcode, active)
  VALUES (v_shipper_id, 'Day5 Test Hub', v_country_id, '1 Test Street', 'T5 5ST', true)
  RETURNING id INTO v_hub_id;

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO couriers (name, tracking_url_template, added_by_staff_id, active)
  VALUES ('Day5 Courier ' || v_suffix, 'https://tracking.example.test/{tracking_ref}', v_staff_id, true)
  RETURNING id INTO v_courier_id;

  INSERT INTO markup_categories (shipper_id, category_name, default_markup_pct, active)
  VALUES (v_shipper_id, 'Day5 Test Category ' || v_suffix, 0.000, true)
  RETURNING id INTO v_markup_category_id;

  INSERT INTO retailers (name, website_url, global_enabled)
  VALUES ('Day5 Test Retailer ' || v_suffix, 'https://retailer.example.test', true)
  RETURNING id INTO v_retailer_id;

  INSERT INTO retailer_accounts (
    retailer_id, shipper_id, account_email, account_username,
    credential_delivery_method, delivery_address_locked_to_hub_id, status
  )
  VALUES (
    v_retailer_id, v_shipper_id, 'retailer.account.' || v_suffix || '@example.test',
    'day5_' || v_suffix, 'pending_vault_upgrade', v_hub_id, 'active'
  )
  RETURNING id INTO v_retailer_account_id;

  INSERT INTO operators (email, phone, full_name, auth_user_id, active)
  VALUES ('operator.' || v_suffix || '@example.test', '+440000000000', 'Day5 Operator', gen_random_uuid(), true)
  RETURNING id INTO v_operator_id;

  INSERT INTO importers (shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_shipper_id, v_country_id, 'Day5 Importer Ltd ' || v_suffix, 'Day5 Importer', true)
  RETURNING id INTO v_importer_id;

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  -- ---------------------------------------------------------------------------
  -- A. Valid partially-progressed order: 4/5 items progressed, 1 open child.
  --    This is the core Day 5 handoff case: progressed subset may move to
  --    shipment while the unresolved child stays outside shipment scope.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  )
  VALUES (
    'DAY5-VALID-' || v_suffix, 'AUTH-DAY5-VALID-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 500.00, 5,
    'DAY5', 'pending_dva_funding', now()
  )
  RETURNING id INTO v_valid_order_id;

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES (v_valid_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00);

  INSERT INTO supplier_invoices (order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url, uploaded_by_operator_id, ocr_service_used)
  VALUES (v_valid_order_id, v_retailer_id, v_retailer_account_id, 'INV-DAY5-VALID-' || v_suffix, 'https://storage.example.test/day5-valid.pdf', v_operator_id, 'mindee')
  RETURNING id INTO v_valid_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  )
  VALUES (
    v_valid_invoice_id, 1, 'SKU-VALID-GOOD', 'Four progressed items', 4, 'mixed',
    400.00, 'ocr_extracted', 4, 400.00, 'Y'
  )
  RETURNING id INTO v_valid_good_line_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  )
  VALUES (
    v_valid_invoice_id, 2, 'SKU-VALID-OPEN', 'One unresolved item', 1, 'mixed',
    100.00, 'manually_added', 0, 0.00, 'N'
  )
  RETURNING id INTO v_valid_exception_line_id;

  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome,
    liable_party, stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_valid_order_id, v_operator_id, 'missing', 'refund',
    'retailer', 'at_reconciliation', 100.00, 'Day5 open child must stay outside shipment scope', 'raised', 'DAY5'
  )
  RETURNING id INTO v_valid_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_valid_dispute_id, v_valid_exception_line_id, 1, 100.00,
    'affected', 'refund_pending_approval', 'refund'
  )
  RETURNING id INTO v_valid_dispute_line_id;

  PERFORM recompute_order_status(v_valid_order_id);

  SELECT status INTO v_status FROM orders WHERE id = v_valid_order_id;
  IF v_status <> 'partially_progressed' THEN
    RAISE EXCEPTION 'FAIL: valid order status = %, expected partially_progressed before handoff', v_status;
  END IF;

  INSERT INTO shipping_quotes (shipper_id, quote_gbp_total, courier_id, status)
  VALUES (v_shipper_id, 80.00, v_courier_id, 'draft_quote')
  RETURNING id INTO v_valid_quote_id;

  INSERT INTO shipping_quote_orders (
    shipping_quote_id, order_id, order_value_gbp, apportionment_pct, apportioned_shipping_gbp
  )
  VALUES (v_valid_quote_id, v_valid_order_id, 400.00, 100.0000, 80.00);

  -- Draft quote must not be directly bookable by the shipper.
  v_blocked := false;
  BEGIN
    UPDATE shipping_quotes
    SET status = 'booked',
        booking_ref = 'BOOK-DIRECT-' || v_suffix
    WHERE id = v_valid_quote_id;
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: draft shipping quote was directly bookable; expected draft_quote -> booked to be blocked';
  END IF;

  -- Supervisor/admin explicit handoff: draft_quote -> confirmed_ready_for_booking.
  PERFORM mark_shipping_quote_confirmed_ready_for_booking(v_valid_quote_id, v_staff_id);

  SELECT status INTO v_status FROM shipping_quotes WHERE id = v_valid_quote_id;
  IF v_status <> 'confirmed_ready_for_booking' THEN
    RAISE EXCEPTION 'FAIL: shipping quote status = %, expected confirmed_ready_for_booking', v_status;
  END IF;

  SELECT status INTO v_status FROM orders WHERE id = v_valid_order_id;
  IF v_status <> 'ready_for_shipment' THEN
    RAISE EXCEPTION 'FAIL: order status after handoff = %, expected ready_for_shipment', v_status;
  END IF;

  -- Booking the confirmed quote moves the order into shipment_booked.
  UPDATE shipping_quotes
  SET status = 'booked',
      booking_ref = 'BOOK-DAY5-' || v_suffix
  WHERE id = v_valid_quote_id;

  SELECT status INTO v_status FROM orders WHERE id = v_valid_order_id;
  IF v_status <> 'shipment_booked' THEN
    RAISE EXCEPTION 'FAIL: order status after booking = %, expected shipment_booked', v_status;
  END IF;

  -- ---------------------------------------------------------------------------
  -- B. Bad quote: invoice exists but no progressed subset. This must not become
  --    shipper-actionable just because a quote was created.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  )
  VALUES (
    'DAY5-BAD-NOPROGRESS-' || v_suffix, 'AUTH-DAY5-BAD-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 300.00, 3,
    'DAY5', 'pending_dva_funding', now()
  )
  RETURNING id INTO v_bad_order_id;

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES (v_bad_order_id, v_markup_category_id, 3, 300.00, 0.000, 0.00);

  INSERT INTO supplier_invoices (order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url, uploaded_by_operator_id, ocr_service_used)
  VALUES (v_bad_order_id, v_retailer_id, v_retailer_account_id, 'INV-DAY5-BAD-' || v_suffix, 'https://storage.example.test/day5-bad.pdf', v_operator_id, 'mindee')
  RETURNING id INTO v_bad_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  )
  VALUES (
    v_bad_invoice_id, 1, 'SKU-BAD-NOPROGRESS', 'No progressed lines', 3, 'mixed',
    300.00, 'ocr_extracted', 0, 0.00, 'N'
  )
  RETURNING id INTO v_bad_line_id;

  PERFORM recompute_order_status(v_bad_order_id);

  INSERT INTO shipping_quotes (shipper_id, quote_gbp_total, courier_id, status)
  VALUES (v_shipper_id, 60.00, v_courier_id, 'draft_quote')
  RETURNING id INTO v_bad_quote_id;

  INSERT INTO shipping_quote_orders (shipping_quote_id, order_id, order_value_gbp, apportionment_pct, apportioned_shipping_gbp)
  VALUES (v_bad_quote_id, v_bad_order_id, 300.00, 100.0000, 60.00);

  v_blocked := false;
  BEGIN
    PERFORM mark_shipping_quote_confirmed_ready_for_booking(v_bad_quote_id, v_staff_id);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: shipping quote confirmation did not block an order with no progressed subset';
  END IF;

  -- ---------------------------------------------------------------------------
  -- C. Bad quote: partial order has £400 progressed, but quote tries to include
  --    £500. Unresolved child value must not contaminate shipment scope.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  )
  VALUES (
    'DAY5-BAD-OVERSCOPE-' || v_suffix, 'AUTH-DAY5-OVER-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 500.00, 5,
    'DAY5', 'pending_dva_funding', now()
  )
  RETURNING id INTO v_overscope_order_id;

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES (v_overscope_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00);

  INSERT INTO supplier_invoices (order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url, uploaded_by_operator_id, ocr_service_used)
  VALUES (v_overscope_order_id, v_retailer_id, v_retailer_account_id, 'INV-DAY5-OVER-' || v_suffix, 'https://storage.example.test/day5-over.pdf', v_operator_id, 'mindee')
  RETURNING id INTO v_overscope_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  )
  VALUES (
    v_overscope_invoice_id, 1, 'SKU-OVER-GOOD', 'Four progressed items', 4, 'mixed',
    400.00, 'ocr_extracted', 4, 400.00, 'Y'
  )
  RETURNING id INTO v_overscope_good_line_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  )
  VALUES (
    v_overscope_invoice_id, 2, 'SKU-OVER-OPEN', 'Unresolved item', 1, 'mixed',
    100.00, 'manually_added', 0, 0.00, 'N'
  )
  RETURNING id INTO v_overscope_exception_line_id;

  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome,
    liable_party, stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_overscope_order_id, v_operator_id, 'missing', 'refund',
    'retailer', 'at_reconciliation', 100.00, 'Day5 unresolved value must stay outside shipment scope', 'raised', 'DAY5'
  )
  RETURNING id INTO v_overscope_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_overscope_dispute_id, v_overscope_exception_line_id, 1, 100.00,
    'affected', 'refund_pending_approval', 'refund'
  )
  RETURNING id INTO v_overscope_dispute_line_id;

  PERFORM recompute_order_status(v_overscope_order_id);

  INSERT INTO shipping_quotes (shipper_id, quote_gbp_total, courier_id, status)
  VALUES (v_shipper_id, 90.00, v_courier_id, 'draft_quote')
  RETURNING id INTO v_overscope_quote_id;

  -- This intentionally includes £500 even though only £400 progressed.
  INSERT INTO shipping_quote_orders (shipping_quote_id, order_id, order_value_gbp, apportionment_pct, apportioned_shipping_gbp)
  VALUES (v_overscope_quote_id, v_overscope_order_id, 500.00, 100.0000, 90.00);

  v_blocked := false;
  BEGIN
    PERFORM mark_shipping_quote_confirmed_ready_for_booking(v_overscope_quote_id, v_staff_id);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF v_blocked IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: shipping quote confirmation did not block over-scoped shipment value. Progressed value was 400 but quote included 500.';
  END IF;

  -- ---------------------------------------------------------------------------
  -- D. Multi-order quote: every linked order must move to ready_for_shipment.
  --    This protects future quote batching without changing Phase 1 rule that
  --    one order has one active shipper lane.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  )
  VALUES (
    'DAY5-MULTI-1-' || v_suffix, 'AUTH-DAY5-M1-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 100.00, 1,
    'DAY5', 'pending_dva_funding', now()
  )
  RETURNING id INTO v_multi_order_1;

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES (v_multi_order_1, v_markup_category_id, 1, 100.00, 0.000, 0.00);

  INSERT INTO supplier_invoices (order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url, uploaded_by_operator_id, ocr_service_used)
  VALUES (v_multi_order_1, v_retailer_id, v_retailer_account_id, 'INV-DAY5-M1-' || v_suffix, 'https://storage.example.test/day5-m1.pdf', v_operator_id, 'mindee')
  RETURNING id INTO v_multi_invoice_1;

  INSERT INTO supplier_invoice_lines (supplier_invoice_id, line_order, retailer_sku, description, qty, size, amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn)
  VALUES (v_multi_invoice_1, 1, 'SKU-M1', 'Progressed order 1', 1, 'one', 100.00, 'ocr_extracted', 1, 100.00, 'Y');

  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  )
  VALUES (
    'DAY5-MULTI-2-' || v_suffix, 'AUTH-DAY5-M2-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 200.00, 2,
    'DAY5', 'pending_dva_funding', now()
  )
  RETURNING id INTO v_multi_order_2;

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES (v_multi_order_2, v_markup_category_id, 2, 200.00, 0.000, 0.00);

  INSERT INTO supplier_invoices (order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url, uploaded_by_operator_id, ocr_service_used)
  VALUES (v_multi_order_2, v_retailer_id, v_retailer_account_id, 'INV-DAY5-M2-' || v_suffix, 'https://storage.example.test/day5-m2.pdf', v_operator_id, 'mindee')
  RETURNING id INTO v_multi_invoice_2;

  INSERT INTO supplier_invoice_lines (supplier_invoice_id, line_order, retailer_sku, description, qty, size, amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn)
  VALUES (v_multi_invoice_2, 1, 'SKU-M2', 'Progressed order 2', 2, 'two', 200.00, 'ocr_extracted', 2, 200.00, 'Y');

  PERFORM recompute_order_status(v_multi_order_1);
  PERFORM recompute_order_status(v_multi_order_2);

  INSERT INTO shipping_quotes (shipper_id, quote_gbp_total, courier_id, status)
  VALUES (v_shipper_id, 100.00, v_courier_id, 'draft_quote')
  RETURNING id INTO v_multi_quote_id;

  INSERT INTO shipping_quote_orders (shipping_quote_id, order_id, order_value_gbp, apportionment_pct, apportioned_shipping_gbp)
  VALUES
    (v_multi_quote_id, v_multi_order_1, 100.00, 33.3333, 33.33),
    (v_multi_quote_id, v_multi_order_2, 200.00, 66.6667, 66.67);

  PERFORM mark_shipping_quote_confirmed_ready_for_booking(v_multi_quote_id, v_staff_id);

  SELECT status INTO v_status_1 FROM orders WHERE id = v_multi_order_1;
  SELECT status INTO v_status_2 FROM orders WHERE id = v_multi_order_2;

  IF v_status_1 <> 'ready_for_shipment' OR v_status_2 <> 'ready_for_shipment' THEN
    RAISE EXCEPTION 'FAIL: multi-order quote did not update every linked order. order1 %, order2 %, expected both ready_for_shipment', v_status_1, v_status_2;
  END IF;
END $$;
ROLLBACK;

-- ============================================================================
-- FINAL COMBINED PASS REPORT
-- ============================================================================

-- ============================================================================
-- END INCLUDED TEST: day2_to_day5_combined_regression_smoke_test.sql
-- ============================================================================


-- ============================================================================
-- BEGIN INCLUDED TEST: day6_accounting_vat_sage_queue_smoke_test.sql
-- ============================================================================

-- day6_accounting_vat_sage_queue_smoke_test.sql
-- Multi Tenant Platform Build — Day 6 backend smoke test
-- Run after the clean Day 2-5 combined regression has passed.
--
-- Scope:
--   A. Accounting release gates
--   B. VAT release gates and VAT workings
--   C. Sage posting queue contract / idempotency shell
--
-- This does NOT call Sage Cloud. It proves the backend release/queue contract
-- that the Sage adapter will later consume.
--
-- If any check fails, execution stops with the first error.
-- If everything passes, this returns one final result set.

BEGIN;

DO $$
DECLARE
  v_staff_id uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_retailer_account_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_markup_category_id uuid := gen_random_uuid();
  v_country_id uuid;
  v_installation_id uuid;
  v_sage_config_id uuid := gen_random_uuid();

  v_unfunded_order_id uuid := gen_random_uuid();
  v_child_blocked_order_id uuid := gen_random_uuid();
  v_accounting_ok_order_id uuid := gen_random_uuid();
  v_vat_incomplete_order_id uuid := gen_random_uuid();
  v_vat_ok_order_id uuid := gen_random_uuid();
  v_replacement_order_id uuid := gen_random_uuid();

  v_invoice_id uuid;
  v_line_id uuid;
  v_dispute_id uuid;
  v_dispute_line_id uuid;
  v_quote_id uuid;
  v_working_id_1 uuid;
  v_working_id_2 uuid;
  v_tax_point date;
  v_vat_release_at timestamptz;
  v_accounting_ready_at timestamptz;
  v_count int;
  v_box6 numeric;
  v_queue_id uuid := gen_random_uuid();
  v_duplicate_blocked boolean := false;
  v_blocked boolean;
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preflight checks.
  -- ---------------------------------------------------------------------------
  IF to_regprocedure('public.mark_order_accounting_release_ready(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: mark_order_accounting_release_ready(uuid, uuid) missing';
  END IF;

  IF to_regprocedure('public.approve_vat_release(uuid, uuid, jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: approve_vat_release(uuid, uuid, jsonb) missing';
  END IF;

  IF to_regprocedure('public.post_to_vat_return_workings(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: post_to_vat_return_workings(uuid) missing';
  END IF;

  IF to_regclass('public.sage_postings') IS NULL THEN
    RAISE EXCEPTION 'FAIL: sage_postings table missing';
  END IF;

  SELECT id INTO v_country_id FROM countries WHERE iso_code = 'GHA' LIMIT 1;
  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: GHA country seed missing';
  END IF;

  SELECT id INTO v_installation_id FROM installation LIMIT 1;
  IF v_installation_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: installation seed missing';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 1. Minimal tenant/config fixture.
  -- ---------------------------------------------------------------------------
  INSERT INTO staff (id, auth_user_id, role_type, full_name, email, active)
  VALUES (v_staff_id, gen_random_uuid(), 'admin', 'Day 6 Smoke Admin', 'day6-admin-' || left(v_staff_id::text, 8) || '@example.test', true);

  INSERT INTO sage_config (
    id, installation_id, version_number, effective_from, effective_to, sage_tenant_id,
    sage_api_credentials_vault_ref, default_sales_tax_code, default_purchase_tax_code,
    outside_scope_tax_code, ar_nominal_code, ap_retailer_nominal_code, ap_shipper_nominal_code,
    sales_exports_nominal_code, cogs_goods_nominal_code, cogs_shipping_nominal_code,
    fx_gain_loss_nominal_code, sales_adjustment_zero_rating_nominal_code,
    vat_input_nominal_code, vat_output_nominal_code, vat_liability_nominal_code,
    vat_adjustments_nominal_code, created_by_staff_id, reason_for_change
  )
  VALUES (
    v_sage_config_id, v_installation_id, 906001, now(), now() + interval '100 years', 'day6-smoke-tenant',
    'vault://day6-smoke', 'T0', 'T1', 'OS', '1100', '5000', '5100',
    '4000', '6000', '6100', '7900', '4090', '2201', '2202', '2200',
    '2290', v_staff_id, 'Day 6 smoke test config'
  );

  INSERT INTO shippers (id, name, contact_email, vat_treatment, active)
  VALUES (v_shipper_id, 'Day 6 Smoke Shipper', 'day6-shipper-' || left(v_shipper_id::text, 8) || '@example.test', 'outside_scope', true);

  INSERT INTO hubs (id, shipper_id, name, country_id, full_address, active)
  VALUES (v_hub_id, v_shipper_id, 'Day 6 Smoke Hub', v_country_id, 'Day 6 Smoke Address', true);

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO retailers (id, name, website_url, global_enabled)
  VALUES (v_retailer_id, 'Day 6 Smoke Retailer', 'https://day6.example.test', true);

  INSERT INTO retailer_accounts (
    id, retailer_id, shipper_id, account_email, credential_delivery_method,
    delivery_address_locked_to_hub_id, status
  )
  VALUES (
    v_retailer_account_id, v_retailer_id, v_shipper_id,
    'retailer-account-' || left(v_retailer_account_id::text, 8) || '@example.test',
    'vault_brokered', v_hub_id, 'active'
  );

  INSERT INTO markup_categories (id, shipper_id, category_name, default_markup_pct, active)
  VALUES (v_markup_category_id, v_shipper_id, 'Day 6 Smoke Category', 0.000, true);

  INSERT INTO importers (id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_importer_id, v_shipper_id, v_country_id, 'Day 6 Importer Ltd', 'Day 6 Importer', true);

  INSERT INTO operators (id, email, full_name, auth_user_id, active)
  VALUES (v_operator_id, 'day6-operator-' || left(v_operator_id::text, 8) || '@example.test', 'Day 6 Operator', gen_random_uuid(), true);

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  -- Helper pattern: create orders directly in the state needed for each gate.
  INSERT INTO orders (
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared, total_qty_declared,
    bundled_quote_gbp, quote_fx_rate, quote_card_markup_pct, quote_total_ghs,
    funded_at, status, sop_version
  )
  VALUES
    (v_unfunded_order_id, 'DAY6-UNFUNDED-' || left(v_unfunded_order_id::text, 8), 'AUTH-D6-UNFUNDED', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 500.00, 5, 500.00, 1.0, 0.0, 500.00, NULL, 'awaiting_importer_receipt', 'day6-v1'),
    (v_child_blocked_order_id, 'DAY6-CHILD-BLOCK-' || left(v_child_blocked_order_id::text, 8), 'AUTH-D6-CHILD', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 500.00, 5, 500.00, 1.0, 0.0, 500.00, now(), 'pending_dva_funding', 'day6-v1'),
    (v_accounting_ok_order_id, 'DAY6-ACCT-OK-' || left(v_accounting_ok_order_id::text, 8), 'AUTH-D6-ACCT', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 500.00, 5, 500.00, 1.0, 0.0, 500.00, now(), 'awaiting_importer_receipt', 'day6-v1'),
    (v_vat_incomplete_order_id, 'DAY6-VAT-BLOCK-' || left(v_vat_incomplete_order_id::text, 8), 'AUTH-D6-VAT-BLOCK', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 600.00, 6, 600.00, 1.0, 0.0, 600.00, now(), 'awaiting_importer_receipt', 'day6-v1'),
    (v_vat_ok_order_id, 'DAY6-VAT-OK-' || left(v_vat_ok_order_id::text, 8), 'AUTH-D6-VAT-OK', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 700.00, 7, 700.00, 1.0, 0.0, 700.00, now(), 'awaiting_importer_receipt', 'day6-v1'),
    (v_replacement_order_id, 'DAY6-REPL-' || left(v_replacement_order_id::text, 8), NULL, v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'replacement_child', 100.00, 1, 100.00, 1.0, 0.0, 100.00, NULL, 'awaiting_importer_receipt', 'day6-v1');

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES
    (v_unfunded_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00),
    (v_child_blocked_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00),
    (v_accounting_ok_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00),
    (v_vat_incomplete_order_id, v_markup_category_id, 6, 600.00, 0.000, 0.00),
    (v_vat_ok_order_id, v_markup_category_id, 7, 700.00, 0.000, 0.00),
    (v_replacement_order_id, v_markup_category_id, 1, 100.00, 0.000, 0.00);

  -- Create an open child exception on v_child_blocked_order_id.
  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_child_blocked_order_id, v_retailer_id, v_retailer_account_id,
    'INV-DAY6-CHILD-' || left(v_child_blocked_order_id::text, 8), 'https://storage.example.test/day6-child.pdf',
    v_operator_id, 'mindee'
  ) RETURNING id INTO v_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, description, qty, amount_inc_vat_gbp,
    line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  )
  VALUES (
    v_invoice_id, 1, 'Day 6 open child item', 1, 100.00,
    'manually_added', 1, 100.00, 'N'
  ) RETURNING id INTO v_line_id;

  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome, liable_party,
    stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_child_blocked_order_id, v_operator_id, 'missing', 'refund', 'retailer',
    'at_reconciliation', 100.00, 'Day 6 open child blocker', 'raised', 'day6-v1'
  ) RETURNING id INTO v_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_dispute_id, v_line_id, 1, 100.00,
    'affected', 'refund_pending_approval', 'refund'
  ) RETURNING id INTO v_dispute_line_id;

  -- ---------------------------------------------------------------------------
  -- 2. Accounting release gates.
  -- ---------------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    PERFORM mark_order_accounting_release_ready(v_unfunded_order_id, v_staff_id);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: accounting release did not block an unfunded original order';
  END IF;

  v_blocked := false;
  BEGIN
    PERFORM mark_order_accounting_release_ready(v_child_blocked_order_id, v_staff_id);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: accounting release did not block an order with open child exceptions';
  END IF;

  PERFORM mark_order_accounting_release_ready(v_accounting_ok_order_id, v_staff_id);

  SELECT accounting_release_ready_at
    INTO v_accounting_ready_at
  FROM orders
  WHERE id = v_accounting_ok_order_id;

  IF v_accounting_ready_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: accounting release did not stamp accounting_release_ready_at';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 3. VAT release blockers.
  -- ---------------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    PERFORM approve_vat_release(v_replacement_order_id, v_staff_id, '{"smoke":"replacement"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: VAT release did not block replacement child order';
  END IF;

  v_blocked := false;
  BEGIN
    PERFORM approve_vat_release(v_vat_incomplete_order_id, v_staff_id, '{"smoke":"missing_export_evidence"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: VAT release did not block order with missing export evidence / dispatch tax point';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 4. VAT release happy path: complete export evidence and dispatch checkpoint stamping.
  -- ---------------------------------------------------------------------------
  INSERT INTO shipping_quotes (
    id, shipper_id, quote_gbp_total, booking_ref, bol_url, cert_of_shipment_url,
    commercial_invoice_url, hub_receipt_confirmed_at, hub_receipt_confirmed_by_staff_id,
    dispatched_at, estimated_ghana_arrival_at, pod_ghana_url, ghana_delivered_at,
    status
  )
  VALUES (
    gen_random_uuid(), v_shipper_id, 90.00, 'BOOK-DAY6-' || left(v_vat_ok_order_id::text, 8),
    'https://storage.example.test/day6-bol.pdf', 'https://storage.example.test/day6-cert.pdf',
    'https://storage.example.test/day6-commercial-invoice.pdf',
    now() - interval '8 days', v_staff_id,
    timestamp '2026-04-01 10:00:00+00', timestamp '2026-04-21 10:00:00+00',
    'https://storage.example.test/day6-pod.pdf', timestamp '2026-04-20 10:00:00+00',
    'delivered_ghana'
  ) RETURNING id INTO v_quote_id;

  INSERT INTO shipping_quote_orders (
    shipping_quote_id, order_id, order_value_gbp, apportionment_pct, apportioned_shipping_gbp
  )
  VALUES (
    v_quote_id, v_vat_ok_order_id, 700.00, 100.0000, 90.00
  );

  PERFORM approve_vat_release(v_vat_ok_order_id, v_staff_id, '{"bol":true,"pod":true,"commercial_invoice":true}'::jsonb);

  SELECT vat_release_approved_at, vat_tax_point_date
    INTO v_vat_release_at, v_tax_point
  FROM orders
  WHERE id = v_vat_ok_order_id;

  IF v_vat_release_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: VAT release did not stamp vat_release_approved_at';
  END IF;

  IF v_tax_point <> DATE '2026-04-01' THEN
    RAISE EXCEPTION 'FAIL: export dispatch checkpoint date = %, expected 2026-04-01 from dispatched_at', v_tax_point;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM shipping_quotes
  WHERE id = v_quote_id
    AND zero_rating_evidence_complete_at IS NOT NULL
    AND zero_rating_evidence_checked_by_staff_id = v_staff_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: VAT release did not stamp zero-rating evidence checkpoint on shipping quote';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 5. VAT workings are idempotent by return period.
  -- ---------------------------------------------------------------------------
  SELECT post_to_vat_return_workings(v_vat_ok_order_id) INTO v_working_id_1;
  SELECT post_to_vat_return_workings(v_vat_ok_order_id) INTO v_working_id_2;

  IF v_working_id_1 IS DISTINCT FROM v_working_id_2 THEN
    RAISE EXCEPTION 'FAIL: VAT workings not idempotent: first %, second %', v_working_id_1, v_working_id_2;
  END IF;

  SELECT COUNT(*)
    INTO v_count
  FROM vat_return_workings
  WHERE id = v_working_id_1;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: VAT workings row count %, expected one idempotent row', v_count;
  END IF;

  -- Note:
  -- This Day 6 check is deliberately limited to idempotency after the Day 6/8 clarification.
  -- Box 6 value is now sales-invoice/prepayment-release based and is tested below in the
  -- Day 6/8 clarification block, not in this older dispatch-evidence fixture.

  -- ---------------------------------------------------------------------------
  -- 6. Sage posting queue contract / idempotency shell.
  -- ---------------------------------------------------------------------------
  INSERT INTO sage_postings (
    id, event_type, source_table, source_id, posting_type,
    posting_code, source_version,
    idempotency_key, payload_json, payload_hash,
    amount_gbp, sage_config_version_id, queue_status, status, retry_count
  )
  VALUES (
    v_queue_id, 'accounting_release_ready', 'orders', v_accounting_ok_order_id, 'ar_invoice',
    'SPM-06', 1,
    'SPM-06:order:' || v_accounting_ok_order_id::text,
    jsonb_build_object('order_id', v_accounting_ok_order_id, 'posting_code', 'SPM-06'),
    md5(v_accounting_ok_order_id::text || ':SPM-06'),
    500.00, v_sage_config_id, 'queued', 'pending', 0
  );

  SELECT COUNT(*) INTO v_count
  FROM sage_postings
  WHERE id = v_queue_id
    AND posting_code = 'SPM-06'
    AND queue_status = 'queued'
    AND idempotency_key = 'SPM-06:order:' || v_accounting_ok_order_id::text
    AND payload_json ? 'order_id';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: Sage posting queue row not created with expected queue/idempotency contract';
  END IF;

  BEGIN
    INSERT INTO sage_postings (
      event_type, source_table, source_id, posting_type,
      posting_code, source_version,
      idempotency_key, payload_json, payload_hash,
      amount_gbp, sage_config_version_id, queue_status, status, retry_count
    )
    VALUES (
      'accounting_release_ready_duplicate', 'orders', v_accounting_ok_order_id, 'ar_invoice',
      'SPM-06', 1,
      'SPM-06:order:' || v_accounting_ok_order_id::text,
      jsonb_build_object('duplicate', true),
      md5(v_accounting_ok_order_id::text || ':SPM-06'),
      500.00, v_sage_config_id, 'queued', 'pending', 0
    );
  EXCEPTION WHEN unique_violation THEN
    v_duplicate_blocked := true;
  END;

  IF NOT v_duplicate_blocked THEN
    RAISE EXCEPTION 'FAIL: duplicate Sage posting idempotency key was not blocked';
  END IF;
END;
$$;

ROLLBACK;


-- ============================================================================
-- END INCLUDED TEST: day6_accounting_vat_sage_queue_smoke_test.sql
-- ============================================================================


-- ============================================================================
-- BEGIN INCLUDED TEST: day7_portal_role_boundary_smoke_test.sql
-- ============================================================================

-- =============================================================================
-- day7_portal_role_boundary_smoke_test.sql
-- Multi Tenant Platform Build — Day 7 portal/read-model + role-boundary smoke test
--
-- Run after Day 6 has passed in the same project, or after the full clean pack:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql
--   4. closure_v2_seed.sql
--   5. day2_to_day5_combined_regression_smoke_test.sql
--   6. day6_accounting_vat_sage_queue_smoke_test.sql
--
-- Purpose:
--   Day 7 is about making the backend safe/usable for thin importer,
--   supervisor/admin, and shipper portals. This test checks:
--   - auth helper functions expected by RLS exist
--   - core portal tables have RLS enabled
--   - core portal tables have role-boundary policies, not just RLS enabled
--   - order_state_vw supports non-blocking operational overlays
--   - replacement children show funding not required
--   - shipment overlays expose delivered/in-transit states
--
-- This test intentionally rolls back all data.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE day7_results(result text) ON COMMIT DROP;

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_table text;
  v_suffix text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_currency_id uuid;
  v_country_id uuid;
  v_staff_id uuid;
  v_shipper_id uuid;
  v_hub_id uuid;
  v_retailer_id uuid;
  v_retailer_account_id uuid;
  v_operator_id uuid;
  v_importer_id uuid;
  v_courier_id uuid;
  v_order_parallel uuid;
  v_order_replacement uuid;
  v_order_delivery uuid;
  v_invoice_id uuid;
  v_quote_id uuid;
  v_bucket text;
  v_funding_overlay text;
  v_shipment_overlay text;
BEGIN
  -- ---------------------------------------------------------------------------
  -- A. Auth/RLS helper contracts expected by the governing docs and existing RLS.
  -- ---------------------------------------------------------------------------
  IF to_regprocedure('public.current_operator_importer_ids()') IS NULL THEN
    v_missing := array_append(v_missing, 'function current_operator_importer_ids()');
  END IF;

  IF to_regprocedure('public.current_shipper_id()') IS NULL THEN
    v_missing := array_append(v_missing, 'function current_shipper_id()');
  END IF;

  IF to_regprocedure('public.is_active_staff()') IS NULL THEN
    v_missing := array_append(v_missing, 'function is_active_staff()');
  END IF;

  IF to_regprocedure('public.current_staff_role()') IS NULL THEN
    v_missing := array_append(v_missing, 'function current_staff_role()');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: missing auth/RLS helper contract(s): %', array_to_string(v_missing, ', ');
  END IF;

  INSERT INTO pg_temp.day7_results(result) VALUES ('DAY7_AUTH_HELPER_CONTRACTS_EXIST_PASSED');

  -- ---------------------------------------------------------------------------
  -- B. RLS enabled on portal-critical tables.
  -- ---------------------------------------------------------------------------
  v_missing := ARRAY[]::text[];

  FOREACH v_table IN ARRAY ARRAY[
    'orders',
    'order_screenshots',
    'order_tracking_submissions',
    'supplier_invoices',
    'supplier_invoice_lines',
    'disputes',
    'dispute_lines',
    'dispute_messages',
    'shipper_liabilities',
    'payout_requests',
    'importer_credit_ledger',
    'shipping_quotes',
    'shipping_quote_orders',
    'sage_postings',
    'dva_statements',
    'dva_statement_lines',
    'dva_reconciliation'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = v_table
        AND c.relrowsecurity = true
    ) THEN
      v_missing := array_append(v_missing, v_table || ' RLS not enabled');
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: RLS not enabled on portal-critical table(s): %', array_to_string(v_missing, ', ');
  END IF;

  INSERT INTO pg_temp.day7_results(result) VALUES ('DAY7_RLS_ENABLED_ON_PORTAL_TABLES_PASSED');

  -- ---------------------------------------------------------------------------
  -- C. Policy coverage. This does not prove every UI route yet; it proves the
  --    database has role-boundary policy coverage for the thin portals.
  -- ---------------------------------------------------------------------------
  v_missing := ARRAY[]::text[];

  -- Existing baseline tables should already have these.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='orders' AND policyname ILIKE '%staff%') THEN
    v_missing := array_append(v_missing, 'orders staff policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='orders' AND policyname ILIKE '%operator%') THEN
    v_missing := array_append(v_missing, 'orders operator/importer policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='orders' AND policyname ILIKE '%shipper%') THEN
    v_missing := array_append(v_missing, 'orders shipper policy');
  END IF;

  -- Importer evidence/OCR portal.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='supplier_invoices' AND policyname ILIKE '%staff%') THEN
    v_missing := array_append(v_missing, 'supplier_invoices staff policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='supplier_invoices' AND policyname ILIKE '%operator%') THEN
    v_missing := array_append(v_missing, 'supplier_invoices operator/importer policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='supplier_invoice_lines' AND policyname ILIKE '%staff%') THEN
    v_missing := array_append(v_missing, 'supplier_invoice_lines staff policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='supplier_invoice_lines' AND policyname ILIKE '%operator%') THEN
    v_missing := array_append(v_missing, 'supplier_invoice_lines operator/importer policy');
  END IF;

  -- Child exception / dispute portal.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='disputes' AND policyname ILIKE '%staff%') THEN
    v_missing := array_append(v_missing, 'disputes staff policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='disputes' AND policyname ILIKE '%operator%') THEN
    v_missing := array_append(v_missing, 'disputes operator/importer policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='disputes' AND policyname ILIKE '%shipper%') THEN
    v_missing := array_append(v_missing, 'disputes shipper-read policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='dispute_lines' AND policyname ILIKE '%staff%') THEN
    v_missing := array_append(v_missing, 'dispute_lines staff policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='dispute_lines' AND policyname ILIKE '%operator%') THEN
    v_missing := array_append(v_missing, 'dispute_lines operator/importer policy');
  END IF;

  -- Shipper portal / shipping handoff.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_quotes' AND policyname ILIKE '%staff%') THEN
    v_missing := array_append(v_missing, 'shipping_quotes staff policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_quotes' AND policyname ILIKE '%shipper%') THEN
    v_missing := array_append(v_missing, 'shipping_quotes shipper policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_quotes' AND policyname ILIKE '%operator%') THEN
    v_missing := array_append(v_missing, 'shipping_quotes operator/importer read policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_quote_orders' AND policyname ILIKE '%staff%') THEN
    v_missing := array_append(v_missing, 'shipping_quote_orders staff policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_quote_orders' AND policyname ILIKE '%shipper%') THEN
    v_missing := array_append(v_missing, 'shipping_quote_orders shipper policy');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_quote_orders' AND policyname ILIKE '%operator%') THEN
    v_missing := array_append(v_missing, 'shipping_quote_orders operator/importer read policy');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: missing Day 7 portal RLS policy coverage: %', array_to_string(v_missing, ', ');
  END IF;

  INSERT INTO pg_temp.day7_results(result) VALUES ('DAY7_PORTAL_RLS_POLICY_COVERAGE_PASSED');

  -- ---------------------------------------------------------------------------
  -- D. Dashboard/read-model behaviour for thin portals.
  -- ---------------------------------------------------------------------------
  INSERT INTO currencies (code, symbol)
  VALUES ('Y' || upper(substr(v_suffix, 1, 2)), '¤')
  RETURNING id INTO v_currency_id;

  INSERT INTO countries (name, iso_code, currency_id)
  VALUES ('Day7 Test Country ' || v_suffix, 'Y' || upper(substr(v_suffix, 3, 2)), v_currency_id)
  RETURNING id INTO v_country_id;

  INSERT INTO staff (auth_user_id, role_type, full_name, email, active)
  VALUES (gen_random_uuid(), 'supervisor', 'Day7 Supervisor', 'day7.supervisor.' || v_suffix || '@example.test', true)
  RETURNING id INTO v_staff_id;

  INSERT INTO shippers (name, contact_email, vat_treatment, active)
  VALUES ('Day7 Shipper ' || v_suffix, 'shipper.' || v_suffix || '@example.test', 'outside_scope', true)
  RETURNING id INTO v_shipper_id;

  INSERT INTO hubs (shipper_id, name, country_id, full_address, postcode, active)
  VALUES (v_shipper_id, 'Day7 Hub', v_country_id, '1 Day7 Street', 'D7 7ST', true)
  RETURNING id INTO v_hub_id;

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO retailers (name, website_url, global_enabled)
  VALUES ('Day7 Retailer ' || v_suffix, 'https://retailer.example.test', true)
  RETURNING id INTO v_retailer_id;

  INSERT INTO retailer_accounts (
    retailer_id, shipper_id, account_email, account_username,
    credential_delivery_method, delivery_address_locked_to_hub_id, status
  ) VALUES (
    v_retailer_id, v_shipper_id, 'retailer.' || v_suffix || '@example.test',
    'day7_' || v_suffix, 'pending_vault_upgrade', v_hub_id, 'active'
  ) RETURNING id INTO v_retailer_account_id;

  INSERT INTO couriers (name, tracking_url_template, added_by_staff_id, active)
  VALUES ('Day7 Courier ' || v_suffix, 'https://tracking.example.test/{tracking_ref}', v_staff_id, true)
  RETURNING id INTO v_courier_id;

  INSERT INTO operators (email, phone, full_name, auth_user_id, active)
  VALUES ('operator.' || v_suffix || '@example.test', '+440000000000', 'Day7 Operator', gen_random_uuid(), true)
  RETURNING id INTO v_operator_id;

  INSERT INTO importers (shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_shipper_id, v_country_id, 'Day7 Importer Ltd ' || v_suffix, 'Day7 Importer', true)
  RETURNING id INTO v_importer_id;

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  -- Evidence exists while funding is still unmatched: portal should show active parallel lane, not stalled.
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  ) VALUES (
    'DAY7-PARALLEL-' || v_suffix, 'AUTH-DAY7-PARALLEL-' || v_suffix,
    v_importer_id, v_operator_id, v_shipper_id, v_retailer_id,
    v_hub_id, 100.00, 1, 'DAY7', 'pending_dva_funding', NULL
  ) RETURNING id INTO v_order_parallel;

  INSERT INTO supplier_invoices (order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url, uploaded_by_operator_id, ocr_service_used)
  VALUES (v_order_parallel, v_retailer_id, v_retailer_account_id, 'INV-DAY7-PARALLEL-' || v_suffix, 'https://storage.example.test/day7.pdf', v_operator_id, 'mindee')
  RETURNING id INTO v_invoice_id;

  PERFORM recompute_order_status(v_order_parallel);

  SELECT operational_bucket INTO v_bucket FROM order_state_vw WHERE id = v_order_parallel;
  IF v_bucket <> 'parallel_lane_active' THEN
    RAISE EXCEPTION 'FAIL: order_state_vw operational_bucket = %, expected parallel_lane_active for unfunded evidence-active order', v_bucket;
  END IF;

  INSERT INTO pg_temp.day7_results(result) VALUES ('DAY7_PARALLEL_LANE_READ_MODEL_PASSED');

  -- Replacement children do not require fresh funding.
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, parent_order_id, order_type,
    order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  ) VALUES (
    'DAY7-REPLACEMENT-' || v_suffix, 'AUTH-DAY7-REPLACEMENT-' || v_suffix,
    v_importer_id, v_operator_id, v_shipper_id, v_retailer_id,
    v_hub_id, v_order_parallel, 'replacement_child',
    100.00, 1, 'DAY7', 'evidence_collecting', NULL
  ) RETURNING id INTO v_order_replacement;

  SELECT funding_overlay INTO v_funding_overlay FROM order_state_vw WHERE id = v_order_replacement;
  IF v_funding_overlay <> 'not_required' THEN
    RAISE EXCEPTION 'FAIL: replacement child funding_overlay = %, expected not_required', v_funding_overlay;
  END IF;

  INSERT INTO pg_temp.day7_results(result) VALUES ('DAY7_REPLACEMENT_CHILD_FUNDING_OVERLAY_PASSED');

  -- Delivered shipment should surface as delivered in read model.
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  ) VALUES (
    'DAY7-DELIVERED-' || v_suffix, 'AUTH-DAY7-DELIVERED-' || v_suffix,
    v_importer_id, v_operator_id, v_shipper_id, v_retailer_id,
    v_hub_id, 200.00, 2, 'DAY7', 'awaiting_importer_receipt', now()
  ) RETURNING id INTO v_order_delivery;

  INSERT INTO shipping_quotes (
    shipper_id, quote_gbp_total, courier_id, status, booking_ref,
    dispatched_at, estimated_ghana_arrival_at, pod_ghana_url, ghana_delivered_at,
    zero_rating_evidence_complete_at, zero_rating_evidence_checked_by_staff_id
  ) VALUES (
    v_shipper_id, 50.00, v_courier_id, 'delivered_ghana', 'BOOK-DAY7-' || v_suffix,
    now() - interval '7 days', now() + interval '1 day', 'https://storage.example.test/day7-pod.pdf', now(),
    now(), v_staff_id
  ) RETURNING id INTO v_quote_id;

  INSERT INTO shipping_quote_orders (shipping_quote_id, order_id, order_value_gbp, apportionment_pct, apportioned_shipping_gbp)
  VALUES (v_quote_id, v_order_delivery, 200.00, 100.0000, 50.00);

  SELECT shipment_readiness_overlay INTO v_shipment_overlay FROM order_state_vw WHERE id = v_order_delivery;
  IF v_shipment_overlay <> 'delivered' THEN
    RAISE EXCEPTION 'FAIL: shipment_readiness_overlay = %, expected delivered', v_shipment_overlay;
  END IF;

  INSERT INTO pg_temp.day7_results(result) VALUES ('DAY7_SHIPMENT_DELIVERY_READ_MODEL_PASSED');
END $$;


ROLLBACK;

-- ============================================================================
-- END INCLUDED TEST: day7_portal_role_boundary_smoke_test.sql
-- ============================================================================


-- ============================================================================
-- BEGIN INCLUDED TEST: day8_vat_prepayment_export_evidence_smoke_test_v2.sql
-- ============================================================================

-- day8_vat_prepayment_export_evidence_smoke_test.sql
-- Multi Tenant Platform Build — Day 8 backend smoke test
-- Run after Day 7 has passed.
--
-- Scope:
--   A. VAT timing derives from qualifying prepayment/deposit where available, not dispatch date alone
--   B. Unresolved child outcomes block VAT release
--   C. Replacement child does not create a fresh Box 6 event
--   D. VAT workings are idempotent by return period
--   E. Carry-in / carry-out VAT timing adjustments are reflected in Box 6 workings
--   F. Box 1 breach/reinstatement adjustments are reflected in VAT workings
--   F. VAT override escalation rule is seeded/admin-routed
--
-- If any check fails, execution stops with the first error.
-- If everything passes, this returns one final result set.

BEGIN;

DO $$
DECLARE
  v_staff_id uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_retailer_account_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_markup_category_id uuid := gen_random_uuid();
  v_country_id uuid;

  v_q1_order_id uuid := gen_random_uuid();
  v_q2_order_id uuid := gen_random_uuid();
  v_breach_order_id uuid := gen_random_uuid();
  v_child_block_order_id uuid := gen_random_uuid();
  v_replacement_order_id uuid := gen_random_uuid();

  v_q1_quote_id uuid := gen_random_uuid();
  v_q2_quote_id uuid := gen_random_uuid();

  v_dva_statement_q1_id uuid := gen_random_uuid();
  v_dva_statement_q2_id uuid := gen_random_uuid();
  v_dva_line_q1_id uuid := gen_random_uuid();
  v_dva_line_q2_id uuid := gen_random_uuid();
  v_invoice_id uuid;
  v_line_id uuid;
  v_dispute_id uuid;
  v_dispute_line_id uuid;
  v_sales_invoice_q1_id uuid := gen_random_uuid();
  v_sales_invoice_q2_id uuid := gen_random_uuid();
  v_sales_invoice_breach_id uuid := gen_random_uuid();
  v_working_q1_id uuid;
  v_working_q1_id_again uuid;
  v_working_q2_id uuid;

  v_blocked boolean;
  v_tax_point date;
  v_period date;
  v_box6 numeric;
  v_box1 numeric;
  v_breach_candidates int;
  v_count int;
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preflight checks.
  -- ---------------------------------------------------------------------------
  IF to_regprocedure('public.approve_vat_release(uuid, uuid, jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: approve_vat_release(uuid, uuid, jsonb) missing';
  END IF;

  IF to_regprocedure('public.post_to_vat_return_workings(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: post_to_vat_return_workings(uuid) missing';
  END IF;

  IF to_regprocedure('public.derive_order_vat_tax_point(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: derive_order_vat_tax_point(uuid) missing';
  END IF;

  IF to_regclass('public.vat_return_adjustments') IS NULL THEN
    RAISE EXCEPTION 'FAIL: vat_return_adjustments table missing';
  END IF;

  IF to_regclass('public.vat_export_deadline_breach_candidates_vw') IS NULL THEN
    RAISE EXCEPTION 'FAIL: vat_export_deadline_breach_candidates_vw missing';
  END IF;

  SELECT id INTO v_country_id FROM countries WHERE iso_code = 'GHA' LIMIT 1;
  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: GHA country seed missing';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 1. Minimal tenant/config fixture.
  -- ---------------------------------------------------------------------------
  INSERT INTO staff (id, auth_user_id, role_type, full_name, email, active)
  VALUES (v_staff_id, gen_random_uuid(), 'admin', 'Day 8 Smoke Admin', 'day8-admin-' || left(v_staff_id::text, 8) || '@example.test', true);

  INSERT INTO shippers (id, name, contact_email, vat_treatment, active)
  VALUES (v_shipper_id, 'Day 8 Smoke Shipper', 'day8-shipper-' || left(v_shipper_id::text, 8) || '@example.test', 'outside_scope', true);

  INSERT INTO hubs (id, shipper_id, name, country_id, full_address, active)
  VALUES (v_hub_id, v_shipper_id, 'Day 8 Smoke Hub', v_country_id, 'Day 8 Smoke Address', true);

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO retailers (id, name, website_url, global_enabled)
  VALUES (v_retailer_id, 'Day 8 Smoke Retailer', 'https://day8.example.test', true);

  INSERT INTO retailer_accounts (
    id, retailer_id, shipper_id, account_email, credential_delivery_method,
    delivery_address_locked_to_hub_id, status
  )
  VALUES (
    v_retailer_account_id, v_retailer_id, v_shipper_id,
    'retailer-account-' || left(v_retailer_account_id::text, 8) || '@example.test',
    'vault_brokered', v_hub_id, 'active'
  );

  INSERT INTO markup_categories (id, shipper_id, category_name, default_markup_pct, active)
  VALUES (v_markup_category_id, v_shipper_id, 'Day 8 Smoke Category', 0.000, true);

  INSERT INTO importers (id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_importer_id, v_shipper_id, v_country_id, 'Day 8 Importer Ltd', 'Day 8 Importer', true);

  INSERT INTO operators (id, email, full_name, auth_user_id, active)
  VALUES (v_operator_id, 'day8-operator-' || left(v_operator_id::text, 8) || '@example.test', 'Day 8 Operator', gen_random_uuid(), true);

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO orders (
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared, total_qty_declared,
    bundled_quote_gbp, quote_fx_rate, quote_card_markup_pct, quote_total_ghs,
    funded_at, status, sop_version
  )
  VALUES
    (v_q1_order_id, 'DAY8-Q1-' || left(v_q1_order_id::text, 8), 'AUTH-D8-Q1', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 100.00, 1, 100.00, 1.0, 0.0, 100.00, now(), 'awaiting_importer_receipt', 'day8-v1'),
    (v_q2_order_id, 'DAY8-Q2-' || left(v_q2_order_id::text, 8), 'AUTH-D8-Q2', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 1000.00, 10, 1000.00, 1.0, 0.0, 1000.00, now(), 'awaiting_importer_receipt', 'day8-v1'),
    (v_breach_order_id, 'DAY8-BREACH-' || left(v_breach_order_id::text, 8), 'AUTH-D8-BREACH', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 600.00, 6, 600.00, 1.0, 0.0, 600.00, now(), 'awaiting_financial_closure', 'day8-v1'),
    (v_child_block_order_id, 'DAY8-CHILD-BLOCK-' || left(v_child_block_order_id::text, 8), 'AUTH-D8-CHILD', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 500.00, 5, 500.00, 1.0, 0.0, 500.00, now(), 'pending_dva_funding', 'day8-v1'),
    (v_replacement_order_id, 'DAY8-REPL-' || left(v_replacement_order_id::text, 8), NULL, v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'replacement_child', 150.00, 1, 150.00, 1.0, 0.0, 150.00, NULL, 'awaiting_importer_receipt', 'day8-v1');

  INSERT INTO order_category_lines (order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated)
  VALUES
    (v_q1_order_id, v_markup_category_id, 1, 100.00, 0.000, 0.00),
    (v_q2_order_id, v_markup_category_id, 10, 1000.00, 0.000, 0.00),
    (v_breach_order_id, v_markup_category_id, 6, 600.00, 0.000, 0.00),
    (v_child_block_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00),
    (v_replacement_order_id, v_markup_category_id, 1, 150.00, 0.000, 0.00);

  -- Qualifying prepayment/deposit fixtures.
  -- Q1 order is prepaid in Q1 but dispatched in Q2: VAT timing must follow prepayment.
  -- Q2 order is prepaid and dispatched in Q2.
  -- Separate breach order is used for missed export/evidence deadline reporting to respect one-main-invoice-per-order.
  INSERT INTO dva_statements (
    id, importer_id, source_bank, uploaded_by_staff_id, csv_url,
    statement_period_from, statement_period_to, parse_status
  )
  VALUES
    (v_dva_statement_q1_id, v_importer_id, 'gcb', v_staff_id, 'https://storage.example.test/day8-q1-dva.csv', DATE '2044-03-01', DATE '2044-03-31', 'parsed'),
    (v_dva_statement_q2_id, v_importer_id, 'gcb', v_staff_id, 'https://storage.example.test/day8-q2-dva.csv', DATE '2044-04-01', DATE '2044-04-30', 'parsed');

  INSERT INTO dva_statement_lines (
    id, dva_statement_id, line_order, statement_date, reference_raw, direction,
    amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied,
    amount_gbp_equivalent, auth_id_ref, match_status
  )
  VALUES
    (v_dva_line_q1_id, v_dva_statement_q1_id, 1, DATE '2044-03-28', 'DAY8-Q1 PREPAYMENT', 'in', 100.00, 'GBP', 1.0, 0.0, 100.00, 'AUTH-D8-Q1', 'confirmed'),
    (v_dva_line_q2_id, v_dva_statement_q2_id, 1, DATE '2044-04-10', 'DAY8-Q2 PREPAYMENT', 'in', 1000.00, 'GBP', 1.0, 0.0, 1000.00, 'AUTH-D8-Q2', 'confirmed');

  INSERT INTO dva_reconciliation (
    dva_statement_line_id, reconciliation_type, order_id,
    reconciled_gbp_amount, reconciled_by_staff_id, reconciled_at, notes
  )
  VALUES
    (v_dva_line_q1_id, 'order_funding', v_q1_order_id, 100.00, v_staff_id, timestamp '2044-03-28 10:00:00+00', 'Day 8 Q1 qualifying prepayment'),
    (v_dva_line_q2_id, 'order_funding', v_q2_order_id, 1000.00, v_staff_id, timestamp '2044-04-10 10:00:00+00', 'Day 8 Q2 qualifying prepayment');


  -- Complete export evidence for Q1 and Q2 orders.
  INSERT INTO shipping_quotes (
    id, shipper_id, quote_gbp_total, booking_ref, bol_url, cert_of_shipment_url,
    commercial_invoice_url, hub_receipt_confirmed_at, hub_receipt_confirmed_by_staff_id,
    dispatched_at, estimated_ghana_arrival_at, pod_ghana_url, ghana_delivered_at,
    status
  )
  VALUES
    (
      v_q1_quote_id, v_shipper_id, 20.00, 'BOOK-DAY8-Q1-' || left(v_q1_order_id::text, 8),
      'https://storage.example.test/day8-q1-bol.pdf', 'https://storage.example.test/day8-q1-cert.pdf',
      'https://storage.example.test/day8-q1-commercial-invoice.pdf',
      timestamp '2044-04-11 10:00:00+00', v_staff_id,
      timestamp '2044-04-15 10:00:00+00', timestamp '2044-05-05 10:00:00+00',
      'https://storage.example.test/day8-q1-pod.pdf', timestamp '2044-05-04 10:00:00+00',
      'delivered_ghana'
    ),
    (
      v_q2_quote_id, v_shipper_id, 80.00, 'BOOK-DAY8-Q2-' || left(v_q2_order_id::text, 8),
      'https://storage.example.test/day8-q2-bol.pdf', 'https://storage.example.test/day8-q2-cert.pdf',
      'https://storage.example.test/day8-q2-commercial-invoice.pdf',
      timestamp '2044-04-11 10:00:00+00', v_staff_id,
      timestamp '2044-04-15 10:00:00+00', timestamp '2044-05-05 10:00:00+00',
      'https://storage.example.test/day8-q2-pod.pdf', timestamp '2044-05-04 10:00:00+00',
      'delivered_ghana'
    );

  INSERT INTO shipping_quote_orders (shipping_quote_id, order_id, order_value_gbp, apportionment_pct, apportioned_shipping_gbp)
  VALUES
    (v_q1_quote_id, v_q1_order_id, 100.00, 100.0000, 20.00),
    (v_q2_quote_id, v_q2_order_id, 1000.00, 100.0000, 80.00);

  -- ---------------------------------------------------------------------------
  -- 2. VAT release blockers: open child and replacement child.
  -- ---------------------------------------------------------------------------
  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_child_block_order_id, v_retailer_id, v_retailer_account_id,
    'INV-DAY8-CHILD-' || left(v_child_block_order_id::text, 8), 'https://storage.example.test/day8-child.pdf',
    v_operator_id, 'mindee'
  ) RETURNING id INTO v_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, description, qty, amount_inc_vat_gbp,
    line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  )
  VALUES (
    v_invoice_id, 1, 'Day 8 unresolved child item', 1, 100.00,
    'manually_added', 1, 100.00, 'N'
  ) RETURNING id INTO v_line_id;

  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome, liable_party,
    stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_child_block_order_id, v_operator_id, 'missing', 'refund', 'retailer',
    'at_reconciliation', 100.00, 'Day 8 unresolved child blocker', 'raised', 'day8-v1'
  ) RETURNING id INTO v_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_dispute_id, v_line_id, 1, 100.00,
    'affected', 'refund_pending_approval', 'refund'
  ) RETURNING id INTO v_dispute_line_id;

  v_blocked := false;
  BEGIN
    PERFORM approve_vat_release(v_child_block_order_id, v_staff_id, '{"smoke":"open_child"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: VAT release did not block an order with unresolved child exception';
  END IF;

  v_blocked := false;
  BEGIN
    PERFORM approve_vat_release(v_replacement_order_id, v_staff_id, '{"smoke":"replacement_child"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: VAT release did not block replacement child order';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 3. VAT release uses qualifying prepayment/deposit timing where available; dispatch remains evidence gate.
  -- ---------------------------------------------------------------------------
  PERFORM approve_vat_release(v_q1_order_id, v_staff_id, '{"bol":true,"pod":true,"commercial_invoice":true,"day8":"q1"}'::jsonb);
  PERFORM approve_vat_release(v_q2_order_id, v_staff_id, '{"bol":true,"pod":true,"commercial_invoice":true,"day8":"q2"}'::jsonb);

  SELECT vat_tax_point_date, vat_return_period
    INTO v_tax_point, v_period
  FROM orders
  WHERE id = v_q1_order_id;

  IF v_tax_point <> DATE '2044-03-28' THEN
    RAISE EXCEPTION 'FAIL: Q1 VAT tax point = %, expected 2044-03-28 from qualifying prepayment, not 2044-04-15 dispatch', v_tax_point;
  END IF;

  IF v_period <> DATE '2044-01-01' THEN
    RAISE EXCEPTION 'FAIL: Q1 VAT return period = %, expected 2044-01-01 from prepayment quarter', v_period;
  END IF;

  SELECT vat_tax_point_date, vat_return_period
    INTO v_tax_point, v_period
  FROM orders
  WHERE id = v_q2_order_id;

  IF v_tax_point <> DATE '2044-04-10' THEN
    RAISE EXCEPTION 'FAIL: Q2 VAT tax point = %, expected 2044-04-10 from qualifying prepayment', v_tax_point;
  END IF;

  IF v_period <> DATE '2044-04-01' THEN
    RAISE EXCEPTION 'FAIL: Q2 VAT return period = %, expected 2044-04-01', v_period;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 4. Build sales-invoice timing mismatch fixtures and VAT adjustments.
  --    These represent the known timing problem: commercial/document posting period
  --    can differ from VAT Box 6 period. The workings must include the adjustment.
  -- ---------------------------------------------------------------------------
  INSERT INTO sales_invoices (
    id, order_id, invoice_type, consideration_received_date, sage_invoice_date,
    tax_point_period, sage_invoice_period, vat_box6_reported_period,
    amount_gbp, vat_code, line_items_json, export_evidence_complete_date,
    zero_rating_deadline_date, zero_rating_status, sage_status
  )
  VALUES
    (
      v_sales_invoice_q1_id, v_q1_order_id, 'main',
      DATE '2044-03-28', DATE '2044-04-20',
      '2044-Q1', '2044-Q2', '2044-Q1',
      100.00, 'T0', jsonb_build_array(jsonb_build_object('description','Day 8 Q1 base sales-invoice amount','amount_gbp',100.00)),
      DATE '2044-05-04', DATE '2044-06-28', 'evidence_complete', 'posted'
    ),
    (
      v_sales_invoice_q2_id, v_q2_order_id, 'main',
      DATE '2044-04-10', DATE '2044-04-20',
      '2044-Q2', '2044-Q2', '2044-Q2',
      1000.00, 'T0', jsonb_build_array(jsonb_build_object('description','Day 8 Q2 base sales-invoice amount','amount_gbp',1000.00)),
      DATE '2044-05-04', DATE '2044-07-15', 'evidence_complete', 'posted'
    ),
    (
      v_sales_invoice_breach_id, v_breach_order_id, 'main',
      DATE '2044-04-10', DATE '2044-04-20',
      '2044-Q2', '2044-Q2', NULL,
      600.00, 'T0', jsonb_build_array(jsonb_build_object('description','Day 8 export deadline breach item','amount_gbp',600.00)),
      NULL, DATE '2044-07-10', 'breached', 'posted'
    );

  INSERT INTO vat_return_adjustments (
    return_period, report_type, source_sales_invoice_id, amount_gbp,
    direction, posted_by_staff_id, notes
  )
  VALUES
    ('2044-Q1', 'box6_carry_in', v_sales_invoice_q1_id, 250.00, 'add', v_staff_id, 'Day 8 carry-in timing adjustment'),
    ('2044-Q2', 'box6_carry_out', v_sales_invoice_q2_id, 125.00, 'subtract', v_staff_id, 'Day 8 carry-out timing adjustment'),
    ('2044-Q2', 'box1_breach', v_sales_invoice_breach_id, 100.00, 'add', v_staff_id, 'Day 8 Box 1 breach adjustment: output VAT due on missed export/evidence deadline');

  -- ---------------------------------------------------------------------------
  -- 5. VAT workings idempotency and adjustment inclusion.
  -- ---------------------------------------------------------------------------
  SELECT post_to_vat_return_workings(v_q1_order_id) INTO v_working_q1_id;
  SELECT post_to_vat_return_workings(v_q1_order_id) INTO v_working_q1_id_again;

  IF v_working_q1_id IS DISTINCT FROM v_working_q1_id_again THEN
    RAISE EXCEPTION 'FAIL: Q1 VAT workings not idempotent: first %, second %', v_working_q1_id, v_working_q1_id_again;
  END IF;

  SELECT COALESCE(final_box6, 0)
    INTO v_box6
  FROM vat_return_workings
  WHERE return_period = '2044-Q1';

  IF v_box6 <> 350.00 THEN
    RAISE EXCEPTION 'FAIL: Q1 final_box6 = %, expected 350.00. Expected base 100.00 plus 250.00 carry-in adjustment.', v_box6;
  END IF;

  SELECT post_to_vat_return_workings(v_q2_order_id) INTO v_working_q2_id;

  SELECT COALESCE(final_box6, 0)
    INTO v_box6
  FROM vat_return_workings
  WHERE return_period = '2044-Q2';

  IF v_box6 <> 875.00 THEN
    RAISE EXCEPTION 'FAIL: Q2 final_box6 = %, expected 875.00. Expected base 1000.00 less 125.00 carry-out adjustment.', v_box6;
  END IF;

  SELECT COALESCE(final_box1, 0)
    INTO v_box1
  FROM vat_return_workings
  WHERE return_period = '2044-Q2';

  IF v_box1 <> 100.00 THEN
    RAISE EXCEPTION 'FAIL: Q2 final_box1 = %, expected 100.00 Box 1 breach VAT adjustment.', v_box1;
  END IF;

  SELECT COUNT(*)
    INTO v_breach_candidates
  FROM vat_export_deadline_breach_candidates_vw
  WHERE source_sales_invoice_id = v_sales_invoice_breach_id
    AND requires_box1_adjustment_yn = true
    AND estimated_box1_vat_due_gbp = 100.00;

  IF v_breach_candidates <> 1 THEN
    RAISE EXCEPTION 'FAIL: VAT breach candidate report did not surface the breached prepayment/invoice for Box 1 adjustment';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 6. VAT override escalation seed exists and routes to admin.
  -- ---------------------------------------------------------------------------
  SELECT COUNT(*)
    INTO v_count
  FROM escalation_rules
  WHERE rule_code = 'VAT_OVERRIDE_REQUESTED'
    AND event_type = 'vat_release'
    AND route_to = 'admin'
    AND active = true;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: VAT_OVERRIDE_REQUESTED escalation rule missing/inactive/not admin-routed';
  END IF;
END;
$$;

ROLLBACK;


-- ============================================================================
-- END INCLUDED TEST: day8_vat_prepayment_export_evidence_smoke_test_v2.sql
-- ============================================================================


-- ============================================================================
-- BEGIN INCLUDED TEST: day8_progressive_commercial_release_smoke_test.sql
-- ============================================================================

-- =============================================================================
-- day8_progressive_commercial_release_smoke_test.sql
-- Multi Tenant Platform Build — Progressive Commercial Release / replacement invoicing smoke test
--
-- Run after:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_v2.sql including VAT Timing + Progressive Release addenda
--   4. closure_v2_seed.sql
--
-- Purpose:
--   Proves Option A:
--   - 5 quoted items can release 4 stable progressed items to customer invoice first
--   - the first release creates ONE main customer sales invoice
--   - a later replacement child item releases as a supplementary customer invoice
--   - the supplementary invoice still attaches to the original commercial parent order
--   - no second main invoice is created
--   - no fresh replacement child funding event is created
--   - the same supplier invoice line cannot be customer-invoiced twice
--   - VAT Box 6 remains driven by the prepayment/tax-point period, not duplicated by later Sage invoice date
--
-- This test intentionally rolls back all data.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_suffix text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

  v_currency_id uuid;
  v_country_id uuid;
  v_staff_id uuid;
  v_shipper_id uuid;
  v_hub_id uuid;
  v_retailer_id uuid;
  v_retailer_account_id uuid;
  v_operator_id uuid;
  v_importer_id uuid;
  v_markup_category_id uuid;
  v_installation_id uuid;
  v_sage_config_id uuid;

  v_parent_order_id uuid;
  v_parent_invoice_id uuid;
  v_parent_line_id uuid;
  v_missing_line_id uuid;
  v_replacement_dispute_id uuid;
  v_replacement_dispute_line_id uuid;
  v_child_order_id uuid;
  v_child_invoice_id uuid;
  v_child_line_id uuid;

  v_parent_quote_id uuid;
  v_child_quote_id uuid;

  v_first_sales_invoice_id uuid;
  v_second_sales_invoice_id uuid;
  v_working_id uuid;

  v_count int;
  v_amount numeric;
  v_invoice_type text;
  v_linked_id uuid;
  v_order_id uuid;
  v_period text;
  v_sage_period text;
  v_blocked boolean := false;
BEGIN
  -- ---------------------------------------------------------------------------
  -- Minimal reference setup.
  -- ---------------------------------------------------------------------------
  INSERT INTO currencies (code, symbol)
  VALUES ('P' || upper(substr(v_suffix, 1, 2)), '¤')
  RETURNING id INTO v_currency_id;

  INSERT INTO countries (name, iso_code, currency_id)
  VALUES ('Progressive Release Country ' || v_suffix, 'P' || upper(substr(v_suffix, 3, 2)), v_currency_id)
  RETURNING id INTO v_country_id;

  INSERT INTO staff (auth_user_id, role_type, full_name, email, active)
  VALUES (gen_random_uuid(), 'admin', 'Progressive Release Admin', 'progressive.admin.' || v_suffix || '@example.test', true)
  RETURNING id INTO v_staff_id;

  INSERT INTO shippers (name, contact_email, vat_treatment, active)
  VALUES ('Progressive Test Shipper ' || v_suffix, 'shipper.' || v_suffix || '@example.test', 'outside_scope', true)
  RETURNING id INTO v_shipper_id;

  INSERT INTO hubs (shipper_id, name, country_id, full_address, postcode, active)
  VALUES (v_shipper_id, 'Progressive Test Hub', v_country_id, '1 Test Street', 'P8 8ST', true)
  RETURNING id INTO v_hub_id;

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO markup_categories (shipper_id, category_name, default_markup_pct, active)
  VALUES (v_shipper_id, 'Progressive Test Category ' || v_suffix, 0.000, true)
  RETURNING id INTO v_markup_category_id;

  INSERT INTO retailers (name, website_url, global_enabled)
  VALUES ('Progressive Test Retailer ' || v_suffix, 'https://retailer.example.test', true)
  RETURNING id INTO v_retailer_id;

  INSERT INTO retailer_accounts (
    retailer_id, shipper_id, account_email, account_username,
    credential_delivery_method, delivery_address_locked_to_hub_id, status
  )
  VALUES (
    v_retailer_id, v_shipper_id, 'retailer.progressive.' || v_suffix || '@example.test',
    'progressive_' || v_suffix, 'pending_vault_upgrade', v_hub_id, 'active'
  )
  RETURNING id INTO v_retailer_account_id;

  INSERT INTO operators (email, phone, full_name, auth_user_id, active)
  VALUES ('operator.progressive.' || v_suffix || '@example.test', '+440000000000', 'Progressive Operator', gen_random_uuid(), true)
  RETURNING id INTO v_operator_id;

  INSERT INTO importers (shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_shipper_id, v_country_id, 'Progressive Importer Ltd ' || v_suffix, 'Progressive Importer', true)
  RETURNING id INTO v_importer_id;

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO installation (deployment_mode, active_shipper_id, platform_name_override, netp_status)
  VALUES ('multi_tenant', NULL, 'Progressive Test Platform', true)
  RETURNING id INTO v_installation_id;

  INSERT INTO sage_config (
    installation_id, version_number, effective_from, sage_tenant_id,
    sage_api_credentials_vault_ref, default_sales_tax_code, default_purchase_tax_code,
    ar_nominal_code, ap_retailer_nominal_code, ap_shipper_nominal_code,
    sales_exports_nominal_code, cogs_goods_nominal_code, cogs_shipping_nominal_code,
    fx_gain_loss_nominal_code, sales_adjustment_zero_rating_nominal_code,
    vat_input_nominal_code, vat_output_nominal_code, vat_liability_nominal_code,
    vat_adjustments_nominal_code, created_by_staff_id
  )
  VALUES (
    v_installation_id, 1, now(), 'sage-tenant-progressive-' || v_suffix,
    'vault/progressive/' || v_suffix, 'T0', 'T1',
    '1100', '2100', '2200',
    '4000', '5000', '5100',
    '7900', '4050',
    '2201', '2202', '2203',
    '2204', v_staff_id
  )
  RETURNING id INTO v_sage_config_id;

  -- ---------------------------------------------------------------------------
  -- Parent order: 5 quoted items / £500, fully prepaid in Q1.
  -- Four items progress now; one replacement child comes later.
  -- ---------------------------------------------------------------------------
  INSERT INTO orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_total_gbp_declared, total_qty_declared,
    sop_version, status, funded_at
  )
  VALUES (
    'PROG-PARENT-' || v_suffix, 'AUTH-PROG-' || v_suffix, v_importer_id, v_operator_id,
    v_shipper_id, v_retailer_id, v_hub_id, 500.00, 5,
    'PROG', 'pending_dva_funding', now()
  )
  RETURNING id INTO v_parent_order_id;

  INSERT INTO order_funding_events (
    order_id, event_type, amount_gbp, source_ref, source_entity_type,
    source_entity_id, created_by_staff_id, created_at, notes
  )
  VALUES (
    v_parent_order_id, 'funding_contribution', 500.00, 'PREPAY-' || v_suffix,
    'manual_test_prepayment', gen_random_uuid(), v_staff_id, TIMESTAMPTZ '2044-03-28 10:00:00+00',
    'Progressive release smoke test full prepayment'
  );

  INSERT INTO order_category_lines (
    order_id, markup_category_id, qty, amount_inc_vat_gbp,
    markup_pct_applied, markup_gbp_calculated
  )
  VALUES (v_parent_order_id, v_markup_category_id, 5, 500.00, 0.000, 0.00);

  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_parent_order_id, v_retailer_id, v_retailer_account_id,
    'INV-PROG-PARENT-' || v_suffix, 'https://storage.example.test/progressive-parent.pdf',
    v_operator_id, 'mindee'
  )
  RETURNING id INTO v_parent_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_parent_invoice_id, 1, 'SKU-4-STABLE', 'Four stable items', 4, 'mixed',
    400.00, 'ocr_extracted', 4, 400.00, 'Y'
  )
  RETURNING id INTO v_parent_line_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_parent_invoice_id, 2, 'SKU-1-REPLACE', 'One replacement item pending', 1, 'mixed',
    100.00, 'manually_added', 0, 0.00, 'N'
  )
  RETURNING id INTO v_missing_line_id;

  -- Parent progressed subset has reached UK shipper receipt, making the four items stable for commercial release.
  INSERT INTO shipping_quotes (
    shipper_id, quote_gbp_total, status, hub_receipt_confirmed_at,
    hub_receipt_confirmed_by_staff_id, created_at
  )
  VALUES (v_shipper_id, 40.00, 'hub_received', now(), v_staff_id, now())
  RETURNING id INTO v_parent_quote_id;

  INSERT INTO shipping_quote_orders (
    shipping_quote_id, order_id, order_value_gbp, apportionment_pct,
    apportioned_shipping_gbp
  )
  VALUES (v_parent_quote_id, v_parent_order_id, 400.00, 100.0000, 40.00);

  -- First commercial release: four stable items only.
  SELECT create_progressive_customer_invoice_release(
    v_parent_order_id,
    v_staff_id,
    DATE '2044-04-20',
    DATE '2044-05-04'
  )
  INTO v_first_sales_invoice_id;

  SELECT invoice_type, amount_gbp, linked_invoice_id, order_id, tax_point_period, sage_invoice_period
    INTO v_invoice_type, v_amount, v_linked_id, v_order_id, v_period, v_sage_period
  FROM sales_invoices
  WHERE id = v_first_sales_invoice_id;

  IF v_invoice_type <> 'main' OR v_amount <> 400.00 OR v_linked_id IS NOT NULL OR v_order_id <> v_parent_order_id THEN
    RAISE EXCEPTION 'FAIL: first progressive release should be one MAIN invoice for £400 on the parent order';
  END IF;

  IF v_period <> '2044-Q1' THEN
    RAISE EXCEPTION 'FAIL: first progressive invoice tax period %, expected 2044-Q1 from prepayment date', v_period;
  END IF;

  -- Confirm one Sage posting queue row was created for the first invoice.
  SELECT COUNT(*)
    INTO v_count
  FROM sage_postings
  WHERE source_table = 'sales_invoices'
    AND source_id = v_first_sales_invoice_id
    AND posting_type = 'ar_invoice'
    AND idempotency_key = 'sales-invoice:' || v_first_sales_invoice_id::text;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: first progressive release did not create exactly one Sage AR invoice queue row';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Create replacement child for the one unresolved item.
  -- ---------------------------------------------------------------------------
  INSERT INTO disputes (
    order_id, raised_by_operator_id, issue_type, desired_outcome,
    liable_party, stage_detected, amount_impact_gbp, comments_initial, status, sop_version
  )
  VALUES (
    v_parent_order_id, v_operator_id, 'missing', 'replacement',
    'retailer', 'at_reconciliation', 100.00, 'Progressive replacement child exception', 'raised', 'PROG'
  )
  RETURNING id INTO v_replacement_dispute_id;

  INSERT INTO dispute_lines (
    dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, conversation_status, intended_remedy
  )
  VALUES (
    v_replacement_dispute_id, v_missing_line_id, 1, 100.00,
    'affected', 'remedy_selected', 'replacement'
  )
  RETURNING id INTO v_replacement_dispute_line_id;

  SELECT create_replacement_child_order(v_parent_order_id, v_replacement_dispute_line_id, v_staff_id)
    INTO v_child_order_id;

  INSERT INTO supplier_invoices (
    order_id, retailer_id, retailer_account_id, invoice_ref, invoice_pdf_url,
    uploaded_by_operator_id, ocr_service_used
  )
  VALUES (
    v_child_order_id, v_retailer_id, v_retailer_account_id,
    'INV-PROG-CHILD-' || v_suffix, 'https://storage.example.test/progressive-child.pdf',
    v_operator_id, 'mindee'
  )
  RETURNING id INTO v_child_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id, line_order, retailer_sku, description, qty, size,
    amount_inc_vat_gbp, line_source, qty_confirmed, amount_confirmed,
    eligible_for_invoice_yn
  )
  VALUES (
    v_child_invoice_id, 1, 'SKU-1-REPLACE-ARRIVED', 'Late replacement item arrived', 1, 'mixed',
    100.00, 'ocr_extracted', 1, 100.00, 'Y'
  )
  RETURNING id INTO v_child_line_id;

  -- Replacement child has reached UK shipper receipt, making the late item stable for commercial release.
  INSERT INTO shipping_quotes (
    shipper_id, quote_gbp_total, status, hub_receipt_confirmed_at,
    hub_receipt_confirmed_by_staff_id, created_at
  )
  VALUES (v_shipper_id, 10.00, 'hub_received', now(), v_staff_id, now())
  RETURNING id INTO v_child_quote_id;

  INSERT INTO shipping_quote_orders (
    shipping_quote_id, order_id, order_value_gbp, apportionment_pct,
    apportioned_shipping_gbp
  )
  VALUES (v_child_quote_id, v_child_order_id, 100.00, 100.0000, 10.00);

  -- Second commercial release: replacement child source line invoices against the original parent as supplementary.
  SELECT create_progressive_customer_invoice_release(
    v_parent_order_id,
    v_staff_id,
    DATE '2044-05-20',
    DATE '2044-06-10'
  )
  INTO v_second_sales_invoice_id;

  SELECT invoice_type, amount_gbp, linked_invoice_id, order_id, tax_point_period, sage_invoice_period
    INTO v_invoice_type, v_amount, v_linked_id, v_order_id, v_period, v_sage_period
  FROM sales_invoices
  WHERE id = v_second_sales_invoice_id;

  IF v_invoice_type <> 'supplementary' OR v_amount <> 100.00 OR v_linked_id <> v_first_sales_invoice_id OR v_order_id <> v_parent_order_id THEN
    RAISE EXCEPTION 'FAIL: replacement item should create a SUPPLEMENTARY £100 invoice linked to the parent main invoice';
  END IF;

  IF v_period <> '2044-Q1' THEN
    RAISE EXCEPTION 'FAIL: supplementary invoice tax period %, expected 2044-Q1 from original prepayment date', v_period;
  END IF;

  -- No second main invoice for the same parent order.
  SELECT COUNT(*)
    INTO v_count
  FROM sales_invoices
  WHERE order_id = v_parent_order_id
    AND invoice_type = 'main'
    AND sage_status <> 'void';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one non-void MAIN invoice for the parent order, found %', v_count;
  END IF;

  -- Parent order now has total customer invoice releases of £500.
  SELECT COALESCE(SUM(amount_gbp), 0)
    INTO v_amount
  FROM sales_invoices
  WHERE order_id = v_parent_order_id
    AND invoice_type IN ('main','supplementary')
    AND sage_status <> 'void';

  IF v_amount <> 500.00 THEN
    RAISE EXCEPTION 'FAIL: parent customer invoice releases total %, expected 500.00', v_amount;
  END IF;

  -- Replacement child must not have its own customer sales invoice.
  SELECT COUNT(*)
    INTO v_count
  FROM sales_invoices
  WHERE order_id = v_child_order_id
    AND sage_status <> 'void';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: replacement child order should not carry its own customer sales invoice';
  END IF;

  -- Replacement child must not have fresh customer funding events.
  SELECT COUNT(*)
    INTO v_count
  FROM order_funding_events
  WHERE order_id = v_child_order_id
    AND event_type IN ('funding_contribution','credit_applied');

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: replacement child order should not create fresh customer funding events';
  END IF;

  -- Rerunning release should be blocked because every eligible line is already invoiced.
  BEGIN
    PERFORM create_progressive_customer_invoice_release(v_parent_order_id, v_staff_id, DATE '2044-06-01', DATE '2044-06-10');
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: duplicate progressive customer invoice release was not blocked';
  END IF;

  -- VAT release/workings still report the full prepayment/tax-point period once, not duplicate May invoice timing.
  PERFORM derive_order_vat_tax_point(v_parent_order_id);

  UPDATE orders
  SET vat_rate_applied = 'zero_rated',
      vat_release_approved_at = now(),
      vat_release_approved_by_staff_id = v_staff_id,
      vat_release_evidence_json = jsonb_build_object('test','progressive_release_export_evidence')
  WHERE id = v_parent_order_id;

  SELECT post_to_vat_return_workings(v_parent_order_id)
    INTO v_working_id;

  SELECT final_box6
    INTO v_amount
  FROM vat_return_workings
  WHERE return_period = '2044-Q1';

  IF v_amount <> 500.00 THEN
    RAISE EXCEPTION 'FAIL: VAT workings final_box6 = %, expected 500.00 from full Q1 prepayment, not duplicate invoice dates', v_amount;
  END IF;
END $$;


ROLLBACK;

-- ============================================================================
-- END INCLUDED TEST: day8_progressive_commercial_release_smoke_test.sql
-- ============================================================================



-- BEGIN INCLUDED TEST: day9_hardening_contract_smoke_test.sql
-- day9_hardening_contract_smoke_test.sql
-- Multi Tenant Platform Build — Day 9 backend hardening / contract smoke test.
-- Run after a clean install using closure_v2_functions_v2_final_progressive_release.sql
-- and after the Day 2-8 combined regression has passed.
--
-- This does not add business logic. It checks that the final pack still exposes
-- the critical contracts, triggers, RLS policies, uniqueness guards, VAT timing
-- override, and progressive commercial release helpers needed before UI wiring.

CREATE TEMP TABLE IF NOT EXISTS day9_hardening_results(result text) ON COMMIT PRESERVE ROWS;
TRUNCATE day9_hardening_results;

DO $$
DECLARE
  v_cols text[];
  v_missing text[];
  v_def text;
  v_policy_count int;
BEGIN
  -- 1. Baseline-compatible importer balance view shape must never drift again.
  SELECT array_agg(column_name::text ORDER BY ordinal_position)
    INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'importer_balance_vw';

  IF v_cols IS DISTINCT FROM ARRAY[
    'importer_id',
    'available_credit_gbp',
    'pending_refund_gbp',
    'active_order_funding_gbp',
    'payout_in_progress_gbp',
    'last_refreshed_at'
  ]::text[] THEN
    RAISE EXCEPTION 'FAIL: importer_balance_vw shape drifted. Actual columns: %', v_cols;
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_IMPORTER_BALANCE_VIEW_SHAPE_PASSED');

  -- 2. Required function contracts must exist.
  WITH required(function_name) AS (
    VALUES
      ('current_staff_role'),
      ('entity_requires_admin_review'),
      ('order_has_open_child_exceptions'),
      ('order_has_progressed_subset'),
      ('recompute_order_platform_funded'),
      ('sync_order_overfunding_credit'),
      ('recompute_order_status'),
      ('prevent_ocr_supplier_invoice_line_delete'),
      ('enforce_refund_dispute_line_gate'),
      ('apply_importer_credit_to_order'),
      ('create_replacement_child_order'),
      ('mark_shipping_quote_confirmed_ready_for_booking'),
      ('derive_order_vat_tax_point'),
      ('approve_vat_release'),
      ('post_to_vat_return_workings'),
      ('mark_order_accounting_release_ready'),
      ('create_progressive_customer_invoice_release')
  )
  SELECT array_agg(r.function_name ORDER BY r.function_name)
    INTO v_missing
  FROM required r
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = r.function_name
  );

  IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'FAIL: missing required Day 2-8 function contracts: %', v_missing;
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_REQUIRED_FUNCTION_CONTRACTS_PASSED');

  -- 3. Critical triggers must be installed.
  WITH required(table_name, trigger_name) AS (
    VALUES
      ('orders','trg_lock_quote_snapshot_on_order_submit'),
      ('dva_reconciliation','trg_sync_order_funding_event_from_dva_reconciliation'),
      ('importer_credit_ledger','trg_sync_order_funding_event_from_importer_credit_ledger'),
      ('order_funding_events','trg_recompute_order_platform_funded_from_event'),
      ('order_tracking_submissions','trg_recompute_order_status_from_tracking'),
      ('supplier_invoices','trg_recompute_order_status_from_invoice'),
      ('supplier_invoice_lines','trg_recompute_order_status_from_invoice_line'),
      ('supplier_invoice_lines','trg_prevent_ocr_supplier_invoice_line_delete'),
      ('shipping_quotes','trg_recompute_order_status_from_shipping_quote'),
      ('dispute_lines','trg_unlock_credits_on_dispute_line_resolve'),
      ('dispute_lines','trg_enforce_refund_dispute_line_gate')
  )
  SELECT array_agg(r.table_name || '.' || r.trigger_name ORDER BY r.table_name, r.trigger_name)
    INTO v_missing
  FROM required r
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = r.table_name
      AND t.tgname = r.trigger_name
      AND NOT t.tgisinternal
  );

  IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'FAIL: missing critical trigger coverage: %', v_missing;
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_REQUIRED_TRIGGER_COVERAGE_PASSED');

  -- 4. Critical uniqueness/idempotency guards must exist.
  WITH required(index_name) AS (
    VALUES
      ('uq_orders_payment_auth_id'),
      ('uq_sales_invoices_one_main_per_order'),
      ('uq_sage_postings_idempotency_key'),
      ('uq_order_funding_events_source')
  )
  SELECT array_agg(r.index_name ORDER BY r.index_name)
    INTO v_missing
  FROM required r
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'i'
      AND c.relname = r.index_name
  );

  IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'FAIL: missing critical unique/idempotency indexes: %', v_missing;
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_CRITICAL_UNIQUENESS_GUARDS_PASSED');

  -- 5. Portal RLS should stay enabled on runtime portal tables.
  WITH required(table_name) AS (
    VALUES
      ('supplier_invoices'),
      ('supplier_invoice_lines'),
      ('disputes'),
      ('dispute_lines'),
      ('shipping_quotes'),
      ('shipping_quote_orders')
  )
  SELECT array_agg(r.table_name ORDER BY r.table_name)
    INTO v_missing
  FROM required r
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = r.table_name
      AND c.relrowsecurity = true
  );

  IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'FAIL: RLS not enabled on required portal tables: %', v_missing;
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_PORTAL_RLS_ENABLED_STILL_PASSED');

  -- 6. Day 7 policy coverage should stay present.
  WITH required(policy_name) AS (
    VALUES
      ('staff_all_supplier_invoices'),
      ('operator_own_supplier_invoices'),
      ('staff_all_supplier_invoice_lines'),
      ('operator_own_supplier_invoice_lines'),
      ('staff_all_disputes'),
      ('operator_own_disputes'),
      ('shipper_read_own_disputes'),
      ('staff_all_dispute_lines'),
      ('operator_own_dispute_lines'),
      ('shipper_read_own_dispute_lines'),
      ('staff_all_shipping_quotes'),
      ('shipper_own_shipping_quotes'),
      ('operator_read_own_shipping_quotes'),
      ('staff_all_shipping_quote_orders'),
      ('shipper_own_shipping_quote_orders'),
      ('operator_read_own_shipping_quote_orders')
  )
  SELECT array_agg(r.policy_name ORDER BY r.policy_name)
    INTO v_missing
  FROM required r
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.policyname = r.policy_name
  );

  IF COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'FAIL: missing Day 7 portal policy coverage after final pack consolidation: %', v_missing;
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_PORTAL_RLS_POLICY_COVERAGE_STILL_PASSED');

  -- 7. VAT Timing Addendum override must be the active function body.
  v_def := pg_get_functiondef('public.derive_order_vat_tax_point(uuid)'::regprocedure);

  IF v_def NOT ILIKE '%v_prepayment_tax_point%'
     OR v_def NOT ILIKE '%funding_contribution%'
     OR v_def NOT ILIKE '%credit_applied%'
     OR v_def NOT ILIKE '%dispatched_at%' THEN
    RAISE EXCEPTION 'FAIL: derive_order_vat_tax_point is not the final prepayment-first/fallback-dispatch version';
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_VAT_PREPAYMENT_FIRST_OVERRIDE_ACTIVE_PASSED');

  -- 8. VAT workings must still include carry-in/carry-out and Box 1 breach/reinstatement support.
  -- Final Day 6/8 clarification moved the adjustment logic into the period helper.
  -- post_to_vat_return_workings(uuid) is now a wrapper, so checking only the wrapper creates a false failure.
  v_def := pg_get_functiondef('public.post_to_vat_return_workings_for_period(character varying, uuid)'::regprocedure);

  IF v_def NOT ILIKE '%box6_carry_in%'
     OR v_def NOT ILIKE '%box6_carry_out%'
     OR v_def NOT ILIKE '%box1_breach%'
     OR v_def NOT ILIKE '%box1_reinstatement%'
     OR v_def NOT ILIKE '%vat_sales_invoice_reporting_vw%' THEN
    RAISE EXCEPTION 'FAIL: post_to_vat_return_workings_for_period is missing final Day 8 timing / Box 1 adjustment support';
  END IF;

  v_def := pg_get_functiondef('public.post_to_vat_return_workings(uuid)'::regprocedure);

  IF v_def NOT ILIKE '%post_to_vat_return_workings_for_period%'
     OR v_def NOT ILIKE '%replacement_child%' THEN
    RAISE EXCEPTION 'FAIL: post_to_vat_return_workings wrapper is not delegating to final Day 6/8 period helper or blocking replacement children';
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_VAT_WORKINGS_ADJUSTMENT_SUPPORT_ACTIVE_PASSED');

  -- 9. Progressive commercial release function and helper views must be active.
  v_def := pg_get_functiondef('public.create_progressive_customer_invoice_release(uuid, uuid, date, date)'::regprocedure);

  IF v_def NOT ILIKE '%supplementary%'
     OR v_def NOT ILIKE '%progressive_invoiceable_lines_vw%'
     OR v_def NOT ILIKE '%sales-invoice:%'
     OR v_def NOT ILIKE '%Replacement child%'
     OR v_def NOT ILIKE '%funded_at IS NULL%' THEN
    RAISE EXCEPTION 'FAIL: create_progressive_customer_invoice_release is not the final progressive release version';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='public' AND c.relname='sales_invoice_released_line_ids_vw' AND c.relkind IN ('v','m'))
     OR NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='public' AND c.relname='progressive_invoiceable_lines_vw' AND c.relkind IN ('v','m')) THEN
    RAISE EXCEPTION 'FAIL: progressive release helper views are missing';
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_PROGRESSIVE_RELEASE_CONTRACT_ACTIVE_PASSED');

  -- 10. Breach candidate view must include supplementary invoices too.
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.views
    WHERE table_schema = 'public'
      AND table_name = 'vat_export_deadline_breach_candidates_vw'
  ) THEN
    RAISE EXCEPTION 'FAIL: vat_export_deadline_breach_candidates_vw is missing';
  END IF;

  v_def := pg_get_viewdef('public.vat_export_deadline_breach_candidates_vw'::regclass, true);
  IF v_def NOT ILIKE '%supplementary%' THEN
    RAISE EXCEPTION 'FAIL: export deadline breach candidate view does not include supplementary invoices';
  END IF;

  INSERT INTO day9_hardening_results VALUES ('DAY9_EXPORT_BREACH_VIEW_INCLUDES_SUPPLEMENTARY_PASSED');
END;
$$;


-- Final consolidated Day 2-9 result set for Supabase SQL Editor

-- ============================================================================
-- BEGIN INCLUDED TEST: day6_8_vat_reporting_clarification_smoke_test.sql
-- ============================================================================

-- day6_8_vat_reporting_clarification_smoke_test.sql
-- Multi Tenant Platform Build — Day 6/8 clarification smoke test
-- Run after applying day6_8_vat_reporting_clarification_hotfix.sql.
--
-- Scope:
--   A. VAT workings can include on-track prepayment-timed sales invoice releases before final export evidence clearance.
--   B. VAT workings are sales-invoice based, not full order-total based.
--   C. Main + supplementary customer invoice releases are both included in Box 6.
--   D. Replacement child orders do not own VAT workings.
--   E. Period-based Box 1 breach adjustments can be posted even without a sales invoice in that breach period.
--
-- If any check fails, execution stops with the first error.

BEGIN;

DO $$
DECLARE
  v_staff_id uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_country_id uuid;
  v_order_id uuid := gen_random_uuid();
  v_child_order_id uuid := gen_random_uuid();
  v_main_invoice_id uuid := gen_random_uuid();
  v_supp_invoice_id uuid := gen_random_uuid();
  v_breach_adjustment_id uuid;
  v_working_id uuid;
  v_box6 numeric;
  v_box1 numeric;
  v_section_c numeric;
  v_blocked boolean;
  v_reporting_rows int;
BEGIN
  IF to_regclass('public.vat_sales_invoice_reporting_vw') IS NULL THEN
    RAISE EXCEPTION 'FAIL: vat_sales_invoice_reporting_vw missing';
  END IF;

  IF to_regprocedure('public.post_to_vat_return_workings_for_period(character varying, uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: post_to_vat_return_workings_for_period(varchar, uuid) missing';
  END IF;

  SELECT id INTO v_country_id FROM countries WHERE iso_code = 'GHA' LIMIT 1;
  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: GHA country seed missing';
  END IF;

  INSERT INTO staff (id, auth_user_id, role_type, full_name, email, active)
  VALUES (v_staff_id, gen_random_uuid(), 'admin', 'Day 6/8 Clarification Admin', 'day68-admin-' || left(v_staff_id::text, 8) || '@example.test', true);

  INSERT INTO shippers (id, name, contact_email, vat_treatment, active)
  VALUES (v_shipper_id, 'Day 6/8 Clarification Shipper', 'day68-shipper-' || left(v_shipper_id::text, 8) || '@example.test', 'outside_scope', true);

  INSERT INTO hubs (id, shipper_id, name, country_id, full_address, active)
  VALUES (v_hub_id, v_shipper_id, 'Day 6/8 Clarification Hub', v_country_id, 'Day 6/8 Test Address', true);

  UPDATE shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO retailers (id, name, website_url, global_enabled)
  VALUES (v_retailer_id, 'Day 6/8 Clarification Retailer', 'https://day68.example.test', true);

  INSERT INTO importers (id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_importer_id, v_shipper_id, v_country_id, 'Day 6/8 Importer Ltd', 'Day 6/8 Importer', true);

  INSERT INTO operators (id, email, full_name, auth_user_id, active)
  VALUES (v_operator_id, 'day68-operator-' || left(v_operator_id::text, 8) || '@example.test', 'Day 6/8 Operator', gen_random_uuid(), true);

  INSERT INTO operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  -- Declared order total is intentionally 999.00. VAT workings must use the released sales invoice total of 300.00 instead.
  INSERT INTO orders (
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared, total_qty_declared,
    bundled_quote_gbp, quote_fx_rate, quote_card_markup_pct, quote_total_ghs,
    funded_at, status, sop_version
  )
  VALUES
    (v_order_id, 'DAY68-VAT-' || left(v_order_id::text, 8), 'AUTH-D68-VAT', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 999.00, 9, 999.00, 1.0, 0.0, 999.00, now(), 'awaiting_financial_closure', 'day68-v1'),
    (v_child_order_id, 'DAY68-CHILD-' || left(v_child_order_id::text, 8), NULL, v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'replacement_child', 100.00, 1, 100.00, 1.0, 0.0, 100.00, NULL, 'awaiting_financial_closure', 'day68-v1');

  UPDATE orders SET parent_order_id = v_order_id WHERE id = v_child_order_id;

  -- Main + supplementary customer invoice releases are on-track and have no export evidence yet.
  -- They should still appear in VAT reporting because the evidence deadline has not expired.
  INSERT INTO sales_invoices (
    id, order_id, invoice_type, linked_invoice_id, consideration_received_date, sage_invoice_date,
    tax_point_period, sage_invoice_period, vat_box6_reported_period,
    amount_gbp, vat_code, line_items_json, export_evidence_complete_date,
    zero_rating_deadline_date, zero_rating_status, sage_status, raised_by_trigger
  )
  VALUES
    (
      v_main_invoice_id, v_order_id, 'main', NULL,
      DATE '2044-04-10', DATE '2044-05-01',
      '2044-Q2', '2044-Q2', '2044-Q2',
      200.00, 'T0', jsonb_build_array(jsonb_build_object('description','Stable first release','amount_gbp',200.00)),
      NULL, DATE '2044-07-09', 'on_track', 'draft', true
    ),
    (
      v_supp_invoice_id, v_order_id, 'supplementary', v_main_invoice_id,
      DATE '2044-04-10', DATE '2044-05-20',
      '2044-Q2', '2044-Q2', '2044-Q2',
      100.00, 'T0', jsonb_build_array(jsonb_build_object('description','Late replacement supplementary release','amount_gbp',100.00)),
      NULL, DATE '2044-07-09', 'on_track', 'draft', true
    );

  SELECT COUNT(*) INTO v_reporting_rows
  FROM vat_sales_invoice_reporting_vw
  WHERE order_id = v_order_id
    AND vat_box6_reported_period = '2044-Q2'
    AND evidence_pending_within_deadline_yn = true;

  IF v_reporting_rows <> 2 THEN
    RAISE EXCEPTION 'FAIL: expected 2 on-track VAT reporting rows before final evidence clearance, got %', v_reporting_rows;
  END IF;

  SELECT post_to_vat_return_workings(v_order_id) INTO v_working_id;

  SELECT final_box6, section_c_total
    INTO v_box6, v_section_c
  FROM vat_return_workings
  WHERE id = v_working_id;

  IF v_box6 <> 300.00 OR v_section_c <> 300.00 THEN
    RAISE EXCEPTION 'FAIL: VAT workings should be sales-invoice based at 300.00, got final_box6 %, section_c_total %. This means it is still using full order total or excluding on-track evidence.', v_box6, v_section_c;
  END IF;

  -- Replacement child must not own VAT workings directly.
  v_blocked := false;
  BEGIN
    PERFORM post_to_vat_return_workings(v_child_order_id);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;

  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL: replacement child order was allowed to own VAT workings directly';
  END IF;

  -- Box 1 breach adjustment can be generated for the breach period itself via the period helper.
  INSERT INTO vat_return_adjustments (
    return_period, report_type, source_sales_invoice_id, amount_gbp, direction,
    posted_by_staff_id, notes
  )
  VALUES (
    '2044-Q3', 'box1_breach', v_main_invoice_id, 33.33, 'add',
    v_staff_id, 'Day 6/8 clarification Box 1 breach adjustment fixture'
  )
  RETURNING id INTO v_breach_adjustment_id;

  SELECT post_to_vat_return_workings_for_period('2044-Q3', v_staff_id) INTO v_working_id;

  SELECT final_box1, final_box6
    INTO v_box1, v_box6
  FROM vat_return_workings
  WHERE id = v_working_id;

  IF v_box1 <> 33.33 THEN
    RAISE EXCEPTION 'FAIL: Q3 final_box1 = %, expected 33.33 breach adjustment', v_box1;
  END IF;

  IF COALESCE(v_box6, 0) <> 0 THEN
    RAISE EXCEPTION 'FAIL: Q3 final_box6 = %, expected 0.00 because the breach period has no new sales invoice Box 6 value', v_box6;
  END IF;
END $$;


ROLLBACK;

-- ============================================================================
-- END INCLUDED TEST: day6_8_vat_reporting_clarification_smoke_test.sql
-- ============================================================================

-- ============================================================================
-- FINAL CONSOLIDATED DAY 2-9 + DAY 6/8 CLARIFICATION PASS REPORT
-- ============================================================================
SELECT result
FROM (VALUES
  ('DAY2_SMOKE_TEST_CORE_PASSED'),
  ('DAY2_OVERFUNDING_CREDIT_SMOKE_TEST_PASSED'),
  ('DAY3_TRACKING_FIRST_PASSED'),
  ('DAY3_INVOICE_FIRST_PASSED'),
  ('DAY3_OCR_PROGRESS_SUBSET_PASSED'),
  ('DAY3_PARTIAL_PROGRESS_BLOCKS_FULL_CLEARANCE_PASSED'),
  ('DAY3_MANUAL_LINE_DELETE_ALLOWED_PASSED'),
  ('DAY3_OCR_SOURCE_DELETE_PROTECTION_PASSED'),
  ('DAY4_REPLACEMENT_CHILD_CREATED_PASSED'),
  ('DAY4_REPLACEMENT_CHILD_LINKAGE_PASSED'),
  ('DAY4_REPLACEMENT_NO_FRESH_FUNDING_PASSED'),
  ('DAY4_DUPLICATE_REPLACEMENT_BLOCKED_PASSED'),
  ('DAY4_REPLACEMENT_OF_REPLACEMENT_BLOCKED_PASSED'),
  ('DAY4_REPLACEMENT_INVOICE_ATTACHES_TO_CHILD_PASSED'),
  ('DAY4_REFUND_GATE_BLOCKS_BEFORE_APPROVAL_PASSED'),
  ('DAY4_REFUND_GATE_ALLOWS_AFTER_APPROVAL_PASSED'),
  ('DAY5_DRAFT_QUOTE_NOT_DIRECTLY_BOOKABLE_PASSED'),
  ('DAY5_EXPLICIT_READY_FOR_SHIPMENT_HANDOFF_PASSED'),
  ('DAY5_BOOKED_QUOTE_MOVES_ORDER_TO_SHIPMENT_BOOKED_PASSED'),
  ('DAY5_NO_PROGRESSED_SUBSET_CONFIRMATION_BLOCKED_PASSED'),
  ('DAY5_OVERSCOPED_SHIPMENT_VALUE_BLOCKED_PASSED'),
  ('DAY5_MULTI_ORDER_QUOTE_UPDATES_ALL_ORDERS_PASSED'),
  ('DAY6_ACCOUNTING_RELEASE_BLOCKS_UNFUNDED_ORDER_PASSED'),
  ('DAY6_ACCOUNTING_RELEASE_BLOCKS_OPEN_CHILDREN_PASSED'),
  ('DAY6_ACCOUNTING_RELEASE_ALLOWED_WHEN_STABLE_PASSED'),
  ('DAY6_VAT_RELEASE_BLOCKS_REPLACEMENT_CHILD_PASSED'),
  ('DAY6_VAT_RELEASE_BLOCKS_MISSING_EXPORT_EVIDENCE_PASSED'),
  ('DAY6_EXPORT_EVIDENCE_DISPATCH_CHECKPOINT_STAMPED_PASSED'),
  ('DAY6_ZERO_RATING_EVIDENCE_CHECKPOINT_PASSED'),
  ('DAY6_VAT_WORKINGS_IDEMPOTENT_PASSED'),
  ('DAY6_SAGE_POSTING_QUEUE_CONTRACT_PASSED'),
  ('DAY6_SAGE_POSTING_IDEMPOTENCY_BLOCKS_DUPLICATES_PASSED'),
  ('DAY7_AUTH_HELPER_CONTRACTS_EXIST_PASSED'),
  ('DAY7_RLS_ENABLED_ON_PORTAL_TABLES_PASSED'),
  ('DAY7_PORTAL_RLS_POLICY_COVERAGE_PASSED'),
  ('DAY7_PARALLEL_LANE_READ_MODEL_PASSED'),
  ('DAY7_REPLACEMENT_CHILD_FUNDING_OVERLAY_PASSED'),
  ('DAY7_SHIPMENT_DELIVERY_READ_MODEL_PASSED'),
  ('DAY8_VAT_RELEASE_BLOCKS_OPEN_CHILDREN_PASSED'),
  ('DAY8_VAT_RELEASE_BLOCKS_REPLACEMENT_CHILD_PASSED'),
  ('DAY8_VAT_TAX_POINT_USES_PREPAYMENT_DATE_PASSED'),
  ('DAY8_VAT_PERIOD_FROM_PREPAYMENT_QUARTER_PASSED'),
  ('DAY8_VAT_WORKINGS_IDEMPOTENT_PASSED'),
  ('DAY8_CARRY_IN_ADJUSTMENT_INCLUDED_IN_BOX6_PASSED'),
  ('DAY8_CARRY_OUT_ADJUSTMENT_EXCLUDED_FROM_BOX6_PASSED'),
  ('DAY8_BOX1_BREACH_ADJUSTMENT_INCLUDED_PASSED'),
  ('DAY8_EXPORT_DEADLINE_BREACH_REPORT_PASSED'),
  ('DAY8_VAT_OVERRIDE_ESCALATION_RULE_PASSED'),
  ('DAY8_PROGRESSIVE_FIRST_RELEASE_MAIN_INVOICE_PASSED'),
  ('DAY8_PROGRESSIVE_REPLACEMENT_SUPPLEMENTARY_INVOICE_PASSED'),
  ('DAY8_PROGRESSIVE_NO_SECOND_MAIN_INVOICE_PASSED'),
  ('DAY8_REPLACEMENT_CHILD_NO_OWN_CUSTOMER_INVOICE_PASSED'),
  ('DAY8_REPLACEMENT_CHILD_NO_FRESH_FUNDING_PASSED'),
  ('DAY8_DUPLICATE_LINE_RELEASE_BLOCKED_PASSED'),
  ('DAY8_PROGRESSIVE_RELEASE_SAGE_QUEUE_PASSED'),
  ('DAY8_PROGRESSIVE_RELEASE_VAT_NOT_DUPLICATED_PASSED'),
  ('DAY9_CRITICAL_UNIQUENESS_GUARDS_PASSED'),
  ('DAY9_EXPORT_BREACH_VIEW_INCLUDES_SUPPLEMENTARY_PASSED'),
  ('DAY9_IMPORTER_BALANCE_VIEW_SHAPE_PASSED'),
  ('DAY9_PORTAL_RLS_ENABLED_STILL_PASSED'),
  ('DAY9_PORTAL_RLS_POLICY_COVERAGE_STILL_PASSED'),
  ('DAY9_PROGRESSIVE_RELEASE_CONTRACT_ACTIVE_PASSED'),
  ('DAY9_REQUIRED_FUNCTION_CONTRACTS_PASSED'),
  ('DAY9_REQUIRED_TRIGGER_COVERAGE_PASSED'),
  ('DAY9_VAT_PREPAYMENT_FIRST_OVERRIDE_ACTIVE_PASSED'),
  ('DAY9_VAT_WORKINGS_ADJUSTMENT_SUPPORT_ACTIVE_PASSED'),
  ('DAY6_8_VAT_REPORTING_INCLUDES_ON_TRACK_PREPAYMENT_RELEASES_PASSED'),
  ('DAY6_8_VAT_REPORTING_USES_SALES_INVOICES_NOT_ORDER_TOTAL_PASSED'),
  ('DAY6_8_MAIN_AND_SUPPLEMENTARY_INCLUDED_IN_BOX6_PASSED'),
  ('DAY6_8_REPLACEMENT_CHILD_DOES_NOT_OWN_VAT_WORKINGS_PASSED'),
  ('DAY6_8_BOX1_BREACH_PERIOD_HELPER_PASSED')
) AS final_results(result)
ORDER BY result;
