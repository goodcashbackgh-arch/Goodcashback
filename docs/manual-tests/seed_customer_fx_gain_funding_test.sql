-- Manual test seed: customer/local-currency IN greater than order funding gap.
-- Purpose: create one active inbound DVA statement line that should route surplus to FX gain.
-- Run in Supabase SQL editor after applying:
--   supabase/migrations/20260525_customer_in_fx_gain_from_funding_v1.sql
--
-- Default target uses the visible test order from the funding page screenshot.
-- Change v_target_order_ref if needed.

DO $$
DECLARE
  v_target_order_ref text := 'ORD-1779201540356';
  v_order record;
  v_staff_id uuid;
  v_statement_id uuid;
  v_line_id uuid;
  v_gap numeric(12,2);
  v_fx_gain_seed numeric(12,2) := 11.00;
  v_statement_amount_gbp numeric(12,2);
  v_seed_ref text;
BEGIN
  SELECT o.id, o.order_ref, o.importer_id, o.status, COALESCE(o.order_type, 'original') AS order_type
    INTO v_order
  FROM public.orders o
  WHERE o.order_ref = v_target_order_ref
  LIMIT 1;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Target order_ref % not found. Update v_target_order_ref.', v_target_order_ref;
  END IF;

  IF v_order.order_type <> 'original' THEN
    RAISE EXCEPTION 'Target order % is not original. Found order_type %.', v_target_order_ref, v_order.order_type;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Target order % has blocked status %.', v_target_order_ref, v_order.status;
  END IF;

  v_gap := ROUND(COALESCE(public.order_funding_gap_gbp(v_order.id), 0)::numeric, 2);

  IF v_gap <= 0 THEN
    RAISE EXCEPTION 'Target order % has no positive funding gap. Current gap: %.', v_target_order_ref, v_gap;
  END IF;

  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin', 'supervisor')
  ORDER BY s.created_at NULLS LAST
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'No active admin/supervisor staff row found.';
  END IF;

  v_statement_amount_gbp := ROUND(v_gap + v_fx_gain_seed, 2);
  v_seed_ref := 'FXGAIN-SEED-' || v_target_order_ref || '-' || to_char(now(), 'YYYYMMDDHH24MISS');

  INSERT INTO public.dva_statements (
    importer_id,
    source_bank,
    uploaded_by_staff_id,
    csv_url,
    statement_period_from,
    statement_period_to,
    parse_status,
    parse_errors_json
  ) VALUES (
    v_order.importer_id,
    'gcb',
    v_staff_id,
    'manual://seed-customer-fx-gain-test',
    CURRENT_DATE,
    CURRENT_DATE,
    'parsed',
    NULL
  ) RETURNING id INTO v_statement_id;

  INSERT INTO public.dva_statement_lines (
    dva_statement_id,
    line_order,
    statement_date,
    reference_raw,
    direction,
    amount_local_ccy,
    local_ccy,
    fx_rate_applied,
    card_markup_pct_applied,
    amount_gbp_equivalent,
    auth_id_ref,
    retailer_name_ref,
    match_status
  ) VALUES (
    v_statement_id,
    1,
    CURRENT_DATE,
    LEFT(v_seed_ref || ' customer paid quoted local amount for ' || v_order.order_ref || ' expected FX gain £' || v_fx_gain_seed::text, 255),
    'in',
    v_statement_amount_gbp,
    'GBP',
    1,
    0,
    v_statement_amount_gbp,
    v_seed_ref,
    'FX GAIN SEED',
    'unmatched'
  ) RETURNING id INTO v_line_id;

  RAISE NOTICE 'Seeded customer FX gain test. order_ref=%, order_id=%, gap=%, statement_in=%, expected_fx_gain=%, dva_statement_line_id=%',
    v_order.order_ref, v_order.id, v_gap, v_statement_amount_gbp, v_fx_gain_seed, v_line_id;
END $$;

-- After seeding, open /internal/funding.
-- Expected card:
--   Statement IN = order gap + £11.00
--   Order gap = current gap
--   Confirm surplus/overfunding checkbox appears
--   Apply funding should fund the gap and route £11.00 to fx_card_difference.

-- Verification after pressing Apply funding:
-- select allocation_type, order_id, allocated_gbp_amount, fx_or_card_diff_gbp, notes, created_at
-- from public.dva_statement_line_allocations
-- where allocation_type = 'fx_card_difference'
-- order by created_at desc
-- limit 5;
--
-- select entry_type, direction, amount_gbp, source_type, source_entity_id, notes, created_at
-- from public.importer_credit_ledger
-- order by created_at desc
-- limit 10;
