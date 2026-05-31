BEGIN;

CREATE OR REPLACE FUNCTION public.staff_materialise_vat_adjustment_journal_proposals_v1(
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
  v_proposal_count integer := 0;
  v_blocker_count integer := 0;
  v_inserted_journals jsonb := '[]'::jsonb;
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

  SELECT *
  INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.status IN (
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review'
  )
  OR v_run.locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'VAT return run is not editable for adjustment queue creation. Current status: %, locked_at: %',
      v_run.status,
      v_run.locked_at;
  END IF;

  IF v_run.status NOT IN (
    'draft',
    'calculated',
    'admin_review_required',
    'blocked',
    'admin_approved',
    'sage_adjustment_journals_pending',
    'reopened_for_correction'
  ) THEN
    RAISE EXCEPTION 'VAT return run status % is not allowed for adjustment queue creation.', v_run.status;
  END IF;

  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v1(
    p_vat_return_run_id,
    p_tolerance_gbp
  );

  v_blocker_count := COALESCE((v_preview ->> 'blocker_count')::integer, 0);
  v_proposal_count := COALESCE((v_preview ->> 'proposal_count')::integer, 0);

  IF v_blocker_count > 0 THEN
    RAISE EXCEPTION 'VAT adjustment proposal blockers exist. Resolve blockers before creating journal queue. Blockers: %',
      v_preview -> 'blockers';
  END IF;

  IF v_proposal_count = 0 THEN
    RETURN jsonb_build_object(
      'vat_return_run_id', p_vat_return_run_id,
      'status', 'no_adjustment_journals_required',
      'created_count', 0,
      'journals', '[]'::jsonb,
      'preview', v_preview,
      'posting_allowed', false
    );
  END IF;

  WITH proposals AS (
    SELECT value AS p
    FROM jsonb_array_elements(v_preview -> 'proposals')
  ),
  inserted AS (
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
      created_at,
      updated_at
    )
    SELECT
      p_vat_return_run_id,
      (p #>> '{source_vat_line,vat_return_run_line_id}')::uuid,
      CASE
        WHEN (p ->> 'target_box')::integer = 1 AND p ->> 'direction' = 'increase' THEN 'box1_export_evidence_breach'
        WHEN (p ->> 'target_box')::integer = 1 AND p ->> 'direction' = 'decrease' THEN 'box1_export_evidence_reinstatement'
        WHEN (p ->> 'target_box')::integer = 4 THEN 'box4_input_vat_adjustment'
        WHEN (p ->> 'target_box')::integer = 6 AND p ->> 'direction' = 'increase' THEN 'box6_output_net_prepayment_adjustment'
        WHEN (p ->> 'target_box')::integer = 6 AND p ->> 'direction' = 'decrease' THEN 'box6_output_net_reversal_adjustment'
        WHEN (p ->> 'target_box')::integer = 7 THEN 'box7_input_net_adjustment'
        ELSE 'vat_box_adjustment'
      END,
      (p ->> 'target_box')::integer,
      p ->> 'direction',
      (p ->> 'amount_gbp')::numeric(18,2),
      'platform_calculated',
      p ->> 'idempotency_key',
      '/journals',
      'POST',
      jsonb_build_object(
        'preview_only_source_proposal', p,
        'posting_status', 'not_posted',
        'created_by_rpc', 'staff_materialise_vat_adjustment_journal_proposals_v1',
        'created_at', v_now,
        'contract_version', 'VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1'
      ),
      v_now,
      v_now
    FROM proposals
    ON CONFLICT (idempotency_key) DO UPDATE
      SET request_payload = EXCLUDED.request_payload,
          updated_at = EXCLUDED.updated_at
      WHERE public.vat_return_adjustment_journals.status IN ('platform_calculated','dry_run_failed')
    RETURNING
      id,
      vat_return_run_id,
      vat_return_run_line_id,
      adjustment_type,
      target_box,
      direction,
      amount_gbp,
      status,
      idempotency_key,
      request_payload
  ),
  line_source AS (
    SELECT i.id AS journal_id, 1 AS line_no, i.request_payload #> '{preview_only_source_proposal,proposed_vat_box_journal_line}' AS line_json
    FROM inserted i
    UNION ALL
    SELECT i.id AS journal_id, 2 AS line_no, i.request_payload #> '{preview_only_source_proposal,proposed_balancing_journal_line}' AS line_json
    FROM inserted i
  ),
  inserted_lines AS (
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
    )
    SELECT
      journal_id,
      line_no,
      line_json ->> 'line_role',
      line_json ->> 'account_role',
      COALESCE((line_json ->> 'debit_amount_gbp')::numeric(18,2), 0),
      COALESCE((line_json ->> 'credit_amount_gbp')::numeric(18,2), 0),
      COALESCE((line_json ->> 'include_on_tax_return')::boolean, false),
      NULLIF(line_json ->> 'target_box', '')::integer,
      line_json,
      v_now
    FROM line_source
    ON CONFLICT (vat_return_adjustment_journal_id, line_no) DO UPDATE
      SET line_role = EXCLUDED.line_role,
          account_role = EXCLUDED.account_role,
          debit_amount_gbp = EXCLUDED.debit_amount_gbp,
          credit_amount_gbp = EXCLUDED.credit_amount_gbp,
          include_on_tax_return = EXCLUDED.include_on_tax_return,
          target_box = EXCLUDED.target_box,
          line_payload = EXCLUDED.line_payload
    RETURNING
      vat_return_adjustment_journal_id,
      line_no,
      line_role,
      account_role,
      debit_amount_gbp,
      credit_amount_gbp,
      include_on_tax_return,
      target_box
  ),
  journal_json AS (
    SELECT jsonb_build_object(
      'journal_id', i.id,
      'vat_return_run_line_id', i.vat_return_run_line_id,
      'adjustment_type', i.adjustment_type,
      'target_box', i.target_box,
      'direction', i.direction,
      'amount_gbp', i.amount_gbp,
      'status', i.status,
      'idempotency_key', i.idempotency_key,
      'endpoint_path', '/journals',
      'method', 'POST',
      'posting_allowed', false,
      'lines', COALESCE((
        SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no)
        FROM inserted_lines l
        WHERE l.vat_return_adjustment_journal_id = i.id
      ), '[]'::jsonb)
    ) AS journal
    FROM inserted i
  )
  SELECT COALESCE(jsonb_agg(journal), '[]'::jsonb)
  INTO v_inserted_journals
  FROM journal_json;

  UPDATE public.vat_return_runs
  SET status = 'sage_adjustment_journals_pending',
      updated_at = v_now
  WHERE id = p_vat_return_run_id
    AND status IN ('draft','calculated','admin_review_required','blocked','admin_approved','reopened_for_correction');

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'status', 'platform_calculated_journal_queue_created',
    'created_count', jsonb_array_length(v_inserted_journals),
    'journals', v_inserted_journals,
    'preview', v_preview,
    'posting_allowed', false
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.staff_materialise_vat_adjustment_journal_proposals_v1(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_materialise_vat_adjustment_journal_proposals_v1(uuid, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
