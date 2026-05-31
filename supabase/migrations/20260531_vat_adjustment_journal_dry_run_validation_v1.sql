BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

INSERT INTO public.sage_mapping_settings (mapping_code, mapping_group, display_name, description, value_kind, required_for)
VALUES
  ('VAT_OUTPUT_BOX_CONTROL_LEDGER','vat_adjustment_journals','VAT output Box 1 control ledger','Sage ledger/account id used for VAT-box line movements that increase/decrease Box 1 output VAT.','ledger_account_id',ARRAY['vat_adjustment_journal_box1']::text[]),
  ('VAT_INPUT_BOX_CONTROL_LEDGER','vat_adjustment_journals','VAT input Box 4 control ledger','Sage ledger/account id used for VAT-box line movements that increase/decrease Box 4 input VAT.','ledger_account_id',ARRAY['vat_adjustment_journal_box4']::text[]),
  ('VAT_OUTPUT_NET_CONTROL_LEDGER','vat_adjustment_journals','VAT output net Box 6 ledger','Sage ledger/account id used for VAT-box line movements that increase/decrease Box 6 outputs net.','ledger_account_id',ARRAY['vat_adjustment_journal_box6']::text[]),
  ('VAT_INPUT_NET_CONTROL_LEDGER','vat_adjustment_journals','VAT input net Box 7 ledger','Sage ledger/account id used for VAT-box line movements that increase/decrease Box 7 inputs net.','ledger_account_id',ARRAY['vat_adjustment_journal_box7']::text[]),
  ('VAT_ADJUSTMENT_SUSPENSE_LEDGER','vat_adjustment_journals','VAT adjustment suspense/control ledger','Sage ledger/account id used for the balancing line on VAT adjustment journals. This line must be excluded from the VAT return.','ledger_account_id',ARRAY['vat_adjustment_journal_balancing_line']::text[])
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    updated_at = now();

CREATE OR REPLACE FUNCTION public.staff_validate_vat_adjustment_journal_dry_run_v1(
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
  v_source_line public.vat_return_run_lines%rowtype;
  v_vat_line public.vat_return_adjustment_journal_lines%rowtype;
  v_balance_line public.vat_return_adjustment_journal_lines%rowtype;
  v_line_count integer := 0;
  v_errors jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_total_debits numeric(18,2) := 0;
  v_total_credits numeric(18,2) := 0;
  v_vat_mapping_code text;
  v_balance_mapping_code text := 'VAT_ADJUSTMENT_SUSPENSE_LEDGER';
  v_vat_mapping record;
  v_balance_mapping record;
  v_payload_hash text;
  v_status text;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT adjustment dry-run validation action.';
  END IF;

  SELECT * INTO v_journal
  FROM public.vat_return_adjustment_journals
  WHERE id = p_vat_return_adjustment_journal_id
  FOR UPDATE;

  IF v_journal.id IS NULL THEN
    RAISE EXCEPTION 'VAT adjustment journal not found.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = v_journal.vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','VAT_RETURN_RUN_NOT_FOUND','message','Journal has no valid VAT return run.'));
  END IF;

  IF v_run.locked_at IS NOT NULL OR v_run.status = 'matched_to_sage_locked' THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','VAT_RETURN_LOCKED','message','Locked VAT returns cannot have journals dry-run validated.'));
  END IF;

  IF v_journal.status NOT IN ('platform_calculated', 'dry_run_failed') THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','JOURNAL_STATUS_NOT_DRY_RUN_ELIGIBLE','message','Only platform_calculated or dry_run_failed journals can be dry-run validated.','status',v_journal.status));
  END IF;

  IF v_journal.endpoint_path <> '/journals' OR v_journal.method <> 'POST' THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','INVALID_SAGE_ENDPOINT_OR_METHOD','message','VAT adjustment journals must use POST /journals.','endpoint_path',v_journal.endpoint_path,'method',v_journal.method));
  END IF;

  IF v_journal.target_box NOT IN (1,4,6,7) THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','INVALID_TARGET_BOX','message','VAT adjustment journal target box must be 1, 4, 6 or 7.','target_box',v_journal.target_box));
  END IF;

  IF v_journal.direction NOT IN ('increase','decrease') THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','INVALID_DIRECTION','message','VAT adjustment journal direction must be increase or decrease.','direction',v_journal.direction));
  END IF;

  IF v_journal.amount_gbp IS NULL OR v_journal.amount_gbp <= 0 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','INVALID_AMOUNT','message','VAT adjustment journal amount must be greater than zero.','amount_gbp',v_journal.amount_gbp));
  END IF;

  IF NULLIF(trim(COALESCE(v_journal.idempotency_key, '')), '') IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','MISSING_IDEMPOTENCY_KEY','message','VAT adjustment journal requires an idempotency key before dry-run validation.'));
  END IF;

  SELECT * INTO v_source_line
  FROM public.vat_return_run_lines
  WHERE id = v_journal.vat_return_run_line_id
    AND vat_return_run_id = v_journal.vat_return_run_id
    AND status = 'active';

  IF v_source_line.id IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','SOURCE_VAT_LINE_NOT_FOUND','message','VAT adjustment journal must link to an active source VAT return line.'));
  ELSE
    IF v_source_line.box_number IS DISTINCT FROM v_journal.target_box THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','SOURCE_TARGET_BOX_MISMATCH','message','Source VAT line box does not match journal target box.','source_box',v_source_line.box_number,'journal_box',v_journal.target_box));
    END IF;
    IF v_journal.direction = 'increase' AND v_source_line.direction NOT IN ('natural','increase') THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','SOURCE_DIRECTION_MISMATCH','message','Increase journals require a natural/increase source VAT line.','source_direction',v_source_line.direction));
    END IF;
    IF v_journal.direction = 'decrease' AND v_source_line.direction <> 'decrease' THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','SOURCE_DIRECTION_MISMATCH','message','Decrease journals require a decrease source VAT line.','source_direction',v_source_line.direction));
    END IF;
    IF v_source_line.adjustment_required IS DISTINCT FROM true AND v_source_line.natural_sage_covered IS DISTINCT FROM false THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','SOURCE_LINE_NOT_MARKED_FOR_ADJUSTMENT','message','Source line must be uncovered by Sage or explicitly marked adjustment_required.'));
    END IF;
  END IF;

  SELECT count(*), COALESCE(sum(debit_amount_gbp), 0), COALESCE(sum(credit_amount_gbp), 0)
  INTO v_line_count, v_total_debits, v_total_credits
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_journal.id;

  IF v_line_count <> 2 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','JOURNAL_LINE_COUNT_INVALID','message','VAT adjustment journal must have exactly two lines.','line_count',v_line_count));
  END IF;

  SELECT * INTO v_vat_line
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_journal.id AND line_role = 'vat_box_line'
  LIMIT 1;

  SELECT * INTO v_balance_line
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_journal.id AND line_role = 'balancing_line'
  LIMIT 1;

  IF v_vat_line.id IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','VAT_BOX_LINE_MISSING','message','VAT-box line is missing.'));
  ELSE
    IF v_vat_line.include_on_tax_return IS DISTINCT FROM true THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','VAT_BOX_LINE_NOT_INCLUDED_ON_RETURN','message','VAT-box line must have include_on_tax_return=true.'));
    END IF;
    IF v_vat_line.target_box IS DISTINCT FROM v_journal.target_box THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','VAT_BOX_LINE_TARGET_BOX_MISMATCH','message','VAT-box line target box must match the journal target box.','line_target_box',v_vat_line.target_box,'journal_target_box',v_journal.target_box));
    END IF;
  END IF;

  IF v_balance_line.id IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BALANCING_LINE_MISSING','message','Balancing line is missing.'));
  ELSE
    IF v_balance_line.include_on_tax_return IS DISTINCT FROM false THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BALANCING_LINE_INCLUDED_ON_RETURN','message','Balancing line must have include_on_tax_return=false.'));
    END IF;
    IF v_balance_line.target_box IS NOT NULL THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BALANCING_LINE_HAS_TARGET_BOX','message','Balancing line must not have a VAT target box.'));
    END IF;
  END IF;

  IF round(v_total_debits::numeric, 2) <> round(v_total_credits::numeric, 2) THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','JOURNAL_NOT_BALANCED','message','VAT adjustment journal debit and credit totals must balance.','debits',v_total_debits,'credits',v_total_credits));
  END IF;

  IF round(v_total_debits::numeric, 2) <> round(v_journal.amount_gbp::numeric, 2) OR round(v_total_credits::numeric, 2) <> round(v_journal.amount_gbp::numeric, 2) THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','JOURNAL_TOTAL_DOES_NOT_MATCH_AMOUNT','message','Balanced journal totals must equal the journal adjustment amount.','journal_amount',v_journal.amount_gbp,'debits',v_total_debits,'credits',v_total_credits));
  END IF;

  IF v_vat_line.id IS NOT NULL THEN
    IF v_journal.target_box = 1 AND v_journal.direction = 'increase' AND NOT (v_vat_line.credit_amount_gbp = v_journal.amount_gbp AND v_vat_line.debit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX1_INCREASE_MOVEMENT_INVALID','message','Increase Box 1 must credit the VAT-box line.'));
    END IF;
    IF v_journal.target_box = 1 AND v_journal.direction = 'decrease' AND NOT (v_vat_line.debit_amount_gbp = v_journal.amount_gbp AND v_vat_line.credit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX1_DECREASE_MOVEMENT_INVALID','message','Decrease Box 1 must debit the VAT-box line.'));
    END IF;
    IF v_journal.target_box = 4 AND v_journal.direction = 'increase' AND NOT (v_vat_line.debit_amount_gbp = v_journal.amount_gbp AND v_vat_line.credit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX4_INCREASE_MOVEMENT_INVALID','message','Increase Box 4 must debit the VAT-box line.'));
    END IF;
    IF v_journal.target_box = 4 AND v_journal.direction = 'decrease' AND NOT (v_vat_line.credit_amount_gbp = v_journal.amount_gbp AND v_vat_line.debit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX4_DECREASE_MOVEMENT_INVALID','message','Decrease Box 4 must credit the VAT-box line.'));
    END IF;
    IF v_journal.target_box = 6 AND v_journal.direction = 'increase' AND NOT (v_vat_line.credit_amount_gbp = v_journal.amount_gbp AND v_vat_line.debit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX6_INCREASE_MOVEMENT_INVALID','message','Increase Box 6 must credit the VAT-box line.'));
    END IF;
    IF v_journal.target_box = 6 AND v_journal.direction = 'decrease' AND NOT (v_vat_line.debit_amount_gbp = v_journal.amount_gbp AND v_vat_line.credit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX6_DECREASE_MOVEMENT_INVALID','message','Decrease Box 6 must debit the VAT-box line.'));
    END IF;
    IF v_journal.target_box = 7 AND v_journal.direction = 'increase' AND NOT (v_vat_line.debit_amount_gbp = v_journal.amount_gbp AND v_vat_line.credit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX7_INCREASE_MOVEMENT_INVALID','message','Increase Box 7 must debit the VAT-box line.'));
    END IF;
    IF v_journal.target_box = 7 AND v_journal.direction = 'decrease' AND NOT (v_vat_line.credit_amount_gbp = v_journal.amount_gbp AND v_vat_line.debit_amount_gbp = 0) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BOX7_DECREASE_MOVEMENT_INVALID','message','Decrease Box 7 must credit the VAT-box line.'));
    END IF;
  END IF;

  v_vat_mapping_code := CASE v_journal.target_box
    WHEN 1 THEN 'VAT_OUTPUT_BOX_CONTROL_LEDGER'
    WHEN 4 THEN 'VAT_INPUT_BOX_CONTROL_LEDGER'
    WHEN 6 THEN 'VAT_OUTPUT_NET_CONTROL_LEDGER'
    WHEN 7 THEN 'VAT_INPUT_NET_CONTROL_LEDGER'
  END;

  SELECT * INTO v_vat_mapping
  FROM public.sage_mapping_settings
  WHERE mapping_code = v_vat_mapping_code
    AND value_kind = 'ledger_account_id'
    AND is_active = true
    AND NULLIF(trim(COALESCE(sage_external_id, '')), '') IS NOT NULL;

  SELECT * INTO v_balance_mapping
  FROM public.sage_mapping_settings
  WHERE mapping_code = v_balance_mapping_code
    AND value_kind = 'ledger_account_id'
    AND is_active = true
    AND NULLIF(trim(COALESCE(sage_external_id, '')), '') IS NOT NULL;

  IF v_vat_mapping.mapping_code IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','VAT_BOX_LEDGER_MAPPING_MISSING','message','VAT-box ledger mapping is missing or inactive.','mapping_code',v_vat_mapping_code));
  END IF;

  IF v_balance_mapping.mapping_code IS NULL THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code','BALANCING_LEDGER_MAPPING_MISSING','message','VAT adjustment suspense/control ledger mapping is missing or inactive.','mapping_code',v_balance_mapping_code));
  END IF;

  v_payload_hash := md5(jsonb_build_object(
    'journal_id', v_journal.id,
    'target_box', v_journal.target_box,
    'direction', v_journal.direction,
    'amount_gbp', v_journal.amount_gbp,
    'idempotency_key', v_journal.idempotency_key,
    'vat_line', CASE WHEN v_vat_line.id IS NULL THEN NULL ELSE to_jsonb(v_vat_line) END,
    'balancing_line', CASE WHEN v_balance_line.id IS NULL THEN NULL ELSE to_jsonb(v_balance_line) END,
    'vat_mapping_code', v_vat_mapping_code,
    'balancing_mapping_code', v_balance_mapping_code
  )::text);

  IF jsonb_array_length(v_errors) = 0 THEN
    v_status := 'dry_run_validated';

    UPDATE public.vat_return_adjustment_journal_lines
    SET sage_ledger_account_id = CASE
          WHEN id = v_vat_line.id THEN v_vat_mapping.sage_external_id
          WHEN id = v_balance_line.id THEN v_balance_mapping.sage_external_id
          ELSE sage_ledger_account_id
        END,
        sage_ledger_account_display = CASE
          WHEN id = v_vat_line.id THEN v_vat_mapping.sage_display_name
          WHEN id = v_balance_line.id THEN v_balance_mapping.sage_display_name
          ELSE sage_ledger_account_display
        END
    WHERE vat_return_adjustment_journal_id = v_journal.id;

    UPDATE public.vat_return_adjustment_journals
    SET status = 'dry_run_validated',
        payload_hash = v_payload_hash,
        last_error = NULL,
        request_payload = COALESCE(request_payload, '{}'::jsonb) || jsonb_build_object(
          'dry_run_validated_at', now(),
          'dry_run_validated_by_staff_id', v_staff_id,
          'payload_hash', v_payload_hash,
          'ledger_mapping_codes', jsonb_build_object('vat_box_line', v_vat_mapping_code, 'balancing_line', v_balance_mapping_code)
        ),
        updated_at = now()
    WHERE id = v_journal.id;
  ELSE
    v_status := 'dry_run_failed';

    UPDATE public.vat_return_adjustment_journals
    SET status = 'dry_run_failed',
        payload_hash = v_payload_hash,
        last_error = left(v_errors::text, 2000),
        request_payload = COALESCE(request_payload, '{}'::jsonb) || jsonb_build_object(
          'dry_run_failed_at', now(),
          'dry_run_failed_by_staff_id', v_staff_id,
          'dry_run_errors', v_errors,
          'dry_run_warnings', v_warnings,
          'payload_hash', v_payload_hash,
          'ledger_mapping_codes', jsonb_build_object('vat_box_line', v_vat_mapping_code, 'balancing_line', v_balance_mapping_code)
        ),
        updated_at = now()
    WHERE id = v_journal.id;
  END IF;

  RETURN jsonb_build_object(
    'journal_id', v_journal.id,
    'vat_return_run_id', v_journal.vat_return_run_id,
    'status', v_status,
    'valid', v_status = 'dry_run_validated',
    'errors', v_errors,
    'warnings', v_warnings,
    'payload_hash', v_payload_hash,
    'target_box', v_journal.target_box,
    'direction', v_journal.direction,
    'amount_gbp', v_journal.amount_gbp,
    'ledger_mapping_codes', jsonb_build_object('vat_box_line', v_vat_mapping_code, 'balancing_line', v_balance_mapping_code),
    'posting_allowed', false
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.staff_validate_vat_adjustment_journal_dry_run_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_validate_vat_adjustment_journal_dry_run_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
