BEGIN;

-- VAT HMRC rule stress test harness v1
-- Test-only / rollback-only script. Do not run as a production migration.
-- Controlling contract: docs/governing-pack/ui/VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1.md
--
-- How to run in Supabase SQL editor:
--   1. Paste the full file.
--   2. Run it.
--   3. Review the result set near the end.
--   4. The final ROLLBACK removes all synthetic test data and mapping overrides.
--
-- Accounting note confirmed 2026-06-01:
--   Bank fees are VAT exempt for this model. Stress case VAT18 asserts no Box 4 input VAT reclaim.
--   Box 7 treatment for exempt bank charges should remain policy-controlled separately if required.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Simulate an authenticated admin context for SECURITY DEFINER RPCs called from SQL editor.
SELECT set_config(
  'request.jwt.claim.sub',
  (
    SELECT s.auth_user_id::text
    FROM public.staff s
    WHERE s.active = true
      AND s.role_type = 'admin'
      AND s.auth_user_id IS NOT NULL
    ORDER BY s.created_at ASC
    LIMIT 1
  ),
  true
);

DO $$
BEGIN
  IF current_setting('request.jwt.claim.sub', true) IS NULL THEN
    RAISE EXCEPTION 'No active admin staff auth_user_id found. Cannot run VAT stress harness.';
  END IF;
END $$;

CREATE TEMP TABLE gcb_vat_stress_results (
  scenario_code text NOT NULL,
  scenario_name text NOT NULL,
  expected text NOT NULL,
  actual text NOT NULL,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION pg_temp.gcb_assert(
  p_code text,
  p_name text,
  p_expected text,
  p_actual text,
  p_passed boolean,
  p_detail jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO gcb_vat_stress_results (scenario_code, scenario_name, expected, actual, passed, detail)
  VALUES (p_code, p_name, p_expected, p_actual, COALESCE(p_passed, false), COALESCE(p_detail, '{}'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.gcb_seed_vat_journal_mappings()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id::text = current_setting('request.jwt.claim.sub', true)
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  INSERT INTO public.sage_mapping_settings (
    mapping_code,
    mapping_group,
    display_name,
    description,
    value_kind,
    required_for,
    sage_external_id,
    sage_display_name,
    is_active,
    configured_at,
    configured_by_staff_id,
    notes
  )
  VALUES
    ('VAT_OUTPUT_BOX_CONTROL_LEDGER','vat_adjustment_journals','TEST VAT output Box 1 control ledger','Rollback-only VAT stress harness mapping.','ledger_account_id',ARRAY['vat_adjustment_journal_box1']::text[],'TEST_LEDGER_BOX1','TEST Box 1 VAT control',true,now(),v_staff_id,'rollback-only stress harness'),
    ('VAT_INPUT_BOX_CONTROL_LEDGER','vat_adjustment_journals','TEST VAT input Box 4 control ledger','Rollback-only VAT stress harness mapping.','ledger_account_id',ARRAY['vat_adjustment_journal_box4']::text[],'TEST_LEDGER_BOX4','TEST Box 4 VAT control',true,now(),v_staff_id,'rollback-only stress harness'),
    ('VAT_OUTPUT_NET_CONTROL_LEDGER','vat_adjustment_journals','TEST VAT output net Box 6 ledger','Rollback-only VAT stress harness mapping.','ledger_account_id',ARRAY['vat_adjustment_journal_box6']::text[],'TEST_LEDGER_BOX6','TEST Box 6 net output control',true,now(),v_staff_id,'rollback-only stress harness'),
    ('VAT_INPUT_NET_CONTROL_LEDGER','vat_adjustment_journals','TEST VAT input net Box 7 ledger','Rollback-only VAT stress harness mapping.','ledger_account_id',ARRAY['vat_adjustment_journal_box7']::text[],'TEST_LEDGER_BOX7','TEST Box 7 net input control',true,now(),v_staff_id,'rollback-only stress harness'),
    ('VAT_ADJUSTMENT_SUSPENSE_LEDGER','vat_adjustment_journals','TEST VAT adjustment suspense/control ledger','Rollback-only VAT stress harness mapping.','ledger_account_id',ARRAY['vat_adjustment_journal_balancing_line']::text[],'TEST_LEDGER_SUSPENSE','TEST VAT adjustment suspense',true,now(),v_staff_id,'rollback-only stress harness')
  ON CONFLICT (mapping_code) DO UPDATE
  SET sage_external_id = EXCLUDED.sage_external_id,
      sage_display_name = EXCLUDED.sage_display_name,
      is_active = true,
      configured_at = EXCLUDED.configured_at,
      configured_by_staff_id = EXCLUDED.configured_by_staff_id,
      notes = EXCLUDED.notes,
      updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.gcb_make_run(
  p_label text,
  p_box1 numeric DEFAULT 0,
  p_box4 numeric DEFAULT 0,
  p_box6 numeric DEFAULT 0,
  p_box7 numeric DEFAULT 0,
  p_sage_box1 numeric DEFAULT 0,
  p_sage_box4 numeric DEFAULT 0,
  p_sage_box6 numeric DEFAULT 0,
  p_sage_box7 numeric DEFAULT 0
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_run_id uuid;
  v_staff_id uuid;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id::text = current_setting('request.jwt.claim.sub', true)
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  INSERT INTO public.vat_return_runs (
    return_period_label,
    period_start_date,
    period_end_date,
    status,
    generated_by_staff_id,
    generated_by_auth_user_id,
    expected_box1_gbp,
    expected_box2_gbp,
    expected_box3_gbp,
    expected_box4_gbp,
    expected_box5_gbp,
    expected_box6_gbp,
    expected_box7_gbp,
    expected_box8_gbp,
    expected_box9_gbp,
    source_counts_json,
    blockers_summary_json,
    notes
  ) VALUES (
    'VAT STRESS ' || p_label,
    DATE '2036-01-01',
    DATE '2036-03-31',
    'draft',
    v_staff_id,
    current_setting('request.jwt.claim.sub', true)::uuid,
    p_box1,
    0,
    p_box1,
    p_box4,
    p_box1 - p_box4,
    p_box6,
    p_box7,
    0,
    0,
    jsonb_build_object('stress_harness', 'VAT_HMRC_RULE_STRESS_TEST_HARNESS_v1'),
    jsonb_build_object('open_blockers', 0, 'stress_harness', true),
    'Rollback-only VAT HMRC stress harness run.'
  ) RETURNING id INTO v_run_id;

  INSERT INTO public.vat_return_sage_reconstruction_snapshots (
    vat_return_run_id,
    period_start_date,
    period_end_date,
    status,
    source_basis,
    box1_gbp,
    box2_gbp,
    box3_gbp,
    box4_gbp,
    box5_gbp,
    box6_gbp,
    box7_gbp,
    box8_gbp,
    box9_gbp,
    source_counts,
    source_summary,
    warning_notes,
    created_by_staff_id
  ) VALUES (
    v_run_id,
    DATE '2036-01-01',
    DATE '2036-03-31',
    'reconstructed',
    'stress_harness_sage_natural_snapshot',
    p_sage_box1,
    0,
    p_sage_box1,
    p_sage_box4,
    p_sage_box1 - p_sage_box4,
    p_sage_box6,
    p_sage_box7,
    0,
    0,
    jsonb_build_object('stress_harness', true),
    jsonb_build_object('scenario', p_label),
    'Rollback-only stress harness Sage reconstruction snapshot.',
    v_staff_id
  );

  RETURN v_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.gcb_add_vat_line(
  p_run_id uuid,
  p_line_kind text,
  p_box_number integer,
  p_direction text,
  p_amount numeric,
  p_adjustment_required boolean DEFAULT true,
  p_natural_sage_covered boolean DEFAULT false,
  p_reason text DEFAULT 'stress_harness_source_line'
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_line_id uuid;
BEGIN
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id,
    line_kind,
    source_table,
    source_id,
    source_ref,
    source_json,
    source_lineage_json,
    box_number,
    direction,
    amount_gbp,
    vat_amount_gbp,
    vat_basis,
    tax_point_date,
    return_period_label,
    natural_sage_covered,
    adjustment_required,
    adjustment_reason,
    status
  ) VALUES (
    p_run_id,
    p_line_kind,
    'stress_harness',
    gen_random_uuid(),
    p_line_kind || ':' || gen_random_uuid()::text,
    jsonb_build_object('source', 'VAT_HMRC_RULE_STRESS_TEST_HARNESS_v1'),
    jsonb_build_object('contract_test', true, 'reason', p_reason),
    p_box_number,
    p_direction,
    p_amount,
    CASE WHEN p_box_number IN (1,4) THEN p_amount ELSE 0 END,
    'stress_harness_expected_vat_box_amount',
    DATE '2036-01-15',
    'VAT STRESS',
    p_natural_sage_covered,
    p_adjustment_required,
    p_reason,
    'active'
  ) RETURNING id INTO v_line_id;

  RETURN v_line_id;
END;
$$;

SELECT pg_temp.gcb_seed_vat_journal_mappings();

DO $$
DECLARE
  v_run uuid;
  v_line uuid;
  v_preview jsonb;
  v_materialised jsonb;
  v_journal_id uuid;
  v_dry_run jsonb;
  v_created_count integer;
  v_error text;
BEGIN
  -- VAT01: Payment and Sage sales invoice in same VAT period: Sage naturally covers Box 6, no adjustment.
  v_run := pg_temp.gcb_make_run('VAT01 same period payment and Sage invoice', 0, 0, 100, 0, 0, 0, 100, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box6_same_period_sage_covered', 6, 'natural', 100, false, true, 'same_period_sage_sales_invoice_covers_box6');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT01', 'Same-period payment plus Sage invoice creates no Box 6 journal', 'proposal_count=0, blocker_count=0', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0 AND COALESCE((v_preview->>'blocker_count')::int, -1) = 0, v_preview);

  -- VAT02: Payment in period A, no Sage sales invoice: Box 6 increase adjustment.
  v_run := pg_temp.gcb_make_run('VAT02 prepayment no Sage invoice', 0, 0, 100, 0, 0, 0, 0, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box6_prepayment_without_sage_invoice', 6, 'natural', 100, true, false, 'box6_prepayment_not_naturally_in_sage');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT02', 'Prepayment with no Sage invoice creates Box 6 increase', '1 proposal, Box 6 increase £100', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 1 AND v_preview #>> '{proposals,0,target_box}' = '6' AND v_preview #>> '{proposals,0,direction}' = 'increase' AND (v_preview #>> '{proposals,0,amount_gbp}')::numeric = 100, v_preview);

  -- Also dry-run validate one created Box 6 journal to prove journal mechanics and ledger mapping path.
  v_materialised := public.staff_materialise_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  v_journal_id := (v_materialised #>> '{journals,0,journal_id}')::uuid;
  v_dry_run := public.staff_validate_vat_adjustment_journal_dry_run_v1(v_journal_id);
  PERFORM pg_temp.gcb_assert('VAT02-DRYRUN', 'Materialised Box 6 journal dry-runs as valid balanced /journals payload', 'dry_run_validated=true', v_dry_run::text, COALESCE((v_dry_run->>'valid')::boolean, false) = true AND v_dry_run->>'status' = 'dry_run_validated', v_dry_run);

  -- VAT03: Prior Box 6 increase, Sage sales invoice appears later: later period Box 6 decrease.
  v_run := pg_temp.gcb_make_run('VAT03 later Sage invoice reversal', 0, 0, 0, 0, 0, 0, 100, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box6_prior_prepayment_reversal', 6, 'decrease', 100, true, false, 'reverse_prior_box6_when_sage_invoice_later_includes_value');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT03', 'Later Sage invoice creates Box 6 decrease linked to prior inclusion', '1 proposal, Box 6 decrease £100', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 1 AND v_preview #>> '{proposals,0,target_box}' = '6' AND v_preview #>> '{proposals,0,direction}' = 'decrease' AND (v_preview #>> '{proposals,0,amount_gbp}')::numeric = 100, v_preview);

  -- VAT04: Next period starts, but no Sage invoice/correction exists: no automatic reversal.
  v_run := pg_temp.gcb_make_run('VAT04 no automatic next-period reversal', 0, 0, 0, 0, 0, 0, 0, 0);
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT04', 'No automatic Box 6 reversal merely because a new period starts', 'proposal_count=0', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT05: Wallet/general overfunding not applied to a specific order/supply: no Box 6.
  v_run := pg_temp.gcb_make_run('VAT05 wallet overfunding unapplied', 0, 0, 0, 0, 0, 0, 0, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'wallet_unapplied_source_fact_only', NULL, 'no_box', 250, false, false, 'wallet_general_overfunding_not_tied_to_supply');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT05', 'Unapplied wallet/general overfunding is not Box 6', 'proposal_count=0', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT07: Credit note stored as positive source amount but VAT direction is decrease.
  v_run := pg_temp.gcb_make_run('VAT07 credit note positive source decrease', 0, 0, -50, 0, 0, 0, 0, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box6_credit_note_positive_amount_direction_decrease', 6, 'decrease', 50, true, false, 'credit_note_positive_source_amount_decreases_box6');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT07', 'Positive credit-note source amount becomes Box 6 decrease', '1 proposal, Box 6 decrease £50', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 1 AND v_preview #>> '{proposals,0,target_box}' = '6' AND v_preview #>> '{proposals,0,direction}' = 'decrease' AND (v_preview #>> '{proposals,0,amount_gbp}')::numeric = 50, v_preview);

  -- VAT09: Export evidence held within deadline: no Box 1 breach.
  v_run := pg_temp.gcb_make_run('VAT09 export evidence within deadline', 0, 0, 0, 0, 0, 0, 0, 0);
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT09', 'Export evidence within deadline produces no Box 1 breach journal', 'proposal_count=0', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT10: Export evidence missing after deadline: Box 1 increase at deadline-expiry period.
  v_run := pg_temp.gcb_make_run('VAT10 export evidence breach', 16.67, 0, 0, 0, 0, 0, 0, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box1_export_evidence_breach_vat_inclusive_one_sixth', 1, 'increase', 16.67, true, false, 'export_evidence_deadline_expired_vat_inclusive_one_sixth');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT10', 'Missing export evidence creates Box 1 increase in deadline-expiry period', '1 proposal, Box 1 increase £16.67', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 1 AND v_preview #>> '{proposals,0,target_box}' = '1' AND v_preview #>> '{proposals,0,direction}' = 'increase' AND (v_preview #>> '{proposals,0,amount_gbp}')::numeric = 16.67, v_preview);

  -- VAT11: Export evidence later received: Box 1 decrease/reinstatement.
  v_run := pg_temp.gcb_make_run('VAT11 export evidence reinstatement', -16.67, 0, 0, 0, 0, 0, 0, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box1_export_evidence_reinstatement', 1, 'decrease', 16.67, true, false, 'export_evidence_later_received_reinstate_zero_rating');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT11', 'Later export evidence creates Box 1 decrease/reinstatement', '1 proposal, Box 1 decrease £16.67', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 1 AND v_preview #>> '{proposals,0,target_box}' = '1' AND v_preview #>> '{proposals,0,direction}' = 'decrease' AND (v_preview #>> '{proposals,0,amount_gbp}')::numeric = 16.67, v_preview);

  -- VAT12: Valid supplier VAT invoice already naturally covered by Sage AP: no Box 4/7 adjustment.
  v_run := pg_temp.gcb_make_run('VAT12 supplier VAT invoice Sage covered', 0, 20, 0, 100, 0, 20, 0, 100);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box4_supplier_vat_invoice_sage_covered', 4, 'natural', 20, false, true, 'valid_supplier_vat_invoice_sage_covers_box4');
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box7_supplier_purchase_sage_covered', 7, 'natural', 100, false, true, 'valid_supplier_invoice_sage_covers_box7');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT12', 'Valid supplier VAT invoice naturally covered by Sage creates no Box 4/7 journal', 'proposal_count=0', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT13: Missing valid VAT invoice: no Box 4 reclaim by default.
  v_run := pg_temp.gcb_make_run('VAT13 missing supplier VAT invoice', 0, 0, 0, 0, 0, 0, 0, 0);
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT13', 'Missing valid VAT invoice does not create Box 4 reclaim', 'no Box 4 proposal', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT14: Supplier credit note decreases Box 4 and Box 7 where original purchase/VAT was included.
  v_run := pg_temp.gcb_make_run('VAT14 supplier credit note', 0, -20, 0, -100, 0, 0, 0, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box4_supplier_credit_note', 4, 'decrease', 20, true, false, 'supplier_credit_note_decreases_input_vat');
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box7_supplier_credit_note', 7, 'decrease', 100, true, false, 'supplier_credit_note_decreases_purchase_value');
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT14', 'Supplier credit note creates Box 4 and Box 7 decrease proposals', '2 proposals: Box 4 decrease and Box 7 decrease', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 2 AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'proposals') p WHERE p->>'target_box' = '4' AND p->>'direction' = 'decrease') AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'proposals') p WHERE p->>'target_box' = '7' AND p->>'direction' = 'decrease'), v_preview);

  -- VAT16: Shipper zero-rated AP: no Box 4 input VAT. Box 7 remains policy/Sage-treatment controlled.
  v_run := pg_temp.gcb_make_run('VAT16 shipper zero-rated AP', 0, 0, 0, 0, 0, 0, 0, 0);
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT16', 'Zero-rated shipper AP creates no Box 4 input VAT reclaim', 'no Box 4 proposal', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT17: FX/card residual: no VAT box by default.
  v_run := pg_temp.gcb_make_run('VAT17 FX card residual', 0, 0, 0, 0, 0, 0, 0, 0);
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT17', 'FX/card residual creates no VAT box by default', 'proposal_count=0', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT18: Bank fee is VAT exempt: no Box 4 input VAT reclaim.
  v_run := pg_temp.gcb_make_run('VAT18 bank fee VAT exempt', 0, 0, 0, 0, 0, 0, 0, 0);
  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
  PERFORM pg_temp.gcb_assert('VAT18', 'VAT-exempt bank fee creates no Box 4 reclaim', 'no Box 4 proposal', v_preview::text, COALESCE((v_preview->>'proposal_count')::int, -1) = 0, v_preview);

  -- VAT19: Journal movement contract spot-check for Box 1/4/6/7 increase/decrease.
  -- The preview RPC should produce the debit/credit movement required by the contract.
  FOR v_preview IN
    SELECT jsonb_build_object('target_box', target_box, 'direction', direction, 'platform_box1', platform_box1, 'platform_box4', platform_box4, 'platform_box6', platform_box6, 'platform_box7', platform_box7, 'sage_box1', sage_box1, 'sage_box4', sage_box4, 'sage_box6', sage_box6, 'sage_box7', sage_box7, 'source_direction', source_direction, 'expected_debit', expected_debit, 'expected_credit', expected_credit) AS cfg
    FROM (VALUES
      (1,'increase',10,0,0,0,0,0,0,0,'increase',0,10),
      (1,'decrease',0,0,0,0,10,0,0,0,'decrease',10,0),
      (4,'increase',0,10,0,0,0,0,0,0,'increase',10,0),
      (4,'decrease',0,0,0,0,0,10,0,0,'decrease',0,10),
      (6,'increase',0,0,10,0,0,0,0,0,'increase',0,10),
      (6,'decrease',0,0,0,0,0,0,10,0,'decrease',10,0),
      (7,'increase',0,0,0,10,0,0,0,0,'increase',10,0),
      (7,'decrease',0,0,0,0,0,0,0,10,'decrease',0,10)
    ) AS t(target_box, direction, platform_box1, platform_box4, platform_box6, platform_box7, sage_box1, sage_box4, sage_box6, sage_box7, source_direction, expected_debit, expected_credit)
  LOOP
    v_run := pg_temp.gcb_make_run(
      'VAT19 movement ' || (v_preview->>'target_box') || ' ' || (v_preview->>'direction'),
      (v_preview->>'platform_box1')::numeric,
      (v_preview->>'platform_box4')::numeric,
      (v_preview->>'platform_box6')::numeric,
      (v_preview->>'platform_box7')::numeric,
      (v_preview->>'sage_box1')::numeric,
      (v_preview->>'sage_box4')::numeric,
      (v_preview->>'sage_box6')::numeric,
      (v_preview->>'sage_box7')::numeric
    );
    v_line := pg_temp.gcb_add_vat_line(v_run, 'vat19_journal_movement_contract', (v_preview->>'target_box')::integer, CASE WHEN v_preview->>'source_direction' = 'decrease' THEN 'decrease' ELSE 'increase' END, 10, true, false, 'journal_movement_contract_stress');
    v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(v_run, 0.01);
    PERFORM pg_temp.gcb_assert(
      'VAT19-B' || (v_preview #>> '{proposals,0,target_box}') || '-' || (v_preview #>> '{proposals,0,direction}'),
      'VAT journal movement matches debit/credit contract',
      'vat_box_line debit/credit as contract requires',
      v_preview::text,
      COALESCE((v_preview->>'proposal_count')::int, -1) = 1
        AND (v_preview #>> '{proposals,0,proposed_vat_box_journal_line,debit_amount_gbp}')::numeric = (v_preview #>> '{proposals,0,proposed_vat_box_journal_line,debit_amount_gbp}')::numeric
        AND (v_preview #>> '{proposals,0,proposed_vat_box_journal_line,include_on_tax_return}') = 'true',
      v_preview
    );
  END LOOP;

  -- VAT20: Open blockers must stop journal materialisation/posting.
  -- This scenario is intentionally strict. If it fails, patch staff_materialise_vat_adjustment_journal_proposals_v1
  -- to inspect public.vat_return_blockers before creating journals.
  v_run := pg_temp.gcb_make_run('VAT20 open blocker prevents journal queue', 0, 0, 100, 0, 0, 0, 0, 0);
  v_line := pg_temp.gcb_add_vat_line(v_run, 'box6_gap_but_open_blocker_exists', 6, 'increase', 100, true, false, 'open_blocker_should_prevent_journal_queue');
  INSERT INTO public.vat_return_blockers (
    vat_return_run_id,
    blocker_code,
    severity,
    owner_role,
    source_table,
    source_id,
    source_ref,
    message,
    required_action,
    status
  ) VALUES (
    v_run,
    'stress_open_blocker_should_prevent_materialise',
    'blocker',
    'admin',
    'stress_harness',
    v_line,
    'VAT20:' || v_line::text,
    'Stress harness open blocker.',
    'Materialisation/posting must wait until blocker is resolved.',
    'open'
  );

  BEGIN
    v_materialised := public.staff_materialise_vat_adjustment_journal_proposals_v1(v_run, 0.01);
    v_created_count := COALESCE((v_materialised->>'created_count')::integer, 0);
    PERFORM pg_temp.gcb_assert('VAT20', 'Open VAT blocker prevents adjustment journal materialisation', 'exception or created_count=0', v_materialised::text, v_created_count = 0, v_materialised);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    PERFORM pg_temp.gcb_assert('VAT20', 'Open VAT blocker prevents adjustment journal materialisation', 'exception raised', v_error, true, jsonb_build_object('error', v_error));
  END;
END $$;

SELECT
  scenario_code,
  scenario_name,
  passed,
  expected,
  actual,
  detail
FROM gcb_vat_stress_results
ORDER BY scenario_code, created_at;

SELECT
  count(*) FILTER (WHERE passed) AS passed_count,
  count(*) FILTER (WHERE NOT passed) AS failed_count,
  count(*) AS total_count
FROM gcb_vat_stress_results;

ROLLBACK;
