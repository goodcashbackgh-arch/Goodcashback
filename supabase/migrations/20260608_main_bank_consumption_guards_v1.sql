BEGIN;

-- Main-bank consumption guards v1.
-- Keeps the existing shipper AP allocation RPC untouched, but makes shared main-bank
-- read models/residual allocation guards account for shipper, loyalty, FX and fee consumption.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.main_bank_shipper_ap_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_shipper_ap_allocations'; END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_main_bank_shipper_statement_lines_v1(
  p_status text DEFAULT 'unmatched',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_id uuid,
  statement_date date,
  reference_raw text,
  direction text,
  amount_local numeric,
  local_currency text,
  amount_gbp numeric,
  allocated_gbp numeric,
  remaining_gbp numeric,
  match_status text,
  statement_account_label text,
  source_bank text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'unmatched'));
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: main bank workspace requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for main bank workspace.'; END IF;

  RETURN QUERY
  WITH shipper_allocations AS (
    SELECT
      a.dva_statement_line_id,
      round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2) AS allocated_gbp
    FROM public.main_bank_shipper_ap_allocations a
    GROUP BY a.dva_statement_line_id
  ), residual_allocations AS (
    SELECT
      a.dva_statement_line_id,
      round(COALESCE(sum(a.allocated_gbp_amount) FILTER (
        WHERE a.allocation_status = 'confirmed'
          AND a.allocation_type IN ('fx_card_difference','bank_fee','unmatched_hold')
      ), 0)::numeric, 2) AS allocated_gbp
    FROM public.dva_statement_line_allocations a
    GROUP BY a.dva_statement_line_id
  ), loyalty_matches AS (
    SELECT
      lm.dva_statement_line_id,
      round(COALESCE(sum(lm.matched_gbp_amount) FILTER (WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit')), 0)::numeric, 2) AS matched_gbp
    FROM public.main_bank_completion_loyalty_funding_matches lm
    GROUP BY lm.dva_statement_line_id
  ), base AS (
    SELECT
      dsl.id AS statement_line_id,
      ds.id AS statement_id,
      dsl.statement_date,
      dsl.reference_raw::text,
      dsl.direction::text,
      dsl.amount_local_ccy::numeric AS amount_local,
      dsl.local_ccy::text AS local_currency,
      round(COALESCE(dsl.amount_gbp_equivalent, 0)::numeric, 2) AS amount_gbp,
      COALESCE(sa.allocated_gbp, 0)::numeric AS shipper_allocated_gbp,
      COALESCE(ra.allocated_gbp, 0)::numeric AS residual_allocated_gbp,
      COALESCE(lm.matched_gbp, 0)::numeric AS loyalty_matched_gbp,
      ds.statement_account_label::text,
      ds.source_bank::text
    FROM public.dva_statement_lines dsl
    JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
    LEFT JOIN shipper_allocations sa ON sa.dva_statement_line_id = dsl.id
    LEFT JOIN residual_allocations ra ON ra.dva_statement_line_id = dsl.id
    LEFT JOIN loyalty_matches lm ON lm.dva_statement_line_id = dsl.id
    WHERE COALESCE(ds.statement_account_context, 'importer_dva_card_account') = 'main_company_bank_account'
      AND dsl.direction = 'out'
  ), enriched AS (
    SELECT
      b.*,
      greatest(round((b.amount_gbp - b.shipper_allocated_gbp - b.residual_allocated_gbp - b.loyalty_matched_gbp)::numeric, 2), 0::numeric) AS remaining_after_all_consumption_gbp,
      CASE
        WHEN b.shipper_allocated_gbp + b.residual_allocated_gbp + b.loyalty_matched_gbp <= 0 THEN 'unmatched'
        WHEN b.amount_gbp - b.shipper_allocated_gbp - b.residual_allocated_gbp - b.loyalty_matched_gbp > 0.01 THEN 'part_allocated'
        ELSE 'balanced'
      END::text AS match_status
    FROM base b
  ), filtered AS (
    SELECT e.*
    FROM enriched e
    WHERE (v_status = 'all' OR e.match_status = v_status)
      AND (v_search IS NULL OR lower(concat_ws(' ', e.reference_raw, e.statement_date::text, e.amount_gbp::text, e.source_bank)) LIKE '%' || v_search || '%')
  )
  SELECT
    f.statement_line_id,
    f.statement_id,
    f.statement_date,
    f.reference_raw,
    f.direction,
    f.amount_local,
    f.local_currency,
    f.amount_gbp,
    f.shipper_allocated_gbp AS allocated_gbp,
    f.remaining_after_all_consumption_gbp AS remaining_gbp,
    f.match_status,
    f.statement_account_label,
    f.source_bank,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date DESC, f.statement_line_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

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

  v_amount := round(COALESCE(p_allocated_gbp_amount, 0)::numeric, 2);

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

  SELECT round(COALESCE(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_existing_residual_total
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  IF v_line.statement_account_context = 'main_company_bank_account' THEN
    SELECT round((
      COALESCE((
        SELECT sum(a.allocated_gbp_amount)
        FROM public.main_bank_shipper_ap_allocations a
        WHERE a.dva_statement_line_id = p_dva_statement_line_id
          AND a.allocation_status = 'confirmed'
      ), 0)
      + COALESCE((
        SELECT sum(lm.matched_gbp_amount)
        FROM public.main_bank_completion_loyalty_funding_matches lm
        WHERE lm.dva_statement_line_id = p_dva_statement_line_id
          AND lm.match_status IN ('confirmed','released_available_dashboard_credit')
      ), 0)
    )::numeric, 2)
    INTO v_external_consumed_total;
  END IF;

  v_unallocated_before := round(v_line.amount_gbp_equivalent::numeric - COALESCE(v_existing_residual_total, 0) - COALESCE(v_external_consumed_total, 0), 2);

  IF v_amount > v_unallocated_before + 0.01 THEN
    RAISE EXCEPTION 'FX/card/fee allocation would over-allocate statement line %. Statement GBP %, already residual allocated %, external main-bank consumed %, remaining %, proposed %',
      p_dva_statement_line_id,
      round(v_line.amount_gbp_equivalent::numeric, 2),
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

  SELECT round(COALESCE(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_confirmed_total_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  v_unallocated_after := round(v_line.amount_gbp_equivalent::numeric - COALESCE(v_confirmed_total_after, 0) - COALESCE(v_external_consumed_total, 0), 2);

  RETURN jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'allocation_type', p_allocation_type,
    'allocated_gbp_amount', v_amount,
    'statement_gbp_amount', round(v_line.amount_gbp_equivalent::numeric, 2),
    'confirmed_residual_allocated_before_gbp', v_existing_residual_total,
    'external_main_bank_consumed_gbp', v_external_consumed_total,
    'confirmed_unallocated_before_gbp', v_unallocated_before,
    'confirmed_residual_allocated_after_gbp', v_confirmed_total_after,
    'confirmed_unallocated_after_gbp', v_unallocated_after,
    'balanced_yn', abs(v_unallocated_after) < 0.01
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) IS
'Staff/supervisor SECURITY DEFINER RPC to allocate remaining OUT statement-line balance to FX/card difference or bank fee. Main-bank context subtracts shipper AP and loyalty funding matches before allowing residual allocation. Does not post to Sage.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
