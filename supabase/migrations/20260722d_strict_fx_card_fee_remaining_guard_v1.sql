BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Corrective replacement for the latest migration-level definition in
-- 20260609_main_bank_consumption_guards_v2.sql. Preserve the existing RPC
-- contract and behaviour while making the remaining-balance guard penny-safe.
DO $$
BEGIN
  IF to_regprocedure('public.staff_allocate_statement_line_to_fx_card_or_fee(uuid,character varying,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_allocate_statement_line_to_fx_card_or_fee(uuid,varchar,numeric,text) prerequisite';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_allocate_statement_line_to_fx_card_or_fee(
  p_dva_statement_line_id uuid,
  p_allocation_type varchar,
  p_allocated_gbp_amount numeric,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_line record;
  v_existing_residual_total numeric(12,2) := 0;
  v_external_consumed_total numeric(12,2) := 0;
  v_confirmed_total_after numeric(12,2);
  v_unallocated_before numeric(12,2);
  v_unallocated_after numeric(12,2);
  v_amount numeric(12,2);
  v_allocation_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: FX/card/fee allocation requires auth.uid()';
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
    RAISE EXCEPTION 'Only admin or supervisor staff can allocate FX/card/fee differences. Current role: %', v_staff.role_type;
  END IF;

  IF p_allocation_type NOT IN ('fx_card_difference', 'bank_fee') THEN
    RAISE EXCEPTION 'Unsupported allocation type %. Use fx_card_difference or bank_fee', p_allocation_type;
  END IF;

  v_amount := ROUND(COALESCE(p_allocated_gbp_amount, 0)::numeric, 2);

  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Allocated GBP amount must be greater than zero. Received: %', v_amount;
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
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'DVA/card statement line not found: %', p_dva_statement_line_id;
  END IF;

  IF v_line.direction <> 'out' THEN
    RAISE EXCEPTION 'FX/card/fee allocation currently requires an OUT statement line. Line % has direction %', p_dva_statement_line_id, v_line.direction;
  END IF;

  IF COALESCE(v_line.amount_gbp_equivalent, 0) <= 0 THEN
    RAISE EXCEPTION 'Statement line % has invalid GBP equivalent %', p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_existing_residual_total
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  IF v_line.statement_account_context = 'main_company_bank_account' THEN
    SELECT ROUND((
      COALESCE((
        SELECT SUM(a.allocated_gbp_amount)
        FROM public.main_bank_shipper_ap_allocations a
        WHERE a.dva_statement_line_id = p_dva_statement_line_id
          AND a.allocation_status = 'confirmed'
      ), 0)
      + COALESCE((
        SELECT SUM(lm.matched_gbp_amount)
        FROM public.main_bank_completion_loyalty_funding_matches lm
        WHERE lm.dva_statement_line_id = p_dva_statement_line_id
          AND lm.match_status IN ('confirmed','released_available_dashboard_credit')
      ), 0)
    )::numeric, 2)
    INTO v_external_consumed_total;
  END IF;

  v_unallocated_before := ROUND(
    v_line.amount_gbp_equivalent::numeric
      - COALESCE(v_existing_residual_total, 0)
      - COALESCE(v_external_consumed_total, 0),
    2
  );

  IF v_unallocated_before <= 0.005 THEN
    RAISE EXCEPTION 'Statement line has no remaining balance.';
  END IF;

  IF v_amount > v_unallocated_before + 0.005 THEN
    RAISE EXCEPTION 'FX/card/fee allocation would over-allocate statement line %. Statement GBP %, already residual allocated %, external main-bank consumed %, remaining %, proposed %',
      p_dva_statement_line_id,
      ROUND(v_line.amount_gbp_equivalent::numeric, 2),
      v_existing_residual_total,
      v_external_consumed_total,
      v_unallocated_before,
      v_amount;
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
  ) VALUES (
    p_dva_statement_line_id,
    p_allocation_type,
    NULL,
    NULL,
    NULL,
    v_amount,
    'confirmed',
    v_line.fx_rate_applied,
    v_line.card_markup_pct_applied,
    CASE WHEN p_allocation_type = 'fx_card_difference' THEN v_amount ELSE NULL END,
    p_notes,
    v_staff.id,
    now(),
    v_staff.id,
    now()
  ) RETURNING id INTO v_allocation_id;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_confirmed_total_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  v_unallocated_after := ROUND(
    v_line.amount_gbp_equivalent::numeric
      - COALESCE(v_confirmed_total_after, 0)
      - COALESCE(v_external_consumed_total, 0),
    2
  );

  IF v_unallocated_after < -0.005 THEN
    RAISE EXCEPTION 'FX/card/fee allocation produced a negative remaining balance for statement line %. Remaining %.',
      p_dva_statement_line_id,
      v_unallocated_after;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'allocation_type', p_allocation_type,
    'allocated_gbp_amount', v_amount,
    'statement_gbp_amount', ROUND(v_line.amount_gbp_equivalent::numeric, 2),
    'confirmed_residual_allocated_before_gbp', v_existing_residual_total,
    'external_main_bank_consumed_gbp', v_external_consumed_total,
    'confirmed_unallocated_before_gbp', v_unallocated_before,
    'confirmed_residual_allocated_after_gbp', v_confirmed_total_after,
    'confirmed_unallocated_after_gbp', v_unallocated_after,
    'balanced_yn', ABS(v_unallocated_after) < 0.01
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) IS
'Staff/supervisor SECURITY DEFINER RPC to allocate a positive amount no greater than the rounded remaining OUT balance to FX/card difference or bank fee. Main-bank context subtracts shipper AP and loyalty funding matches. Fails closed on a non-positive or negative remaining balance and does not post to Sage.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
