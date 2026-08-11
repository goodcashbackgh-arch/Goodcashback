BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- DVA statement-line canonical consumption alignment v1.
-- Governing authority:
-- docs/governing-pack/ui/DVA_FUNDING_CONSUMPTION_WORKBENCH_VISIBILITY_ADDENDUM_v1.md
--
-- Exact runtime scope only:
--   1. compatibility-summary aggregate calculation;
--   2. final-balance canonical amount guard;
--   3. retailer-refund/IN canonical amount guard;
--   4. customer-funding + FX split canonical amount guard.
--
-- No data repair. No generic trigger. No new table/column. No UI change.
-- No canonical-control, supplier, loyalty, shipper, Sage, VAT or funding rewrite.

DO $preflight$
DECLARE
  r record;
  v_actual text;
BEGIN
  FOR r IN
    SELECT *
    FROM (VALUES
      ('view', 'public.dva_statement_line_allocation_summary_vw', '1219ed77fd0db05f59624e508fc64357'),
      ('function', 'public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)', '6f369fcd2a64a67736d77bf97d55e4cc'),
      ('function', 'public.staff_allocate_statement_line_to_dispute_or_hold(uuid,character varying,uuid,numeric,text)', 'b90f7d7a2e6293a4c44acab6d08e649a'),
      ('function', 'public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)', '61c8d9289a8b42ff72e6e4d78aaabb96'),
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
      IF to_regclass(r.object_name) IS NULL THEN
        RAISE EXCEPTION 'Preflight failed: required view % is missing.', r.object_name;
      END IF;
      EXECUTE format('SELECT md5(pg_get_viewdef(%L::regclass, true))', r.object_name)
        INTO v_actual;
    ELSE
      IF to_regprocedure(r.object_name) IS NULL THEN
        RAISE EXCEPTION 'Preflight failed: required function % is missing.', r.object_name;
      END IF;
      EXECUTE format('SELECT md5(pg_get_functiondef(%L::regprocedure))', r.object_name)
        INTO v_actual;
    END IF;

    IF v_actual IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION 'Preflight failed: % fingerprint changed. expected %, actual %.', r.object_name, r.expected_md5, v_actual;
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

    IF v_actual IS NULL THEN
      RAISE EXCEPTION 'Preflight failed: required trigger % is missing.', r.trigger_name;
    END IF;
    IF v_actual IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION 'Preflight failed: trigger % fingerprint changed. expected %, actual %.', r.trigger_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;
END
$preflight$;

-- ---------------------------------------------------------------------------
-- 1. Compatibility view: only three existing aggregate availability fields.
-- ---------------------------------------------------------------------------
DO $patch_view$
DECLARE
  v_def text;
  v_patched text;
  v_old text;
  v_new text;
  v_hits integer;
BEGIN
  SELECT pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)
    INTO v_def;
  v_patched := v_def;

  v_old := 'base.normal_confirmed_allocated_gbp + base.loyalty_credit_funding_allocated_gbp AS confirmed_allocated_gbp';
  v_new := 'base.normal_confirmed_allocated_gbp + base.loyalty_credit_funding_allocated_gbp + COALESCE((SELECT sum(abs(dr.reconciled_gbp_amount)) FROM public.dva_reconciliation dr WHERE dr.dva_statement_line_id = base.dva_statement_line_id AND dr.reconciliation_type::text = ''order_funding''::text), 0::numeric) AS confirmed_allocated_gbp';
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Compatibility-view patch anchor count invalid for confirmed_allocated_gbp: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, v_new);

  v_old := 'base.statement_gbp_amount - base.normal_confirmed_allocated_gbp - base.loyalty_credit_funding_allocated_gbp AS confirmed_unallocated_gbp';
  v_new := 'base.statement_gbp_amount - base.normal_confirmed_allocated_gbp - base.loyalty_credit_funding_allocated_gbp - COALESCE((SELECT sum(abs(dr.reconciled_gbp_amount)) FROM public.dva_reconciliation dr WHERE dr.dva_statement_line_id = base.dva_statement_line_id AND dr.reconciliation_type::text = ''order_funding''::text), 0::numeric) AS confirmed_unallocated_gbp';
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Compatibility-view patch anchor count invalid for confirmed_unallocated_gbp: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, v_new);

  v_old := 'abs(base.statement_gbp_amount - base.normal_confirmed_allocated_gbp - base.loyalty_credit_funding_allocated_gbp) < 0.01 AS confirmed_balanced_yn';
  v_new := 'abs(base.statement_gbp_amount - base.normal_confirmed_allocated_gbp - base.loyalty_credit_funding_allocated_gbp - COALESCE((SELECT sum(abs(dr.reconciled_gbp_amount)) FROM public.dva_reconciliation dr WHERE dr.dva_statement_line_id = base.dva_statement_line_id AND dr.reconciliation_type::text = ''order_funding''::text), 0::numeric)) < 0.01 AS confirmed_balanced_yn';
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Compatibility-view patch anchor count invalid for confirmed_balanced_yn: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, v_new);

  EXECUTE 'CREATE OR REPLACE VIEW public.dva_statement_line_allocation_summary_vw AS ' || v_patched;
END
$patch_view$;

-- ---------------------------------------------------------------------------
-- 2. Final-balance writer: canonical amount guard only.
-- ---------------------------------------------------------------------------
DO $patch_final_balance$
DECLARE
  v_reg regprocedure := 'public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)'::regprocedure;
  v_def text;
  v_patched text;
  v_old text;
  v_new text;
  v_hits integer;
BEGIN
  SELECT pg_get_functiondef(v_reg) INTO v_def;
  v_patched := v_def;

  v_old := '  v_settlement record;';
  v_new := '  v_settlement record;' || E'\n' || '  v_statement_control record;';
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Final-balance declaration anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, v_new);

  v_old := '  v_line_remaining_before := ROUND((v_line.amount_gbp_equivalent - v_confirmed_before)::numeric, 2);';
  v_new := $guard$
  SELECT p.* INTO v_statement_control
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_statement_control.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Canonical statement-line control position is missing for %', p_dva_statement_line_id;
  END IF;
  IF COALESCE(v_statement_control.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % is already over-consumed by %', p_dva_statement_line_id, v_statement_control.overconsumed_gbp;
  END IF;

  v_line_remaining_before := ROUND(COALESCE(v_statement_control.remaining_unconsumed_gbp, 0)::numeric, 2);
$guard$;
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Final-balance remaining anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, rtrim(v_new, E'\n'));

  v_old := '  v_line_remaining_after := ROUND((v_line.amount_gbp_equivalent - v_confirmed_after)::numeric, 2);';
  v_new := $postcheck$
  v_line_remaining_after := ROUND((v_line.amount_gbp_equivalent - v_confirmed_after)::numeric, 2);

  SELECT p.* INTO v_statement_control
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_statement_control.statement_line_id IS NULL
     OR COALESCE(v_statement_control.overconsumed_gbp, 0) > 0.005
     OR COALESCE(v_statement_control.principal_lane_count, 0) > 1 THEN
    RAISE EXCEPTION 'Final-balance allocation violates canonical statement-line control for %', p_dva_statement_line_id;
  END IF;
$postcheck$;
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Final-balance postcondition anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, rtrim(v_new, E'\n'));

  EXECUTE v_patched;
END
$patch_final_balance$;

-- ---------------------------------------------------------------------------
-- 3. Operational writer: retailer_refund / IN branch only.
--    OUT exception/hold branches retain their existing amount calculation.
-- ---------------------------------------------------------------------------
DO $patch_retailer_refund$
DECLARE
  v_reg regprocedure := 'public.staff_allocate_statement_line_to_dispute_or_hold(uuid,character varying,uuid,numeric,text)'::regprocedure;
  v_def text;
  v_patched text;
  v_old text;
  v_new text;
  v_hits integer;
BEGIN
  SELECT pg_get_functiondef(v_reg) INTO v_def;
  v_patched := v_def;

  v_old := '  v_order record;';
  v_new := '  v_order record;' || E'\n' || '  v_statement_control record;';
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Retailer-refund declaration anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, v_new);

  -- Single-line anchor only. Canonical guard is inserted at the exact point where
  -- the existing function derives its available amount. OUT branches retain the
  -- original allocation-table calculation unchanged.
  v_old := '  v_unallocated_before := round(v_line.amount_gbp_equivalent::numeric - v_existing_confirmed_total, 2);';
  v_new := $remaining$
  if p_allocation_type = 'retailer_refund' then
    select p.* into v_statement_control
    from public.statement_line_control_position_v1 p
    where p.statement_line_id = p_dva_statement_line_id;

    if v_statement_control.statement_line_id is null then
      raise exception 'Canonical statement-line control position is missing for %', p_dva_statement_line_id;
    end if;
    if coalesce(v_statement_control.overconsumed_gbp, 0) > 0.005 then
      raise exception 'Statement line % is already over-consumed by %', p_dva_statement_line_id, v_statement_control.overconsumed_gbp;
    end if;
    if coalesce(v_statement_control.remaining_unconsumed_gbp, 0) <= 0.005 then
      raise exception 'Statement line % has no canonical remaining amount available for retailer refund allocation', p_dva_statement_line_id;
    end if;

    v_unallocated_before := round(coalesce(v_statement_control.remaining_unconsumed_gbp, 0)::numeric, 2);
  else
    v_unallocated_before := round(v_line.amount_gbp_equivalent::numeric - v_existing_confirmed_total, 2);
  end if;
$remaining$;
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Retailer-refund remaining anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, rtrim(v_new, E'\n'));

  v_old := '  v_unallocated_after := round(v_line.amount_gbp_equivalent::numeric - v_confirmed_total_after, 2);';
  v_new := $postcheck$
  v_unallocated_after := round(v_line.amount_gbp_equivalent::numeric - v_confirmed_total_after, 2);

  if p_allocation_type = 'retailer_refund' then
    select p.* into v_statement_control
    from public.statement_line_control_position_v1 p
    where p.statement_line_id = p_dva_statement_line_id;

    if v_statement_control.statement_line_id is null
       or coalesce(v_statement_control.overconsumed_gbp, 0) > 0.005
       or coalesce(v_statement_control.principal_lane_count, 0) > 1 then
      raise exception 'Retailer refund allocation violates canonical statement-line control for %', p_dva_statement_line_id;
    end if;
  end if;
$postcheck$;
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Retailer-refund postcondition anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, rtrim(v_new, E'\n'));

  EXECUTE v_patched;
END
$patch_retailer_refund$;

-- ---------------------------------------------------------------------------
-- 4. Customer funding + FX split: canonical pre-split, residual and post guards.
-- ---------------------------------------------------------------------------
DO $patch_customer_fx$
DECLARE
  v_reg regprocedure := 'public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)'::regprocedure;
  v_def text;
  v_patched text;
  v_old text;
  v_new text;
  v_hits integer;
BEGIN
  SELECT pg_get_functiondef(v_reg) INTO v_def;
  v_patched := v_def;

  v_old := '  v_order record;';
  v_new := '  v_order record;' || E'\n' || '  v_statement_control record;';
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Customer-FX declaration anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, v_new);

  -- Single-line anchor immediately before the existing funding-gap split.
  v_old := '  v_gap_before := ROUND(COALESCE(public.order_funding_gap_gbp(p_order_id), 0)::numeric, 2);';
  v_new := $guard$
  SELECT p.* INTO v_statement_control
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_statement_control.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Canonical statement-line control position is missing for %', p_dva_statement_line_id;
  END IF;
  IF COALESCE(v_statement_control.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % is already over-consumed by %', p_dva_statement_line_id, v_statement_control.overconsumed_gbp;
  END IF;
  IF v_requested_amount > COALESCE(v_statement_control.remaining_unconsumed_gbp, 0) + 0.005 THEN
    RAISE EXCEPTION 'Requested receipt amount % exceeds canonical statement-line remaining amount %', v_requested_amount, v_statement_control.remaining_unconsumed_gbp;
  END IF;

  v_gap_before := ROUND(COALESCE(public.order_funding_gap_gbp(p_order_id), 0)::numeric, 2);
$guard$;
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Customer-FX funding-gap anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, rtrim(v_new, E'\n'));

  v_old := '  INSERT INTO public.dva_statement_line_allocations (';
  v_new := $residual$
  SELECT p.* INTO v_statement_control
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_statement_control.statement_line_id IS NULL
     OR COALESCE(v_statement_control.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Canonical statement-line control is invalid after order funding for %', p_dva_statement_line_id;
  END IF;
  IF v_fx_gain_amount > COALESCE(v_statement_control.remaining_unconsumed_gbp, 0) + 0.005 THEN
    RAISE EXCEPTION 'FX residual % exceeds canonical post-funding remaining amount %', v_fx_gain_amount, v_statement_control.remaining_unconsumed_gbp;
  END IF;

  INSERT INTO public.dva_statement_line_allocations (
$residual$;
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Customer-FX allocation anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, rtrim(v_new, E'\n'));

  v_old := '  RETURN v_result || jsonb_build_object(';
  v_new := $postcheck$
  SELECT p.* INTO v_statement_control
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_statement_control.statement_line_id IS NULL
     OR COALESCE(v_statement_control.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Customer funding/FX split violates canonical statement-line control for %', p_dva_statement_line_id;
  END IF;

  RETURN v_result || jsonb_build_object(
$postcheck$;
  v_hits := (length(v_patched) - length(replace(v_patched, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Customer-FX postcondition anchor count invalid: %.', v_hits;
  END IF;
  v_patched := replace(v_patched, v_old, rtrim(v_new, E'\n'));

  EXECUTE v_patched;
END
$patch_customer_fx$;

-- ---------------------------------------------------------------------------
-- Postflight: every frozen authority must remain definition-stable.
-- ---------------------------------------------------------------------------
DO $postflight$
DECLARE
  r record;
  v_actual text;
  v_view_def text;
  v_function_def text;
BEGIN
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
      RAISE EXCEPTION 'Postflight failed: frozen % changed. expected %, actual %.', r.object_name, r.expected_md5, v_actual;
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
      RAISE EXCEPTION 'Postflight failed: frozen trigger % changed. expected %, actual %.', r.trigger_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;

  SELECT lower(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true))
    INTO v_view_def;

  IF position('dva_reconciliation' IN v_view_def) = 0
     OR position('order_funding' IN v_view_def) = 0
     OR position('loyalty_internal_transfer_out_gbp' IN v_view_def) = 0
     OR position('loyalty_internal_transfer_in_gbp' IN v_view_def) = 0
     OR position('loyalty_internal_transfer_in_count' IN v_view_def) = 0
     OR position('dva_statement_line_import_links' IN v_view_def) = 0 THEN
    RAISE EXCEPTION 'Postflight failed: compatibility view lost a governed calculation or preservation seam.';
  END IF;

  SELECT lower(pg_get_functiondef('public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('remaining_unconsumed_gbp' IN v_function_def) = 0
     OR position('overconsumed_gbp' IN v_function_def) = 0
     OR position('principal_lane_count' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'Postflight failed: final-balance canonical guard missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.staff_allocate_statement_line_to_dispute_or_hold(uuid,character varying,uuid,numeric,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('retailer_refund' IN v_function_def) = 0
     OR position('exception_hold' IN v_function_def) = 0
     OR position('not_charged_closure' IN v_function_def) = 0
     OR position('unmatched_hold' IN v_function_def) = 0
     OR position('principal_lane_count' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'Postflight failed: retailer-refund canonical guard or frozen OUT branch missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)'::regprocedure))
    INTO v_function_def;
  IF position('statement_line_control_position_v1' IN v_function_def) = 0
     OR position('staff_reconcile_dva_line_to_order(' IN v_function_def) = 0
     OR position('requested receipt amount' IN v_function_def) = 0
     OR position('canonical post-funding remaining amount' IN v_function_def) = 0
     OR position('credit_created_yn' IN v_function_def) = 0 THEN
    RAISE EXCEPTION 'Postflight failed: customer-FX canonical split guard or existing contract missing.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';
COMMIT;
