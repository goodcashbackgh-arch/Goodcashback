BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Treasury statement control corrective pack — Phase 1.
-- Close the manual completion-loyalty release path without changing the
-- established main-bank OUT -> same-importer destination IN pairing workflow.

DO $$
BEGIN
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN
    RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches';
  END IF;
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN
    RAISE EXCEPTION 'Missing public.completion_loyalty_reward_approvals';
  END IF;
  IF to_regclass('public.completion_loyalty_reward_funding_confirmations') IS NULL THEN
    RAISE EXCEPTION 'Missing public.completion_loyalty_reward_funding_confirmations';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing public.importer_credit_ledger';
  END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL OR to_regclass('public.dva_statements') IS NULL THEN
    RAISE EXCEPTION 'Missing DVA/card statement relations';
  END IF;
  IF to_regclass('public.main_bank_shipper_ap_allocations') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.dva_reconciliation') IS NULL THEN
    RAISE EXCEPTION 'Missing statement-line consumption relations';
  END IF;
  IF to_regprocedure('public.staff_confirm_completion_loyalty_reward_funding_v1(uuid,numeric,numeric,uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing manual completion-loyalty funding function';
  END IF;
  IF to_regprocedure('public.staff_pair_loyalty_destination_in_and_release_v1(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing paired completion-loyalty release function';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_release_paired_loyalty_v2(
  p_loyalty_match_id uuid,
  p_destination_in_statement_line_id uuid,
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
  v_match record;
  v_approval record;
  v_source record;
  v_destination record;
  v_source_shipper_gbp numeric(18,2) := 0;
  v_source_other_alloc_gbp numeric(18,2) := 0;
  v_source_loyalty_gbp numeric(18,2) := 0;
  v_source_total_used_gbp numeric(18,2) := 0;
  v_destination_other_used_gbp numeric(18,2) := 0;
  v_destination_remaining_gbp numeric(18,2) := 0;
  v_existing_confirmation_id uuid;
  v_existing_credit_id uuid;
  v_confirmation_id uuid;
  v_credit_id uuid;
  v_amount numeric(18,2);
  v_evidence_ref text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: paired completion-loyalty release requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found.';
  END IF;
  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can pair and release completion loyalty.';
  END IF;

  SELECT lm.*
    INTO v_match
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = p_loyalty_match_id
  FOR UPDATE;

  IF v_match.id IS NULL THEN
    RAISE EXCEPTION 'Completion-loyalty funding match not found: %', p_loyalty_match_id;
  END IF;
  IF v_match.match_status IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Only a confirmed staged loyalty match can be released. Current status: %', v_match.match_status;
  END IF;
  IF COALESCE(v_match.transfer_pair_status, 'source_out_reserved') NOT IN ('source_out_reserved', 'paired_ready_to_release') THEN
    RAISE EXCEPTION 'Loyalty match % is not awaiting destination-IN pairing. Pair status: %', p_loyalty_match_id, v_match.transfer_pair_status;
  END IF;
  IF v_match.funding_confirmation_id IS NOT NULL OR v_match.credit_ledger_id IS NOT NULL THEN
    RAISE EXCEPTION 'Loyalty match % already has release evidence.', p_loyalty_match_id;
  END IF;
  IF v_match.dva_statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Loyalty match % has no source main-bank OUT.', p_loyalty_match_id;
  END IF;

  v_amount := ROUND(COALESCE(v_match.matched_gbp_amount, 0)::numeric, 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Loyalty match amount must be positive.';
  END IF;

  SELECT a.*
    INTO v_approval
  FROM public.completion_loyalty_reward_approvals a
  WHERE a.id = v_match.approval_id
  FOR UPDATE;

  IF v_approval.id IS NULL THEN
    RAISE EXCEPTION 'Completion-loyalty approval not found: %', v_match.approval_id;
  END IF;
  IF v_approval.order_id IS DISTINCT FROM v_match.completed_order_id
     OR v_approval.importer_id IS DISTINCT FROM v_match.importer_id THEN
    RAISE EXCEPTION 'Loyalty match and approval order/importer provenance disagree.';
  END IF;
  IF v_approval.approval_status NOT IN (
    'approved_pending_funding',
    'funding_submitted_pending_match',
    'funding_confirmed_ready_to_release',
    'approved_locked_awaiting_sage'
  ) THEN
    RAISE EXCEPTION 'Approval % is not awaiting paired funding. Status: %', v_approval.id, v_approval.approval_status;
  END IF;
  IF v_amount > ROUND(COALESCE(v_approval.approved_amount_gbp, 0)::numeric, 2) + 0.01 THEN
    RAISE EXCEPTION 'Paired release amount % exceeds approved amount %.', v_amount, v_approval.approved_amount_gbp;
  END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.reference_raw,
    dsl.statement_date,
    ds.importer_id,
    ds.statement_account_context,
    ds.statement_account_label,
    ds.source_bank
  INTO v_source
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = v_match.dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_source.id IS NULL THEN
    RAISE EXCEPTION 'Source OUT statement line not found: %', v_match.dva_statement_line_id;
  END IF;
  IF COALESCE(v_source.statement_account_context, '') <> 'main_company_bank_account'
     OR COALESCE(v_source.direction, '') <> 'out' THEN
    RAISE EXCEPTION 'Completion-loyalty source must be a main-company-bank OUT. Context %, direction %.', v_source.statement_account_context, v_source.direction;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.dva_reconciliation dr
    WHERE dr.dva_statement_line_id = v_source.id
  ) THEN
    RAISE EXCEPTION 'Source OUT % is already used by a DVA reconciliation.', v_source.id;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = v_source.id
      AND a.allocation_status <> 'reversed'
      AND a.allocation_type NOT IN ('fx_card_difference', 'bank_fee', 'unmatched_hold')
  ) THEN
    RAISE EXCEPTION 'Source OUT % has an incompatible active allocation.', v_source.id;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2)
    INTO v_source_shipper_gbp
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.dva_statement_line_id = v_source.id;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2)
    INTO v_source_other_alloc_gbp
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_source.id;

  SELECT ROUND(COALESCE(SUM(lm.matched_gbp_amount) FILTER (
    WHERE lm.match_status IN ('confirmed', 'released_available_dashboard_credit')
  ), 0)::numeric, 2)
    INTO v_source_loyalty_gbp
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.dva_statement_line_id = v_source.id;

  v_source_total_used_gbp := ROUND(
    COALESCE(v_source_shipper_gbp, 0)
    + COALESCE(v_source_other_alloc_gbp, 0)
    + COALESCE(v_source_loyalty_gbp, 0),
    2
  );

  IF v_source_total_used_gbp > ROUND(COALESCE(v_source.amount_gbp_equivalent, 0)::numeric, 2) + 0.01 THEN
    RAISE EXCEPTION 'Source OUT % is over-consumed. Amount %, active use %.', v_source.id, v_source.amount_gbp_equivalent, v_source_total_used_gbp;
  END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.reference_raw,
    dsl.statement_date,
    ds.importer_id,
    ds.statement_account_context,
    ds.statement_account_label,
    ds.source_bank
  INTO v_destination
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_destination_in_statement_line_id
  FOR UPDATE OF dsl;

  IF v_destination.id IS NULL THEN
    RAISE EXCEPTION 'Destination IN statement line not found: %', p_destination_in_statement_line_id;
  END IF;
  IF COALESCE(v_destination.statement_account_context, 'importer_dva_card_account') <> 'importer_dva_card_account'
     OR COALESCE(v_destination.direction, '') <> 'in' THEN
    RAISE EXCEPTION 'Completion-loyalty destination must be an importer DVA/card IN. Context %, direction %.', v_destination.statement_account_context, v_destination.direction;
  END IF;
  IF v_destination.importer_id IS DISTINCT FROM v_match.importer_id THEN
    RAISE EXCEPTION 'Destination importer % does not match loyalty importer %.', v_destination.importer_id, v_match.importer_id;
  END IF;
  IF v_destination.id = v_source.id THEN
    RAISE EXCEPTION 'Source OUT and destination IN must be different physical statement lines.';
  END IF;

  SELECT ROUND(COALESCE(SUM(x.used_gbp), 0)::numeric, 2)
    INTO v_destination_other_used_gbp
  FROM (
    SELECT COALESCE(SUM(dr.reconciled_gbp_amount), 0)::numeric AS used_gbp
    FROM public.dva_reconciliation dr
    WHERE dr.dva_statement_line_id = v_destination.id

    UNION ALL

    SELECT COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric
    FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = v_destination.id

    UNION ALL

    SELECT COALESCE(SUM(lm.matched_gbp_amount) FILTER (
      WHERE lm.match_status IN ('confirmed', 'released_available_dashboard_credit')
        AND lm.id <> p_loyalty_match_id
    ), 0)::numeric
    FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE lm.destination_in_statement_line_id = v_destination.id
  ) x;

  v_destination_remaining_gbp := ROUND(GREATEST(
    COALESCE(v_destination.amount_gbp_equivalent, 0) - COALESCE(v_destination_other_used_gbp, 0),
    0
  )::numeric, 2);

  IF v_amount > v_destination_remaining_gbp + 0.01 THEN
    RAISE EXCEPTION 'Destination IN remaining % is below paired release amount %.', v_destination_remaining_gbp, v_amount;
  END IF;

  SELECT c.id
    INTO v_existing_confirmation_id
  FROM public.completion_loyalty_reward_funding_confirmations c
  WHERE c.approval_id = v_approval.id
    AND c.funding_status IN ('funding_confirmed_ready_to_release', 'released_available_dashboard_credit')
  LIMIT 1
  FOR UPDATE;

  IF v_existing_confirmation_id IS NOT NULL THEN
    RAISE EXCEPTION 'Funding confirmation already exists for approval %: %', v_approval.id, v_existing_confirmation_id;
  END IF;

  SELECT icl.id
    INTO v_existing_credit_id
  FROM public.importer_credit_ledger icl
  WHERE icl.source_type = 'completion_loyalty_reward'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id = v_match.completed_order_id
  LIMIT 1
  FOR UPDATE;

  IF v_existing_credit_id IS NOT NULL THEN
    RAISE EXCEPTION 'Completion-loyalty credit already exists for order %: %', v_match.completed_order_id, v_existing_credit_id;
  END IF;

  UPDATE public.main_bank_completion_loyalty_funding_matches
     SET destination_in_statement_line_id = v_destination.id,
         transfer_pair_status = 'paired_ready_to_release',
         paired_at = now(),
         paired_by_staff_id = v_staff.id,
         paired_by_auth_user_id = v_auth_uid,
         variance_gbp = ROUND((v_destination_remaining_gbp - v_amount)::numeric, 2),
         notes = COALESCE(p_notes, notes)
   WHERE id = p_loyalty_match_id;

  v_evidence_ref := concat_ws(' · ',
    'loyalty-transfer-match:' || p_loyalty_match_id::text,
    'source-out-line:' || v_source.id::text,
    'destination-in-line:' || v_destination.id::text,
    NULLIF(v_destination.statement_account_label::text, ''),
    NULLIF(v_destination.source_bank::text, ''),
    NULLIF(v_destination.statement_date::text, ''),
    NULLIF(v_destination.reference_raw::text, '')
  );

  INSERT INTO public.completion_loyalty_reward_funding_confirmations (
    approval_id,
    completed_order_id,
    importer_id,
    funded_by_staff_id,
    funding_evidence_type,
    dva_statement_line_id,
    funding_evidence_ref,
    amount_funded_gbp,
    amount_released_gbp,
    funding_status,
    notes
  ) VALUES (
    v_approval.id,
    v_match.completed_order_id,
    v_match.importer_id,
    v_staff.id,
    'matched_dva_statement_line',
    v_destination.id,
    v_evidence_ref,
    v_amount,
    v_amount,
    'funding_confirmed_ready_to_release',
    p_notes
  ) RETURNING id INTO v_confirmation_id;

  INSERT INTO public.importer_credit_ledger (
    importer_id,
    entry_type,
    source_table,
    source_id,
    linked_order_id,
    linked_dispute_id,
    direction,
    amount_gbp,
    amount_local_ccy,
    local_ccy,
    effective_at,
    source_type,
    source_entity_type,
    source_entity_id,
    applied_to_order_id,
    lock_reason,
    lock_source_entity_id,
    created_by_staff_id,
    notes
  ) VALUES (
    v_match.importer_id,
    'manual_credit',
    'completion_loyalty_reward_funding_confirmations',
    v_confirmation_id,
    v_match.completed_order_id,
    NULL,
    'credit',
    v_amount,
    v_amount,
    'GBP',
    now(),
    'completion_loyalty_reward',
    'order',
    v_match.completed_order_id,
    NULL,
    NULL,
    v_confirmation_id,
    v_staff.id,
    'Completion loyalty released only after exact paired main-bank OUT and same-importer destination IN validation.'
  ) RETURNING id INTO v_credit_id;

  UPDATE public.completion_loyalty_reward_funding_confirmations
     SET funding_status = 'released_available_dashboard_credit',
         credit_ledger_id = v_credit_id,
         updated_at = now()
   WHERE id = v_confirmation_id;

  UPDATE public.completion_loyalty_reward_approvals
     SET funding_confirmation_id = v_confirmation_id,
         funding_confirmed_at = now(),
         released_at = now(),
         credit_ledger_id = v_credit_id,
         approval_status = 'released_available_dashboard_credit',
         updated_at = now()
   WHERE id = v_approval.id;

  UPDATE public.main_bank_completion_loyalty_funding_matches
     SET funding_confirmation_id = v_confirmation_id,
         credit_ledger_id = v_credit_id,
         match_status = 'released_available_dashboard_credit',
         transfer_pair_status = 'paired_released',
         paired_at = COALESCE(paired_at, now()),
         paired_by_staff_id = COALESCE(paired_by_staff_id, v_staff.id),
         paired_by_auth_user_id = COALESCE(paired_by_auth_user_id, v_auth_uid),
         notes = COALESCE(p_notes, notes)
   WHERE id = p_loyalty_match_id;

  RETURN jsonb_build_object(
    'ok', true,
    'loyalty_match_id', p_loyalty_match_id,
    'approval_id', v_approval.id,
    'funding_confirmation_id', v_confirmation_id,
    'credit_ledger_id', v_credit_id,
    'order_id', v_match.completed_order_id,
    'importer_id', v_match.importer_id,
    'source_out_statement_line_id', v_source.id,
    'destination_in_statement_line_id', v_destination.id,
    'matched_gbp_amount', v_amount,
    'match_status', 'released_available_dashboard_credit',
    'transfer_pair_status', 'paired_released',
    'credit_available_now', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_release_paired_loyalty_v2(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_release_paired_loyalty_v2(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.internal_release_paired_loyalty_v2(uuid, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_release_paired_loyalty_v2(uuid, uuid, text) FROM service_role;

CREATE OR REPLACE FUNCTION public.staff_pair_loyalty_destination_in_and_release_v1(
  p_loyalty_match_id uuid,
  p_destination_in_statement_line_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.internal_release_paired_loyalty_v2(
    p_loyalty_match_id,
    p_destination_in_statement_line_id,
    p_notes
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_pair_loyalty_destination_in_and_release_v1(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_pair_loyalty_destination_in_and_release_v1(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_pair_loyalty_destination_in_and_release_v1(uuid, uuid, text) TO authenticated;

-- Preserve the old signature for dependency stability, but make every direct call fail closed.
CREATE OR REPLACE FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(
  p_approval_id uuid,
  p_amount_funded_gbp numeric,
  p_amount_released_gbp numeric DEFAULT NULL,
  p_dva_statement_line_id uuid DEFAULT NULL,
  p_funding_evidence_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'Direct completion-loyalty funding confirmation is disabled. Use the paired main-bank OUT and same-importer destination-IN release workflow.';
END;
$$;

REVOKE ALL ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) FROM service_role;

COMMENT ON FUNCTION public.internal_release_paired_loyalty_v2(uuid, uuid, text) IS
'Private paired completion-loyalty release helper. Requires one exact staged main-bank OUT match and one same-importer destination IN, validates both capacities, and creates one confirmation and one available credit.';

COMMENT ON FUNCTION public.staff_pair_loyalty_destination_in_and_release_v1(uuid, uuid, text) IS
'Public staff wrapper for the private paired completion-loyalty release helper. No manual evidence-reference release is permitted.';

COMMENT ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) IS
'Disabled legacy/manual entry point retained only for dependency stability. Always fails closed; use paired main-bank OUT plus destination IN release.';

NOTIFY pgrst, 'reload schema';
COMMIT;
