-- Real rollback-safe regression for the three funding outcomes, pending-surplus
-- evidence/credit lifecycle, legacy surplus compatibility, reversal, and one
-- physical supplier OUT allocated A + B + C + FX.
--
-- Run after all migrations through 20260722d. Every fixture and result is rolled
-- back. Any failed assertion aborts the transaction with an exact message.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_country_id uuid;
  v_staff_id uuid := gen_random_uuid();
  v_auth_uid uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_markup_category_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_retailer_account_id uuid := gen_random_uuid();
  v_statement_id uuid := gen_random_uuid();

  v_exact_order_id uuid := gen_random_uuid();
  v_fx_order_id uuid := gen_random_uuid();
  v_pending_order_id uuid := gen_random_uuid();
  v_guard_order_id uuid := gen_random_uuid();
  v_reversal_order_id uuid := gen_random_uuid();
  v_legacy_order_id uuid := gen_random_uuid();
  v_bundle_order_id uuid := gen_random_uuid();

  v_exact_in_id uuid := gen_random_uuid();
  v_fx_in_id uuid := gen_random_uuid();
  v_pending_in_id uuid := gen_random_uuid();
  v_guard_in_id uuid := gen_random_uuid();
  v_reversal_in_id uuid := gen_random_uuid();
  v_legacy_in_id uuid := gen_random_uuid();
  v_bundle_in_id uuid := gen_random_uuid();
  v_pending_out_id uuid := gen_random_uuid();
  v_legacy_out_id uuid := gen_random_uuid();
  v_bundle_out_id uuid := gen_random_uuid();

  v_pending_invoice_id uuid := gen_random_uuid();
  v_legacy_invoice_id uuid := gen_random_uuid();
  v_invoice_a_id uuid := gen_random_uuid();
  v_invoice_b_id uuid := gen_random_uuid();
  v_invoice_c_id uuid := gen_random_uuid();

  v_result jsonb;
  v_repeat jsonb;
  v_reconciliation_id uuid;
  v_allocation_a_id uuid;
  v_allocation_b_id uuid;
  v_allocation_c_id uuid;
  v_count bigint;
  v_amount numeric;
  v_consumed numeric;
  v_reserved numeric;
  v_remaining numeric;
  v_status text;
  v_basis text;
  v_failed boolean;
  v_v2_shape text;
  v_v3_prefix_shape text;
  v_definition text;
BEGIN
  -- Installation/signature checks use exact deployed contracts.
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: exact base funding signature is missing';
  END IF;
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: FX funding RPC is missing';
  END IF;
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: pending-surplus funding RPC is missing';
  END IF;
  IF to_regprocedure('public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: surplus confirmation RPC is missing';
  END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: incremental supplier allocation RPC is missing';
  END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_fx_card_or_fee(uuid,character varying,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: FX/card residual RPC is missing';
  END IF;
  IF to_regprocedure('public.staff_reverse_dva_statement_line_allocation(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: allocation reversal RPC is missing';
  END IF;
  IF to_regclass('public.order_surplus_evidence_position_v3') IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: pending-aware surplus v3 view is missing';
  END IF;

  SELECT string_agg(column_name || ':' || data_type, ',' ORDER BY ordinal_position)
    INTO v_v2_shape
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'order_surplus_evidence_position_v2';

  SELECT string_agg(column_name || ':' || data_type, ',' ORDER BY ordinal_position)
    INTO v_v3_prefix_shape
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'order_surplus_evidence_position_v3'
    AND ordinal_position <= 19;

  IF v_v2_shape IS NULL OR v_v2_shape IS DISTINCT FROM v_v3_prefix_shape THEN
    RAISE EXCEPTION 'REGRESSION: v3 does not preserve the exact v2 column prefix. v2 %, v3 %',
      v_v2_shape, v_v3_prefix_shape;
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)'::regprocedure
  )) INTO v_definition;

  IF position('pg_advisory_xact_lock' in v_definition) = 0
     OR position('for update' in v_definition) = 0
     OR position('immutable physical statement amount' in v_definition) = 0 THEN
    RAISE EXCEPTION 'REGRESSION: pending RPC is missing concurrency or physical-amount controls';
  END IF;

  IF (SELECT count(*)
      FROM pg_index i
      WHERE i.indrelid = 'public.order_pending_funding_surplus'::regclass
        AND i.indisunique
        AND pg_get_expr(i.indpred, i.indrelid) ILIKE '%pending_evidence%credit_confirmed%') < 2 THEN
    RAISE EXCEPTION 'REGRESSION: active pending line/reconciliation uniqueness is missing';
  END IF;

  IF COALESCE((
    SELECT relrowsecurity
    FROM pg_class
    WHERE oid = 'public.order_pending_funding_surplus'::regclass
  ), false) IS DISTINCT FROM true
     OR NOT has_table_privilege('authenticated', 'public.order_pending_funding_surplus', 'SELECT')
     OR has_table_privilege('authenticated', 'public.order_pending_funding_surplus', 'INSERT')
     OR has_table_privilege('authenticated', 'public.order_pending_funding_surplus', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.order_pending_funding_surplus', 'DELETE') THEN
    RAISE EXCEPTION 'REGRESSION: pending-surplus RLS/read-only boundary is invalid';
  END IF;

  SELECT id INTO v_country_id
  FROM public.countries
  WHERE iso_code = 'GHA'
  LIMIT 1;

  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: required GHA country seed is missing';
  END IF;

  -- Isolated tenant fixture. Direct table writes are test setup only; every
  -- economic action below uses the production RPC/trigger path.
  INSERT INTO public.staff(id, auth_user_id, role_type, full_name, email, active)
  VALUES (v_staff_id, v_auth_uid, 'admin', 'Treasury regression admin',
    'treasury-regression-' || left(v_staff_id::text, 8) || '@example.test', true);

  INSERT INTO public.shippers(id, name, contact_email, vat_treatment, active)
  VALUES (v_shipper_id, 'Treasury regression shipper',
    'treasury-shipper-' || left(v_shipper_id::text, 8) || '@example.test', 'outside_scope', true);

  INSERT INTO public.hubs(id, shipper_id, name, country_id, full_address, active)
  VALUES (v_hub_id, v_shipper_id, 'Treasury regression hub', v_country_id, 'Rollback-only test address', true);

  UPDATE public.shippers SET primary_hub_id = v_hub_id WHERE id = v_shipper_id;

  INSERT INTO public.retailers(id, name, website_url, global_enabled)
  VALUES (v_retailer_id, 'Treasury regression retailer ' || left(v_retailer_id::text, 8), 'https://example.test', true);

  INSERT INTO public.markup_categories(id, shipper_id, category_name, default_markup_pct, active)
  VALUES (v_markup_category_id, v_shipper_id, 'Treasury regression category', 0, true);

  INSERT INTO public.importers(id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_importer_id, v_shipper_id, v_country_id, 'Treasury Regression Importer Ltd', 'Treasury Regression', true);

  INSERT INTO public.operators(id, email, full_name, auth_user_id, active)
  VALUES (v_operator_id,
    'treasury-operator-' || left(v_operator_id::text, 8) || '@example.test',
    'Treasury regression operator', gen_random_uuid(), true);

  INSERT INTO public.operator_importers(operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO public.retailer_accounts(
    id, retailer_id, shipper_id, account_email, credential_delivery_method,
    delivery_address_locked_to_hub_id, status
  ) VALUES (
    v_retailer_account_id, v_retailer_id, v_shipper_id,
    'treasury-account-' || left(v_retailer_account_id::text, 8) || '@example.test',
    'vault_brokered', v_hub_id, 'active'
  );

  INSERT INTO public.orders(
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id,
    retailer_id, destination_hub_id, order_type, order_total_gbp_declared,
    total_qty_declared, bundled_quote_gbp, quote_fx_rate,
    quote_card_markup_pct, quote_total_ghs, status, sop_version
  ) VALUES
    (v_exact_order_id, 'REG-EXACT-' || left(v_exact_order_id::text, 8), 'AUTH-EXACT', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 884.96, 1, 884.96, 1, 0, 884.96, 'pending_dva_funding', 'regression-v1'),
    (v_fx_order_id, 'REG-FX-' || left(v_fx_order_id::text, 8), 'AUTH-FX', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 884.96, 1, 884.96, 1, 0, 884.96, 'pending_dva_funding', 'regression-v1'),
    (v_pending_order_id, 'REG-PENDING-' || left(v_pending_order_id::text, 8), 'AUTH-PENDING', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 884.96, 1, 884.96, 1, 0, 884.96, 'pending_dva_funding', 'regression-v1'),
    (v_guard_order_id, 'REG-GUARD-' || left(v_guard_order_id::text, 8), 'AUTH-GUARD', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 884.96, 1, 884.96, 1, 0, 884.96, 'pending_dva_funding', 'regression-v1'),
    (v_reversal_order_id, 'REG-REV-' || left(v_reversal_order_id::text, 8), 'AUTH-REV', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 884.96, 1, 884.96, 1, 0, 884.96, 'pending_dva_funding', 'regression-v1'),
    (v_legacy_order_id, 'REG-LEGACY-' || left(v_legacy_order_id::text, 8), 'AUTH-LEGACY', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 900.00, 1, 900.00, 1, 0, 900.00, 'pending_dva_funding', 'regression-v1'),
    (v_bundle_order_id, 'REG-BUNDLE-' || left(v_bundle_order_id::text, 8), 'AUTH-BUNDLE', v_importer_id, v_operator_id, v_shipper_id, v_retailer_id, v_hub_id, 'original', 890.00, 3, 890.00, 1, 0, 890.00, 'pending_dva_funding', 'regression-v1');

  INSERT INTO public.order_category_lines(
    order_id, markup_category_id, qty, amount_inc_vat_gbp,
    markup_pct_applied, markup_gbp_calculated
  ) VALUES
    (v_exact_order_id, v_markup_category_id, 1, 884.96, 0, 0),
    (v_fx_order_id, v_markup_category_id, 1, 884.96, 0, 0),
    (v_pending_order_id, v_markup_category_id, 1, 884.96, 0, 0),
    (v_guard_order_id, v_markup_category_id, 1, 884.96, 0, 0),
    (v_reversal_order_id, v_markup_category_id, 1, 884.96, 0, 0),
    (v_legacy_order_id, v_markup_category_id, 1, 900.00, 0, 0),
    (v_bundle_order_id, v_markup_category_id, 3, 890.00, 0, 0);

  INSERT INTO public.dva_statements(
    id, importer_id, statement_account_context, statement_account_key,
    statement_account_label, source_bank, uploaded_by_staff_id, csv_url,
    statement_period_from, statement_period_to, parse_status
  ) VALUES (
    v_statement_id, v_importer_id, 'importer_dva_card_account', v_importer_id::text,
    'Treasury rollback regression', 'gcb', v_staff_id,
    'regression://pending-surplus-and-supplier-bundle', CURRENT_DATE, CURRENT_DATE, 'parsed'
  );

  INSERT INTO public.dva_statement_lines(
    id, dva_statement_id, line_order, statement_date, reference_raw, direction,
    amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied,
    amount_gbp_equivalent, auth_id_ref, retailer_name_ref, match_status
  ) VALUES
    (v_exact_in_id, v_statement_id, 1, CURRENT_DATE, 'REG exact funding IN', 'in', 900, 'GBP', 1, 0, 900, 'AUTH-EXACT', 'Regression retailer', 'unmatched'),
    (v_fx_in_id, v_statement_id, 2, CURRENT_DATE, 'REG FX funding IN', 'in', 900, 'GBP', 1, 0, 900, 'AUTH-FX', 'Regression retailer', 'unmatched'),
    (v_pending_in_id, v_statement_id, 3, CURRENT_DATE, 'REG pending funding IN', 'in', 900, 'GBP', 1, 0, 900, 'AUTH-PENDING', 'Regression retailer', 'unmatched'),
    (v_guard_in_id, v_statement_id, 4, CURRENT_DATE, 'REG physical amount guard IN', 'in', 900, 'GBP', 1, 0, 900, 'AUTH-GUARD', 'Regression retailer', 'unmatched'),
    (v_reversal_in_id, v_statement_id, 5, CURRENT_DATE, 'REG pending reversal IN', 'in', 900, 'GBP', 1, 0, 900, 'AUTH-REV', 'Regression retailer', 'unmatched'),
    (v_legacy_in_id, v_statement_id, 6, CURRENT_DATE, 'REG legacy surplus IN', 'in', 900, 'GBP', 1, 0, 900, 'AUTH-LEGACY', 'Regression retailer', 'unmatched'),
    (v_bundle_in_id, v_statement_id, 7, CURRENT_DATE, 'REG bundle funding IN', 'in', 890, 'GBP', 1, 0, 890, 'AUTH-BUNDLE', 'Regression retailer', 'unmatched'),
    (v_pending_out_id, v_statement_id, 8, CURRENT_DATE, 'REG pending evidence OUT', 'out', 884.96, 'GBP', 1, 0, 884.96, NULL, 'Regression retailer', 'unmatched'),
    (v_legacy_out_id, v_statement_id, 9, CURRENT_DATE, 'REG legacy evidence OUT', 'out', 794.97, 'GBP', 1, 0, 794.97, NULL, 'Regression retailer', 'unmatched'),
    (v_bundle_out_id, v_statement_id, 10, CURRENT_DATE, 'REG supplier A B C FX OUT', 'out', 890, 'GBP', 1, 0, 890, NULL, 'Regression retailer', 'unmatched');

  INSERT INTO public.supplier_invoices(
    id, order_id, retailer_id, retailer_account_id, invoice_ref,
    invoice_pdf_url, uploaded_by_operator_id, ocr_service_used,
    ocr_invoice_ref, ocr_invoice_total_gbp, reconciliation_gbp_total,
    review_status, blocked_from_sage_yn, is_current_for_order,
    reviewed_by_staff_id, reviewed_at, review_notes
  ) VALUES
    (v_pending_invoice_id, v_pending_order_id, v_retailer_id, v_retailer_account_id, 'REG-PEND-' || left(v_pending_invoice_id::text, 8), 'regression://pending-invoice', v_operator_id, 'manual', 'REG-PEND-' || left(v_pending_invoice_id::text, 8), 884.96, 884.96, 'approved_current', false, false, v_staff_id, now(), 'Rollback regression'),
    (v_legacy_invoice_id, v_legacy_order_id, v_retailer_id, v_retailer_account_id, 'REG-LEG-' || left(v_legacy_invoice_id::text, 8), 'regression://legacy-invoice', v_operator_id, 'manual', 'REG-LEG-' || left(v_legacy_invoice_id::text, 8), 794.97, 794.97, 'approved_current', false, false, v_staff_id, now(), 'Rollback regression'),
    (v_invoice_a_id, v_bundle_order_id, v_retailer_id, v_retailer_account_id, 'REG-A-' || left(v_invoice_a_id::text, 8), 'regression://invoice-a', v_operator_id, 'manual', 'REG-A-' || left(v_invoice_a_id::text, 8), 449.98, 449.98, 'approved_current', false, false, v_staff_id, now(), 'Rollback regression'),
    (v_invoice_b_id, v_bundle_order_id, v_retailer_id, v_retailer_account_id, 'REG-B-' || left(v_invoice_b_id::text, 8), 'regression://invoice-b', v_operator_id, 'manual', 'REG-B-' || left(v_invoice_b_id::text, 8), 249.99, 249.99, 'approved_current', false, false, v_staff_id, now(), 'Rollback regression'),
    (v_invoice_c_id, v_bundle_order_id, v_retailer_id, v_retailer_account_id, 'REG-C-' || left(v_invoice_c_id::text, 8), 'regression://invoice-c', v_operator_id, 'manual', 'REG-C-' || left(v_invoice_c_id::text, 8), 95.00, 95.00, 'approved_current', false, false, v_staff_id, now(), 'Rollback regression');

  INSERT INTO public.supplier_invoice_lines(
    supplier_invoice_id, line_order, description, qty, amount_inc_vat_gbp,
    line_source, qty_confirmed, amount_confirmed, eligible_for_invoice_yn
  ) VALUES
    (v_pending_invoice_id, 1, 'Pending evidence', 1, 884.96, 'manually_added', 1, 884.96, 'Y'),
    (v_legacy_invoice_id, 1, 'Legacy evidence', 1, 794.97, 'manually_added', 1, 794.97, 'Y'),
    (v_invoice_a_id, 1, 'Supplier invoice A', 1, 449.98, 'manually_added', 1, 449.98, 'Y'),
    (v_invoice_b_id, 1, 'Supplier invoice B', 1, 249.99, 'manually_added', 1, 249.99, 'Y'),
    (v_invoice_c_id, 1, 'Supplier invoice C', 1, 95.00, 'manually_added', 1, 95.00, 'Y');

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);

  -- Funding scenario 1: enter exactly the £884.96 gap from a physical £900 IN.
  v_result := public.staff_reconcile_dva_line_to_order(
    v_exact_in_id, v_exact_order_id, 884.96, false, NULL, 'Regression exact funding');

  SELECT active_consumed_gbp, active_reserved_gbp, remaining_unconsumed_gbp
    INTO v_consumed, v_reserved, v_remaining
  FROM public.statement_line_control_position_v1
  WHERE statement_line_id = v_exact_in_id;

  IF v_consumed <> 884.96 OR v_reserved <> 0 OR v_remaining <> 15.04
     OR public.order_funding_total_gbp(v_exact_order_id) <> 884.96 THEN
    RAISE EXCEPTION 'REGRESSION funding 1: consumed %, reserved %, remaining %, funding %',
      v_consumed, v_reserved, v_remaining, public.order_funding_total_gbp(v_exact_order_id);
  END IF;
  IF EXISTS (SELECT 1 FROM public.dva_statement_line_allocations WHERE dva_statement_line_id = v_exact_in_id AND allocation_type = 'fx_card_difference' AND allocation_status = 'confirmed')
     OR EXISTS (SELECT 1 FROM public.order_pending_funding_surplus WHERE order_id = v_exact_order_id AND status <> 'reversed')
     OR EXISTS (SELECT 1 FROM public.importer_credit_ledger WHERE source_entity_type = 'order' AND source_entity_id = v_exact_order_id) THEN
    RAISE EXCEPTION 'REGRESSION funding 1: created FX, pending surplus, or customer credit';
  END IF;

  -- Funding scenario 2: £900 entered with FX confirmed.
  v_result := public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(
    v_fx_in_id, v_fx_order_id, 900, NULL, 'Regression explicit FX');

  SELECT active_consumed_gbp, active_reserved_gbp, remaining_unconsumed_gbp
    INTO v_consumed, v_reserved, v_remaining
  FROM public.statement_line_control_position_v1
  WHERE statement_line_id = v_fx_in_id;

  SELECT COALESCE(SUM(allocated_gbp_amount), 0) INTO v_amount
  FROM public.dva_statement_line_allocations
  WHERE dva_statement_line_id = v_fx_in_id
    AND allocation_type = 'fx_card_difference'
    AND allocation_status = 'confirmed';

  IF public.order_funding_total_gbp(v_fx_order_id) <> 884.96
     OR v_amount <> 15.04 OR v_consumed <> 900 OR v_reserved <> 0 OR v_remaining <> 0 THEN
    RAISE EXCEPTION 'REGRESSION funding 2: funding %, FX %, consumed %, reserved %, remaining %',
      public.order_funding_total_gbp(v_fx_order_id), v_amount, v_consumed, v_reserved, v_remaining;
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_pending_funding_surplus WHERE order_id = v_fx_order_id AND status <> 'reversed')
     OR EXISTS (SELECT 1 FROM public.importer_credit_ledger WHERE source_entity_type = 'order' AND source_entity_id = v_fx_order_id) THEN
    RAISE EXCEPTION 'REGRESSION funding 2: created pending surplus or customer credit';
  END IF;

  -- Funding scenario 3: £900 entered without FX; the £15.04 is reserved,
  -- neutral, non-credit, and idempotent.
  v_result := public.staff_reconcile_dva_line_to_order_pending_surplus_v1(
    v_pending_in_id, v_pending_order_id, 900, NULL, 'Regression pending surplus');
  v_repeat := public.staff_reconcile_dva_line_to_order_pending_surplus_v1(
    v_pending_in_id, v_pending_order_id, 900, NULL, 'Regression pending surplus retry');

  SELECT active_consumed_gbp, active_reserved_gbp, remaining_unconsumed_gbp
    INTO v_consumed, v_reserved, v_remaining
  FROM public.statement_line_control_position_v1
  WHERE statement_line_id = v_pending_in_id;

  SELECT COUNT(*), COALESCE(SUM(pending_surplus_gbp), 0)
    INTO v_count, v_amount
  FROM public.order_pending_funding_surplus
  WHERE order_id = v_pending_order_id
    AND status = 'pending_evidence';

  IF public.order_funding_total_gbp(v_pending_order_id) <> 884.96
     OR v_consumed <> 884.96 OR v_reserved <> 15.04 OR v_remaining <> 0
     OR v_count <> 1 OR v_amount <> 15.04
     OR COALESCE((v_repeat->>'already_exists')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'REGRESSION funding 3: funding %, consumed %, reserved %, remaining %, rows %, pending %, retry %',
      public.order_funding_total_gbp(v_pending_order_id), v_consumed, v_reserved,
      v_remaining, v_count, v_amount, v_repeat;
  END IF;
  IF EXISTS (SELECT 1 FROM public.dva_statement_line_allocations WHERE dva_statement_line_id = v_pending_in_id AND allocation_type = 'fx_card_difference' AND allocation_status = 'confirmed')
     OR EXISTS (SELECT 1 FROM public.importer_credit_ledger WHERE source_entity_type = 'order' AND source_entity_id = v_pending_order_id) THEN
    RAISE EXCEPTION 'REGRESSION funding 3: created FX or automatic customer credit';
  END IF;

  -- Physical £900 guard: £900.01 must fail before creating any economic row.
  v_failed := false;
  BEGIN
    PERFORM public.staff_reconcile_dva_line_to_order_pending_surplus_v1(
      v_guard_in_id, v_guard_order_id, 900.01, NULL, 'Regression physical guard');
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
    IF SQLERRM NOT ILIKE '%exceeds immutable physical statement amount%' THEN
      RAISE EXCEPTION 'REGRESSION physical guard: unexpected error: %', SQLERRM;
    END IF;
  END;
  IF NOT v_failed
     OR EXISTS (SELECT 1 FROM public.dva_reconciliation WHERE dva_statement_line_id = v_guard_in_id)
     OR EXISTS (SELECT 1 FROM public.order_pending_funding_surplus WHERE dva_statement_line_id = v_guard_in_id)
     OR EXISTS (SELECT 1 FROM public.order_funding_events WHERE order_id = v_guard_order_id)
     OR EXISTS (SELECT 1 FROM public.importer_credit_ledger WHERE source_entity_type = 'order' AND source_entity_id = v_guard_order_id) THEN
    RAISE EXCEPTION 'REGRESSION physical guard: £900.01 was not rejected atomically';
  END IF;

  -- Evidence appears only after an actual approved invoice allocation. Effective
  -- receipt is £900, authoritative supplier evidence is £884.96, surplus £15.04.
  PERFORM public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
    v_pending_out_id, v_pending_invoice_id, 884.96, 'Regression pending evidence');

  SELECT effective_receipt_gbp, evidence_value_gbp, evidence_surplus_gbp,
         evidence_status, evidence_basis
    INTO v_consumed, v_reserved, v_amount, v_status, v_basis
  FROM public.order_surplus_evidence_position_v3
  WHERE order_id = v_pending_order_id;

  IF v_consumed <> 900 OR v_reserved <> 884.96 OR v_amount <> 15.04
     OR v_status <> 'ready_strong_in_out_surplus' OR v_basis <> 'matched_supplier_out' THEN
    RAISE EXCEPTION 'REGRESSION pending evidence: receipt %, evidence %, surplus %, status %, basis %',
      v_consumed, v_reserved, v_amount, v_status, v_basis;
  END IF;

  v_result := public.staff_confirm_surplus_from_evidence_min_v1(
    v_pending_order_id, 'supervisor_confirmed_credit', 'Regression evidence confirmation');
  v_repeat := public.staff_confirm_surplus_from_evidence_min_v1(
    v_pending_order_id, 'supervisor_confirmed_credit', 'Regression idempotent retry');

  SELECT COUNT(*), COALESCE(SUM(amount_gbp), 0)
    INTO v_count, v_amount
  FROM public.importer_credit_ledger
  WHERE importer_id = v_importer_id
    AND direction = 'credit'
    AND source_type IN ('overfunding', 'settlement_credit')
    AND source_entity_type = 'order'
    AND source_entity_id = v_pending_order_id;

  IF v_count <> 1 OR v_amount <> 15.04
     OR COALESCE((v_repeat->>'already_confirmed')::boolean, false) IS DISTINCT FROM true
     OR (SELECT status FROM public.order_pending_funding_surplus WHERE order_id = v_pending_order_id) <> 'credit_confirmed' THEN
    RAISE EXCEPTION 'REGRESSION pending confirmation: count %, credit %, repeat %', v_count, v_amount, v_repeat;
  END IF;

  v_failed := false;
  BEGIN
    DELETE FROM public.dva_reconciliation
    WHERE id = (
      SELECT dva_reconciliation_id
      FROM public.order_pending_funding_surplus
      WHERE order_id = v_pending_order_id
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
    IF SQLERRM NOT ILIKE '%reverse the confirmed customer credit%' THEN
      RAISE EXCEPTION 'REGRESSION confirmed-credit reversal guard: unexpected error: %', SQLERRM;
    END IF;
  END;
  IF NOT v_failed
     OR public.order_funding_total_gbp(v_pending_order_id) <> 884.96
     OR (SELECT status FROM public.order_pending_funding_surplus WHERE order_id = v_pending_order_id) <> 'credit_confirmed' THEN
    RAISE EXCEPTION 'REGRESSION confirmed-credit reversal guard did not fail closed';
  END IF;

  -- Funding reversal is linked to the actual reconciliation row. It preserves a
  -- historical pending row and releases both the funding use and reservation.
  v_result := public.staff_reconcile_dva_line_to_order_pending_surplus_v1(
    v_reversal_in_id, v_reversal_order_id, 900, NULL, 'Regression reversal');
  v_reconciliation_id := (v_result->>'dva_reconciliation_id')::uuid;
  DELETE FROM public.dva_reconciliation WHERE id = v_reconciliation_id;

  SELECT active_consumed_gbp, active_reserved_gbp, remaining_unconsumed_gbp
    INTO v_consumed, v_reserved, v_remaining
  FROM public.statement_line_control_position_v1
  WHERE statement_line_id = v_reversal_in_id;

  IF public.order_funding_total_gbp(v_reversal_order_id) <> 0
     OR v_consumed <> 0 OR v_reserved <> 0 OR v_remaining <> 900
     OR (SELECT status FROM public.order_pending_funding_surplus WHERE order_id = v_reversal_order_id) <> 'reversed'
     OR (SELECT reversed_at FROM public.order_pending_funding_surplus WHERE order_id = v_reversal_order_id) IS NULL
     OR EXISTS (SELECT 1 FROM public.importer_credit_ledger WHERE source_entity_type = 'order' AND source_entity_id = v_reversal_order_id) THEN
    RAISE EXCEPTION 'REGRESSION pending reversal: funding %, consumed %, reserved %, remaining %',
      public.order_funding_total_gbp(v_reversal_order_id), v_consumed, v_reserved, v_remaining;
  END IF;

  -- Legacy ordinary-surplus rows stay on exact v2 behaviour: £900 funding less
  -- £794.97 real supplier evidence produces one £105.03 credit.
  PERFORM public.staff_reconcile_dva_line_to_order(
    v_legacy_in_id, v_legacy_order_id, 900, false, NULL, 'Regression legacy funding');
  PERFORM public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
    v_legacy_out_id, v_legacy_invoice_id, 794.97, 'Regression legacy evidence');

  IF (SELECT pending_position_count FROM public.order_surplus_evidence_position_v3 WHERE order_id = v_legacy_order_id) <> 0
     OR (SELECT evidence_surplus_gbp FROM public.order_surplus_evidence_position_v2 WHERE order_id = v_legacy_order_id) <> 105.03
     OR (SELECT evidence_surplus_gbp FROM public.order_surplus_evidence_position_v3 WHERE order_id = v_legacy_order_id) <> 105.03
     OR (SELECT evidence_status FROM public.order_surplus_evidence_position_v2 WHERE order_id = v_legacy_order_id) IS DISTINCT FROM
        (SELECT evidence_status FROM public.order_surplus_evidence_position_v3 WHERE order_id = v_legacy_order_id) THEN
    RAISE EXCEPTION 'REGRESSION legacy surplus: v2/v3 ordinary-row compatibility failed';
  END IF;

  PERFORM public.staff_confirm_surplus_from_evidence_min_v1(
    v_legacy_order_id, 'supervisor_confirmed_credit', 'Regression legacy confirmation');
  v_repeat := public.staff_confirm_surplus_from_evidence_min_v1(
    v_legacy_order_id, 'supervisor_confirmed_credit', 'Regression legacy retry');

  SELECT COUNT(*), COALESCE(SUM(amount_gbp), 0)
    INTO v_count, v_amount
  FROM public.importer_credit_ledger
  WHERE direction = 'credit'
    AND source_type IN ('overfunding', 'settlement_credit')
    AND source_entity_type = 'order'
    AND source_entity_id = v_legacy_order_id;

  IF v_count <> 1 OR v_amount <> 105.03
     OR COALESCE((v_repeat->>'already_confirmed')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'REGRESSION legacy confirmation: count %, credit %, retry %', v_count, v_amount, v_repeat;
  END IF;

  -- Supplier A + B + C + FX on one physical £890 OUT.
  PERFORM public.staff_reconcile_dva_line_to_order(
    v_bundle_in_id, v_bundle_order_id, 890, false, NULL, 'Regression bundle funding');

  v_result := public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
    v_bundle_out_id, v_invoice_a_id, 449.98, 'Regression supplier A');
  v_allocation_a_id := (v_result->>'allocation_id')::uuid;
  IF (v_result->>'statement_remaining_after_gbp')::numeric <> 440.02 THEN
    RAISE EXCEPTION 'REGRESSION supplier A: remaining %', v_result->>'statement_remaining_after_gbp';
  END IF;

  v_result := public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
    v_bundle_out_id, v_invoice_b_id, 249.99, 'Regression supplier B');
  v_allocation_b_id := (v_result->>'allocation_id')::uuid;
  IF (v_result->>'statement_remaining_after_gbp')::numeric <> 190.03 THEN
    RAISE EXCEPTION 'REGRESSION supplier B: remaining %', v_result->>'statement_remaining_after_gbp';
  END IF;

  v_result := public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
    v_bundle_out_id, v_invoice_c_id, 95.00, 'Regression supplier C');
  v_allocation_c_id := (v_result->>'allocation_id')::uuid;
  IF (v_result->>'statement_remaining_after_gbp')::numeric <> 95.03 THEN
    RAISE EXCEPTION 'REGRESSION supplier C: remaining %', v_result->>'statement_remaining_after_gbp';
  END IF;

  -- Duplicate invoice use is rejected and leaves one active row.
  v_failed := false;
  BEGIN
    PERFORM public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
      v_bundle_out_id, v_invoice_c_id, 0.01, 'Regression duplicate rejection');
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  SELECT COUNT(*) INTO v_count
  FROM public.dva_statement_line_allocations
  WHERE dva_statement_line_id = v_bundle_out_id
    AND supplier_invoice_id = v_invoice_c_id
    AND allocation_type = 'supplier_invoice'
    AND allocation_status <> 'reversed';
  IF NOT v_failed OR v_count <> 1 THEN
    RAISE EXCEPTION 'REGRESSION duplicate invoice: rejected %, active rows %', v_failed, v_count;
  END IF;

  -- One leg reverses independently; A and C stay confirmed. Reapplication of B
  -- is a fresh auditable allocation and restores only that invoice leg.
  PERFORM public.staff_reverse_dva_statement_line_allocation(
    v_allocation_b_id, 'Regression reverse supplier B only');

  IF (SELECT allocation_status FROM public.dva_statement_line_allocations WHERE id = v_allocation_b_id) <> 'reversed'
     OR (SELECT allocation_status FROM public.dva_statement_line_allocations WHERE id = v_allocation_a_id) <> 'confirmed'
     OR (SELECT allocation_status FROM public.dva_statement_line_allocations WHERE id = v_allocation_c_id) <> 'confirmed'
     OR (SELECT confirmed_unallocated_gbp FROM public.dva_statement_line_allocation_summary_vw WHERE dva_statement_line_id = v_bundle_out_id) <> 345.02 THEN
    RAISE EXCEPTION 'REGRESSION supplier reversal: individual leg did not reverse cleanly';
  END IF;

  v_result := public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
    v_bundle_out_id, v_invoice_b_id, 249.99, 'Regression supplier B reapplied');
  IF (v_result->>'statement_remaining_after_gbp')::numeric <> 95.03 THEN
    RAISE EXCEPTION 'REGRESSION supplier B reapply: remaining %', v_result->>'statement_remaining_after_gbp';
  END IF;

  v_result := public.staff_allocate_statement_line_to_fx_card_or_fee(
    v_bundle_out_id, 'fx_card_difference', 95.03, 'Regression final FX/card residual');
  IF COALESCE((v_result->>'balanced_yn')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'REGRESSION supplier FX: final residual did not balance line: %', v_result;
  END IF;

  -- A further penny must be rejected by the real write-time amount guard.
  v_failed := false;
  BEGIN
    PERFORM public.staff_allocate_statement_line_to_fx_card_or_fee(
      v_bundle_out_id, 'fx_card_difference', 0.01, 'Regression over-allocation rejection');
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
    IF SQLERRM NOT ILIKE '%over-allocate%' THEN
      RAISE EXCEPTION 'REGRESSION supplier over-allocation: unexpected error: %', SQLERRM;
    END IF;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'REGRESSION supplier over-allocation: extra £0.01 was accepted';
  END IF;

  SELECT COALESCE(SUM(allocated_gbp_amount), 0) INTO v_amount
  FROM public.dva_statement_line_allocations
  WHERE dva_statement_line_id = v_bundle_out_id
    AND allocation_type = 'supplier_invoice'
    AND allocation_status = 'confirmed';
  IF v_amount <> 794.97 THEN
    RAISE EXCEPTION 'REGRESSION supplier final: supplier total %, expected 794.97', v_amount;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM (
    SELECT supplier_invoice_id
    FROM public.dva_statement_line_allocations
    WHERE dva_statement_line_id = v_bundle_out_id
      AND allocation_type = 'supplier_invoice'
      AND allocation_status = 'confirmed'
    GROUP BY supplier_invoice_id
    HAVING COUNT(*) <> 1
  ) duplicates;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'REGRESSION supplier final: duplicate active invoice allocations remain';
  END IF;

  IF (SELECT COUNT(DISTINCT a.order_id) FROM public.dva_statement_line_allocations a WHERE a.dva_statement_line_id = v_bundle_out_id AND a.allocation_type = 'supplier_invoice' AND a.allocation_status = 'confirmed') <> 1
     OR (SELECT MIN(a.order_id) FROM public.dva_statement_line_allocations a WHERE a.dva_statement_line_id = v_bundle_out_id AND a.allocation_type = 'supplier_invoice' AND a.allocation_status = 'confirmed') IS DISTINCT FROM v_bundle_order_id
     OR (SELECT COUNT(DISTINCT a.source_bank_account_mapping_code) FROM public.dva_statement_line_allocations a WHERE a.dva_statement_line_id = v_bundle_out_id AND a.allocation_type = 'supplier_invoice' AND a.allocation_status = 'confirmed') <> 1
     OR EXISTS (
       SELECT 1
       FROM public.dva_statement_line_allocations a
       JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
       JOIN public.orders o ON o.id = si.order_id
       WHERE a.dva_statement_line_id = v_bundle_out_id
         AND a.allocation_type = 'supplier_invoice'
         AND a.allocation_status = 'confirmed'
         AND (o.id IS DISTINCT FROM v_bundle_order_id
           OR o.importer_id IS DISTINCT FROM v_importer_id
           OR o.retailer_id IS DISTINCT FROM v_retailer_id)
     ) THEN
    RAISE EXCEPTION 'REGRESSION supplier final: order/importer/retailer/source mapping integrity failed';
  END IF;

  SELECT confirmed_allocated_gbp, confirmed_unallocated_gbp,
         CASE WHEN confirmed_balanced_yn THEN 'balanced' ELSE 'unbalanced' END
    INTO v_consumed, v_remaining, v_status
  FROM public.dva_statement_line_allocation_summary_vw
  WHERE dva_statement_line_id = v_bundle_out_id;

  SELECT COALESCE(SUM(allocated_gbp_amount), 0) INTO v_amount
  FROM public.dva_statement_line_allocations
  WHERE dva_statement_line_id = v_bundle_out_id
    AND allocation_type = 'fx_card_difference'
    AND allocation_status = 'confirmed';

  IF v_consumed <> 890 OR v_remaining <> 0 OR v_status <> 'balanced' OR v_amount <> 95.03
     OR (SELECT overconsumed_gbp FROM public.statement_line_control_position_v1 WHERE statement_line_id = v_bundle_out_id) <> 0
     OR (SELECT COUNT(*) FROM public.dva_statement_line_allocations WHERE id = v_allocation_b_id AND allocation_status = 'reversed' AND reversed_at IS NOT NULL AND reversed_by_staff_id = v_staff_id) <> 1 THEN
    RAISE EXCEPTION 'REGRESSION supplier final: total %, remaining %, status %, FX %',
      v_consumed, v_remaining, v_status, v_amount;
  END IF;

  RAISE NOTICE 'PASS: real funding, pending-surplus, legacy surplus, reversal, and A+B+C+FX regression completed; transaction will roll back';
END;
$regression$;

ROLLBACK;
