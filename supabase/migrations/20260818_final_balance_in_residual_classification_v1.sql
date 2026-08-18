BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final-balance IN residual classification v1.
-- Governing authority:
-- docs/governing-pack/ui/DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md
--
-- Purpose:
-- Complete the deliberately separate second-stage classification path for an
-- importer DVA/card IN statement line after a confirmed final_balance_payment
-- has reduced the linked order final balance to zero.
--
-- This migration is additive only. It does NOT replace or alter:
--   - staff_allocate_statement_line_to_final_balance_payment_v1(...)
--   - staff_allocate_statement_line_to_fx_card_or_fee(...)
--   - accepted-estimate funding / order_funding
--   - customer/importer credit
--   - canonical statement-control views/resolver
--   - Sage / VAT / supplier / shipment behaviour
--   - any existing business-data row.

DO $preflight$
DECLARE
  v_existing_comment text;
BEGIN
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Missing public.staff';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Missing public.orders';
  END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statements';
  END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_lines';
  END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_line_allocations';
  END IF;
  IF to_regclass('public.statement_line_control_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing canonical public.statement_line_control_position_v1';
  END IF;
  IF to_regprocedure('public.internal_order_final_sale_settlement_v2(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_order_final_sale_settlement_v2(uuid)';
  END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing existing final-balance allocation RPC';
  END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_fx_card_or_fee(uuid,character varying,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing existing OUT FX/card/fee allocation RPC';
  END IF;

  -- Do not overwrite an unrelated future implementation with the same name.
  IF to_regprocedure('public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)') IS NOT NULL THEN
    SELECT obj_description(
      'public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)'::regprocedure,
      'pg_proc'
    ) INTO v_existing_comment;

    IF COALESCE(v_existing_comment, '') NOT LIKE 'FINAL_BALANCE_IN_RESIDUAL_CLASSIFIER_V1:%' THEN
      RAISE EXCEPTION 'Existing staff_classify_final_balance_in_residual_v1 is not this governed implementation';
    END IF;
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.staff_classify_final_balance_in_residual_v1(
  p_dva_statement_line_id uuid,
  p_allocation_type varchar,
  p_allocated_gbp_amount numeric DEFAULT NULL,
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
  v_order record;
  v_position record;
  v_after record;
  v_settlement record;
  v_final_allocation record;
  v_final_allocation_count integer := 0;
  v_amount numeric(12,2);
  v_remaining_before numeric(12,2);
  v_remaining_after numeric(12,2);
  v_allocation_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: final-balance residual classification requires auth.uid()';
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
    RAISE EXCEPTION 'Only admin or supervisor staff can classify final-balance residuals. Current role: %', v_staff.role_type;
  END IF;

  IF p_allocation_type NOT IN ('fx_card_difference', 'bank_fee') THEN
    RAISE EXCEPTION 'Unsupported final-balance IN residual type %. Use fx_card_difference or bank_fee', p_allocation_type;
  END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.fx_rate_applied,
    dsl.card_markup_pct_applied,
    ds.importer_id,
    COALESCE(ds.statement_account_context, 'importer_dva_card_account') AS statement_account_context
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
    RAISE EXCEPTION 'Final-balance residual classification requires an IN statement line. Line % has direction %',
      p_dva_statement_line_id, v_line.direction;
  END IF;

  IF v_line.statement_account_context <> 'importer_dva_card_account' THEN
    RAISE EXCEPTION 'Final-balance residual classification requires importer DVA/card context. Line % has context %',
      p_dva_statement_line_id, v_line.statement_account_context;
  END IF;

  IF COALESCE(v_line.amount_gbp_equivalent, 0) <= 0 THEN
    RAISE EXCEPTION 'Statement line % has invalid GBP equivalent %', p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  END IF;

  SELECT p.*
    INTO v_position
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_position.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Canonical statement-line control position missing for %', p_dva_statement_line_id;
  END IF;

  IF COALESCE(v_position.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % is already over-consumed by £%',
      p_dva_statement_line_id, v_position.overconsumed_gbp;
  END IF;

  IF COALESCE(v_position.active_reserved_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % has £% reserved and cannot be residual-classified',
      p_dva_statement_line_id, v_position.active_reserved_gbp;
  END IF;

  IF COALESCE(v_position.principal_lane_count, 0) <> 1 THEN
    RAISE EXCEPTION 'Statement line % must have exactly one active principal lane before final-balance residual classification. Current count: %',
      p_dva_statement_line_id, v_position.principal_lane_count;
  END IF;

  IF NOT ('final_balance_payment' = ANY(COALESCE(v_position.active_economic_lanes, ARRAY[]::text[]))) THEN
    RAISE EXCEPTION 'Statement line % has no active final_balance_payment lane', p_dva_statement_line_id;
  END IF;

  v_remaining_before := ROUND(COALESCE(v_position.remaining_unconsumed_gbp, 0)::numeric, 2);

  IF v_remaining_before <= 0.005 THEN
    RAISE EXCEPTION 'Statement line % has no canonical residual remaining', p_dva_statement_line_id;
  END IF;

  SELECT COUNT(*)
    INTO v_final_allocation_count
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed'
    AND a.order_id IS NOT NULL;

  IF v_final_allocation_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one confirmed final_balance_payment allocation on statement line %. Found %',
      p_dva_statement_line_id, v_final_allocation_count;
  END IF;

  SELECT a.id, a.order_id
    INTO v_final_allocation
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed'
    AND a.order_id IS NOT NULL
  LIMIT 1;

  SELECT o.id, o.order_ref, o.importer_id, o.status
    INTO v_order
  FROM public.orders o
  WHERE o.id = v_final_allocation.order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Linked order not found for final-balance allocation %', v_final_allocation.id;
  END IF;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Importer mismatch: statement importer % does not match final-balance order % importer %',
      v_line.importer_id, v_order.id, v_order.importer_id;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot classify final-balance residual for order % with status %', v_order.id, v_order.status;
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
    RAISE EXCEPTION 'Order % still has final balance due £%; residual classification is blocked until it reaches zero',
      v_order.id, v_settlement.final_balance_due_gbp;
  END IF;

  v_amount := ROUND(COALESCE(p_allocated_gbp_amount, v_remaining_before)::numeric, 2);

  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Residual classification amount must be greater than zero';
  END IF;

  IF v_amount > v_remaining_before + 0.005 THEN
    RAISE EXCEPTION 'Residual classification would over-allocate statement line %. Canonical remaining £%, proposed £%',
      p_dva_statement_line_id, v_remaining_before, v_amount;
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
    p_allocation_type,
    NULL,
    NULL,
    v_order.id,
    v_amount,
    'confirmed',
    v_line.fx_rate_applied,
    v_line.card_markup_pct_applied,
    CASE WHEN p_allocation_type = 'fx_card_difference' THEN v_amount ELSE NULL END,
    concat_ws(
      E'\n',
      NULLIF(TRIM(COALESCE(p_notes, '')), ''),
      'Final-balance IN residual classified only after the linked final balance reached zero.'
    ),
    v_staff.id,
    now(),
    v_staff.id,
    now()
  )
  RETURNING id INTO v_allocation_id;

  SELECT p.*
    INTO v_after
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_after.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Canonical statement-line control position disappeared after residual classification';
  END IF;

  IF COALESCE(v_after.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Residual classification would over-consume statement line % by £%',
      p_dva_statement_line_id, v_after.overconsumed_gbp;
  END IF;

  IF COALESCE(v_after.principal_lane_count, 0) <> 1 THEN
    RAISE EXCEPTION 'Residual classification altered principal-lane integrity for statement line %', p_dva_statement_line_id;
  END IF;

  v_remaining_after := ROUND(COALESCE(v_after.remaining_unconsumed_gbp, 0)::numeric, 2);

  IF ABS(v_remaining_after - ROUND((v_remaining_before - v_amount)::numeric, 2)) > 0.005 THEN
    RAISE EXCEPTION 'Canonical residual movement mismatch. Before £%, classified £%, after £%',
      v_remaining_before, v_amount, v_remaining_after;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'classifier', 'FINAL_BALANCE_IN_RESIDUAL_CLASSIFIER_V1',
    'allocation_id', v_allocation_id,
    'final_balance_allocation_id', v_final_allocation.id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', v_order.id,
    'order_ref', v_order.order_ref,
    'allocation_type', p_allocation_type,
    'allocated_gbp_amount', v_amount,
    'canonical_remaining_before_gbp', v_remaining_before,
    'canonical_remaining_after_gbp', v_remaining_after,
    'canonical_overconsumed_after_gbp', COALESCE(v_after.overconsumed_gbp, 0),
    'balanced_yn', v_remaining_after <= 0.005
  );
END;
$function$;

COMMENT ON FUNCTION public.staff_classify_final_balance_in_residual_v1(uuid, varchar, numeric, text) IS
'FINAL_BALANCE_IN_RESIDUAL_CLASSIFIER_V1: dedicated staff/supervisor classifier for residual on an importer DVA/card IN line after one confirmed final_balance_payment has reduced the linked order final balance to zero. Existing OUT residual, funding, credit, Sage and VAT paths are untouched.';

REVOKE ALL ON FUNCTION public.staff_classify_final_balance_in_residual_v1(uuid, varchar, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_classify_final_balance_in_residual_v1(uuid, varchar, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_classify_final_balance_in_residual_v1(uuid, varchar, numeric, text) TO authenticated;

DO $postflight$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Postflight failed: classifier was not installed';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)'::regprocedure
  )) INTO v_def;

  IF position('direction <> ''in''' in v_def) = 0
     OR position('final_balance_payment' in v_def) = 0
     OR position('statement_line_control_position_v1' in v_def) = 0
     OR position('internal_order_final_sale_settlement_v2' in v_def) = 0
     OR position('final_balance_due_gbp' in v_def) = 0 THEN
    RAISE EXCEPTION 'Postflight failed: classifier guard shape is incomplete';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Postflight failed: authenticated execute grant missing';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Postflight failed: anon must not have execute';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Read-only confirmation after execution:
SELECT jsonb_build_object(
  'probe', 'FINAL_BALANCE_IN_RESIDUAL_CLASSIFIER_POSTFLIGHT_V1',
  'ready', to_regprocedure('public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)') IS NOT NULL,
  'security_definer', (
    SELECT p.prosecdef
    FROM pg_proc p
    WHERE p.oid = 'public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)'::regprocedure
  ),
  'authenticated_execute', has_function_privilege(
    'authenticated',
    'public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)',
    'EXECUTE'
  ),
  'anon_execute_revoked', NOT has_function_privilege(
    'anon',
    'public.staff_classify_final_balance_in_residual_v1(uuid,character varying,numeric,text)',
    'EXECUTE'
  ),
  'business_rows_changed_by_migration', false,
  'existing_out_rpc_changed', false,
  'existing_final_balance_rpc_changed', false
) AS result;
