-- Supplier payment behavioural regression closure pack B v1
-- Scenarios:
--   1. Released loyalty only resolves to the exact governed loyalty wallet.
--   2. Mixed funding (cash + loyalty) with two exact candidate sources fails closed.
--
-- Safety:
--   * Uses existing valid paired-released loyalty data only as a shape/template.
--   * Creates isolated test rows with fresh UUIDs.
--   * Calls the real readiness and final allocation functions.
--   * Finishes with ROLLBACK; no test data persists and nothing posts to Sage.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE supplier_payment_pack_b_results (
  scenario_no integer PRIMARY KEY,
  scenario text NOT NULL,
  status text NOT NULL CHECK (status IN ('PASS','FAIL')),
  finding text NOT NULL,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

DO $$
DECLARE
  v_staff_id uuid;
  v_auth_user_id uuid;

  v_template_match record;
  v_template_invoice record;
  v_template_order_json jsonb;
  v_template_credit_json jsonb;
  v_template_approval_json jsonb;
  v_template_line_json jsonb;
  v_template_invoice_json jsonb;

  v_wallet_code text;
  v_expected_mapping text;
  v_json jsonb;
  v_result jsonb;
  v_ready boolean;
  v_blocker text;
  v_error text;
  v_count integer;
  v_next_line_order integer;

  -- Scenario 1 ids.
  s1_order_id uuid := gen_random_uuid();
  s1_credit_id uuid := gen_random_uuid();
  s1_debit_id uuid := gen_random_uuid();
  s1_approval_id uuid := gen_random_uuid();
  s1_match_id uuid := gen_random_uuid();
  s1_destination_in_line_id uuid := gen_random_uuid();
  s1_payment_out_line_id uuid := gen_random_uuid();
  s1_invoice_id uuid := gen_random_uuid();
  s1_amount numeric(12,2) := 100.00;

  -- Scenario 2 ids.
  s2_order_id uuid := gen_random_uuid();
  s2_credit_id uuid := gen_random_uuid();
  s2_debit_id uuid := gen_random_uuid();
  s2_approval_id uuid := gen_random_uuid();
  s2_match_id uuid := gen_random_uuid();
  s2_destination_in_line_id uuid := gen_random_uuid();
  s2_cash_in_line_id uuid := gen_random_uuid();
  s2_cash_reconciliation_id uuid := gen_random_uuid();
  s2_payment_out_line_id uuid := gen_random_uuid();
  s2_invoice_id uuid := gen_random_uuid();
  s2_leg_amount numeric(12,2) := 100.00;
BEGIN
  -- Required governed objects.
  IF to_regprocedure('public.internal_supplier_payment_readiness_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_supplier_payment_readiness_v1(uuid)';
  END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)';
  END IF;
  IF to_regprocedure('public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_completion_loyalty_statement_ledger_resolver_v1(uuid)';
  END IF;

  SELECT s.id, s.auth_user_id
    INTO v_staff_id, v_auth_user_id
  FROM public.staff s
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
    AND s.role_type IN ('admin','supervisor')
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.created_at, s.id
  LIMIT 1;

  IF v_staff_id IS NULL OR v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'No active admin/supervisor staff row with auth_user_id is available';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::text, true);

  -- Find one genuinely valid paired-released loyalty row. This is used only to
  -- preserve the current live table shapes and destination-wallet configuration.
  SELECT
    lm.*,
    o.retailer_id,
    dst.dsl_json AS destination_line_json,
    resolver.resolved_wallet_code,
    resolver.resolved_mapping_code
  INTO v_template_match
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  JOIN LATERAL (
    SELECT to_jsonb(dsl) AS dsl_json
    FROM public.dva_statement_lines dsl
    WHERE dsl.id = lm.destination_in_statement_line_id
  ) dst ON true
  JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(lm.destination_in_statement_line_id) resolver
    ON resolver.blocker IS NULL
   AND resolver.resolved_wallet_code IN ('virtual_gbp_wallet','dva_ghs_wallet')
  WHERE lm.match_status = 'released_available_dashboard_credit'
    AND lm.transfer_pair_status = 'paired_released'
    AND lm.destination_in_statement_line_id IS NOT NULL
    AND lm.credit_ledger_id IS NOT NULL
    AND lm.approval_id IS NOT NULL
  ORDER BY lm.created_at DESC, lm.id DESC
  LIMIT 1;

  IF v_template_match.id IS NULL THEN
    RAISE EXCEPTION 'No valid paired-released completion-loyalty row exists. Pair and release one normal loyalty transfer before running Pack B.';
  END IF;

  SELECT to_jsonb(o) INTO v_template_order_json
  FROM public.orders o
  WHERE o.id = v_template_match.completed_order_id;

  SELECT to_jsonb(c) INTO v_template_credit_json
  FROM public.importer_credit_ledger c
  WHERE c.id = v_template_match.credit_ledger_id;

  SELECT to_jsonb(a) INTO v_template_approval_json
  FROM public.completion_loyalty_reward_approvals a
  WHERE a.id = v_template_match.approval_id;

  v_template_line_json := v_template_match.destination_line_json;
  v_wallet_code := v_template_match.resolved_wallet_code;
  v_expected_mapping := CASE v_wallet_code
    WHEN 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
    WHEN 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
    ELSE NULL
  END;

  IF v_template_order_json IS NULL OR v_template_credit_json IS NULL OR v_template_approval_json IS NULL OR v_template_line_json IS NULL OR v_expected_mapping IS NULL THEN
    RAISE EXCEPTION 'Could not load complete paired-released loyalty fixture shape';
  END IF;

  SELECT si.*, to_jsonb(si) AS invoice_json
    INTO v_template_invoice
  FROM public.supplier_invoices si
  WHERE si.review_status = 'approved_current'
    AND COALESCE(si.ocr_invoice_total_gbp, si.reconciliation_gbp_total) > 0
  ORDER BY si.reviewed_at DESC NULLS LAST, si.created_at DESC NULLS LAST, si.id DESC
  LIMIT 1;

  IF v_template_invoice.id IS NULL THEN
    RAISE EXCEPTION 'No approved_current supplier invoice exists to provide the current invoice row shape';
  END IF;
  v_template_invoice_json := v_template_invoice.invoice_json;

  SELECT COALESCE(MAX(dsl.line_order), 0) + 1000
    INTO v_next_line_order
  FROM public.dva_statement_lines dsl
  WHERE dsl.dva_statement_id = (v_template_line_json->>'dva_statement_id')::uuid;

  -----------------------------------------------------------------------------
  -- Scenario 1: released loyalty only.
  -----------------------------------------------------------------------------
  v_json := v_template_order_json || jsonb_build_object(
    'id', s1_order_id,
    'order_ref', 'REG-PACK-B-LOYALTY-' || left(s1_order_id::text, 8),
    'payment_auth_id', 'REG-PACK-B-LOYALTY-' || s1_order_id::text,
    'order_type', 'original',
    'order_total_gbp_declared', s1_amount,
    'funded_at', now(),
    'status', 'evidence_collecting',
    'created_at', now(),
    'updated_at', now(),
    'completed_at', null
  );
  INSERT INTO public.orders SELECT * FROM jsonb_populate_record(NULL::public.orders, v_json);

  v_json := v_template_line_json || jsonb_build_object(
    'id', s1_destination_in_line_id,
    'line_order', v_next_line_order,
    'direction', 'in',
    'amount_local_ccy', s1_amount,
    'amount_gbp_equivalent', s1_amount,
    'reference_raw', 'REG PACK B LOYALTY DESTINATION IN',
    'match_status', 'confirmed',
    'created_at', now()
  );
  INSERT INTO public.dva_statement_lines SELECT * FROM jsonb_populate_record(NULL::public.dva_statement_lines, v_json);

  v_json := v_template_credit_json || jsonb_build_object(
    'id', s1_credit_id,
    'importer_id', v_template_match.importer_id,
    'entry_type', 'manual_credit',
    'source_table', 'completion_loyalty_reward_funding_confirmations',
    'source_id', gen_random_uuid(),
    'linked_order_id', s1_order_id,
    'linked_dispute_id', null,
    'direction', 'credit',
    'amount_gbp', s1_amount,
    'amount_local_ccy', s1_amount,
    'local_ccy', 'GBP',
    'source_type', 'completion_loyalty_reward',
    'source_entity_type', 'order',
    'source_entity_id', s1_order_id,
    'applied_to_order_id', null,
    'lock_reason', null,
    'created_by_staff_id', v_staff_id,
    'effective_at', now(),
    'created_at', now(),
    'notes', 'Regression Pack B scenario 1 released loyalty source lot.'
  );
  INSERT INTO public.importer_credit_ledger SELECT * FROM jsonb_populate_record(NULL::public.importer_credit_ledger, v_json);

  v_json := v_template_approval_json || jsonb_build_object(
    'id', s1_approval_id,
    'order_id', s1_order_id,
    'importer_id', v_template_match.importer_id,
    'approved_by_staff_id', v_staff_id,
    'qualifying_signed_gross_basis_gbp', s1_amount,
    'qualifying_net_spend_gbp', s1_amount,
    'suggested_reward_gbp', s1_amount,
    'approved_amount_gbp', s1_amount,
    'credit_ledger_id', s1_credit_id,
    'approval_status', 'released_available_dashboard_credit',
    'funding_confirmation_id', null,
    'created_at', now(),
    'updated_at', now(),
    'notes', 'Regression Pack B scenario 1 approval fixture.'
  );
  INSERT INTO public.completion_loyalty_reward_approvals
  SELECT * FROM jsonb_populate_record(NULL::public.completion_loyalty_reward_approvals, v_json);

  INSERT INTO public.main_bank_completion_loyalty_funding_matches (
    id, dva_statement_line_id, completed_order_id, importer_id, approval_id,
    funding_confirmation_id, credit_ledger_id, matched_gbp_amount, match_status,
    notes, created_by_staff_id, created_by_auth_user_id, created_at,
    destination_in_statement_line_id, activation_route, card_used_by,
    transfer_pair_status, paired_at, paired_by_staff_id, paired_by_auth_user_id,
    variance_gbp
  ) VALUES (
    s1_match_id, v_template_match.dva_statement_line_id, s1_order_id,
    v_template_match.importer_id, s1_approval_id, NULL, s1_credit_id,
    s1_amount, 'released_available_dashboard_credit',
    'Regression Pack B scenario 1 paired-released fixture.', v_staff_id,
    v_auth_user_id, now(), s1_destination_in_line_id,
    COALESCE(v_template_match.activation_route, 'dva_account_top_up'),
    COALESCE(v_template_match.card_used_by, 'staff'), 'paired_released', now(),
    v_staff_id, v_auth_user_id, 0
  );

  -- Exact source-lot application debit. The installed ledger trigger should create
  -- the credit_applied event; the fallback insert below makes the fixture explicit
  -- without duplicating it when the trigger is active.
  v_json := v_template_credit_json || jsonb_build_object(
    'id', s1_debit_id,
    'importer_id', v_template_match.importer_id,
    'entry_type', 'applied_to_order',
    'source_table', 'importer_credit_ledger',
    'source_id', s1_credit_id,
    'linked_order_id', s1_order_id,
    'linked_dispute_id', null,
    'direction', 'debit',
    'amount_gbp', s1_amount,
    'amount_local_ccy', s1_amount,
    'local_ccy', 'GBP',
    'source_type', 'credit_application',
    'source_entity_type', 'importer_credit_ledger',
    'source_entity_id', s1_credit_id,
    'applied_to_order_id', s1_order_id,
    'lock_reason', null,
    'created_by_staff_id', v_staff_id,
    'effective_at', now(),
    'created_at', now(),
    'notes', 'Regression Pack B scenario 1 exact loyalty application debit.'
  );
  INSERT INTO public.importer_credit_ledger SELECT * FROM jsonb_populate_record(NULL::public.importer_credit_ledger, v_json);

  INSERT INTO public.order_funding_events (
    order_id, event_type, amount_gbp, source_ref, source_entity_type,
    source_entity_id, created_by_staff_id, created_at, notes
  )
  SELECT s1_order_id, 'credit_applied', s1_amount,
         'importer_credit_ledger:' || s1_debit_id::text,
         'importer_credit_ledger', s1_debit_id, v_staff_id, now(),
         'Regression Pack B scenario 1 fallback funding event.'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.order_funding_events ofe
    WHERE ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
      AND ofe.source_entity_id = s1_debit_id
  );

  v_json := v_template_invoice_json || jsonb_build_object(
    'id', s1_invoice_id,
    'order_id', s1_order_id,
    'retailer_id', (v_template_order_json->>'retailer_id')::uuid,
    'invoice_ref', 'REG-PACK-B-LOYALTY-INV-' || left(s1_invoice_id::text, 8),
    'ocr_invoice_ref', 'REG-PACK-B-LOYALTY-INV-' || left(s1_invoice_id::text, 8),
    'ocr_invoice_total_gbp', s1_amount,
    'reconciliation_gbp_total', s1_amount,
    'review_status', 'approved_current',
    'blocked_from_sage_yn', false,
    'is_current_for_order', true,
    'reviewed_by_staff_id', v_staff_id,
    'reviewed_at', now(),
    'uploaded_at', now(),
    'review_notes', 'Regression Pack B scenario 1 approved invoice fixture.'
  );
  INSERT INTO public.supplier_invoices SELECT * FROM jsonb_populate_record(NULL::public.supplier_invoices, v_json);

  v_json := v_template_line_json || jsonb_build_object(
    'id', s1_payment_out_line_id,
    'line_order', v_next_line_order + 1,
    'direction', 'out',
    'amount_local_ccy', s1_amount,
    'amount_gbp_equivalent', s1_amount,
    'reference_raw', 'REG PACK B LOYALTY SUPPLIER OUT',
    'match_status', 'unmatched',
    'created_at', now()
  );
  INSERT INTO public.dva_statement_lines SELECT * FROM jsonb_populate_record(NULL::public.dva_statement_lines, v_json);

  SELECT r.supplier_payment_ready_yn, r.blocker
    INTO v_ready, v_blocker
  FROM public.internal_supplier_payment_readiness_v1(s1_order_id) r;

  IF v_ready IS DISTINCT FROM true OR v_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Scenario 1 readiness failed: ready %, blocker %', v_ready, v_blocker;
  END IF;

  v_result := public.staff_allocate_statement_line_to_supplier_invoice(
    s1_payment_out_line_id, s1_invoice_id, s1_amount,
    'Regression Pack B scenario 1 loyalty-only allocation.'
  );

  IF COALESCE(v_result->>'source_bank_account_mapping_code', '') <> v_expected_mapping
     OR COALESCE(v_result->>'source_wallet_code', '') <> v_wallet_code
     OR COALESCE(v_result->>'source_resolution_reason', '') <> 'exact_remaining_released_loyalty_source' THEN
    RAISE EXCEPTION 'Scenario 1 resolved wrong source: %', v_result;
  END IF;

  INSERT INTO supplier_payment_pack_b_results
  VALUES (
    1,
    'Released loyalty only',
    'PASS',
    'The full physical supplier OUT resolved to the one exact paired-released loyalty wallet.',
    jsonb_build_object(
      'order_id', s1_order_id,
      'invoice_id', s1_invoice_id,
      'statement_line_id', s1_payment_out_line_id,
      'wallet_code', v_wallet_code,
      'mapping_code', v_expected_mapping,
      'allocation_result', v_result
    )
  );

  -----------------------------------------------------------------------------
  -- Scenario 2: mixed funding (cash + loyalty), both exact for the physical OUT.
  -- Readiness must pass, but the final source selection must fail closed as
  -- ambiguous rather than inventing a split or defaulting to cash.
  -----------------------------------------------------------------------------
  v_json := v_template_order_json || jsonb_build_object(
    'id', s2_order_id,
    'order_ref', 'REG-PACK-B-MIXED-' || left(s2_order_id::text, 8),
    'payment_auth_id', 'REG-PACK-B-MIXED-' || s2_order_id::text,
    'order_type', 'original',
    'order_total_gbp_declared', s2_leg_amount * 2,
    'funded_at', now(),
    'status', 'evidence_collecting',
    'created_at', now(),
    'updated_at', now(),
    'completed_at', null
  );
  INSERT INTO public.orders SELECT * FROM jsonb_populate_record(NULL::public.orders, v_json);

  v_json := v_template_line_json || jsonb_build_object(
    'id', s2_destination_in_line_id,
    'line_order', v_next_line_order + 2,
    'direction', 'in',
    'amount_local_ccy', s2_leg_amount,
    'amount_gbp_equivalent', s2_leg_amount,
    'reference_raw', 'REG PACK B MIXED LOYALTY DESTINATION IN',
    'match_status', 'confirmed',
    'created_at', now()
  );
  INSERT INTO public.dva_statement_lines SELECT * FROM jsonb_populate_record(NULL::public.dva_statement_lines, v_json);

  v_json := v_template_credit_json || jsonb_build_object(
    'id', s2_credit_id,
    'importer_id', v_template_match.importer_id,
    'entry_type', 'manual_credit',
    'source_table', 'completion_loyalty_reward_funding_confirmations',
    'source_id', gen_random_uuid(),
    'linked_order_id', s2_order_id,
    'linked_dispute_id', null,
    'direction', 'credit',
    'amount_gbp', s2_leg_amount,
    'amount_local_ccy', s2_leg_amount,
    'local_ccy', 'GBP',
    'source_type', 'completion_loyalty_reward',
    'source_entity_type', 'order',
    'source_entity_id', s2_order_id,
    'applied_to_order_id', null,
    'lock_reason', null,
    'created_by_staff_id', v_staff_id,
    'effective_at', now(),
    'created_at', now(),
    'notes', 'Regression Pack B scenario 2 released loyalty source lot.'
  );
  INSERT INTO public.importer_credit_ledger SELECT * FROM jsonb_populate_record(NULL::public.importer_credit_ledger, v_json);

  v_json := v_template_approval_json || jsonb_build_object(
    'id', s2_approval_id,
    'order_id', s2_order_id,
    'importer_id', v_template_match.importer_id,
    'approved_by_staff_id', v_staff_id,
    'qualifying_signed_gross_basis_gbp', s2_leg_amount,
    'qualifying_net_spend_gbp', s2_leg_amount,
    'suggested_reward_gbp', s2_leg_amount,
    'approved_amount_gbp', s2_leg_amount,
    'credit_ledger_id', s2_credit_id,
    'approval_status', 'released_available_dashboard_credit',
    'funding_confirmation_id', null,
    'created_at', now(),
    'updated_at', now(),
    'notes', 'Regression Pack B scenario 2 approval fixture.'
  );
  INSERT INTO public.completion_loyalty_reward_approvals
  SELECT * FROM jsonb_populate_record(NULL::public.completion_loyalty_reward_approvals, v_json);

  INSERT INTO public.main_bank_completion_loyalty_funding_matches (
    id, dva_statement_line_id, completed_order_id, importer_id, approval_id,
    funding_confirmation_id, credit_ledger_id, matched_gbp_amount, match_status,
    notes, created_by_staff_id, created_by_auth_user_id, created_at,
    destination_in_statement_line_id, activation_route, card_used_by,
    transfer_pair_status, paired_at, paired_by_staff_id, paired_by_auth_user_id,
    variance_gbp
  ) VALUES (
    s2_match_id, v_template_match.dva_statement_line_id, s2_order_id,
    v_template_match.importer_id, s2_approval_id, NULL, s2_credit_id,
    s2_leg_amount, 'released_available_dashboard_credit',
    'Regression Pack B scenario 2 paired-released fixture.', v_staff_id,
    v_auth_user_id, now(), s2_destination_in_line_id,
    COALESCE(v_template_match.activation_route, 'dva_account_top_up'),
    COALESCE(v_template_match.card_used_by, 'staff'), 'paired_released', now(),
    v_staff_id, v_auth_user_id, 0
  );

  v_json := v_template_credit_json || jsonb_build_object(
    'id', s2_debit_id,
    'importer_id', v_template_match.importer_id,
    'entry_type', 'applied_to_order',
    'source_table', 'importer_credit_ledger',
    'source_id', s2_credit_id,
    'linked_order_id', s2_order_id,
    'linked_dispute_id', null,
    'direction', 'debit',
    'amount_gbp', s2_leg_amount,
    'amount_local_ccy', s2_leg_amount,
    'local_ccy', 'GBP',
    'source_type', 'credit_application',
    'source_entity_type', 'importer_credit_ledger',
    'source_entity_id', s2_credit_id,
    'applied_to_order_id', s2_order_id,
    'lock_reason', null,
    'created_by_staff_id', v_staff_id,
    'effective_at', now(),
    'created_at', now(),
    'notes', 'Regression Pack B scenario 2 exact loyalty application debit.'
  );
  INSERT INTO public.importer_credit_ledger SELECT * FROM jsonb_populate_record(NULL::public.importer_credit_ledger, v_json);

  INSERT INTO public.order_funding_events (
    order_id, event_type, amount_gbp, source_ref, source_entity_type,
    source_entity_id, created_by_staff_id, created_at, notes
  )
  SELECT s2_order_id, 'credit_applied', s2_leg_amount,
         'importer_credit_ledger:' || s2_debit_id::text,
         'importer_credit_ledger', s2_debit_id, v_staff_id, now(),
         'Regression Pack B scenario 2 fallback loyalty event.'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.order_funding_events ofe
    WHERE ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
      AND ofe.source_entity_id = s2_debit_id
  );

  -- Proven cash leg.
  v_json := v_template_line_json || jsonb_build_object(
    'id', s2_cash_in_line_id,
    'line_order', v_next_line_order + 3,
    'direction', 'in',
    'amount_local_ccy', s2_leg_amount,
    'amount_gbp_equivalent', s2_leg_amount,
    'reference_raw', 'REG PACK B MIXED CASH FUNDING IN',
    'match_status', 'confirmed',
    'created_at', now()
  );
  INSERT INTO public.dva_statement_lines SELECT * FROM jsonb_populate_record(NULL::public.dva_statement_lines, v_json);

  INSERT INTO public.dva_reconciliation (
    id, dva_statement_line_id, reconciliation_type, order_id,
    supplier_invoice_id, dispute_id, reconciled_gbp_amount,
    reconciled_by_staff_id, reconciled_at, notes
  ) VALUES (
    s2_cash_reconciliation_id, s2_cash_in_line_id, 'order_funding', s2_order_id,
    NULL, NULL, s2_leg_amount, v_staff_id, now(),
    'Regression Pack B scenario 2 proven cash funding leg.'
  );

  INSERT INTO public.order_funding_events (
    order_id, event_type, amount_gbp, source_ref, source_entity_type,
    source_entity_id, created_by_staff_id, created_at, notes
  )
  SELECT s2_order_id, 'funding_contribution', s2_leg_amount,
         'dva_reconciliation:' || s2_cash_reconciliation_id::text,
         'dva_reconciliation', s2_cash_reconciliation_id, v_staff_id, now(),
         'Regression Pack B scenario 2 fallback cash event.'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.order_funding_events ofe
    WHERE ofe.event_type = 'funding_contribution'
      AND ofe.source_entity_type = 'dva_reconciliation'
      AND ofe.source_entity_id = s2_cash_reconciliation_id
  );

  v_json := v_template_invoice_json || jsonb_build_object(
    'id', s2_invoice_id,
    'order_id', s2_order_id,
    'retailer_id', (v_template_order_json->>'retailer_id')::uuid,
    'invoice_ref', 'REG-PACK-B-MIXED-INV-' || left(s2_invoice_id::text, 8),
    'ocr_invoice_ref', 'REG-PACK-B-MIXED-INV-' || left(s2_invoice_id::text, 8),
    'ocr_invoice_total_gbp', s2_leg_amount,
    'reconciliation_gbp_total', s2_leg_amount,
    'review_status', 'approved_current',
    'blocked_from_sage_yn', false,
    'is_current_for_order', true,
    'reviewed_by_staff_id', v_staff_id,
    'reviewed_at', now(),
    'uploaded_at', now(),
    'review_notes', 'Regression Pack B scenario 2 approved invoice fixture.'
  );
  INSERT INTO public.supplier_invoices SELECT * FROM jsonb_populate_record(NULL::public.supplier_invoices, v_json);

  v_json := v_template_line_json || jsonb_build_object(
    'id', s2_payment_out_line_id,
    'line_order', v_next_line_order + 4,
    'direction', 'out',
    'amount_local_ccy', s2_leg_amount,
    'amount_gbp_equivalent', s2_leg_amount,
    'reference_raw', 'REG PACK B MIXED SUPPLIER OUT',
    'match_status', 'unmatched',
    'created_at', now()
  );
  INSERT INTO public.dva_statement_lines SELECT * FROM jsonb_populate_record(NULL::public.dva_statement_lines, v_json);

  SELECT r.supplier_payment_ready_yn, r.blocker
    INTO v_ready, v_blocker
  FROM public.internal_supplier_payment_readiness_v1(s2_order_id) r;

  IF v_ready IS DISTINCT FROM true OR v_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Scenario 2 readiness failed before source selection: ready %, blocker %', v_ready, v_blocker;
  END IF;

  v_error := NULL;
  BEGIN
    PERFORM public.staff_allocate_statement_line_to_supplier_invoice(
      s2_payment_out_line_id, s2_invoice_id, s2_leg_amount,
      'Regression Pack B scenario 2 must fail closed as ambiguous.'
    );
    RAISE EXCEPTION 'Scenario 2 unexpectedly allocated mixed exact funding';
  EXCEPTION
    WHEN OTHERS THEN
      v_error := SQLERRM;
      IF position('source_funding_ambiguous_for_supplier_payment_bank_resolution' in v_error) = 0 THEN
        RAISE EXCEPTION 'Scenario 2 raised wrong error: %', v_error;
      END IF;
  END;

  SELECT COUNT(*)::integer INTO v_count
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = s2_payment_out_line_id
    AND a.allocation_status <> 'reversed';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Scenario 2 wrote % active allocation row(s) despite ambiguity', v_count;
  END IF;

  INSERT INTO supplier_payment_pack_b_results
  VALUES (
    2,
    'Mixed funding (cash + loyalty)',
    'PASS',
    'Readiness accepted both proven funding legs, but final source resolution failed closed because cash and loyalty were both exact candidates for one physical OUT.',
    jsonb_build_object(
      'order_id', s2_order_id,
      'invoice_id', s2_invoice_id,
      'statement_line_id', s2_payment_out_line_id,
      'cash_leg_gbp', s2_leg_amount,
      'loyalty_leg_gbp', s2_leg_amount,
      'physical_out_gbp', s2_leg_amount,
      'expected_error', v_error,
      'active_allocation_rows_after_failure', v_count
    )
  );
END $$;

SELECT scenario_no, scenario, status, finding, evidence
FROM supplier_payment_pack_b_results
ORDER BY scenario_no;

DO $$
DECLARE
  v_pass_count integer;
BEGIN
  SELECT COUNT(*) INTO v_pass_count
  FROM supplier_payment_pack_b_results
  WHERE status = 'PASS';

  IF v_pass_count <> 2 THEN
    RAISE EXCEPTION 'Pack B incomplete: expected 2 PASS rows, found %', v_pass_count;
  END IF;
END $$;

ROLLBACK;
