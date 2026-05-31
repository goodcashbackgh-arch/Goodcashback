BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_approve_vat_adjustment_journal_v1(
  p_vat_return_adjustment_journal_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_staff_id uuid;
  v_journal public.vat_return_adjustment_journals%rowtype;
  v_run public.vat_return_runs%rowtype;
  v_vat_line public.vat_return_adjustment_journal_lines%rowtype;
  v_balance_line public.vat_return_adjustment_journal_lines%rowtype;
  v_line_count integer := 0;
  v_total_debits numeric(18,2) := 0;
  v_total_credits numeric(18,2) := 0;
  v_open_blockers integer := 0;
  v_unapproved_journals integer := 0;
  v_errors jsonb := '[]'::jsonb;
  v_new_run_status text;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT journal approval action.';
  END IF;

  SELECT *
  INTO v_journal
  FROM public.vat_return_adjustment_journals
  WHERE id = p_vat_return_adjustment_journal_id
  FOR UPDATE;

  IF v_journal.id IS NULL THEN
    RAISE EXCEPTION 'VAT adjustment journal not found.';
  END IF;

  SELECT *
  INTO v_run
  FROM public.vat_return_runs
  WHERE id = v_journal.vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'VAT_RETURN_RUN_NOT_FOUND',
      'message', 'Journal has no valid VAT return run.'
    ));
  END IF;

  IF v_run.locked_at IS NOT NULL OR v_run.status = 'matched_to_sage_locked' THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'VAT_RETURN_LOCKED',
      'message', 'Locked VAT returns cannot have journals approved.'
    ));
  END IF;

  IF v_run.status IN (
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'mismatch_needs_admin_review'
  ) THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'VAT_RETURN_STATUS_NOT_APPROVABLE',
      'message', 'VAT return status is not eligible for journal approval.',
      'run_status', v_run.status
    ));
  END IF;

  IF v_journal.status <> 'dry_run_validated' THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'JOURNAL_NOT_DRY_RUN_VALIDATED',
      'message', 'Only dry_run_validated journals can be admin approved.',
      'journal_status', v_journal.status
    ));
  END IF;

  IF NULLIF(trim(COALESCE(v_journal.payload_hash, '')), '') IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'PAYLOAD_HASH_MISSING',
      'message', 'Dry-run validated journal must have a payload_hash before approval.'
    ));
  END IF;

  IF NULLIF(trim(COALESCE(v_journal.idempotency_key, '')), '') IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'IDEMPOTENCY_KEY_MISSING',
      'message', 'Journal must have an idempotency key before approval.'
    ));
  END IF;

  SELECT count(*)
  INTO v_open_blockers
  FROM public.vat_return_blockers b
  WHERE b.vat_return_run_id = v_journal.vat_return_run_id
    AND b.status = 'open'
    AND b.severity = 'blocker';

  IF v_open_blockers > 0 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'OPEN_VAT_RETURN_BLOCKERS',
      'message', 'Open blocker(s) exist for this VAT return run.',
      'open_blockers', v_open_blockers
    ));
  END IF;

  SELECT count(*),
         COALESCE(sum(debit_amount_gbp), 0),
         COALESCE(sum(credit_amount_gbp), 0)
  INTO v_line_count, v_total_debits, v_total_credits
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_journal.id;

  IF v_line_count <> 2 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'JOURNAL_LINE_COUNT_INVALID',
      'message', 'Approved VAT journal must have exactly two lines.',
      'line_count', v_line_count
    ));
  END IF;

  SELECT *
  INTO v_vat_line
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_journal.id
    AND line_role = 'vat_box_line'
  LIMIT 1;

  SELECT *
  INTO v_balance_line
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_journal.id
    AND line_role = 'balancing_line'
  LIMIT 1;

  IF v_vat_line.id IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'VAT_BOX_LINE_MISSING',
      'message', 'VAT-box line is missing.'
    ));
  ELSE
    IF v_vat_line.include_on_tax_return IS DISTINCT FROM true THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'VAT_BOX_LINE_NOT_INCLUDED_ON_RETURN',
        'message', 'VAT-box line must be included on tax return.'
      ));
    END IF;

    IF v_vat_line.target_box IS DISTINCT FROM v_journal.target_box THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'VAT_BOX_LINE_TARGET_BOX_MISMATCH',
        'message', 'VAT-box line target box must match journal target box.'
      ));
    END IF;

    IF NULLIF(trim(COALESCE(v_vat_line.sage_ledger_account_id, '')), '') IS NULL THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'VAT_BOX_LINE_SAGE_LEDGER_MISSING',
        'message', 'VAT-box line must have Sage ledger account id populated from dry-run validation.'
      ));
    END IF;
  END IF;

  IF v_balance_line.id IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'BALANCING_LINE_MISSING',
      'message', 'Balancing line is missing.'
    ));
  ELSE
    IF v_balance_line.include_on_tax_return IS DISTINCT FROM false THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'BALANCING_LINE_INCLUDED_ON_RETURN',
        'message', 'Balancing line must be excluded from tax return.'
      ));
    END IF;

    IF v_balance_line.target_box IS NOT NULL THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'BALANCING_LINE_HAS_TARGET_BOX',
        'message', 'Balancing line must not have a target VAT box.'
      ));
    END IF;

    IF NULLIF(trim(COALESCE(v_balance_line.sage_ledger_account_id, '')), '') IS NULL THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'BALANCING_LINE_SAGE_LEDGER_MISSING',
        'message', 'Balancing line must have Sage ledger account id populated from dry-run validation.'
      ));
    END IF;
  END IF;

  IF round(v_total_debits::numeric, 2) <> round(v_total_credits::numeric, 2) THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'JOURNAL_NOT_BALANCED',
      'message', 'Journal debit and credit totals must balance.',
      'debits', v_total_debits,
      'credits', v_total_credits
    ));
  END IF;

  IF round(v_total_debits::numeric, 2) <> round(v_journal.amount_gbp::numeric, 2)
     OR round(v_total_credits::numeric, 2) <> round(v_journal.amount_gbp::numeric, 2) THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'JOURNAL_TOTAL_DOES_NOT_MATCH_AMOUNT',
      'message', 'Journal debit/credit totals must equal adjustment amount.',
      'journal_amount', v_journal.amount_gbp,
      'debits', v_total_debits,
      'credits', v_total_credits
    ));
  END IF;

  IF jsonb_array_length(v_errors) > 0 THEN
    RAISE EXCEPTION 'Cannot approve VAT adjustment journal: %', v_errors;
  END IF;

  UPDATE public.vat_return_adjustment_journals
  SET status = 'admin_approved',
      approved_by_staff_id = v_staff_id,
      approved_by_auth_user_id = auth.uid(),
      approved_at = now(),
      request_payload = COALESCE(request_payload, '{}'::jsonb) || jsonb_build_object(
        'admin_approved_at', now(),
        'admin_approved_by_staff_id', v_staff_id,
        'admin_approved_by_auth_user_id', auth.uid(),
        'approved_payload_hash', v_journal.payload_hash
      ),
      updated_at = now()
  WHERE id = v_journal.id;

  SELECT count(*)
  INTO v_unapproved_journals
  FROM public.vat_return_adjustment_journals j
  WHERE j.vat_return_run_id = v_journal.vat_return_run_id
    AND j.status IN ('platform_calculated', 'dry_run_failed', 'dry_run_validated');

  IF v_unapproved_journals = 0 THEN
    UPDATE public.vat_return_runs
    SET status = 'admin_approved',
        admin_approved_at = now(),
        admin_approved_by_staff_id = v_staff_id,
        updated_at = now()
    WHERE id = v_journal.vat_return_run_id
      AND status = 'sage_adjustment_journals_pending';

    v_new_run_status := 'admin_approved';
  ELSE
    v_new_run_status := v_run.status;
  END IF;

  RETURN jsonb_build_object(
    'journal_id', v_journal.id,
    'vat_return_run_id', v_journal.vat_return_run_id,
    'journal_status', 'admin_approved',
    'run_status', v_new_run_status,
    'approved_by_staff_id', v_staff_id,
    'approved_by_auth_user_id', auth.uid(),
    'approved_at', now(),
    'payload_hash', v_journal.payload_hash,
    'posting_allowed', false
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.staff_approve_vat_adjustment_journal_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_approve_vat_adjustment_journal_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
