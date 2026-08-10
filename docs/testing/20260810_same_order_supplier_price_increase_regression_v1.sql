BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_trigger_definition text;
  v_count integer;
  v_md5 text;
  v_security_definer boolean;
  v_config text[];
  v_args text;
  v_summary_lock_pos integer;
  v_invoice_lock_pos integer;
  v_advisory_lock_pos integer;
  v_order_lock_pos integer;
  v_breach_lock_pos integer;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Freeze established authorities this build must not change.
  -- -------------------------------------------------------------------------
  SELECT md5(pg_get_functiondef('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)'::regprocedure))
  INTO v_md5;
  IF v_md5 IS DISTINCT FROM '44719b0f9a435f01ea138e1cca6a034e' THEN
    RAISE EXCEPTION 'FAIL: supplier header-review RPC fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.flag_order_bundle_limit_after_summary_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '9227a2afe69a79b745f7934534325125' THEN
    RAISE EXCEPTION 'FAIL: existing bundle-limit INSERT authority changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.enforce_order_locks()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '497230d0cf04001f37c5e805cdd8da25' THEN
    RAISE EXCEPTION 'FAIL: enforce_order_locks fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.order_funding_total_gbp(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '7f71d968c6662c1df535a50428797fb4' THEN
    RAISE EXCEPTION 'FAIL: order_funding_total_gbp fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.order_funding_gap_gbp(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '8c2ce167a7012ee50b98d9886c455454' THEN
    RAISE EXCEPTION 'FAIL: order_funding_gap_gbp fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.recompute_order_platform_funded(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'cfd3c7bca289b26e748a00c8170a3a9b' THEN
    RAISE EXCEPTION 'FAIL: recompute_order_platform_funded fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.sync_order_overfunding_credit(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'f2dcd920585c696b59c80b8baab220b8' THEN
    RAISE EXCEPTION 'FAIL: sync_order_overfunding_credit fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.internal_supplier_payment_readiness_v1(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '004105ba835a28c500e6b697cb4b75bb' THEN
    RAISE EXCEPTION 'FAIL: supplier payment readiness fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '7f4499adddc7c7433cae6e2a17c68282' THEN
    RAISE EXCEPTION 'FAIL: supplier payment bundle source fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '3d888918bff171d132049104b5692937' THEN
    RAISE EXCEPTION 'FAIL: DVA order-funding RPC fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.staff_progress_supplier_invoice_lines(uuid,uuid,uuid[],text)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'aa32e0922cfa600a517fc8f0a23ca1b0' THEN
    RAISE EXCEPTION 'FAIL: supplier invoice line progression fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_viewdef('public.order_reconciliation_vw'::regclass, true)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'ae9bb789b2e536c96029573fa8969214' THEN
    RAISE EXCEPTION 'FAIL: Build 4 order_reconciliation_vw fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_viewdef('public.order_reconciliation_v2_vw'::regclass, true)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '08a1e31a6798dc1f8e19d17f423bb56f' THEN
    RAISE EXCEPTION 'FAIL: Build 4 order_reconciliation_v2_vw fingerprint changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_viewdef('public.order_supplier_invoice_bundle_summary_v1'::regclass, true)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '124ff92c4bb40582012109e7835e83ec' THEN
    RAISE EXCEPTION 'FAIL: established supplier bundle summary changed: %.', v_md5;
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Explicitly prove the discarded scope-creep authorities are absent.
  -- -------------------------------------------------------------------------
  IF to_regclass('public.order_supplier_price_position_v1') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: discarded order_supplier_price_position_v1 still exists.';
  END IF;
  IF to_regprocedure('public.enforce_supplier_invoice_order_price_limit_v1()') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: discarded global supplier approval price guard still exists.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger t
    WHERE t.tgname = 'trg_enforce_supplier_invoice_order_price_limit_v1'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL: discarded global supplier approval transition trigger still exists.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Narrow protection: generic Save cannot clear a genuine live breach.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.protect_order_bundle_limit_breach_resolution_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: bundle breach resolution protector is missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.protect_order_bundle_limit_breach_resolution_v1()'::regprocedure))
  INTO v_definition;

  IF position('old.flag_type is distinct from ''order_bundle_limit_breach''' in v_definition) = 0
     OR position('old.status not in (''open'', ''under_review'')' in v_definition) = 0
     OR position('new.status is distinct from ''resolved''' in v_definition) = 0
     OR position('sum(fs.invoice_total_gbp)' in v_definition) = 0
     OR position('new.status := old.status' in v_definition) = 0
     OR position('new.resolved_by_staff_id := old.resolved_by_staff_id' in v_definition) = 0
     OR position('new.resolved_at := old.resolved_at' in v_definition) = 0
     OR position('new.resolution_notes := old.resolution_notes' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: bundle breach resolution protector is broader or weaker than governed.';
  END IF;

  IF position('pg_advisory_xact_lock' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: flag-resolution protector takes the bundle advisory lock and can invert summary UPDATE lock order.';
  END IF;

  SELECT count(*)::integer, min(pg_get_triggerdef(t.oid, true))
  INTO v_count, v_trigger_definition
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.supplier_invoice_review_flags'::regclass
    AND t.tgname = 'trg_protect_order_bundle_limit_breach_resolution_v1'
    AND NOT t.tgisinternal;

  IF v_count <> 1
     OR position('BEFORE UPDATE OF status, resolved_by_staff_id, resolved_at, resolution_notes' in v_trigger_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: bundle breach resolution trigger definition is wrong: %.', v_trigger_definition;
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Narrow UPDATE coverage: existing INSERT trigger stays untouched.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.flag_order_bundle_limit_after_summary_update_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: financial-summary UPDATE breach function is missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.flag_order_bundle_limit_after_summary_update_v1()'::regprocedure))
  INTO v_definition;

  IF position('new.invoice_total_gbp is not distinct from old.invoice_total_gbp' in v_definition) = 0
     OR position('v_order_type <> ''original''' in v_definition) = 0
     OR position('sum(fs.invoice_total_gbp)' in v_definition) = 0
     OR position('order_bundle_limit:' in v_definition) = 0
     OR position('flag_type = ''order_bundle_limit_breach''' in v_definition) = 0
     OR position('coalesce(new.entered_by_operator_id, old.entered_by_operator_id)' in v_definition) = 0
     OR position('f.raised_by_operator_id' in v_definition) = 0
     OR position('no review flag was falsely attributed' in v_definition) = 0
     OR position('v_raised_by_operator_id' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: summary UPDATE breach function lost governed scope/provenance.';
  END IF;

  SELECT count(*)::integer, min(pg_get_triggerdef(t.oid, true))
  INTO v_count, v_trigger_definition
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.supplier_invoice_financial_summary'::regclass
    AND t.tgname = 'trg_flag_order_bundle_limit_after_summary_update_v1'
    AND NOT t.tgisinternal;

  IF v_count <> 1
     OR position('AFTER UPDATE OF invoice_total_gbp' in v_trigger_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: summary UPDATE trigger definition is wrong: %.', v_trigger_definition;
  END IF;

  -- -------------------------------------------------------------------------
  -- 5. Dedicated provenance-bound write RPC.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: dedicated price-increase RPC is missing.';
  END IF;

  SELECT p.prosecdef, p.proconfig, lower(pg_get_functiondef(p.oid)), pg_get_function_arguments(p.oid)
  INTO v_security_definer, v_config, v_definition, v_args
  FROM pg_proc p
  WHERE p.oid = 'public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)'::regprocedure;

  IF NOT COALESCE(v_security_definer, false) THEN
    RAISE EXCEPTION 'FAIL: dedicated price-increase RPC is not SECURITY DEFINER.';
  END IF;
  IF NOT COALESCE(v_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'FAIL: dedicated RPC search_path boundary changed: %.', v_config;
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated role lacks dedicated price-increase EXECUTE.';
  END IF;
  IF has_function_privilege('anon', 'public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon unexpectedly has dedicated price-increase EXECUTE.';
  END IF;

  IF lower(v_args) NOT LIKE '%p_order_id uuid%'
     OR lower(v_args) NOT LIKE '%p_supplier_invoice_id uuid%'
     OR lower(v_args) NOT LIKE '%p_review_notes text%'
     OR lower(v_args) LIKE '%amount%'
     OR lower(v_args) LIKE '%new_total%'
     OR lower(v_args) LIKE '%new_order%' THEN
    RAISE EXCEPTION 'FAIL: dedicated RPC argument boundary is wrong: %.', v_args;
  END IF;

  FOR v_trigger_definition IN
    SELECT unnest(ARRAY[
      'pg_advisory_xact_lock',
      'order_bundle_limit:',
      'order_type, ''original''',
      'content_locked_at is not null',
      'completed_at is not null',
      'accounting_release_ready_at is not null',
      'vat_release_approved_at is not null',
      'vat_return_period is not null',
      'markup_applied_gbp',
      'supplier_invoice_id = p_supplier_invoice_id',
      'flag_type = ''order_bundle_limit_breach''',
      'status in (''open'', ''under_review'')',
      'sum(fs.invoice_total_gbp)',
      'event_type = ''funding_reversed''',
      'source_type = ''overfunding''',
      'order_pending_funding_surplus',
      'order_funding_total_gbp',
      'order_funding_position_vw',
      'quote_total_ghs / v_old_total',
      'recompute_order_platform_funded',
      'sync_order_overfunding_credit',
      'v_event_count_after <> v_event_count_before'
    ])
  LOOP
    IF position(v_trigger_definition in v_definition) = 0 THEN
      RAISE EXCEPTION 'FAIL: dedicated RPC lost required governed token %.', v_trigger_definition;
    END IF;
  END LOOP;

  -- Lock order: summary rows -> invoice rows -> advisory -> order -> exact breach.
  v_summary_lock_pos := position('for update of fs' in v_definition);
  v_invoice_lock_pos := position('for update of si' in substring(v_definition from v_summary_lock_pos + 1));
  IF v_invoice_lock_pos > 0 THEN
    v_invoice_lock_pos := v_invoice_lock_pos + v_summary_lock_pos;
  END IF;
  v_advisory_lock_pos := position('pg_advisory_xact_lock(hashtext(''order_bundle_limit:'' || p_order_id::text))' in v_definition);
  v_order_lock_pos := position('where o.id = p_order_id' in v_definition);
  v_breach_lock_pos := position('for update of f' in v_definition);

  IF v_summary_lock_pos = 0
     OR v_invoice_lock_pos <= v_summary_lock_pos
     OR v_advisory_lock_pos <= v_invoice_lock_pos
     OR v_order_lock_pos <= v_advisory_lock_pos
     OR v_breach_lock_pos <= v_order_lock_pos THEN
    RAISE EXCEPTION 'FAIL: price RPC lock order drifted: summary %, invoice %, advisory %, order %, breach %.',
      v_summary_lock_pos, v_invoice_lock_pos, v_advisory_lock_pos, v_order_lock_pos, v_breach_lock_pos;
  END IF;

  IF position('accepted_invoice_gross_gbp' in v_definition) > 0
     OR position('order_supplier_price_position_v1' in v_definition) > 0
     OR position('bundled_quote_gbp' in v_definition) > 0
     OR position('bundled_final_gbp' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: dedicated RPC reintroduced a discarded or out-of-scope value authority.';
  END IF;
END
$regression$;

SELECT
  'PASS'::text AS regression_result,
  'Existing breach flag remains authoritative; generic header Save is untouched but cannot clear a genuine live bundle breach; summary total UPDATE receives the same narrow breach control with genuine operator provenance; the dedicated RPC uses the governed lock order and existing funding synchronisation while protected DVA, supplier-payment and Build 4 authorities retain their reviewed fingerprints.'::text AS details;

ROLLBACK;
