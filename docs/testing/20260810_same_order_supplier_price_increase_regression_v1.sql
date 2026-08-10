BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_view_definition text;
  v_trigger_definition text;
  v_count integer;
  v_md5 text;
  v_security_definer boolean;
  v_config text[];
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Freeze explicitly untouched established authorities.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: established supplier header-review RPC is missing.';
  END IF;

  SELECT md5(pg_get_functiondef('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)'::regprocedure))
  INTO v_md5;
  IF v_md5 IS DISTINCT FROM '44719b0f9a435f01ea138e1cca6a034e' THEN
    RAISE EXCEPTION 'FAIL: supplier header-review RPC fingerprint changed: %.', v_md5;
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
    RAISE EXCEPTION 'FAIL: supplier invoice bundle summary fingerprint changed: %.', v_md5;
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. New live read model contract.
  -- -------------------------------------------------------------------------
  IF to_regclass('public.order_supplier_price_position_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: order_supplier_price_position_v1 is missing.';
  END IF;

  SELECT pg_get_viewdef('public.order_supplier_price_position_v1'::regclass, true)
  INTO v_view_definition;

  FOR v_definition IN
    SELECT unnest(ARRAY[
      'accepted_invoice_gross_gbp',
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded',
      'order_bundle_limit_breach',
      'retailer_match_yn',
      'invoice_ref_match_yn',
      'total_match_yn',
      'ocr_line_count',
      'pending_adjustment_yn',
      'unverified_invoice_count',
      'missing_accepted_total_count',
      'review_anchor_supplier_invoice_id'
    ])
  LOOP
    IF position(v_definition in v_view_definition) = 0 THEN
      RAISE EXCEPTION 'FAIL: live supplier price position is missing required token %.', v_definition;
    END IF;
  END LOOP;

  SELECT count(*)::integer
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'order_supplier_price_position_v1'
    AND column_name IN (
      'order_id','order_type','current_order_value_gbp','accepted_supplier_bundle_gbp',
      'price_increase_required_gbp','over_limit_yn','active_invoice_count',
      'missing_accepted_total_count','unverified_invoice_count','review_anchor_supplier_invoice_id'
    );
  IF v_count <> 10 THEN
    RAISE EXCEPTION 'FAIL: live supplier price position shape incomplete; found % required columns.', v_count;
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. New approval-state backstop protects every existing approval caller.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.enforce_supplier_invoice_order_price_limit_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: supplier approval price-limit guard is missing.';
  END IF;

  SELECT count(*)::integer, min(pg_get_triggerdef(t.oid, true))
  INTO v_count, v_trigger_definition
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.supplier_invoices'::regclass
    AND t.tgname = 'trg_enforce_supplier_invoice_order_price_limit_v1'
    AND NOT t.tgisinternal;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one supplier price-limit approval trigger, found %.', v_count;
  END IF;
  IF position('AFTER INSERT OR UPDATE' in upper(v_trigger_definition)) = 0
     OR position('enforce_supplier_invoice_order_price_limit_v1' in v_trigger_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: supplier approval transition trigger definition is wrong: %.', v_trigger_definition;
  END IF;

  SELECT lower(pg_get_functiondef('public.enforce_supplier_invoice_order_price_limit_v1()'::regprocedure))
  INTO v_definition;
  IF position('order_type <> ''original''' in v_definition) = 0
     OR position('unverified_invoice_count' in v_definition) = 0
     OR position('missing_accepted_total_count' in v_definition) = 0
     OR position('accepted_supplier_bundle_gbp' in v_definition) = 0
     OR position('order_total_gbp_declared + 0.01' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: supplier approval backstop lost an original-order/verified-bundle control.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Dedicated write RPC contract and security boundary.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.staff_approve_order_supplier_price_increase_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: dedicated price-increase RPC is missing.';
  END IF;

  SELECT p.prosecdef, p.proconfig, lower(pg_get_functiondef(p.oid))
  INTO v_security_definer, v_config, v_definition
  FROM pg_proc p
  WHERE p.oid = 'public.staff_approve_order_supplier_price_increase_v1(uuid,text)'::regprocedure;

  IF NOT COALESCE(v_security_definer, false) THEN
    RAISE EXCEPTION 'FAIL: dedicated price-increase RPC is not SECURITY DEFINER.';
  END IF;
  IF NOT COALESCE(v_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'FAIL: dedicated price-increase RPC search_path boundary changed: %.', v_config;
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.staff_approve_order_supplier_price_increase_v1(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated role lacks price-increase RPC EXECUTE.';
  END IF;
  IF has_function_privilege('anon', 'public.staff_approve_order_supplier_price_increase_v1(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon unexpectedly has price-increase RPC EXECUTE.';
  END IF;

  FOR v_view_definition IN
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
      'review_anchor_supplier_invoice_id is null',
      'missing_accepted_total_count',
      'unverified_invoice_count',
      'event_type = ''funding_reversed''',
      'source_type = ''overfunding''',
      'order_pending_funding_surplus',
      'order_funding_total_gbp',
      'order_funding_position_vw',
      'quote_total_ghs / v_old_total',
      'recompute_order_platform_funded',
      'sync_order_overfunding_credit',
      'v_event_count_after <> v_event_count_before',
      'flag_type = ''order_bundle_limit_breach'''
    ])
  LOOP
    IF position(v_view_definition in v_definition) = 0 THEN
      RAISE EXCEPTION 'FAIL: dedicated price-increase RPC lost required guard/action token %.', v_view_definition;
    END IF;
  END LOOP;

  IF position('p_new_order' in v_definition) > 0
     OR position('p_new_total' in v_definition) > 0
     OR position('p_amount' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: dedicated price-increase RPC accepts a browser-supplied amount.';
  END IF;

  IF position('bundled_quote_gbp' in v_definition) > 0
     OR position('bundled_final_gbp' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: dedicated price-increase RPC touches separate bundled quote/final fields.';
  END IF;

  -- Only bundle-limit flags may be resolved by the dedicated RPC.
  IF position('flag_type = ''order_bundle_limit_breach''' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: dedicated RPC does not scope flag resolution to bundle-limit flags.';
  END IF;
END
$regression$;

SELECT
  'PASS'::text AS regression_result,
  'Same-order supplier price increase adds only a verified live bundle read model, an additive approval-state backstop and a dedicated server-derived order-price RPC while protected funding, DVA, supplier-payment, bundle-summary and Build 4 authorities retain their reviewed fingerprints.'::text AS details;

ROLLBACK;
