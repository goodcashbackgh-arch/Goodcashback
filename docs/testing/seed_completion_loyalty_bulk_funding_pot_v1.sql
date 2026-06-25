-- Seed Completion Loyalty Bulk Funding Pot v1
-- Purpose: create a controlled persistent 2-reward same-importer funding-pot test.
-- Run in Supabase SQL Editor after:
--   supabase/migrations/20260625_completion_loyalty_bulk_funding_pot_release_v1.sql
--
-- This seed is additive. It does not post to Sage, does not touch VAT, does not
-- change apply-to-order logic, and does not touch shipper AP or residual flows.
-- It creates:
--   - 2 cloned test orders for the same importer as an existing staged loyalty row;
--   - 2 approved-pending-funding completion-loyalty approvals;
--   - 1 new main-bank OUT statement line for £27.00;
--   - 1 new same-importer DVA/card IN statement line for £27.00;
--   - 2 staged loyalty matches of £13.50 each using the same source OUT line.
-- Expected UI after running:
--   /internal/dva-reconciliation/main-bank?target=completion_loyalty&status=all
--   Funding pot view -> Exact pot -> 2 rewards -> Bulk release exact pot enabled.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_seed_tag text := 'BULK-POT-SEED-V1';
  v_reward_amount numeric(18,2) := 13.50;
  v_total_amount numeric(18,2) := 27.00;

  v_existing_seed_count integer := 0;
  v_base_match record;
  v_staff_id uuid;
  v_auth_user_id uuid;
  v_importer_id uuid;

  v_base_order_json jsonb;
  v_base_approval_json jsonb;
  v_base_statement_json jsonb;
  v_base_line_json jsonb;

  v_order_a_id uuid := gen_random_uuid();
  v_order_b_id uuid := gen_random_uuid();
  v_approval_a_id uuid := gen_random_uuid();
  v_approval_b_id uuid := gen_random_uuid();
  v_source_statement_id uuid := gen_random_uuid();
  v_dest_statement_id uuid := gen_random_uuid();
  v_source_out_line_id uuid := gen_random_uuid();
  v_dest_in_line_id uuid := gen_random_uuid();
  v_match_a_id uuid := gen_random_uuid();
  v_match_b_id uuid := gen_random_uuid();

  v_order_a_ref text := 'ORD-BULK-POT-TEST-A';
  v_order_b_ref text := 'ORD-BULK-POT-TEST-B';

  v_json jsonb;
BEGIN
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_reward_approvals'; END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regprocedure('public.staff_pair_loyalty_funding_pot_and_release_v1(uuid[], uuid, text)') IS NULL THEN RAISE EXCEPTION 'Missing bulk release RPC. Run 20260625_completion_loyalty_bulk_funding_pot_release_v1.sql first.'; END IF;

  SELECT count(*)::integer
    INTO v_existing_seed_count
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.notes ILIKE '%' || v_seed_tag || '%'
    AND lm.match_status IN ('confirmed','released_available_dashboard_credit');

  IF v_existing_seed_count > 0 THEN
    RAISE EXCEPTION 'Seed % already exists with % active loyalty match row(s). Do not reseed until the test is cleaned up or superseded.', v_seed_tag, v_existing_seed_count;
  END IF;

  SELECT
    lm.*,
    o.order_ref,
    ds.id AS source_statement_id,
    dsl.id AS source_line_id
  INTO v_base_match
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  JOIN public.dva_statement_lines dsl ON dsl.id = lm.dva_statement_line_id
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE lm.match_status = 'confirmed'
    AND COALESCE(lm.transfer_pair_status, 'source_out_reserved') IN ('source_out_reserved','paired_ready_to_release')
    AND lm.destination_in_statement_line_id IS NULL
    AND lm.credit_ledger_id IS NULL
    AND lm.funding_confirmation_id IS NULL
  ORDER BY lm.created_at DESC, lm.id DESC
  LIMIT 1;

  IF v_base_match.id IS NULL THEN
    RAISE EXCEPTION 'No existing staged completion-loyalty OUT row found to clone safely. Create one normal single-row reserved OUT first.';
  END IF;

  v_importer_id := v_base_match.importer_id;

  SELECT COALESCE(v_base_match.created_by_staff_id, s.id), s.auth_user_id
    INTO v_staff_id, v_auth_user_id
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin','supervisor')
  ORDER BY CASE WHEN s.id = v_base_match.created_by_staff_id THEN 0 WHEN s.role_type = 'admin' THEN 1 ELSE 2 END,
           s.created_at NULLS LAST,
           s.id
  LIMIT 1;

  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'No active admin/supervisor staff row found for seed audit fields.'; END IF;

  SELECT to_jsonb(o) INTO v_base_order_json
  FROM public.orders o
  WHERE o.id = v_base_match.completed_order_id;

  SELECT to_jsonb(a) INTO v_base_approval_json
  FROM public.completion_loyalty_reward_approvals a
  WHERE a.id = v_base_match.approval_id;

  SELECT to_jsonb(ds) INTO v_base_statement_json
  FROM public.dva_statements ds
  WHERE ds.id = v_base_match.source_statement_id;

  SELECT to_jsonb(dsl) INTO v_base_line_json
  FROM public.dva_statement_lines dsl
  WHERE dsl.id = v_base_match.source_line_id;

  IF v_base_order_json IS NULL OR v_base_approval_json IS NULL OR v_base_statement_json IS NULL OR v_base_line_json IS NULL THEN
    RAISE EXCEPTION 'Could not load base order/approval/statement/line for cloning.';
  END IF;

  -- Clone two test orders from the existing clean completed order shape.
  v_json := v_base_order_json || jsonb_build_object(
    'id', v_order_a_id::text,
    'order_ref', v_order_a_ref,
    'payment_auth_id', v_seed_tag || '-AUTH-A',
    'importer_id', v_importer_id::text,
    'created_at', now(),
    'updated_at', now(),
    'completed_at', now()
  );
  INSERT INTO public.orders SELECT * FROM jsonb_populate_record(NULL::public.orders, v_json);

  v_json := v_base_order_json || jsonb_build_object(
    'id', v_order_b_id::text,
    'order_ref', v_order_b_ref,
    'payment_auth_id', v_seed_tag || '-AUTH-B',
    'importer_id', v_importer_id::text,
    'created_at', now(),
    'updated_at', now(),
    'completed_at', now()
  );
  INSERT INTO public.orders SELECT * FROM jsonb_populate_record(NULL::public.orders, v_json);

  -- Clone two approval rows but keep them pending funding, with no credit released.
  v_json := v_base_approval_json || jsonb_build_object(
    'id', v_approval_a_id::text,
    'order_id', v_order_a_id::text,
    'importer_id', v_importer_id::text,
    'approved_by_staff_id', v_staff_id::text,
    'proposal_snapshot_json', jsonb_build_object('seed', v_seed_tag, 'order_ref', v_order_a_ref, 'cloned_from_order_ref', v_base_match.order_ref),
    'qualifying_signed_gross_basis_gbp', 135.00,
    'qualifying_net_spend_gbp', 135.00,
    'default_reward_rate_pct', 10,
    'suggested_reward_gbp', v_reward_amount,
    'approved_reward_rate_pct', 10,
    'approved_amount_gbp', v_reward_amount,
    'reason', 'completion_loyalty_reward',
    'notes', v_seed_tag || ' approval A',
    'credit_ledger_id', NULL,
    'approval_status', 'approved_pending_funding',
    'funding_confirmation_id', NULL,
    'funding_confirmed_at', NULL,
    'released_at', NULL,
    'created_at', now(),
    'updated_at', now()
  );
  INSERT INTO public.completion_loyalty_reward_approvals SELECT * FROM jsonb_populate_record(NULL::public.completion_loyalty_reward_approvals, v_json);

  v_json := v_base_approval_json || jsonb_build_object(
    'id', v_approval_b_id::text,
    'order_id', v_order_b_id::text,
    'importer_id', v_importer_id::text,
    'approved_by_staff_id', v_staff_id::text,
    'proposal_snapshot_json', jsonb_build_object('seed', v_seed_tag, 'order_ref', v_order_b_ref, 'cloned_from_order_ref', v_base_match.order_ref),
    'qualifying_signed_gross_basis_gbp', 135.00,
    'qualifying_net_spend_gbp', 135.00,
    'default_reward_rate_pct', 10,
    'suggested_reward_gbp', v_reward_amount,
    'approved_reward_rate_pct', 10,
    'approved_amount_gbp', v_reward_amount,
    'reason', 'completion_loyalty_reward',
    'notes', v_seed_tag || ' approval B',
    'credit_ledger_id', NULL,
    'approval_status', 'approved_pending_funding',
    'funding_confirmation_id', NULL,
    'funding_confirmed_at', NULL,
    'released_at', NULL,
    'created_at', now(),
    'updated_at', now()
  );
  INSERT INTO public.completion_loyalty_reward_approvals SELECT * FROM jsonb_populate_record(NULL::public.completion_loyalty_reward_approvals, v_json);

  -- Create one source OUT statement and one same-importer destination IN statement.
  v_json := v_base_statement_json || jsonb_build_object(
    'id', v_source_statement_id::text,
    'importer_id', NULL,
    'source_bank', 'other',
    'csv_url', 'manual-seed://' || v_seed_tag || '/main-bank-out',
    'statement_period_from', '2026-06-25',
    'statement_period_to', '2026-06-25',
    'parse_status', 'parsed',
    'parse_errors_json', NULL,
    'uploaded_by_staff_id', v_staff_id::text,
    'uploaded_at', now(),
    'statement_account_context', 'main_company_bank_account',
    'statement_account_key', 'main_company_bank_account',
    'statement_account_label', 'Main company bank account'
  );
  INSERT INTO public.dva_statements SELECT * FROM jsonb_populate_record(NULL::public.dva_statements, v_json);

  v_json := v_base_statement_json || jsonb_build_object(
    'id', v_dest_statement_id::text,
    'importer_id', v_importer_id::text,
    'source_bank', 'other',
    'csv_url', 'manual-seed://' || v_seed_tag || '/dva-card-in',
    'statement_period_from', '2026-06-25',
    'statement_period_to', '2026-06-25',
    'parse_status', 'parsed',
    'parse_errors_json', NULL,
    'uploaded_by_staff_id', v_staff_id::text,
    'uploaded_at', now(),
    'statement_account_context', 'importer_dva_card_account',
    'statement_account_key', v_importer_id::text,
    'statement_account_label', 'Importer DVA/card account'
  );
  INSERT INTO public.dva_statements SELECT * FROM jsonb_populate_record(NULL::public.dva_statements, v_json);

  v_json := v_base_line_json || jsonb_build_object(
    'id', v_source_out_line_id::text,
    'dva_statement_id', v_source_statement_id::text,
    'line_order', 1,
    'statement_date', '2026-06-25',
    'reference_raw', 'TEST-BULK-LOYALTY-MAIN-BANK-OUT-' || left(v_source_out_line_id::text, 8),
    'direction', 'out',
    'amount_local_ccy', v_total_amount,
    'local_ccy', 'GBP',
    'fx_rate_applied', 1,
    'card_markup_pct_applied', 0,
    'amount_gbp_equivalent', v_total_amount,
    'auth_id_ref', 'BULK-POT-OUT-' || left(v_source_out_line_id::text, 8),
    'retailer_name_ref', NULL,
    'match_status', 'unmatched',
    'created_at', now()
  );
  INSERT INTO public.dva_statement_lines SELECT * FROM jsonb_populate_record(NULL::public.dva_statement_lines, v_json);

  v_json := v_base_line_json || jsonb_build_object(
    'id', v_dest_in_line_id::text,
    'dva_statement_id', v_dest_statement_id::text,
    'line_order', 1,
    'statement_date', '2026-06-25',
    'reference_raw', 'TEST-BULK-LOYALTY-DVA-CARD-IN-' || left(v_dest_in_line_id::text, 8),
    'direction', 'in',
    'amount_local_ccy', v_total_amount,
    'local_ccy', 'GBP',
    'fx_rate_applied', 1,
    'card_markup_pct_applied', 0,
    'amount_gbp_equivalent', v_total_amount,
    'auth_id_ref', 'BULK-POT-IN-' || left(v_dest_in_line_id::text, 8),
    'retailer_name_ref', NULL,
    'match_status', 'unmatched',
    'created_at', now()
  );
  INSERT INTO public.dva_statement_lines SELECT * FROM jsonb_populate_record(NULL::public.dva_statement_lines, v_json);

  -- Create two staged OUT reservations against the same source OUT line.
  INSERT INTO public.main_bank_completion_loyalty_funding_matches (
    id,
    dva_statement_line_id,
    completed_order_id,
    importer_id,
    approval_id,
    funding_confirmation_id,
    credit_ledger_id,
    matched_gbp_amount,
    match_status,
    notes,
    created_by_staff_id,
    created_by_auth_user_id,
    transfer_pair_status,
    activation_route,
    card_used_by,
    destination_in_statement_line_id
  ) VALUES
  (
    v_match_a_id,
    v_source_out_line_id,
    v_order_a_id,
    v_importer_id,
    v_approval_a_id,
    NULL,
    NULL,
    v_reward_amount,
    'confirmed',
    v_seed_tag || ' match A',
    v_staff_id,
    v_auth_user_id,
    'source_out_reserved',
    'dva_account_top_up',
    'staff',
    NULL
  ),
  (
    v_match_b_id,
    v_source_out_line_id,
    v_order_b_id,
    v_importer_id,
    v_approval_b_id,
    NULL,
    NULL,
    v_reward_amount,
    'confirmed',
    v_seed_tag || ' match B',
    v_staff_id,
    v_auth_user_id,
    'source_out_reserved',
    'dva_account_top_up',
    'staff',
    NULL
  );

  RAISE NOTICE 'Seeded %: source OUT %, destination IN %, matches %, %', v_seed_tag, v_source_out_line_id, v_dest_in_line_id, v_match_a_id, v_match_b_id;
END $$;

SELECT
  'SEEDED_BULK_COMPLETION_LOYALTY_POT' AS status,
  lm.importer_id,
  min(o.order_ref) AS first_order_ref,
  max(o.order_ref) AS second_order_ref,
  lm.dva_statement_line_id AS source_out_statement_line_id,
  count(*) AS reward_rows,
  round(sum(lm.matched_gbp_amount)::numeric, 2) AS reward_total_gbp
FROM public.main_bank_completion_loyalty_funding_matches lm
JOIN public.orders o ON o.id = lm.completed_order_id
WHERE lm.notes ILIKE '%BULK-POT-SEED-V1%'
  AND lm.match_status = 'confirmed'
GROUP BY lm.importer_id, lm.dva_statement_line_id;

COMMIT;
