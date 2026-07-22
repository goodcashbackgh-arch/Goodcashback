-- Treasury statement control regression pack v1.
-- Exactly 100 rollback-safe checks.
--
-- Apply, in order:
--   20260722b_statement_interpretation_and_sequential_supplier_allocation_v1.sql
--   20260722c_supplier_payment_next_invoice_eligibility_and_ranking_v1.sql
--   20260722d_treasury_control_hardening_v1.sql
--
-- Then run this file in the target Supabase SQL editor.
-- This pack creates TEMP objects only, does not modify business data, and fails closed
-- after returning the complete per-scenario result set.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE treasury_control_regression_results (
  test_no integer PRIMARY KEY,
  area text NOT NULL,
  scenario text NOT NULL,
  passed boolean NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.record_treasury_test(
  p_test_no integer,
  p_area text,
  p_scenario text,
  p_passed boolean,
  p_details jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $test$
BEGIN
  INSERT INTO treasury_control_regression_results(test_no, area, scenario, passed, details)
  VALUES (p_test_no, p_area, p_scenario, COALESCE(p_passed, false), COALESCE(p_details, '{}'::jsonb));
END;
$test$;

CREATE OR REPLACE FUNCTION pg_temp.assert_function_definition(
  p_test_no integer,
  p_area text,
  p_scenario text,
  p_signature text,
  p_required text[],
  p_forbidden text[] DEFAULT ARRAY[]::text[]
)
RETURNS void
LANGUAGE plpgsql
AS $test$
DECLARE
  v_oid regprocedure;
  v_definition text := '';
  v_token text;
  v_missing text[] := ARRAY[]::text[];
  v_present_forbidden text[] := ARRAY[]::text[];
BEGIN
  v_oid := to_regprocedure(p_signature);
  IF v_oid IS NOT NULL THEN
    v_definition := lower(pg_get_functiondef(v_oid));
  END IF;

  FOREACH v_token IN ARRAY COALESCE(p_required, ARRAY[]::text[]) LOOP
    IF position(lower(v_token) in v_definition) = 0 THEN
      v_missing := array_append(v_missing, v_token);
    END IF;
  END LOOP;

  FOREACH v_token IN ARRAY COALESCE(p_forbidden, ARRAY[]::text[]) LOOP
    IF position(lower(v_token) in v_definition) > 0 THEN
      v_present_forbidden := array_append(v_present_forbidden, v_token);
    END IF;
  END LOOP;

  PERFORM pg_temp.record_treasury_test(
    p_test_no,
    p_area,
    p_scenario,
    v_oid IS NOT NULL
      AND cardinality(v_missing) = 0
      AND cardinality(v_present_forbidden) = 0,
    jsonb_build_object(
      'signature', p_signature,
      'missing_required', v_missing,
      'present_forbidden', v_present_forbidden
    )
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.record_treasury_test(
    p_test_no, p_area, p_scenario, false,
    jsonb_build_object('error', SQLERRM, 'signature', p_signature)
  );
END;
$test$;

CREATE OR REPLACE FUNCTION pg_temp.assert_view_definition(
  p_test_no integer,
  p_area text,
  p_scenario text,
  p_relation text,
  p_required text[],
  p_forbidden text[] DEFAULT ARRAY[]::text[]
)
RETURNS void
LANGUAGE plpgsql
AS $test$
DECLARE
  v_oid regclass;
  v_definition text := '';
  v_token text;
  v_missing text[] := ARRAY[]::text[];
  v_present_forbidden text[] := ARRAY[]::text[];
BEGIN
  v_oid := to_regclass(p_relation);
  IF v_oid IS NOT NULL THEN
    v_definition := lower(pg_get_viewdef(v_oid, true));
  END IF;

  FOREACH v_token IN ARRAY COALESCE(p_required, ARRAY[]::text[]) LOOP
    IF position(lower(v_token) in v_definition) = 0 THEN
      v_missing := array_append(v_missing, v_token);
    END IF;
  END LOOP;

  FOREACH v_token IN ARRAY COALESCE(p_forbidden, ARRAY[]::text[]) LOOP
    IF position(lower(v_token) in v_definition) > 0 THEN
      v_present_forbidden := array_append(v_present_forbidden, v_token);
    END IF;
  END LOOP;

  PERFORM pg_temp.record_treasury_test(
    p_test_no,
    p_area,
    p_scenario,
    v_oid IS NOT NULL
      AND cardinality(v_missing) = 0
      AND cardinality(v_present_forbidden) = 0,
    jsonb_build_object(
      'relation', p_relation,
      'missing_required', v_missing,
      'present_forbidden', v_present_forbidden
    )
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.record_treasury_test(
    p_test_no, p_area, p_scenario, false,
    jsonb_build_object('error', SQLERRM, 'relation', p_relation)
  );
END;
$test$;

CREATE OR REPLACE FUNCTION pg_temp.assert_zero_rows(
  p_test_no integer,
  p_area text,
  p_scenario text,
  p_sql text
)
RETURNS void
LANGUAGE plpgsql
AS $test$
DECLARE
  v_count bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM (%s) regression_violations', p_sql) INTO v_count;
  PERFORM pg_temp.record_treasury_test(
    p_test_no,
    p_area,
    p_scenario,
    v_count = 0,
    jsonb_build_object('violations', v_count)
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.record_treasury_test(
    p_test_no, p_area, p_scenario, false,
    jsonb_build_object('error', SQLERRM)
  );
END;
$test$;

-- 1-15: installation and protected baseline.
SELECT pg_temp.record_treasury_test(1, 'installation', 'Interpretation correction table exists',
  to_regclass('public.statement_line_interpretation_corrections') IS NOT NULL);
SELECT pg_temp.record_treasury_test(2, 'installation', 'Effective interpretation view exists',
  to_regclass('public.statement_line_effective_interpretation_v1') IS NOT NULL);
SELECT pg_temp.record_treasury_test(3, 'installation', 'Resolver v2 exists',
  to_regprocedure('public.internal_statement_line_control_resolver_v2(uuid)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(4, 'installation', 'Treasury worklist exists',
  to_regprocedure('public.internal_statement_line_control_worklist_v1(uuid,integer,integer)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(5, 'installation', 'Interpretation correction RPC exists',
  to_regprocedure('public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(6, 'installation', 'Sequential supplier allocator exists',
  to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(7, 'installation', 'Next-invoice eligibility and ranking function exists',
  to_regprocedure('public.internal_supplier_payment_next_invoice_candidates_v1(uuid)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(8, 'installation', 'Existing reversal RPC exists',
  to_regprocedure('public.staff_reverse_dva_statement_line_allocation(uuid,text)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(9, 'installation', 'Amount-aware control position remains installed',
  to_regclass('public.statement_line_control_position_v1') IS NOT NULL);
SELECT pg_temp.record_treasury_test(10, 'installation', 'Amount-aware usage evidence remains installed',
  to_regclass('public.statement_line_control_usage_v1') IS NOT NULL);
SELECT pg_temp.record_treasury_test(11, 'installation', 'Existing supplier-payment candidate view remains installed',
  to_regclass('public.supplier_payment_candidate_status_vw') IS NOT NULL);
SELECT pg_temp.record_treasury_test(12, 'installation', 'Existing atomic bundle allocator remains installed',
  to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(13, 'installation', 'Existing strict single-invoice allocator remains installed',
  EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'staff_allocate_statement_line_to_supplier_invoice'
  ));
SELECT pg_temp.record_treasury_test(14, 'installation', 'Order-funding statement-line trigger remains installed and enabled',
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_guard_order_funding_statement_line_v1'
      AND tgrelid = to_regclass('public.dva_reconciliation')
      AND NOT tgisinternal
      AND tgenabled <> 'D'
  ));
SELECT pg_temp.record_treasury_test(15, 'installation', 'Supplier allocation source-provenance columns remain installed',
  (
    SELECT count(*) = 2
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dva_statement_line_allocations'
      AND column_name IN ('source_bank_account_mapping_code', 'source_wallet_code')
  ));

-- 16-25: privileges and direct-write boundaries.
SELECT pg_temp.record_treasury_test(16, 'security', 'Interpretation correction table has RLS enabled',
  COALESCE((
    SELECT relrowsecurity
    FROM pg_class
    WHERE oid = to_regclass('public.statement_line_interpretation_corrections')
  ), false));
SELECT pg_temp.record_treasury_test(17, 'security', 'Authenticated staff retain read access to interpretation history',
  CASE WHEN to_regclass('public.statement_line_interpretation_corrections') IS NULL THEN false
    ELSE has_table_privilege('authenticated', 'public.statement_line_interpretation_corrections', 'SELECT') END);
SELECT pg_temp.record_treasury_test(18, 'security', 'Authenticated users have no direct interpretation insert',
  CASE WHEN to_regclass('public.statement_line_interpretation_corrections') IS NULL THEN false
    ELSE NOT has_table_privilege('authenticated', 'public.statement_line_interpretation_corrections', 'INSERT') END);
SELECT pg_temp.record_treasury_test(19, 'security', 'Authenticated users have no direct interpretation update',
  CASE WHEN to_regclass('public.statement_line_interpretation_corrections') IS NULL THEN false
    ELSE NOT has_table_privilege('authenticated', 'public.statement_line_interpretation_corrections', 'UPDATE') END);
SELECT pg_temp.record_treasury_test(20, 'security', 'Authenticated users have no direct interpretation delete',
  CASE WHEN to_regclass('public.statement_line_interpretation_corrections') IS NULL THEN false
    ELSE NOT has_table_privilege('authenticated', 'public.statement_line_interpretation_corrections', 'DELETE') END);
SELECT pg_temp.record_treasury_test(21, 'security', 'Authenticated role can execute interpretation RPC',
  CASE WHEN to_regprocedure('public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)') IS NULL
    THEN false
    ELSE has_function_privilege('authenticated', 'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)', 'EXECUTE')
  END);
SELECT pg_temp.record_treasury_test(22, 'security', 'Authenticated role can execute sequential allocator',
  CASE WHEN to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)') IS NULL
    THEN false
    ELSE has_function_privilege('authenticated', 'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)', 'EXECUTE')
  END);
SELECT pg_temp.record_treasury_test(23, 'security', 'Authenticated role can execute eligibility and ranking',
  CASE WHEN to_regprocedure('public.internal_supplier_payment_next_invoice_candidates_v1(uuid)') IS NULL
    THEN false
    ELSE has_function_privilege('authenticated', 'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)', 'EXECUTE')
  END);
SELECT pg_temp.record_treasury_test(24, 'security', 'Authenticated role can execute audited reversal',
  CASE WHEN to_regprocedure('public.staff_reverse_dva_statement_line_allocation(uuid,text)') IS NULL
    THEN false
    ELSE has_function_privilege('authenticated', 'public.staff_reverse_dva_statement_line_allocation(uuid,text)', 'EXECUTE')
  END);
SELECT pg_temp.record_treasury_test(25, 'security', 'Anonymous role cannot execute new treasury write or ranking RPCs',
  (
    CASE WHEN to_regprocedure('public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)') IS NULL THEN false
      ELSE NOT has_function_privilege('anon', 'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)', 'EXECUTE') END
  ) AND (
    CASE WHEN to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)') IS NULL THEN false
      ELSE NOT has_function_privilege('anon', 'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)', 'EXECUTE') END
  ) AND (
    CASE WHEN to_regprocedure('public.internal_supplier_payment_next_invoice_candidates_v1(uuid)') IS NULL THEN false
      ELSE NOT has_function_privilege('anon', 'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)', 'EXECUTE') END
  ));

-- 26-40: immutable evidence and audited interpretation contract.
SELECT pg_temp.record_treasury_test(26, 'interpretation', 'Exactly one active correction is structurally enforced',
  EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    WHERE i.indrelid = to_regclass('public.statement_line_interpretation_corrections')
      AND i.indisunique
      AND pg_get_expr(i.indpred, i.indrelid) ILIKE '%active%'
  ));
SELECT pg_temp.record_treasury_test(27, 'interpretation', 'Correction reason minimum-length constraint exists',
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = to_regclass('public.statement_line_interpretation_corrections')
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%correction_reason%'
      AND pg_get_constraintdef(oid) ILIKE '%8%'
  ));
SELECT pg_temp.record_treasury_test(28, 'interpretation', 'Raw direction snapshot accepts only IN or OUT',
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = to_regclass('public.statement_line_interpretation_corrections')
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%raw_direction_snapshot%'
      AND pg_get_constraintdef(oid) ILIKE '%in%'
      AND pg_get_constraintdef(oid) ILIKE '%out%'
  ));
SELECT pg_temp.record_treasury_test(29, 'interpretation', 'Effective direction accepts only IN or OUT',
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = to_regclass('public.statement_line_interpretation_corrections')
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%effective_direction%'
      AND pg_get_constraintdef(oid) ILIKE '%in%'
      AND pg_get_constraintdef(oid) ILIKE '%out%'
  ));
SELECT pg_temp.record_treasury_test(30, 'interpretation', 'Economic classification constraint contains all governed lanes',
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = to_regclass('public.statement_line_interpretation_corrections')
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%customer_order_funding%'
      AND pg_get_constraintdef(oid) ILIKE '%supplier_payment%'
      AND pg_get_constraintdef(oid) ILIKE '%retailer_refund%'
      AND pg_get_constraintdef(oid) ILIKE '%completion_loyalty_source_transfer%'
      AND pg_get_constraintdef(oid) ILIKE '%main_bank_shipper_ap%'
  ));
SELECT pg_temp.assert_view_definition(31, 'interpretation', 'Effective view exposes raw bank direction separately',
  'public.statement_line_effective_interpretation_v1',
  ARRAY['dsl.direction', 'raw_direction', 'effective_direction']);
SELECT pg_temp.assert_view_definition(32, 'interpretation', 'Effective view preserves raw statement amount',
  'public.statement_line_effective_interpretation_v1',
  ARRAY['dsl.amount_gbp_equivalent'],
  ARRAY['c.amount_gbp_equivalent']);
SELECT pg_temp.assert_view_definition(33, 'interpretation', 'Description correction changes display only',
  'public.statement_line_effective_interpretation_v1',
  ARRAY['dsl.reference_raw', 'raw_description', 'corrected_display_description', 'effective_display_description']);
SELECT pg_temp.assert_function_definition(34, 'interpretation', 'Correction RPC is restricted to admin and supervisor',
  'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)',
  ARRAY['admin', 'supervisor', 'active']);
SELECT pg_temp.assert_function_definition(35, 'interpretation', 'Correction RPC enforces an eight-character reason',
  'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)',
  ARRAY['char_length(v_reason) < 8']);
SELECT pg_temp.assert_function_definition(36, 'interpretation', 'Correction RPC enforces account-context and direction compatibility',
  'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)',
  ARRAY['requires importer dva/card in', 'supplier payment requires importer dva/card out', 'requires main-company-bank out']);
SELECT pg_temp.assert_function_definition(37, 'interpretation', 'Correction RPC blocks active economic use',
  'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)',
  ARRAY['already has active economic use', 'dva_reconciliation', 'dva_statement_line_allocations', 'main_bank_completion_loyalty_funding_matches', 'main_bank_shipper_ap_allocations']);
SELECT pg_temp.assert_function_definition(38, 'interpretation', 'Correction RPC blocks active cash-posting evidence',
  'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)',
  ARRAY['cash_posting_snapshots', 'active cash-posting snapshot']);
SELECT pg_temp.assert_function_definition(39, 'interpretation', 'Correction RPC supersedes rather than deletes prior history',
  'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)',
  ARRAY['active = false', 'superseded_at', 'superseded_by_staff_id', 'insert into public.statement_line_interpretation_corrections'],
  ARRAY['delete from public.statement_line_interpretation_corrections']);
SELECT pg_temp.assert_function_definition(40, 'interpretation', 'Correction RPC never mutates the physical statement line',
  'public.staff_correct_statement_line_interpretation_v1(uuid,text,text,text,text)',
  ARRAY['from public.dva_statement_lines'],
  ARRAY['update public.dva_statement_lines', 'delete from public.dva_statement_lines']);

-- 41-55: resolver v2 and worklist.
SELECT pg_temp.record_treasury_test(41, 'resolver', 'Resolver v2 is security definer and stable',
  COALESCE((
    SELECT prosecdef AND provolatile = 's'
    FROM pg_proc
    WHERE oid = to_regprocedure('public.internal_statement_line_control_resolver_v2(uuid)')
  ), false));
SELECT pg_temp.record_treasury_test(42, 'resolver', 'Legacy resolver v1 is no longer directly executable by authenticated',
  CASE WHEN to_regprocedure('public.internal_statement_line_control_resolver_v1(uuid)') IS NULL THEN false
    ELSE NOT has_function_privilege('authenticated', 'public.internal_statement_line_control_resolver_v1(uuid)', 'EXECUTE')
  END);
SELECT pg_temp.record_treasury_test(43, 'resolver', 'Authenticated staff can execute resolver v2',
  CASE WHEN to_regprocedure('public.internal_statement_line_control_resolver_v2(uuid)') IS NULL THEN false
    ELSE has_function_privilege('authenticated', 'public.internal_statement_line_control_resolver_v2(uuid)', 'EXECUTE')
  END);
SELECT pg_temp.assert_function_definition(44, 'resolver', 'Resolver v2 exposes raw and effective interpretation together',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['raw_description', 'effective_display_description', 'raw_direction', 'effective_direction', 'effective_economic_classification']);
SELECT pg_temp.assert_function_definition(45, 'resolver', 'Resolver v2 exposes blocked, review-required, open and controlled states',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['blocked', 'review_required', 'open', 'controlled']);
SELECT pg_temp.assert_function_definition(46, 'resolver', 'Resolver v2 blocks statement-line overconsumption',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['statement_line_overconsumed', 'overconsumed_gbp > 0.01']);
SELECT pg_temp.assert_function_definition(47, 'resolver', 'Resolver v2 blocks incompatible principal lanes',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['incompatible_principal_economic_lanes', 'principal_lane_count > 1']);
SELECT pg_temp.assert_function_definition(48, 'resolver', 'Resolver v2 retains legacy-loyalty review routing',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['legacy_loyalty_evidence_without_modern_match_link', 'legacy_completion_loyalty_funding']);
SELECT pg_temp.assert_function_definition(49, 'resolver', 'Funding eligibility remains importer DVA/card IN only',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['statement_account_context = ''importer_dva_card_account''', 'effective_direction = ''in''', 'funding_action_allowed_yn']);
SELECT pg_temp.assert_function_definition(50, 'resolver', 'Supplier-payment classification routes to supplier payment',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['effective_economic_classification = ''supplier_payment''', '''supplier_payment''']);
SELECT pg_temp.assert_function_definition(51, 'resolver', 'Main-bank shipper classification routes to shipper AP',
  'public.internal_statement_line_control_resolver_v2(uuid)',
  ARRAY['effective_economic_classification = ''main_bank_shipper_ap''', '''main_bank_shipper_ap''']);
SELECT pg_temp.assert_function_definition(52, 'worklist', 'Worklist limit is fail-safe capped at 500',
  'public.internal_statement_line_control_worklist_v1(uuid,integer,integer)',
  ARRAY['least', 'greatest', '500']);
SELECT pg_temp.assert_function_definition(53, 'worklist', 'Worklist requires an active staff account',
  'public.internal_statement_line_control_worklist_v1(uuid,integer,integer)',
  ARRAY['auth.uid() is null', 'not public.is_active_staff()', 'active staff account required']);
SELECT pg_temp.assert_function_definition(54, 'worklist', 'Worklist returns total count for controlled pagination',
  'public.internal_statement_line_control_worklist_v1(uuid,integer,integer)',
  ARRAY['count(*) over()', 'total_count']);
SELECT pg_temp.assert_function_definition(55, 'worklist', 'Worklist is deterministically ordered newest-first',
  'public.internal_statement_line_control_worklist_v1(uuid,integer,integer)',
  ARRAY['order by b.statement_date desc', 'b.dva_statement_line_id desc']);

-- 56-65: existing routes remain available and unchanged in authority.
SELECT pg_temp.record_treasury_test(56, 'compatibility', 'Strict single-invoice supplier allocator remains available',
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'staff_allocate_statement_line_to_supplier_invoice'
  ));
SELECT pg_temp.record_treasury_test(57, 'compatibility', 'Atomic multi-invoice bundle allocator remains available',
  to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(58, 'compatibility', 'Supplier-payment readiness gate remains authoritative',
  to_regprocedure('public.internal_supplier_payment_readiness_v1(uuid)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(59, 'compatibility', 'Existing supplier source resolver remains authoritative',
  to_regprocedure('public.internal_supplier_payment_bundle_source_v1(uuid,numeric)') IS NOT NULL);
SELECT pg_temp.record_treasury_test(60, 'compatibility', 'Order-funding trigger still executes the shared guard',
  EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE t.tgname = 'trg_guard_order_funding_statement_line_v1'
      AND p.proname = 'internal_guard_order_funding_statement_line_v1'
      AND NOT t.tgisinternal
  ));
SELECT pg_temp.record_treasury_test(61, 'compatibility', 'Existing allocation summary remains available',
  to_regclass('public.dva_statement_line_allocation_summary_vw') IS NOT NULL);
SELECT pg_temp.record_treasury_test(62, 'compatibility', 'Existing funding review worklist remains available',
  to_regclass('public.day2_dva_review_worklist_vw') IS NOT NULL);
SELECT pg_temp.record_treasury_test(63, 'compatibility', 'Sequential allocator is a separate RPC, not a replacement overload',
  (
    SELECT count(*) = 1
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'staff_allocate_statement_line_to_supplier_invoice_incremental_v1'
  ) AND EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'staff_allocate_statement_line_to_supplier_invoice'
  ));
SELECT pg_temp.assert_function_definition(64, 'compatibility', 'Atomic bundle still requires one full physical OUT and shared source provenance',
  'public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)',
  ARRAY['jsonb_to_recordset', 'full amount', 'source_bank_account_mapping_code', 'source_wallet_code', 'approved_current']);
SELECT pg_temp.assert_function_definition(65, 'compatibility', 'Sequential allocator contains no Sage or VAT posting writes',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['insert into public.dva_statement_line_allocations'],
  ARRAY['insert into public.sage', 'update public.sage', 'vat_return', 'vat_posting']);

-- 66-80: sequential allocator write-time guards.
SELECT pg_temp.assert_function_definition(66, 'sequential', 'Sequential writes are admin/supervisor only',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['admin', 'supervisor', 'active']);
SELECT pg_temp.assert_function_definition(67, 'sequential', 'Sequential allocator locks the physical statement row',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['public.dva_statement_lines dsl', 'for update']);
SELECT pg_temp.assert_function_definition(68, 'sequential', 'Sequential allocator does not try to lock the interpretation view',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['from public.statement_line_effective_interpretation_v1 e'],
  ARRAY['for update of e']);
SELECT pg_temp.assert_function_definition(69, 'sequential', 'Sequential route requires importer DVA/card OUT',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['sequential supplier allocation requires effective importer dva/card out']);
SELECT pg_temp.assert_function_definition(70, 'sequential', 'Sequential route accepts only unclassified or supplier-payment interpretation',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['effective_economic_classification not in (''unclassified'', ''supplier_payment'')']);
SELECT pg_temp.assert_function_definition(71, 'sequential', 'Draft and held allocation rows block sequential use',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['allocation_status in (''draft'', ''held'')', 'resolve draft/held allocations']);
SELECT pg_temp.assert_function_definition(72, 'sequential', 'Active non-supplier use blocks sequential allocation',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['allocation_type <> ''supplier_invoice''', 'incompatible active non-supplier allocation']);
SELECT pg_temp.assert_function_definition(73, 'sequential', 'Statement remaining amount is enforced',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['exceeds statement-line remaining amount', 'no remaining amount to allocate']);
SELECT pg_temp.assert_function_definition(74, 'sequential', 'Only approved-current invoices may be allocated',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['review_status is distinct from ''approved_current''']);
SELECT pg_temp.assert_function_definition(75, 'sequential', 'Supplier-invoice remaining amount is enforced',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['already fully allocated', 'exceeds supplier-invoice remaining amount']);
SELECT pg_temp.assert_function_definition(76, 'sequential', 'Duplicate active line-to-invoice allocation is rejected',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['already has an active allocation to invoice']);
SELECT pg_temp.assert_function_definition(77, 'sequential', 'Statement importer must match order importer',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['statement-line importer', 'does not match order importer']);
SELECT pg_temp.assert_function_definition(78, 'sequential', 'Archived and cancelled orders are rejected at write time',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['v_order.status in (''archived'', ''cancelled'')']);
SELECT pg_temp.assert_function_definition(79, 'sequential', 'Supplier-payment funding readiness is repeated at write time',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['internal_supplier_payment_readiness_v1', 'supplier_payment_ready_yn', 'source_funding_required_for_supplier_payment_bank_resolution']);
SELECT pg_temp.assert_function_definition(80, 'sequential', 'Later allocations inherit one order/importer/retailer and source mapping',
  'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)',
  ARRAY['same order, importer and retailer', 'existing sequential allocation source mapping is missing or inconsistent', 'inherited_from_first_statement_line_supplier_allocation']);

-- 81-90: hard eligibility and non-binding ranking.
SELECT pg_temp.record_treasury_test(81, 'eligibility', 'Eligibility function is stable security definer',
  COALESCE((
    SELECT prosecdef AND provolatile = 's'
    FROM pg_proc
    WHERE oid = to_regprocedure('public.internal_supplier_payment_next_invoice_candidates_v1(uuid)')
  ), false));
SELECT pg_temp.assert_function_definition(82, 'eligibility', 'Eligibility function requires active staff',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['auth.uid() is null', 'not public.is_active_staff()', 'active staff account required']);
SELECT pg_temp.assert_function_definition(83, 'eligibility', 'Candidate scope is restricted to the statement importer',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['c.importer_id = ls.importer_id']);
SELECT pg_temp.assert_function_definition(84, 'eligibility', 'Archived and cancelled candidates are hard-blocked before display',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['candidate_order_archived_or_cancelled', 'candidate_order_status in (''archived'', ''cancelled'')']);
SELECT pg_temp.assert_function_definition(85, 'eligibility', 'Draft or held statement allocations hard-block every candidate',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['statement_line_has_draft_or_held_allocation', 'draft_or_held_count > 0']);
SELECT pg_temp.assert_function_definition(86, 'eligibility', 'Active non-supplier statement use hard-blocks every candidate',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['statement_line_has_active_non_supplier_allocation', 'active_non_supplier_count > 0']);
SELECT pg_temp.assert_function_definition(87, 'eligibility', 'Existing sequence locks order and retailer identity',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['candidate_not_same_locked_order', 'candidate_not_same_locked_retailer', 'locked_order_id', 'locked_retailer_id']);
SELECT pg_temp.assert_function_definition(88, 'eligibility', 'Already-used invoice is hard-blocked on the same statement line',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['candidate_invoice_already_allocated_on_statement_line']);
SELECT pg_temp.assert_function_definition(89, 'ranking', 'Ranking is exactly the governed 100-point model',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['amount_fit_score', 'retailer_fit_score', 'reference_fit_score', 'date_fit_score', 'ranking_score', '40', '25', '20', '15']);
SELECT pg_temp.assert_function_definition(90, 'ranking', 'Hard eligibility sorts before score and remains independent of ranking',
  'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)',
  ARRAY['hard_blocker is null', 'hard_eligible_yn', 'ranking_score']);

-- 91-95: audited reversal.
SELECT pg_temp.assert_function_definition(91, 'reversal', 'Allocation reversal is admin/supervisor only',
  'public.staff_reverse_dva_statement_line_allocation(uuid,text)',
  ARRAY['admin', 'supervisor', 'active']);
SELECT pg_temp.assert_function_definition(92, 'reversal', 'Allocation reversal requires an eight-character reason',
  'public.staff_reverse_dva_statement_line_allocation(uuid,text)',
  ARRAY['length(v_reason) < 8']);
SELECT pg_temp.assert_function_definition(93, 'reversal', 'Reversal fills actor, time and reason audit columns',
  'public.staff_reverse_dva_statement_line_allocation(uuid,text)',
  ARRAY['reversed_by_staff_id', 'reversed_at', 'reversal_reason']);
SELECT pg_temp.assert_function_definition(94, 'reversal', 'Reversal changes status rather than deleting the allocation',
  'public.staff_reverse_dva_statement_line_allocation(uuid,text)',
  ARRAY['allocation_status = ''reversed'''],
  ARRAY['delete from public.dva_statement_line_allocations']);
SELECT pg_temp.assert_function_definition(95, 'reversal', 'Reversal reports recalculated allocated and remaining amounts',
  'public.staff_reverse_dva_statement_line_allocation(uuid,text)',
  ARRAY['confirmed_allocated_after_gbp', 'confirmed_unallocated_after_gbp', 'reversed_amount_gbp']);

-- 96-100: live-data invariants and pilot-route preservation.
SELECT pg_temp.assert_zero_rows(
  96,
  'live_invariant',
  'No statement line has more than one active interpretation correction',
  $sql$
    SELECT dva_statement_line_id
    FROM public.statement_line_interpretation_corrections
    WHERE active
    GROUP BY dva_statement_line_id
    HAVING count(*) > 1
  $sql$
);

SELECT pg_temp.assert_zero_rows(
  97,
  'live_invariant',
  'Effective interpretation has one row per physical line and preserves raw direction, description and amount',
  $sql$
    SELECT dsl.id
    FROM public.dva_statement_lines dsl
    LEFT JOIN public.statement_line_effective_interpretation_v1 e
      ON e.dva_statement_line_id = dsl.id
    GROUP BY dsl.id, dsl.direction, dsl.reference_raw, dsl.amount_gbp_equivalent
    HAVING count(e.dva_statement_line_id) <> 1
       OR max(e.raw_direction) IS DISTINCT FROM dsl.direction::text
       OR max(e.raw_description) IS DISTINCT FROM dsl.reference_raw::text
       OR max(e.amount_gbp_equivalent) IS DISTINCT FROM dsl.amount_gbp_equivalent
  $sql$
);

SELECT pg_temp.assert_zero_rows(
  98,
  'live_invariant',
  'Resolver v2 is one-row-per-line and preserves the amount equation',
  $sql$
    SELECT p.statement_line_id
    FROM public.statement_line_control_position_v1 p
    LEFT JOIN LATERAL public.internal_statement_line_control_resolver_v2(p.statement_line_id) r ON true
    GROUP BY
      p.statement_line_id,
      p.statement_gbp_amount,
      p.active_consumed_gbp,
      p.active_reserved_gbp,
      p.remaining_unconsumed_gbp,
      p.overconsumed_gbp
    HAVING count(r.statement_line_id) <> 1
       OR abs(
         p.statement_gbp_amount
         - p.active_consumed_gbp
         - p.active_reserved_gbp
         - p.remaining_unconsumed_gbp
         + p.overconsumed_gbp
       ) > 0.01
  $sql$
);

SELECT pg_temp.assert_zero_rows(
  99,
  'live_invariant',
  'Active supplier allocations preserve one identity/source and never over-allocate a line or invoice',
  $sql$
    WITH line_identity_violations AS (
      SELECT a.dva_statement_line_id AS id
      FROM public.dva_statement_line_allocations a
      JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
      JOIN public.orders o ON o.id = si.order_id
      WHERE a.allocation_type = 'supplier_invoice'
        AND a.allocation_status = 'confirmed'
      GROUP BY a.dva_statement_line_id
      HAVING count(DISTINCT si.order_id) > 1
         OR count(DISTINCT o.importer_id) > 1
         OR count(DISTINCT o.retailer_id) > 1
         OR count(DISTINCT concat_ws('|',
              nullif(btrim(a.source_bank_account_mapping_code), ''),
              nullif(btrim(a.source_wallet_code), '')
            )) > 1
         OR bool_or(nullif(btrim(a.source_bank_account_mapping_code), '') IS NULL)
    ),
    line_amount_violations AS (
      SELECT a.dva_statement_line_id AS id
      FROM public.dva_statement_line_allocations a
      JOIN public.dva_statement_lines dsl ON dsl.id = a.dva_statement_line_id
      WHERE a.allocation_type = 'supplier_invoice'
        AND a.allocation_status = 'confirmed'
      GROUP BY a.dva_statement_line_id, dsl.amount_gbp_equivalent
      HAVING round(sum(a.allocated_gbp_amount)::numeric, 2)
           > round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric, 2) + 0.01
    ),
    invoice_allocated AS (
      SELECT
        a.supplier_invoice_id,
        round(sum(a.allocated_gbp_amount)::numeric, 2) AS allocated_gbp
      FROM public.dva_statement_line_allocations a
      WHERE a.allocation_type = 'supplier_invoice'
        AND a.allocation_status = 'confirmed'
      GROUP BY a.supplier_invoice_id
    ),
    invoice_totals AS (
      SELECT
        si.id AS supplier_invoice_id,
        round(coalesce(
          si.ocr_invoice_total_gbp,
          si.reconciliation_gbp_total,
          sum(coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)),
          0
        )::numeric, 2) AS invoice_total_gbp
      FROM public.supplier_invoices si
      LEFT JOIN public.supplier_invoice_lines sil
        ON sil.supplier_invoice_id = si.id
      GROUP BY
        si.id,
        si.ocr_invoice_total_gbp,
        si.reconciliation_gbp_total
    ),
    invoice_amount_violations AS (
      SELECT ia.supplier_invoice_id AS id
      FROM invoice_allocated ia
      JOIN invoice_totals it
        ON it.supplier_invoice_id = ia.supplier_invoice_id
      WHERE ia.allocated_gbp > it.invoice_total_gbp + 0.01
    )
    SELECT id FROM line_identity_violations
    UNION ALL SELECT id FROM line_amount_violations
    UNION ALL SELECT id FROM invoice_amount_violations
  $sql$
);

SELECT pg_temp.assert_zero_rows(
  100,
  'live_invariant',
  'Historical evidence consumes no current amount and blocked positions expose the correct blocker',
  $sql$
    SELECT u.statement_line_id
    FROM public.statement_line_control_usage_v1 u
    WHERE u.evidence_state = 'historical'
      AND (u.consumed_gbp <> 0 OR u.reserved_gbp <> 0)
    UNION ALL
    SELECT p.statement_line_id
    FROM public.statement_line_control_position_v1 p
    CROSS JOIN LATERAL public.internal_statement_line_control_resolver_v2(p.statement_line_id) r
    WHERE (p.overconsumed_gbp > 0.01 AND (r.control_status <> 'blocked' OR r.blocker <> 'statement_line_overconsumed'))
       OR (p.principal_lane_count > 1 AND (r.control_status <> 'blocked' OR r.blocker <> 'incompatible_principal_economic_lanes'))
  $sql$
);

SELECT
  test_no,
  area,
  scenario,
  CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result,
  details
FROM treasury_control_regression_results
ORDER BY test_no;

SELECT
  count(*) AS scenario_count,
  count(*) FILTER (WHERE passed) AS passed_count,
  count(*) FILTER (WHERE NOT passed) AS failed_count,
  CASE
    WHEN count(*) = 100 AND bool_and(passed)
      THEN 'PASS: all 100 treasury statement-control scenarios passed'
    WHEN count(*) <> 100
      THEN format('FAIL: expected 100 scenarios but recorded %s', count(*))
    ELSE format('FAIL: %s of 100 treasury statement-control scenarios failed', count(*) FILTER (WHERE NOT passed))
  END AS regression_result
FROM treasury_control_regression_results;

DO $test$
DECLARE
  v_count integer;
  v_failed integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT passed)
    INTO v_count, v_failed
  FROM treasury_control_regression_results;

  IF v_count <> 100 THEN
    RAISE EXCEPTION 'FAIL: treasury regression recorded % scenarios; expected 100', v_count;
  END IF;

  IF v_failed > 0 THEN
    RAISE EXCEPTION 'FAIL: % of 100 treasury statement-control scenarios failed', v_failed;
  END IF;
END;
$test$;

ROLLBACK;
