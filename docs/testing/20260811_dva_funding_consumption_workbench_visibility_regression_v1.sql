BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE _dva_funding_consumption_regression_result (
  regression_result text NOT NULL,
  details text NOT NULL
) ON COMMIT DROP;

DO $regression$
DECLARE
  r record;
  v_actual text;
  v_view_def text;
  v_reconstructed_view_def text;
  v_function_def text;
  v_expected_columns text[];
  v_actual_columns text[];
  v_start_anchor text;
  v_end_anchor text;
  v_anchor_pos integer;
  v_expr_start integer;
  v_alias_rel integer;
  v_expr_end integer;
  v_order_funding_hits integer;

  v_line_1 uuid := '28acc326-dd04-4ea8-b2b4-4d429e8ec5b7'::uuid;
  v_line_2 uuid := '0791dd47-43b3-4c16-bcb3-185d5de964da'::uuid;
  v_order_id uuid;
  v_line_importer_id uuid;

  v_staff_id uuid;
  v_staff_auth_uid uuid;
  v_reject_dispute_id uuid;

  v_final_order_id uuid;
  v_final_importer_id uuid;
  v_final_amount numeric;

  v_refund_dispute_id uuid;
  v_refund_importer_id uuid;

  v_fx_order_id uuid;
  v_fx_importer_id uuid;
  v_fx_gap numeric;

  v_block_reasons text[] := ARRAY[]::text[];

  v_compat_remaining numeric;
  v_compat_balanced boolean;
  v_canonical_remaining numeric;
  v_canonical_over numeric;
  v_consumed numeric;
  v_statement numeric;
  v_principal_count integer;

  v_count_before integer;
  v_count_after integer;
  v_alloc_count_before integer;
  v_alloc_count_after integer;
  v_rejected boolean;

  v_candidate_amount numeric;
  v_statement_id uuid;
  v_test_line_id uuid;
  v_result jsonb;
  v_credit_before numeric;
  v_credit_after numeric;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Frozen authorities must remain exactly as audited before any exercise.
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
  -- 2. Compatibility view: exact 33-column contract plus exact reconstruction
  --    of the audited pre-change definition after removing only the three
  --    authorised order-funding expression additions.
  -- -------------------------------------------------------------------------
  v_expected_columns := ARRAY[
    'dva_statement_line_id','dva_statement_id','importer_id','statement_date',
    'reference_raw','direction','amount_local_ccy','local_ccy','fx_rate_applied',
    'card_markup_pct_applied','statement_gbp_amount','auth_id_ref','retailer_name_ref',
    'match_status','confirmed_allocated_gbp','open_allocated_gbp',
    'supplier_invoice_allocated_gbp','retailer_refund_allocated_gbp',
    'fx_card_or_fee_allocated_gbp','exception_or_hold_allocated_gbp',
    'active_allocation_count','confirmed_unallocated_gbp','confirmed_balanced_yn',
    'final_balance_payment_allocated_gbp','statement_account_context',
    'statement_account_label','source_bank','loyalty_credit_funding_allocated_gbp',
    'main_bank_loyalty_match_count','control_match_reason',
    'loyalty_internal_transfer_out_gbp','loyalty_internal_transfer_in_gbp',
    'loyalty_internal_transfer_in_count'
  ];

  SELECT array_agg(c.column_name::text ORDER BY c.ordinal_position)
    INTO v_actual_columns
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'dva_statement_line_allocation_summary_vw';

  IF v_actual_columns IS DISTINCT FROM v_expected_columns THEN
    RAISE EXCEPTION 'FAIL: compatibility view column contract changed. expected %, actual %.', v_expected_columns, v_actual_columns;
  END IF;

  SELECT pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)
    INTO v_view_def;

  v_order_funding_hits :=
    (length(lower(v_view_def)) - length(replace(lower(v_view_def), 'order_funding', '')))
    / length('order_funding');

  IF v_order_funding_hits <> 3 THEN
    RAISE EXCEPTION 'FAIL: compatibility view must contain exactly three authorised order_funding additions; found %.', v_order_funding_hits;
  END IF;

  v_reconstructed_view_def := v_view_def;

  -- confirmed_allocated_gbp: replace the entire post-migration target expression,
  -- including any deparser-added parentheses, with the exact audited old target.
  v_start_anchor := 'base.match_status,';
  v_anchor_pos := position(v_start_anchor IN v_reconstructed_view_def);
  IF v_anchor_pos = 0 THEN
    RAISE EXCEPTION 'FAIL: reconstruction anchor missing before confirmed_allocated_gbp.';
  END IF;
  v_expr_start := v_anchor_pos + length(v_start_anchor);
  WHILE substring(v_reconstructed_view_def FROM v_expr_start FOR 1) ~ '[[:space:]]' LOOP
    v_expr_start := v_expr_start + 1;
  END LOOP;
  v_end_anchor := ' AS confirmed_allocated_gbp';
  v_alias_rel := position(v_end_anchor IN substring(v_reconstructed_view_def FROM v_expr_start));
  IF v_alias_rel = 0 THEN
    RAISE EXCEPTION 'FAIL: reconstruction alias missing for confirmed_allocated_gbp.';
  END IF;
  v_expr_end := v_expr_start + v_alias_rel - 1 + length(v_end_anchor) - 1;
  v_reconstructed_view_def :=
    substring(v_reconstructed_view_def FROM 1 FOR v_expr_start - 1)
    || 'base.normal_confirmed_allocated_gbp + base.loyalty_credit_funding_allocated_gbp AS confirmed_allocated_gbp'
    || substring(v_reconstructed_view_def FROM v_expr_end + 1);

  -- confirmed_unallocated_gbp.
  v_start_anchor := 'base.active_allocation_count,';
  v_anchor_pos := position(v_start_anchor IN v_reconstructed_view_def);
  IF v_anchor_pos = 0 THEN
    RAISE EXCEPTION 'FAIL: reconstruction anchor missing before confirmed_unallocated_gbp.';
  END IF;
  v_expr_start := v_anchor_pos + length(v_start_anchor);
  WHILE substring(v_reconstructed_view_def FROM v_expr_start FOR 1) ~ '[[:space:]]' LOOP
    v_expr_start := v_expr_start + 1;
  END LOOP;
  v_end_anchor := ' AS confirmed_unallocated_gbp';
  v_alias_rel := position(v_end_anchor IN substring(v_reconstructed_view_def FROM v_expr_start));
  IF v_alias_rel = 0 THEN
    RAISE EXCEPTION 'FAIL: reconstruction alias missing for confirmed_unallocated_gbp.';
  END IF;
  v_expr_end := v_expr_start + v_alias_rel - 1 + length(v_end_anchor) - 1;
  v_reconstructed_view_def :=
    substring(v_reconstructed_view_def FROM 1 FOR v_expr_start - 1)
    || 'base.statement_gbp_amount - base.normal_confirmed_allocated_gbp - base.loyalty_credit_funding_allocated_gbp AS confirmed_unallocated_gbp'
    || substring(v_reconstructed_view_def FROM v_expr_end + 1);

  -- confirmed_balanced_yn.
  v_start_anchor := 'AS confirmed_unallocated_gbp,';
  v_anchor_pos := position(v_start_anchor IN v_reconstructed_view_def);
  IF v_anchor_pos = 0 THEN
    RAISE EXCEPTION 'FAIL: reconstruction anchor missing before confirmed_balanced_yn.';
  END IF;
  v_expr_start := v_anchor_pos + length(v_start_anchor);
  WHILE substring(v_reconstructed_view_def FROM v_expr_start FOR 1) ~ '[[:space:]]' LOOP
    v_expr_start := v_expr_start + 1;
  END LOOP;
  v_end_anchor := ' AS confirmed_balanced_yn';
  v_alias_rel := position(v_end_anchor IN substring(v_reconstructed_view_def FROM v_expr_start));
  IF v_alias_rel = 0 THEN
    RAISE EXCEPTION 'FAIL: reconstruction alias missing for confirmed_balanced_yn.';
  END IF;
  v_expr_end := v_expr_start + v_alias_rel - 1 + length(v_end_anchor) - 1;
  v_reconstructed_view_def :=
    substring(v_reconstructed_view_def FROM 1 FOR v_expr_start - 1)
    || 'abs(base.statement_gbp_amount - base.normal_confirmed_allocated_gbp - base.loyalty_credit_funding_allocated_gbp) < 0.01 AS confirmed_balanced_yn'
    || substring(v_reconstructed_view_def FROM v_expr_end + 1);

  IF md5(v_reconstructed_view_def) IS DISTINCT FROM '1219ed77fd0db05f59624e508fc64357' THEN
    RAISE EXCEPTION 'FAIL: removing only the three authorised order-funding additions does not reconstruct the exact audited compatibility view. reconstructed md5 %.', md5(v_reconstructed_view_def);
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Known live funding+FX fixtures must be fully consumed in both models.
  -- -------------------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_line_1)
     OR NOT EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_line_2) THEN
    INSERT INTO pg_temp._dva_funding_consumption_regression_result(regression_result, details)
    VALUES ('BLOCKED_PREREQUISITE', 'Known audited £726.40/£20.18 statement-line fixtures are not both present. No behavioural exercises were run.');
    RETURN;
  END IF;

  FOR r IN
    SELECT * FROM (VALUES (v_line_1), (v_line_2)) AS x(line_id)
  LOOP
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
      p.overconsumed_gbp,
      p.principal_lane_count
    INTO
      v_consumed,
      v_canonical_remaining,
      v_canonical_over,
      v_principal_count
    FROM public.statement_line_control_position_v1 p
    WHERE p.statement_line_id = r.line_id;

    IF v_statement IS NULL
       OR ABS(COALESCE(v_compat_remaining, 999999)) > 0.005
       OR COALESCE(v_compat_balanced, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: compatibility line % is not balanced. statement %, remaining %, balanced %.', r.line_id, v_statement, v_compat_remaining, v_compat_balanced;
    END IF;

    IF ABS(COALESCE(v_canonical_remaining, 999999)) > 0.005
       OR ABS(COALESCE(v_canonical_over, 999999)) > 0.005
       OR ABS(COALESCE(v_consumed, 0) - COALESCE(v_statement, 0)) > 0.005
       OR COALESCE(v_principal_count, 0) > 1 THEN
      RAISE EXCEPTION 'FAIL: canonical line % disagrees with physical amount. statement %, consumed %, remaining %, over %, principal lanes %.',
        r.line_id, v_statement, v_consumed, v_canonical_remaining, v_canonical_over, v_principal_count;
    END IF;
  END LOOP;

  SELECT dr.order_id
    INTO v_order_id
  FROM public.dva_reconciliation dr
  WHERE dr.dva_statement_line_id = v_line_2
    AND dr.reconciliation_type::text = 'order_funding'
  ORDER BY dr.reconciled_at, dr.id
  LIMIT 1;

  SELECT ds.importer_id
    INTO v_line_importer_id
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = v_line_2;

  IF v_order_id IS NULL OR v_line_importer_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: known £20.18 line lost its audited order-funding/importer linkage.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Changed-writer source contract. In particular, the existing retailer
  --    refund +0.01 tolerance is explicitly frozen by the governing addendum.
  -- -------------------------------------------------------------------------
  SELECT lower(pg_get_functiondef('public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('remaining_unconsumed_gbp' IN v_function_def) = 0
     OR position('overconsumed_gbp' IN v_function_def) = 0
     OR position('principal_lane_count' IN v_function_def) = 0
     OR position('internal_order_final_sale_settlement_v2' IN v_function_def) = 0
     OR position('final_balance_allocation_id' IN v_function_def) = 0
     OR position('needs_residual_classification_yn' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: final-balance writer lost its existing result/settlement contract or canonical guard.';
  END IF;

  SELECT lower(pg_get_functiondef('public.staff_allocate_statement_line_to_dispute_or_hold(uuid,character varying,uuid,numeric,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('retailer_refund' IN v_function_def) = 0
     OR position('exception_hold' IN v_function_def) = 0
     OR position('not_charged_closure' IN v_function_def) = 0
     OR position('unmatched_hold' IN v_function_def) = 0
     OR position('principal_lane_count' IN v_function_def) = 0
     OR position('confirmed_unallocated_before_gbp' IN v_function_def) = 0
     OR position('confirmed_unallocated_after_gbp' IN v_function_def) = 0
     OR position('v_amount > v_unallocated_before + 0.01' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: dispute/hold writer lost an existing branch/result field, canonical retailer-refund guard, or frozen +0.01 tolerance.';
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
  -- 5. READ-ONLY prerequisite discovery for every subsequent writer exercise.
  --    Nothing below this point runs unless all required eligible targets exist.
  -- -------------------------------------------------------------------------
  SELECT s.id, s.auth_user_id
    INTO v_staff_id, v_staff_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin', 'supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.id
  LIMIT 1;

  IF v_staff_auth_uid IS NULL OR v_staff_id IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'no active admin/supervisor auth user');
  END IF;

  SELECT d.id
    INTO v_reject_dispute_id
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  WHERE o.importer_id = v_line_importer_id
    AND o.status NOT IN ('archived', 'cancelled')
  ORDER BY d.raised_at DESC NULLS LAST, d.id
  LIMIT 1;

  IF v_reject_dispute_id IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'no dispute for the known £20.18 line importer to exercise refund rejection');
  END IF;

  SELECT s.order_id, s.importer_id,
         ROUND(LEAST(s.final_balance_due_gbp, 1.00)::numeric, 2)
    INTO v_final_order_id, v_final_importer_id, v_final_amount
  FROM public.internal_order_final_sale_settlement_v2(NULL) s
  JOIN public.orders o ON o.id = s.order_id
  WHERE s.importer_id IS NOT NULL
    AND COALESCE(s.final_sale_value_exists, false) = true
    AND COALESCE(s.customer_sales_state, '') <> 'partial_posted'
    AND COALESCE(s.final_balance_due_gbp, 0) > 0.01
    AND o.status NOT IN ('archived', 'cancelled')
  ORDER BY s.final_balance_due_gbp, s.order_id
  LIMIT 1;

  IF v_final_order_id IS NULL OR COALESCE(v_final_amount, 0) <= 0 THEN
    v_block_reasons := array_append(v_block_reasons, 'no eligible final-balance-due order');
  END IF;

  SELECT d.id, o.importer_id
    INTO v_refund_dispute_id, v_refund_importer_id
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  WHERE o.importer_id IS NOT NULL
    AND o.status NOT IN ('archived', 'cancelled')
  ORDER BY d.raised_at DESC NULLS LAST, d.id
  LIMIT 1;

  IF v_refund_dispute_id IS NULL OR v_refund_importer_id IS NULL THEN
    v_block_reasons := array_append(v_block_reasons, 'no eligible dispute for retailer-refund success path');
  END IF;

  SELECT o.id, o.importer_id, ROUND(public.order_funding_gap_gbp(o.id)::numeric, 2)
    INTO v_fx_order_id, v_fx_importer_id, v_fx_gap
  FROM public.orders o
  WHERE o.importer_id IS NOT NULL
    AND COALESCE(o.order_type, 'original') = 'original'
    AND o.status NOT IN ('archived', 'cancelled')
    AND ROUND(COALESCE(public.order_funding_gap_gbp(o.id), 0)::numeric, 2) > 0.01
  ORDER BY public.order_funding_gap_gbp(o.id), o.id
  LIMIT 1;

  IF v_fx_order_id IS NULL OR v_fx_importer_id IS NULL OR COALESCE(v_fx_gap, 0) <= 0.01 THEN
    v_block_reasons := array_append(v_block_reasons, 'no eligible original order with a positive funding gap');
  END IF;

  IF cardinality(v_block_reasons) > 0 THEN
    INSERT INTO pg_temp._dva_funding_consumption_regression_result(regression_result, details)
    VALUES (
      'BLOCKED_PREREQUISITE',
      'Read-only prerequisite discovery blocked behavioural regression: ' || array_to_string(v_block_reasons, '; ') || '. No writer exercise was run.'
    );
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_staff_auth_uid::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_staff_auth_uid::text, 'role', 'authenticated')::text,
    true
  );

  IF auth.uid() IS DISTINCT FROM v_staff_auth_uid THEN
    RAISE EXCEPTION 'FAIL: unable to establish active staff auth context.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 6. Known fully-consumed line: all three reuse routes must reject and leave
  --    no surviving economic-use row.
  -- -------------------------------------------------------------------------
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
    RAISE EXCEPTION 'FAIL: final-balance writer did not reject the fully consumed funding line.';
  END IF;

  SELECT count(*)::integer
    INTO v_count_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_line_2
    AND a.allocation_status <> 'reversed';

  IF v_count_after <> v_count_before THEN
    RAISE EXCEPTION 'FAIL: rejected final-balance attempt changed active allocation count from % to %.', v_count_before, v_count_after;
  END IF;

  SELECT count(*)::integer
    INTO v_count_before
  FROM public.dva_reconciliation dr
  WHERE dr.dva_statement_line_id = v_line_2;
  SELECT count(*)::integer
    INTO v_alloc_count_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_line_2
    AND a.allocation_status <> 'reversed';

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
    RAISE EXCEPTION 'FAIL: customer-FX writer did not reject reuse of the fully consumed line.';
  END IF;

  SELECT count(*)::integer
    INTO v_count_after
  FROM public.dva_reconciliation dr
  WHERE dr.dva_statement_line_id = v_line_2;
  SELECT count(*)::integer
    INTO v_alloc_count_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_line_2
    AND a.allocation_status <> 'reversed';

  IF v_count_after <> v_count_before OR v_alloc_count_after <> v_alloc_count_before THEN
    RAISE EXCEPTION 'FAIL: rejected customer-FX attempt left residue. reconciliation %->%, allocations %->%.',
      v_count_before, v_count_after, v_alloc_count_before, v_alloc_count_after;
  END IF;

  SELECT count(*)::integer
    INTO v_count_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_line_2
    AND a.allocation_status <> 'reversed';

  v_rejected := false;
  BEGIN
    PERFORM public.staff_allocate_statement_line_to_dispute_or_hold(
      v_line_2,
      'retailer_refund',
      v_reject_dispute_id,
      0.01,
      '[REGRESSION_ONLY] canonical fully-consumed retailer-refund rejection'
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := position('no canonical remaining amount' IN lower(SQLERRM)) > 0
                  OR position('canonical' IN lower(SQLERRM)) > 0;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: retailer-refund writer did not reject the fully consumed funding line.';
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
  -- 7. VALID FINAL-BALANCE PATH. Fresh statement evidence only; all writes are
  --    rolled back by the nested subtransaction after assertions.
  -- -------------------------------------------------------------------------
  v_statement_id := gen_random_uuid();
  v_test_line_id := gen_random_uuid();

  BEGIN
    INSERT INTO public.dva_statements(
      id, importer_id, statement_account_context, statement_account_key,
      statement_account_label, source_bank, uploaded_by_staff_id, csv_url,
      statement_period_from, statement_period_to, parse_status
    ) VALUES (
      v_statement_id, v_final_importer_id, 'importer_dva_card_account',
      v_final_importer_id::text, 'Rollback final-balance success path', 'regression',
      v_staff_id, 'regression://dva-final-balance-' || v_statement_id::text,
      CURRENT_DATE, CURRENT_DATE, 'parsed'
    );

    INSERT INTO public.dva_statement_lines(
      id, dva_statement_id, line_order, statement_date, reference_raw, direction,
      amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied,
      amount_gbp_equivalent, auth_id_ref, retailer_name_ref, match_status
    ) VALUES (
      v_test_line_id, v_statement_id, 1, CURRENT_DATE, 'ROLLBACK valid final balance IN', 'in',
      v_final_amount, 'GBP', 1, 0, v_final_amount,
      'REG-FINAL-' || left(v_test_line_id::text, 8), 'Regression only', 'unmatched'
    );

    SELECT public.staff_allocate_statement_line_to_final_balance_payment_v1(
      v_test_line_id,
      v_final_order_id,
      false,
      '[REGRESSION_ONLY] valid final-balance path'
    ) INTO v_result;

    IF COALESCE((v_result ->> 'ok')::boolean, false) IS NOT TRUE
       OR ROUND(COALESCE((v_result ->> 'amount_to_final_balance_gbp')::numeric, 0), 2) <> v_final_amount
       OR ROUND(COALESCE((v_result ->> 'statement_remaining_before_gbp')::numeric, 0), 2) <> v_final_amount
       OR ABS(COALESCE((v_result ->> 'statement_remaining_after_gbp')::numeric, 999999)) > 0.005
       OR ABS(COALESCE((v_result ->> 'fx_excess_classified_gbp')::numeric, 0)) > 0.005 THEN
      RAISE EXCEPTION 'FAIL: valid final-balance result contract changed: %', v_result;
    END IF;

    SELECT p.active_consumed_gbp, p.remaining_unconsumed_gbp, p.overconsumed_gbp, p.principal_lane_count
      INTO v_consumed, v_canonical_remaining, v_canonical_over, v_principal_count
    FROM public.statement_line_control_position_v1 p
    WHERE p.statement_line_id = v_test_line_id;

    IF ABS(v_consumed - v_final_amount) > 0.005
       OR ABS(v_canonical_remaining) > 0.005
       OR ABS(v_canonical_over) > 0.005
       OR v_principal_count <> 1 THEN
      RAISE EXCEPTION 'FAIL: valid final-balance canonical position incorrect: consumed %, remaining %, over %, principal %.',
        v_consumed, v_canonical_remaining, v_canonical_over, v_principal_count;
    END IF;

    RAISE EXCEPTION 'REGRESSION_ROLLBACK_VALID_FINAL_BALANCE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'REGRESSION_ROLLBACK_VALID_FINAL_BALANCE' THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_test_line_id)
     OR EXISTS (SELECT 1 FROM public.dva_statements WHERE id = v_statement_id) THEN
    RAISE EXCEPTION 'FAIL: valid final-balance subtransaction left test evidence behind.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 8. VALID RETAILER-REFUND PATH. The existing +0.01 tolerance is not changed;
  --    this exercises a normal exact-amount refund only.
  -- -------------------------------------------------------------------------
  v_candidate_amount := 1.00;
  v_statement_id := gen_random_uuid();
  v_test_line_id := gen_random_uuid();

  BEGIN
    INSERT INTO public.dva_statements(
      id, importer_id, statement_account_context, statement_account_key,
      statement_account_label, source_bank, uploaded_by_staff_id, csv_url,
      statement_period_from, statement_period_to, parse_status
    ) VALUES (
      v_statement_id, v_refund_importer_id, 'importer_dva_card_account',
      v_refund_importer_id::text, 'Rollback retailer-refund success path', 'regression',
      v_staff_id, 'regression://dva-retailer-refund-' || v_statement_id::text,
      CURRENT_DATE, CURRENT_DATE, 'parsed'
    );

    INSERT INTO public.dva_statement_lines(
      id, dva_statement_id, line_order, statement_date, reference_raw, direction,
      amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied,
      amount_gbp_equivalent, auth_id_ref, retailer_name_ref, match_status
    ) VALUES (
      v_test_line_id, v_statement_id, 1, CURRENT_DATE, 'ROLLBACK valid retailer refund IN', 'in',
      v_candidate_amount, 'GBP', 1, 0, v_candidate_amount,
      'REG-REFUND-' || left(v_test_line_id::text, 8), 'Regression only', 'unmatched'
    );

    SELECT public.staff_allocate_statement_line_to_dispute_or_hold(
      v_test_line_id,
      'retailer_refund',
      v_refund_dispute_id,
      v_candidate_amount,
      '[REGRESSION_ONLY] valid retailer-refund path'
    ) INTO v_result;

    IF COALESCE((v_result ->> 'ok')::boolean, false) IS NOT TRUE
       OR v_result ->> 'allocation_type' IS DISTINCT FROM 'retailer_refund'
       OR ROUND(COALESCE((v_result ->> 'allocated_gbp_amount')::numeric, 0), 2) <> v_candidate_amount
       OR ROUND(COALESCE((v_result ->> 'confirmed_unallocated_before_gbp')::numeric, 0), 2) <> v_candidate_amount
       OR ABS(COALESCE((v_result ->> 'confirmed_unallocated_after_gbp')::numeric, 999999)) > 0.005 THEN
      RAISE EXCEPTION 'FAIL: valid retailer-refund result contract changed: %', v_result;
    END IF;

    SELECT p.active_consumed_gbp, p.remaining_unconsumed_gbp, p.overconsumed_gbp, p.principal_lane_count
      INTO v_consumed, v_canonical_remaining, v_canonical_over, v_principal_count
    FROM public.statement_line_control_position_v1 p
    WHERE p.statement_line_id = v_test_line_id;

    IF ABS(v_consumed - v_candidate_amount) > 0.005
       OR ABS(v_canonical_remaining) > 0.005
       OR ABS(v_canonical_over) > 0.005
       OR v_principal_count <> 1 THEN
      RAISE EXCEPTION 'FAIL: valid retailer-refund canonical position incorrect: consumed %, remaining %, over %, principal %.',
        v_consumed, v_canonical_remaining, v_canonical_over, v_principal_count;
    END IF;

    RAISE EXCEPTION 'REGRESSION_ROLLBACK_VALID_RETAILER_REFUND';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'REGRESSION_ROLLBACK_VALID_RETAILER_REFUND' THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_test_line_id)
     OR EXISTS (SELECT 1 FROM public.dva_statements WHERE id = v_statement_id) THEN
    RAISE EXCEPTION 'FAIL: valid retailer-refund subtransaction left test evidence behind.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 9. VALID CUSTOMER FUNDING + FX SPLIT. Fresh statement evidence, existing
  --    original order with a positive funding gap, immediate rollback afterwards.
  -- -------------------------------------------------------------------------
  v_candidate_amount := ROUND(v_fx_gap + 0.10, 2);
  v_statement_id := gen_random_uuid();
  v_test_line_id := gen_random_uuid();

  SELECT ROUND(COALESCE(SUM(CASE WHEN icl.direction = 'credit' THEN ABS(icl.amount_gbp) ELSE -ABS(icl.amount_gbp) END), 0)::numeric, 2)
    INTO v_credit_before
  FROM public.importer_credit_ledger icl
  WHERE icl.source_entity_type = 'order'
    AND icl.source_entity_id = v_fx_order_id;

  BEGIN
    INSERT INTO public.dva_statements(
      id, importer_id, statement_account_context, statement_account_key,
      statement_account_label, source_bank, uploaded_by_staff_id, csv_url,
      statement_period_from, statement_period_to, parse_status
    ) VALUES (
      v_statement_id, v_fx_importer_id, 'importer_dva_card_account',
      v_fx_importer_id::text, 'Rollback customer-FX success path', 'regression',
      v_staff_id, 'regression://dva-customer-fx-' || v_statement_id::text,
      CURRENT_DATE, CURRENT_DATE, 'parsed'
    );

    INSERT INTO public.dva_statement_lines(
      id, dva_statement_id, line_order, statement_date, reference_raw, direction,
      amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied,
      amount_gbp_equivalent, auth_id_ref, retailer_name_ref, match_status
    ) VALUES (
      v_test_line_id, v_statement_id, 1, CURRENT_DATE, 'ROLLBACK valid customer FX IN', 'in',
      v_candidate_amount, 'GBP', 1, 0, v_candidate_amount,
      'REG-FX-' || left(v_test_line_id::text, 8), 'Regression only', 'unmatched'
    );

    SELECT public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(
      v_test_line_id,
      v_fx_order_id,
      v_candidate_amount,
      NULL,
      '[REGRESSION_ONLY] valid customer funding + FX split'
    ) INTO v_result;

    IF COALESCE((v_result ->> 'customer_fx_gain_routed_yn')::boolean, false) IS NOT TRUE
       OR ROUND(COALESCE((v_result ->> 'funding_amount_gbp')::numeric, 0), 2) <> v_fx_gap
       OR ROUND(COALESCE((v_result ->> 'fx_gain_gbp')::numeric, 0), 2) <> 0.10
       OR COALESCE((v_result ->> 'credit_created_yn')::boolean, true) IS NOT FALSE
       OR ABS(
            ROUND(COALESCE((v_result ->> 'funding_amount_gbp')::numeric, 0), 2)
            + ROUND(COALESCE((v_result ->> 'fx_gain_gbp')::numeric, 0), 2)
            - v_candidate_amount
          ) > 0.005 THEN
      RAISE EXCEPTION 'FAIL: valid customer funding+FX result contract changed: %', v_result;
    END IF;

    IF (SELECT COUNT(*) FROM public.dva_reconciliation dr
        WHERE dr.dva_statement_line_id = v_test_line_id
          AND dr.reconciliation_type::text = 'order_funding'
          AND ABS(dr.reconciled_gbp_amount - v_fx_gap) <= 0.005) <> 1 THEN
      RAISE EXCEPTION 'FAIL: valid customer-FX split did not create exactly one expected funding reconciliation.';
    END IF;

    IF (SELECT COUNT(*) FROM public.dva_statement_line_allocations a
        WHERE a.dva_statement_line_id = v_test_line_id
          AND a.allocation_type = 'fx_card_difference'
          AND a.allocation_status = 'confirmed'
          AND ABS(a.allocated_gbp_amount - 0.10) <= 0.005) <> 1 THEN
      RAISE EXCEPTION 'FAIL: valid customer-FX split did not create exactly one £0.10 FX allocation.';
    END IF;

    SELECT ROUND(COALESCE(SUM(CASE WHEN icl.direction = 'credit' THEN ABS(icl.amount_gbp) ELSE -ABS(icl.amount_gbp) END), 0)::numeric, 2)
      INTO v_credit_after
    FROM public.importer_credit_ledger icl
    WHERE icl.source_entity_type = 'order'
      AND icl.source_entity_id = v_fx_order_id;

    IF v_credit_after IS DISTINCT FROM v_credit_before THEN
      RAISE EXCEPTION 'FAIL: valid customer-FX split changed importer credit from % to %.', v_credit_before, v_credit_after;
    END IF;

    SELECT p.active_consumed_gbp, p.remaining_unconsumed_gbp, p.overconsumed_gbp, p.principal_lane_count
      INTO v_consumed, v_canonical_remaining, v_canonical_over, v_principal_count
    FROM public.statement_line_control_position_v1 p
    WHERE p.statement_line_id = v_test_line_id;

    IF ABS(v_consumed - v_candidate_amount) > 0.005
       OR ABS(v_canonical_remaining) > 0.005
       OR ABS(v_canonical_over) > 0.005
       OR v_principal_count <> 1 THEN
      RAISE EXCEPTION 'FAIL: valid customer-FX canonical position incorrect: consumed %, remaining %, over %, principal %.',
        v_consumed, v_canonical_remaining, v_canonical_over, v_principal_count;
    END IF;

    RAISE EXCEPTION 'REGRESSION_ROLLBACK_VALID_CUSTOMER_FX';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM 'REGRESSION_ROLLBACK_VALID_CUSTOMER_FX' THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (SELECT 1 FROM public.dva_statement_lines WHERE id = v_test_line_id)
     OR EXISTS (SELECT 1 FROM public.dva_statements WHERE id = v_statement_id) THEN
    RAISE EXCEPTION 'FAIL: valid customer-FX subtransaction left test evidence behind.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 10. Frozen authorities must still be exact after every success exercise.
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
      RAISE EXCEPTION 'FAIL: frozen % changed after behavioural exercises. expected %, actual %.', r.object_name, r.expected_md5, v_actual;
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
      RAISE EXCEPTION 'FAIL: frozen trigger % changed after behavioural exercises. expected %, actual %.', r.trigger_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;

  INSERT INTO pg_temp._dva_funding_consumption_regression_result(regression_result, details)
  VALUES (
    'PASS',
    'Frozen authorities/triggers unchanged; exact 33-column compatibility contract preserved; removing only the three authorised order-funding expressions reconstructs the audited pre-change view fingerprint; both live funding+FX lines are fully consumed; invalid reuse is rejected; valid final-balance, retailer-refund and customer funding+FX paths execute and roll back without residue.'
  );
END
$regression$;

SELECT regression_result, details
FROM pg_temp._dva_funding_consumption_regression_result;

ROLLBACK;
