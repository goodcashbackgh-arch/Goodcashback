BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  r record;
  v_actual text;
  v_view_def text;
  v_function_def text;
  v_line_1 uuid := '28acc326-dd04-4ea8-b2b4-4d429e8ec5b7'::uuid;
  v_line_2 uuid := '0791dd47-43b3-4c16-bcb3-185d5de964da'::uuid;
  v_order_id uuid := '1e00758c-4b63-4a2a-be18-b5c4e274b62f'::uuid;
  v_staff_auth_uid uuid;
  v_compat_remaining numeric;
  v_compat_balanced boolean;
  v_canonical_remaining numeric;
  v_canonical_over numeric;
  v_consumed numeric;
  v_statement numeric;
  v_count_before integer;
  v_count_after integer;
  v_rejected boolean;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Frozen authorities must remain exactly as audited before the build.
  -- -------------------------------------------------------------------------
  FOR r IN
    SELECT *
    FROM (VALUES
      ('function', 'public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)', '3d888918bff171d132049104b5692937'),
      ('function', 'public.trg_sync_order_funding_event_from_dva_reconciliation()', '28fa4b6b255956601d84ed813dfca47e'),
      ('function', 'public.internal_guard_order_funding_statement_line_v1()', 'b687d2343908cc3b526efaebd3d820d9'),
      ('view', 'public.statement_line_effective_interpretation_v1', 'b9f63595b613c69715fe807836bdd4ef'),
      ('function', 'public.internal_completion_loyalty_destination_in_candidates_v1(uuid,text,integer,integer)', '4c77b96b38121b879ccf273b829b5aa6'),
      ('function', 'public.staff_pair_loyalty_destination_in_and_release_v1(uuid,uuid,text)', '49d05f8d9400611d74582fd6d5e3e0c5'),
      ('function', 'public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)', '93d34501d77c71d4c3ace0424f1d29b5'),
      ('view', 'public.statement_line_control_position_v1', 'fe6ee2fc8909e383b8d584995b30cc78'),
      ('function', 'public.internal_statement_line_control_resolver_v2(uuid)', 'eb9bfa5ea572335272217c372fa02f53'),
      ('function', 'public.staff_allocate_main_bank_line_to_shipper_ap_v1(uuid,uuid,numeric,text)', '233823bb26a631cc6e2e51a36ee89e27'),
      ('function', 'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)', 'b4f70e857141436a585bfb0a1b472d5c'),
      ('function', 'public.internal_supplier_payment_readiness_v1(uuid)', '004105ba835a28c500e6b697cb4b75bb'),
      ('function', 'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)', '7f4499adddc7c7433cae6e2a17c68282'),
      ('view', 'public.statement_line_control_usage_v1', '581d367a31ab0f689f3d31b46df5922e'),
      ('function', 'public.internal_statement_line_control_worklist_v1(uuid,integer,integer)', '021697c6302f2cedb39610a79dba2e1f')
    ) AS x(object_type, object_name, expected_md5)
  LOOP
    IF r.object_type = 'view' THEN
      EXECUTE format('SELECT md5(pg_get_viewdef(%L::regclass, true))', r.object_name)
        INTO v_actual;
    ELSE
      EXECUTE format('SELECT md5(pg_get_functiondef(%L::regprocedure))', r.object_name)
        INTO v_actual;
    END IF;

    IF v_actual IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION 'FAIL: frozen % changed. expected %, actual %.', r.object_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;

  FOR r IN
    SELECT *
    FROM (VALUES
      ('trg_guard_order_funding_statement_line_v1', '138e59bd4364968240d0ab0b091e9541'),
      ('trg_reverse_pending_surplus_with_funding_v1', '9a4b8bb6215fc62fad9dda9124a86ac8'),
      ('trg_sync_dva_line_status_from_order_funding_v1', '406a73e25a5687dc26a00cdad5dc6e3b'),
      ('trg_sync_order_funding_event_from_dva_reconciliation', 'b6ac2d75684239db99580da7157bbaa3')
    ) AS x(trigger_name, expected_md5)
  LOOP
    SELECT md5(pg_get_triggerdef(t.oid, true))
      INTO v_actual
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'dva_reconciliation'
      AND t.tgname = r.trigger_name
      AND NOT t.tgisinternal;

    IF v_actual IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION 'FAIL: frozen trigger % changed. expected %, actual %.', r.trigger_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- 2. Compatibility view must preserve its established contract while adding
  --    only the governed order-funding aggregate consumption.
  -- -------------------------------------------------------------------------
  SELECT lower(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true))
    INTO v_view_def;

  IF position('dva_reconciliation' IN v_view_def) = 0
     OR position('order_funding' IN v_view_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: compatibility summary does not include governed order-funding consumption.';
  END IF;

  IF position('dva_statement_line_allocations' IN v_view_def) = 0
     OR position('main_bank_completion_loyalty_funding_matches' IN v_view_def) = 0
     OR position('loyalty_internal_transfer_out_gbp' IN v_view_def) = 0
     OR position('loyalty_internal_transfer_in_gbp' IN v_view_def) = 0
     OR position('loyalty_internal_transfer_in_count' IN v_view_def) = 0
     OR position('dva_statement_line_import_links' IN v_view_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: compatibility summary lost an existing allocation, loyalty or voided-import seam.';
  END IF;

  -- No replacement order-funding columns are allowed; the change belongs only
  -- inside the three existing compatibility aggregate fields.
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'dva_statement_line_allocation_summary_vw'
      AND c.column_name IN ('order_funding_allocated_gbp', 'order_funding_reconciliation_count')
  ) THEN
    RAISE EXCEPTION 'FAIL: compatibility view contract was widened with replacement order-funding columns.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Known live funding + FX lines must agree between compatibility and
  --    canonical controls: fully consumed, zero remaining, no overconsumption.
  -- -------------------------------------------------------------------------
  FOR r IN
    SELECT * FROM (VALUES (v_line_1), (v_line_2)) AS x(line_id)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = r.line_id) THEN
      RAISE EXCEPTION 'FAIL: required live regression statement line % is missing.', r.line_id;
    END IF;

    SELECT
      s.statement_gbp_amount,
      s.confirmed_unallocated_gbp,
      s.confirmed_balanced_yn
    INTO
      v_statement,
      v_compat_remaining,
      v_compat_balanced
    FROM public.dva_statement_line_allocation_summary_vw s
    WHERE s.dva_statement_line_id = r.line_id;

    SELECT
      p.active_consumed_gbp,
      p.remaining_unconsumed_gbp,
      p.overconsumed_gbp
    INTO
      v_consumed,
      v_canonical_remaining,
      v_canonical_over
    FROM public.statement_line_control_position_v1 p
    WHERE p.statement_line_id = r.line_id;

    IF ABS(COALESCE(v_compat_remaining, 999999)) > 0.005
       OR COALESCE(v_compat_balanced, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: compatibility line % is not balanced. remaining %, balanced %.', r.line_id, v_compat_remaining, v_compat_balanced;
    END IF;

    IF ABS(COALESCE(v_canonical_remaining, 999999)) > 0.005
       OR ABS(COALESCE(v_canonical_over, 999999)) > 0.005
       OR ABS(COALESCE(v_consumed, 0) - COALESCE(v_statement, 0)) > 0.005 THEN
      RAISE EXCEPTION 'FAIL: canonical line % disagrees with physical amount. statement %, consumed %, remaining %, over %.', r.line_id, v_statement, v_consumed, v_canonical_remaining, v_canonical_over;
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- 4. The three changed writers must contain only the governed local seams.
  -- -------------------------------------------------------------------------
  SELECT lower(pg_get_functiondef('public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('remaining_unconsumed_gbp' IN v_function_def) = 0
     OR position('overconsumed_gbp' IN v_function_def) = 0
     OR position('principal_lane_count' IN v_function_def) = 0
     OR position('internal_order_final_sale_settlement_v2' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: final-balance writer lost its existing settlement path or canonical guard.';
  END IF;

  SELECT lower(pg_get_functiondef('public.staff_allocate_statement_line_to_dispute_or_hold(uuid,character varying,uuid,numeric,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('retailer_refund' IN v_function_def) = 0
     OR position('exception_hold' IN v_function_def) = 0
     OR position('not_charged_closure' IN v_function_def) = 0
     OR position('unmatched_hold' IN v_function_def) = 0
     OR position('principal_lane_count' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: dispute/hold writer lost an existing branch or canonical retailer-refund guard.';
  END IF;

  SELECT lower(pg_get_functiondef('public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('requested receipt amount' IN v_function_def) = 0
     OR position('canonical post-funding remaining amount' IN v_function_def) = 0
     OR position('public.staff_reconcile_dva_line_to_order(' IN v_function_def) = 0
     OR position('''fx_card_difference''' IN v_function_def) = 0
     OR position('credit_created_yn' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer-FX writer lost its existing split contract or canonical guards.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 5. Exercise the two unsafe reuse paths against the known fully consumed IN
  --    line. The functions must reject before creating allocation rows.
  -- -------------------------------------------------------------------------
  SELECT s.auth_user_id
    INTO v_staff_auth_uid
  FROM public.staff s
  WHERE s.active = true
    AND s.role_type IN ('admin', 'supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY s.id
  LIMIT 1;

  IF v_staff_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active admin/supervisor auth user is available for guarded-writer regression.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_staff_auth_uid::text, true);
  IF auth.uid() IS DISTINCT FROM v_staff_auth_uid THEN
    RAISE EXCEPTION 'FAIL: unable to establish active staff auth context.';
  END IF;

  SELECT count(*)::integer
    INTO v_count_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_line_2
    AND a.allocation_status <> 'reversed';

  v_rejected := false;
  BEGIN
    PERFORM public.staff_allocate_statement_line_to_final_balance_payment_v1(
      v_line_2,
      v_order_id,
      false,
      '[REGRESSION_ONLY] canonical fully-consumed final-balance rejection'
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := position('no remaining gbp to allocate' IN lower(SQLERRM)) > 0
                  OR position('canonical' IN lower(SQLERRM)) > 0;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: final-balance writer did not reject the fully consumed funding line through its canonical/zero-remaining guard.';
  END IF;

  SELECT count(*)::integer
    INTO v_count_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_line_2
    AND a.allocation_status <> 'reversed';

  IF v_count_after <> v_count_before THEN
    RAISE EXCEPTION 'FAIL: rejected final-balance attempt changed active allocation count from % to %.', v_count_before, v_count_after;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.staff_allocate_statement_line_to_dispute_or_hold(
      v_line_2,
      'retailer_refund',
      gen_random_uuid(),
      0.01,
      '[REGRESSION_ONLY] canonical fully-consumed retailer-refund rejection'
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := position('no canonical remaining amount' IN lower(SQLERRM)) > 0
                  OR position('canonical' IN lower(SQLERRM)) > 0;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: retailer-refund writer did not reject the fully consumed funding line through its canonical guard.';
  END IF;

  SELECT count(*)::integer
    INTO v_count_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_line_2
    AND a.allocation_status <> 'reversed';

  IF v_count_after <> v_count_before THEN
    RAISE EXCEPTION 'FAIL: rejected retailer-refund attempt changed active allocation count from % to %.', v_count_before, v_count_after;
  END IF;

  -- -------------------------------------------------------------------------
  -- 6. Customer-FX wrapper must reject reuse of the same fully consumed line
  --    before producing either another funding reconciliation or FX allocation.
  -- -------------------------------------------------------------------------
  SELECT count(*)::integer
    INTO v_count_before
  FROM public.dva_reconciliation dr
  WHERE dr.dva_statement_line_id = v_line_2;

  v_rejected := false;
  BEGIN
    PERFORM public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(
      v_line_2,
      v_order_id,
      0.01,
      NULL,
      '[REGRESSION_ONLY] canonical fully-consumed customer-FX rejection'
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := position('requested receipt amount' IN lower(SQLERRM)) > 0
                  OR position('canonical' IN lower(SQLERRM)) > 0;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: customer-FX writer did not reject reuse of the fully consumed line through its pre-split canonical guard.';
  END IF;

  SELECT count(*)::integer
    INTO v_count_after
  FROM public.dva_reconciliation dr
  WHERE dr.dva_statement_line_id = v_line_2;

  IF v_count_after <> v_count_before THEN
    RAISE EXCEPTION 'FAIL: rejected customer-FX attempt changed reconciliation count from % to %.', v_count_before, v_count_after;
  END IF;
END
$regression$;

SELECT
  'PASS'::text AS regression_result,
  'Frozen authorities unchanged; compatibility summary and canonical position agree at zero remaining for both live funding+FX lines; final-balance, retailer-refund and customer-FX reuse attempts fail without residue.'::text AS details;

ROLLBACK;
