BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final-balance IN FX residual classification v1.
-- Governing authority:
-- docs/governing-pack/accounting/FINAL_BALANCE_IN_FX_RESIDUAL_CLASSIFICATION_AMENDMENT_v1.md
--
-- Additive-only sibling writer. No existing treasury function/view is replaced.

DO $preflight$
DECLARE
  r record;
  v_actual text;
  v_existing_comment text;
BEGIN
  FOR r IN
    SELECT *
    FROM (VALUES
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
      ('view', 'public.statement_line_control_usage_v1', '581d367a31ab0f689f3d31b46df5922e')
    ) AS x(object_type, object_name, expected_md5)
  LOOP
    IF r.object_type = 'view' THEN
      IF to_regclass(r.object_name) IS NULL THEN
        RAISE EXCEPTION 'PRECHECK: frozen view missing: %', r.object_name;
      END IF;
      EXECUTE format('SELECT md5(pg_get_viewdef(%L::regclass, true))', r.object_name)
        INTO v_actual;
    ELSE
      IF to_regprocedure(r.object_name) IS NULL THEN
        RAISE EXCEPTION 'PRECHECK: frozen function missing: %', r.object_name;
      END IF;
      EXECUTE format('SELECT md5(pg_get_functiondef(%L::regprocedure))', r.object_name)
        INTO v_actual;
    END IF;

    IF v_actual IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION 'PRECHECK: frozen % changed. expected %, actual %',
        r.object_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;

  IF to_regclass('public.staff') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.dva_statements') IS NULL
     OR to_regclass('public.dva_statement_lines') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'PRECHECK: required treasury tables are missing';
  END IF;

  IF to_regprocedure('public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)') IS NOT NULL THEN
    SELECT obj_description(
      'public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)'::regprocedure,
      'pg_proc'
    ) INTO v_existing_comment;

    IF COALESCE(v_existing_comment, '') NOT LIKE 'FINAL_BALANCE_IN_FX_RESIDUAL_V1:%' THEN
      RAISE EXCEPTION 'PRECHECK: staff_classify_final_balance_in_fx_residual_v1 already exists with unknown authority';
    END IF;
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.staff_classify_final_balance_in_fx_residual_v1(
  p_dva_statement_line_id uuid,
  p_expected_residual_gbp numeric,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_line record;
  v_position_before record;
  v_position_after record;
  v_final_allocation record;
  v_final_allocation_count integer := 0;
  v_existing_fx_count integer := 0;
  v_order record;
  v_settlement record;
  v_expected numeric(12,2);
  v_residual numeric(12,2);
  v_allocation_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: final-balance IN FX residual classification requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can classify final-balance IN FX residuals. Current role: %', v_staff.role_type;
  END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.fx_rate_applied,
    dsl.card_markup_pct_applied,
    ds.importer_id,
    ds.statement_account_context
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds
    ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'DVA/card statement line not found: %', p_dva_statement_line_id;
  END IF;

  IF v_line.direction <> 'in' THEN
    RAISE EXCEPTION 'Final-balance FX residual classification requires an IN statement line. Line % has direction %',
      p_dva_statement_line_id, v_line.direction;
  END IF;

  IF v_line.statement_account_context IS DISTINCT FROM 'importer_dva_card_account' THEN
    RAISE EXCEPTION 'Final-balance FX residual classification requires importer_dva_card_account context. Line % has context %',
      p_dva_statement_line_id, v_line.statement_account_context;
  END IF;

  IF COALESCE(v_line.amount_gbp_equivalent, 0) <= 0 THEN
    RAISE EXCEPTION 'Statement line % has invalid GBP equivalent %',
      p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  END IF;

  SELECT p.*
    INTO v_position_before
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_position_before.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Canonical statement-line control position missing for %', p_dva_statement_line_id;
  END IF;

  IF COALESCE(v_position_before.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % is already over-consumed by £%',
      p_dva_statement_line_id, v_position_before.overconsumed_gbp;
  END IF;

  IF COALESCE(v_position_before.active_reserved_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % has £% reserved; FX residual classification is blocked',
      p_dva_statement_line_id, v_position_before.active_reserved_gbp;
  END IF;

  IF COALESCE(v_position_before.principal_lane_count, 0) <> 1 THEN
    RAISE EXCEPTION 'Statement line % must have exactly one principal lane before final-balance FX residual classification. Current count: %',
      p_dva_statement_line_id, v_position_before.principal_lane_count;
  END IF;

  IF NOT (
    'final_balance_payment' = ANY(
      COALESCE(v_position_before.active_economic_lanes, ARRAY[]::text[])
    )
  ) THEN
    RAISE EXCEPTION 'Statement line % has no active final_balance_payment economic lane', p_dva_statement_line_id;
  END IF;

  v_residual := ROUND(COALESCE(v_position_before.remaining_unconsumed_gbp, 0)::numeric, 2);
  v_expected := ROUND(COALESCE(p_expected_residual_gbp, 0)::numeric, 2);

  IF v_residual <= 0.005 THEN
    RAISE EXCEPTION 'Statement line % has no canonical residual remaining', p_dva_statement_line_id;
  END IF;

  IF v_expected <= 0 THEN
    RAISE EXCEPTION 'Expected residual must be greater than zero';
  END IF;

  IF ABS(v_expected - v_residual) > 0.005 THEN
    RAISE EXCEPTION 'Expected residual £% does not equal canonical remaining £% for statement line %',
      v_expected, v_residual, p_dva_statement_line_id;
  END IF;

  SELECT COUNT(*)::integer
    INTO v_final_allocation_count
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status <> 'reversed';

  IF v_final_allocation_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one active final_balance_payment allocation on statement line %. Found %',
      p_dva_statement_line_id, v_final_allocation_count;
  END IF;

  SELECT
    a.id,
    a.order_id,
    a.allocation_status,
    a.allocated_gbp_amount
  INTO v_final_allocation
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status <> 'reversed'
  LIMIT 1;

  IF v_final_allocation.allocation_status <> 'confirmed' THEN
    RAISE EXCEPTION 'Final-balance allocation % on statement line % is not confirmed',
      v_final_allocation.id, p_dva_statement_line_id;
  END IF;

  IF v_final_allocation.order_id IS NULL THEN
    RAISE EXCEPTION 'Final-balance allocation % has no linked order', v_final_allocation.id;
  END IF;

  SELECT COUNT(*)::integer
    INTO v_existing_fx_count
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'fx_card_difference'
    AND a.allocation_status <> 'reversed';

  IF v_existing_fx_count <> 0 THEN
    RAISE EXCEPTION 'Statement line % already has an active FX/card difference allocation', p_dva_statement_line_id;
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, o.status
    INTO v_order
  FROM public.orders o
  WHERE o.id = v_final_allocation.order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Linked order not found for final-balance allocation %', v_final_allocation.id;
  END IF;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Importer mismatch: statement importer % does not match linked order % importer %',
      v_line.importer_id, v_order.id, v_order.importer_id;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot classify final-balance FX residual for order % with status %', v_order.id, v_order.status;
  END IF;

  SELECT *
    INTO v_settlement
  FROM public.internal_order_final_sale_settlement_v2(v_order.id)
  LIMIT 1;

  IF v_settlement.order_id IS NULL THEN
    RAISE EXCEPTION 'Final-sale settlement row missing for order %', v_order.id;
  END IF;

  IF COALESCE(v_settlement.final_sale_value_exists, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Final-sale value does not exist for order %', v_order.id;
  END IF;

  IF ROUND(COALESCE(v_settlement.final_balance_due_gbp, 0)::numeric, 2) > 0.005 THEN
    RAISE EXCEPTION 'Order % still has final balance due £%; FX residual classification is not allowed yet',
      v_order.id, v_settlement.final_balance_due_gbp;
  END IF;

  INSERT INTO public.dva_statement_line_allocations (
    dva_statement_line_id,
    allocation_type,
    supplier_invoice_id,
    dispute_id,
    order_id,
    allocated_gbp_amount,
    allocation_status,
    fx_rate_applied,
    card_markup_pct_applied,
    fx_or_card_diff_gbp,
    notes,
    created_by_staff_id,
    created_at,
    confirmed_by_staff_id,
    confirmed_at
  )
  VALUES (
    p_dva_statement_line_id,
    'fx_card_difference',
    NULL,
    NULL,
    v_order.id,
    v_residual,
    'confirmed',
    v_line.fx_rate_applied,
    v_line.card_markup_pct_applied,
    v_residual,
    concat_ws(
      E'\n',
      NULLIF(TRIM(COALESCE(p_notes, '')), ''),
      'Residual classified only after final balance reached zero.'
    ),
    v_staff.id,
    now(),
    v_staff.id,
    now()
  )
  RETURNING id INTO v_allocation_id;

  SELECT p.*
    INTO v_position_after
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_position_after.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Canonical statement-line control position disappeared after FX residual classification';
  END IF;

  IF ABS(COALESCE(v_position_after.remaining_unconsumed_gbp, 0)) > 0.005 THEN
    RAISE EXCEPTION 'FX residual classification did not fully consume statement line %. Remaining £%',
      p_dva_statement_line_id, v_position_after.remaining_unconsumed_gbp;
  END IF;

  IF COALESCE(v_position_after.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'FX residual classification over-consumed statement line % by £%',
      p_dva_statement_line_id, v_position_after.overconsumed_gbp;
  END IF;

  IF COALESCE(v_position_after.active_reserved_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % gained an unexpected reservation of £% during FX residual classification',
      p_dva_statement_line_id, v_position_after.active_reserved_gbp;
  END IF;

  IF COALESCE(v_position_after.principal_lane_count, 0) <> 1 THEN
    RAISE EXCEPTION 'FX residual classification altered principal-lane integrity for statement line %. Count %',
      p_dva_statement_line_id, v_position_after.principal_lane_count;
  END IF;

  IF NOT (
    'final_balance_payment' = ANY(COALESCE(v_position_after.active_economic_lanes, ARRAY[]::text[]))
    AND 'fx_card_difference' = ANY(COALESCE(v_position_after.active_economic_lanes, ARRAY[]::text[]))
  ) THEN
    RAISE EXCEPTION 'Expected final_balance_payment + fx_card_difference economic lanes are not both active after classification';
  END IF;

  IF ABS(
    COALESCE(v_position_after.active_consumed_gbp, 0)
    - (COALESCE(v_position_before.active_consumed_gbp, 0) + v_residual)
  ) > 0.005 THEN
    RAISE EXCEPTION 'Canonical consumed amount did not move by exactly the classified residual. Before £%, residual £%, after £%',
      v_position_before.active_consumed_gbp, v_residual, v_position_after.active_consumed_gbp;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'classifier', 'FINAL_BALANCE_IN_FX_RESIDUAL_V1',
    'allocation_id', v_allocation_id,
    'final_balance_allocation_id', v_final_allocation.id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', v_order.id,
    'order_ref', v_order.order_ref,
    'allocated_gbp_amount', v_residual,
    'canonical_consumed_before_gbp', ROUND(COALESCE(v_position_before.active_consumed_gbp, 0)::numeric, 2),
    'canonical_consumed_after_gbp', ROUND(COALESCE(v_position_after.active_consumed_gbp, 0)::numeric, 2),
    'canonical_remaining_after_gbp', ROUND(COALESCE(v_position_after.remaining_unconsumed_gbp, 0)::numeric, 2),
    'canonical_overconsumed_after_gbp', ROUND(COALESCE(v_position_after.overconsumed_gbp, 0)::numeric, 2),
    'principal_lane_count_after', v_position_after.principal_lane_count,
    'balanced_yn', ABS(COALESCE(v_position_after.remaining_unconsumed_gbp, 0)) <= 0.005
  );
END;
$function$;

COMMENT ON FUNCTION public.staff_classify_final_balance_in_fx_residual_v1(uuid, numeric, text) IS
'FINAL_BALANCE_IN_FX_RESIDUAL_V1: additive staff/supervisor sibling writer that classifies only the exact canonical residual on an importer DVA/card IN line after one confirmed final_balance_payment has reduced the linked order final balance to zero. Reuses existing fx_card_difference semantics; no funding, credit, settlement, Sage or VAT rewrite.';

REVOKE ALL ON FUNCTION public.staff_classify_final_balance_in_fx_residual_v1(uuid, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_classify_final_balance_in_fx_residual_v1(uuid, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_classify_final_balance_in_fx_residual_v1(uuid, numeric, text) TO authenticated;

DO $postflight$
DECLARE
  r record;
  v_actual text;
  v_def text;
  v_prosecdef boolean;
  v_config text[];
BEGIN
  FOR r IN
    SELECT *
    FROM (VALUES
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
      ('view', 'public.statement_line_control_usage_v1', '581d367a31ab0f689f3d31b46df5922e')
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
      RAISE EXCEPTION 'POSTCHECK: frozen % changed. expected %, actual %',
        r.object_name, r.expected_md5, v_actual;
    END IF;
  END LOOP;

  IF to_regprocedure('public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'POSTCHECK: new final-balance IN FX residual writer is missing';
  END IF;

  SELECT
    p.prosecdef,
    p.proconfig,
    lower(pg_get_functiondef(p.oid))
  INTO
    v_prosecdef,
    v_config,
    v_def
  FROM pg_proc p
  WHERE p.oid = 'public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)'::regprocedure;

  IF COALESCE(v_prosecdef, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'POSTCHECK: new writer is not SECURITY DEFINER';
  END IF;

  IF NOT COALESCE(v_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'POSTCHECK: new writer search_path is not locked';
  END IF;

  IF position('statement_line_control_position_v1' in v_def) = 0
     OR position('internal_order_final_sale_settlement_v2' in v_def) = 0
     OR position('final_balance_payment' in v_def) = 0
     OR position('fx_card_difference' in v_def) = 0
     OR position('p_expected_residual_gbp' in v_def) = 0 THEN
    RAISE EXCEPTION 'POSTCHECK: new writer lost a governed safety seam';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'POSTCHECK: anon must not execute new writer';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'POSTCHECK: authenticated execute grant missing';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;

SELECT jsonb_build_object(
  'probe', 'FINAL_BALANCE_IN_FX_RESIDUAL_MIGRATION_POSTFLIGHT_V1',
  'ready', to_regprocedure('public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)') IS NOT NULL,
  'business_rows_changed_by_migration', false,
  'existing_treasury_authorities_changed', false,
  'authenticated_execute', has_function_privilege(
    'authenticated',
    'public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)',
    'EXECUTE'
  ),
  'anon_execute_revoked', NOT has_function_privilege(
    'anon',
    'public.staff_classify_final_balance_in_fx_residual_v1(uuid,numeric,text)',
    'EXECUTE'
  )
) AS result;
