BEGIN;

CREATE OR REPLACE FUNCTION public.staff_materialise_vat_adjustment_journal_proposals_v2(
  p_vat_return_run_id uuid,
  p_tolerance_gbp numeric DEFAULT 0.01
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_staff_id uuid;
  v_run public.vat_return_runs%rowtype;
  v_preview jsonb;
  v_proposal jsonb;
  v_journal_id uuid;
  v_existing_status text;
  v_primary_source_id uuid;
  v_line jsonb;
  v_allocation_result jsonb;
  v_created jsonb := '[]'::jsonb;
  v_now timestamptz := now();
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT adjustment queue action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.locked_at IS NOT NULL OR v_run.status IN (
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review'
  ) THEN
    RAISE EXCEPTION 'VAT return run is not editable for v2 journal materialisation.';
  END IF;

  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v2(
    p_vat_return_run_id,
    p_tolerance_gbp
  );

  IF COALESCE((v_preview ->> 'blocker_count')::integer, 0) > 0 THEN
    RAISE EXCEPTION 'VAT adjustment proposal blockers exist: %', v_preview -> 'blockers';
  END IF;

  IF COALESCE((v_preview ->> 'proposal_count')::integer, 0) = 0 THEN
    RETURN jsonb_build_object(
      'vat_return_run_id', p_vat_return_run_id,
      'status', 'no_adjustment_journals_required',
      'created_count', 0,
      'journals', '[]'::jsonb,
      'posting_allowed', false
    );
  END IF;

  FOR v_proposal IN
    SELECT value FROM jsonb_array_elements(v_preview -> 'proposals')
  LOOP
    v_journal_id := NULL;
    v_existing_status := NULL;

    SELECT (x ->> 'vat_return_run_line_id')::uuid
    INTO v_primary_source_id
    FROM jsonb_array_elements(v_proposal -> 'source_allocations') x
    ORDER BY x ->> 'vat_return_run_line_id'
    LIMIT 1;

    INSERT INTO public.vat_return_adjustment_journals (
      vat_return_run_id,
      vat_return_run_line_id,
      adjustment_type,
      target_box,
      direction,
      amount_gbp,
      status,
      idempotency_key,
      endpoint_path,
      method,
      request_payload,
      source_allocation_version,
      created_at,
      updated_at
    ) VALUES (
      p_vat_return_run_id,
      v_primary_source_id,
      CASE
        WHEN (v_proposal ->> 'target_box')::integer = 1 AND v_proposal ->> 'direction' = 'increase' THEN 'box1_export_evidence_breach'
        WHEN (v_proposal ->> 'target_box')::integer = 1 AND v_proposal ->> 'direction' = 'decrease' THEN 'box1_export_evidence_reinstatement'
        WHEN (v_proposal ->> 'target_box')::integer = 4 THEN 'box4_input_vat_adjustment'
        WHEN (v_proposal ->> 'target_box')::integer = 6 AND v_proposal ->> 'direction' = 'increase' THEN 'box6_output_net_prepayment_adjustment'
        WHEN (v_proposal ->> 'target_box')::integer = 6 AND v_proposal ->> 'direction' = 'decrease' THEN 'box6_output_net_reversal_adjustment'
        WHEN (v_proposal ->> 'target_box')::integer = 7 THEN 'box7_input_net_adjustment'
        ELSE 'vat_box_adjustment'
      END,
      (v_proposal ->> 'target_box')::integer,
      v_proposal ->> 'direction',
      (v_proposal ->> 'amount_gbp')::numeric(18,2),
      'platform_calculated',
      v_proposal ->> 'idempotency_key',
      '/journals',
      'POST',
      jsonb_build_object(
        'preview_only_source_proposal', v_proposal,
        'posting_status', 'not_posted',
        'created_by_rpc', 'staff_materialise_vat_adjustment_journal_proposals_v2',
        'created_at', v_now,
        'contract_version', 'VAT_ADJUSTMENT_MULTI_SOURCE_ALLOCATION_ADDENDUM_v1'
      ),
      'multi_source_v1',
      v_now,
      v_now
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO v_journal_id;

    IF v_journal_id IS NULL THEN
      SELECT j.id, j.status
      INTO v_journal_id, v_existing_status
      FROM public.vat_return_adjustment_journals j
      WHERE j.idempotency_key = v_proposal ->> 'idempotency_key'
      FOR UPDATE;

      IF v_journal_id IS NULL THEN
        RAISE EXCEPTION 'Idempotent VAT adjustment journal could not be resolved for key %.',
          v_proposal ->> 'idempotency_key';
      END IF;

      IF v_existing_status NOT IN ('platform_calculated','dry_run_failed') THEN
        RAISE EXCEPTION 'Existing VAT adjustment journal % is not editable for idempotent rematerialisation; status %.',
          v_journal_id, v_existing_status;
      END IF;

      UPDATE public.vat_return_adjustment_journals
      SET request_payload = jsonb_build_object(
            'preview_only_source_proposal', v_proposal,
            'posting_status', 'not_posted',
            'created_by_rpc', 'staff_materialise_vat_adjustment_journal_proposals_v2',
            'created_at', v_now,
            'contract_version', 'VAT_ADJUSTMENT_MULTI_SOURCE_ALLOCATION_ADDENDUM_v1'
          ),
          updated_at = v_now
      WHERE id = v_journal_id;
    END IF;

    DELETE FROM public.vat_return_adjustment_journal_lines
    WHERE vat_return_adjustment_journal_id = v_journal_id;

    FOR v_line IN
      SELECT value FROM jsonb_array_elements(jsonb_build_array(
        v_proposal -> 'proposed_vat_box_journal_line',
        v_proposal -> 'proposed_balancing_journal_line'
      ))
    LOOP
      INSERT INTO public.vat_return_adjustment_journal_lines (
        vat_return_adjustment_journal_id,
        line_no,
        line_role,
        account_role,
        debit_amount_gbp,
        credit_amount_gbp,
        include_on_tax_return,
        target_box,
        line_payload,
        created_at
      ) VALUES (
        v_journal_id,
        (v_line ->> 'line_no')::integer,
        v_line ->> 'line_role',
        v_line ->> 'account_role',
        COALESCE((v_line ->> 'debit_amount_gbp')::numeric(18,2), 0),
        COALESCE((v_line ->> 'credit_amount_gbp')::numeric(18,2), 0),
        COALESCE((v_line ->> 'include_on_tax_return')::boolean, false),
        NULLIF(v_line ->> 'target_box', '')::integer,
        v_line,
        v_now
      );
    END LOOP;

    v_allocation_result := public.staff_replace_vat_adjustment_source_allocations_v1(
      v_journal_id,
      v_proposal -> 'source_allocations'
    );

    v_created := v_created || jsonb_build_array(jsonb_build_object(
      'journal_id', v_journal_id,
      'target_box', (v_proposal ->> 'target_box')::integer,
      'direction', v_proposal ->> 'direction',
      'amount_gbp', (v_proposal ->> 'amount_gbp')::numeric(18,2),
      'source_count', jsonb_array_length(v_proposal -> 'source_allocations'),
      'source_allocation_hash', v_allocation_result ->> 'source_allocation_hash',
      'status', 'platform_calculated',
      'posting_allowed', false
    ));
  END LOOP;

  UPDATE public.vat_return_runs
  SET status = 'sage_adjustment_journals_pending',
      updated_at = v_now
  WHERE id = p_vat_return_run_id
    AND status IN ('draft','calculated','admin_review_required','blocked','admin_approved','reopened_for_correction');

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'status', 'multi_source_v1_journal_queue_created',
    'created_count', jsonb_array_length(v_created),
    'journals', v_created,
    'preview', v_preview,
    'posting_allowed', false
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.staff_materialise_vat_adjustment_journal_proposals_v2(uuid, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_materialise_vat_adjustment_journal_proposals_v2(uuid, numeric)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
