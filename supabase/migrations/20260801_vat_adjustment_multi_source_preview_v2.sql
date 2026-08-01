BEGIN;

CREATE OR REPLACE FUNCTION public.staff_preview_vat_adjustment_journal_proposals_v2(
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
  v_recon record;
  v_gap record;
  v_group record;
  v_source record;
  v_gap_amount numeric(18,2);
  v_abs_gap numeric(18,2);
  v_direction text;
  v_remaining numeric(18,2);
  v_alloc numeric(18,2);
  v_source_basis numeric(18,2);
  v_group_total numeric(18,2);
  v_allocations jsonb;
  v_proposals jsonb := '[]'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_gap_summary jsonb := '[]'::jsonb;
  v_account_role text;
  v_vat_box_debit numeric(18,2);
  v_vat_box_credit numeric(18,2);
  v_balancing_debit numeric(18,2);
  v_balancing_credit numeric(18,2);
  v_idempotency_key text;
  v_allocation_identity text;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT adjustment proposal preview action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  SELECT * INTO v_recon
  FROM public.vat_return_sage_reconstruction_snapshots r
  WHERE r.vat_return_run_id = p_vat_return_run_id
  ORDER BY r.created_at DESC
  LIMIT 1;

  IF v_recon.id IS NULL THEN
    RAISE EXCEPTION 'No Sage VAT reconstruction snapshot found for VAT return run.';
  END IF;

  FOR v_gap IN
    SELECT *
    FROM (
      VALUES
        (1, 'Box 1 output VAT', COALESCE(v_run.expected_box1_gbp, 0), COALESCE(v_recon.box1_gbp, 0)),
        (4, 'Box 4 input VAT', COALESCE(v_run.expected_box4_gbp, 0), COALESCE(v_recon.box4_gbp, 0)),
        (6, 'Box 6 outputs net', COALESCE(v_run.expected_box6_gbp, 0), COALESCE(v_recon.box6_gbp, 0)),
        (7, 'Box 7 inputs net', COALESCE(v_run.expected_box7_gbp, 0), COALESCE(v_recon.box7_gbp, 0))
    ) AS g(target_box, box_label, platform_amount_gbp, sage_natural_amount_gbp)
  LOOP
    v_gap_amount := round((v_gap.platform_amount_gbp - v_gap.sage_natural_amount_gbp)::numeric, 2);

    IF abs(v_gap_amount) <= p_tolerance_gbp THEN
      CONTINUE;
    END IF;

    v_abs_gap := abs(v_gap_amount);
    v_direction := CASE WHEN v_gap_amount >= 0 THEN 'increase' ELSE 'decrease' END;

    v_gap_summary := v_gap_summary || jsonb_build_array(jsonb_build_object(
      'target_box', v_gap.target_box,
      'box_label', v_gap.box_label,
      'platform_amount_gbp', v_gap.platform_amount_gbp,
      'sage_natural_amount_gbp', v_gap.sage_natural_amount_gbp,
      'gap_gbp', v_gap_amount,
      'abs_gap_gbp', v_abs_gap,
      'direction', v_direction
    ));

    -- Pick one provably compatible group. Grouping is deliberately stricter
    -- than box/direction alone and may block rather than guess.
    SELECT * INTO v_group
    FROM (
      SELECT
        l.line_kind,
        l.vat_basis,
        l.tax_point_date,
        l.adjustment_reason,
        l.prior_vat_return_line_id,
        count(*) AS source_count,
        round(sum(CASE
          WHEN v_gap.target_box IN (1,4) THEN abs(l.vat_amount_gbp)
          WHEN v_gap.target_box IN (6,7) THEN abs(l.amount_gbp)
          ELSE 0
        END), 2) AS group_total_gbp
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = p_vat_return_run_id
        AND l.status = 'active'
        AND l.adjustment_required = true
        AND l.box_number = v_gap.target_box
        AND (
          (v_direction = 'increase' AND l.direction IN ('natural','increase'))
          OR (v_direction = 'decrease' AND l.direction = 'decrease')
        )
      GROUP BY
        l.line_kind,
        l.vat_basis,
        l.tax_point_date,
        l.adjustment_reason,
        l.prior_vat_return_line_id
      HAVING round(sum(CASE
        WHEN v_gap.target_box IN (1,4) THEN abs(l.vat_amount_gbp)
        WHEN v_gap.target_box IN (6,7) THEN abs(l.amount_gbp)
        ELSE 0
      END), 2) >= round(v_abs_gap - p_tolerance_gbp, 2)
    ) compatible_groups
    ORDER BY
      abs(group_total_gbp - v_abs_gap),
      source_count,
      line_kind,
      tax_point_date NULLS LAST,
      prior_vat_return_line_id NULLS FIRST
    LIMIT 1;

    IF v_group.line_kind IS NULL THEN
      SELECT round(COALESCE(sum(CASE
        WHEN v_gap.target_box IN (1,4) THEN abs(l.vat_amount_gbp)
        WHEN v_gap.target_box IN (6,7) THEN abs(l.amount_gbp)
        ELSE 0
      END), 0), 2)
      INTO v_group_total
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = p_vat_return_run_id
        AND l.status = 'active'
        AND l.adjustment_required = true
        AND l.box_number = v_gap.target_box
        AND (
          (v_direction = 'increase' AND l.direction IN ('natural','increase'))
          OR (v_direction = 'decrease' AND l.direction = 'decrease')
        );

      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
        'severity', 'blocker',
        'code', CASE
          WHEN COALESCE(v_group_total, 0) = 0 THEN 'VAT_GAP_HAS_NO_SOURCE_LINE'
          WHEN v_group_total < v_abs_gap - p_tolerance_gbp THEN 'VAT_GAP_SOURCE_LINE_SHORTFALL'
          ELSE 'VAT_GAP_SOURCES_NOT_COMPATIBLE_FOR_GROUPING'
        END,
        'target_box', v_gap.target_box,
        'box_label', v_gap.box_label,
        'gap_gbp', v_gap_amount,
        'candidate_source_total_gbp', COALESCE(v_group_total, 0),
        'required_action', 'Review source compatibility. V2 will not combine lines with different source, date, VAT-basis or correction semantics.'
      ));
      CONTINUE;
    END IF;

    v_remaining := v_abs_gap;
    v_allocations := '[]'::jsonb;

    FOR v_source IN
      SELECT l.*
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = p_vat_return_run_id
        AND l.status = 'active'
        AND l.adjustment_required = true
        AND l.box_number = v_gap.target_box
        AND l.line_kind IS NOT DISTINCT FROM v_group.line_kind
        AND l.vat_basis IS NOT DISTINCT FROM v_group.vat_basis
        AND l.tax_point_date IS NOT DISTINCT FROM v_group.tax_point_date
        AND l.adjustment_reason IS NOT DISTINCT FROM v_group.adjustment_reason
        AND l.prior_vat_return_line_id IS NOT DISTINCT FROM v_group.prior_vat_return_line_id
        AND (
          (v_direction = 'increase' AND l.direction IN ('natural','increase'))
          OR (v_direction = 'decrease' AND l.direction = 'decrease')
        )
      ORDER BY l.created_at, l.id
    LOOP
      EXIT WHEN v_remaining <= p_tolerance_gbp;

      v_source_basis := round(CASE
        WHEN v_gap.target_box IN (1,4) THEN abs(v_source.vat_amount_gbp)
        WHEN v_gap.target_box IN (6,7) THEN abs(v_source.amount_gbp)
        ELSE 0
      END, 2);

      IF v_source_basis <= 0 THEN
        CONTINUE;
      END IF;

      v_alloc := least(v_source_basis, v_remaining);

      v_allocations := v_allocations || jsonb_build_array(jsonb_build_object(
        'vat_return_run_line_id', v_source.id,
        'allocated_amount_gbp', round(v_alloc, 2),
        'line_kind', v_source.line_kind,
        'source_table', v_source.source_table,
        'source_id', v_source.source_id,
        'source_ref', v_source.source_ref,
        'source_direction', v_source.direction,
        'source_amount_gbp', v_source.amount_gbp,
        'vat_amount_gbp', v_source.vat_amount_gbp,
        'vat_basis', v_source.vat_basis,
        'tax_point_date', v_source.tax_point_date,
        'prior_vat_return_line_id', v_source.prior_vat_return_line_id
      ));

      v_remaining := round(v_remaining - v_alloc, 2);
    END LOOP;

    IF v_remaining > p_tolerance_gbp THEN
      v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
        'severity', 'blocker',
        'code', 'VAT_GAP_COMPATIBLE_GROUP_ALLOCATION_SHORTFALL',
        'target_box', v_gap.target_box,
        'gap_gbp', v_gap_amount,
        'remaining_gbp', v_remaining
      ));
      CONTINUE;
    END IF;

    v_account_role := CASE v_gap.target_box
      WHEN 1 THEN 'vat_output_box_control'
      WHEN 4 THEN 'vat_input_box_control'
      WHEN 6 THEN 'vat_output_net_control'
      WHEN 7 THEN 'vat_input_net_control'
    END;

    IF v_gap.target_box IN (1,6) THEN
      IF v_direction = 'increase' THEN
        v_vat_box_debit := 0; v_vat_box_credit := v_abs_gap;
        v_balancing_debit := v_abs_gap; v_balancing_credit := 0;
      ELSE
        v_vat_box_debit := v_abs_gap; v_vat_box_credit := 0;
        v_balancing_debit := 0; v_balancing_credit := v_abs_gap;
      END IF;
    ELSE
      IF v_direction = 'increase' THEN
        v_vat_box_debit := v_abs_gap; v_vat_box_credit := 0;
        v_balancing_debit := 0; v_balancing_credit := v_abs_gap;
      ELSE
        v_vat_box_debit := 0; v_vat_box_credit := v_abs_gap;
        v_balancing_debit := v_abs_gap; v_balancing_credit := 0;
      END IF;
    END IF;

    SELECT string_agg(
      concat_ws(':',
        x ->> 'vat_return_run_line_id',
        to_char((x ->> 'allocated_amount_gbp')::numeric, 'FM999999999999990.00')
      ),
      '|' ORDER BY x ->> 'vat_return_run_line_id'
    )
    INTO v_allocation_identity
    FROM jsonb_array_elements(v_allocations) x;

    v_idempotency_key := md5(
      p_vat_return_run_id::text || ':' ||
      v_gap.target_box::text || ':' ||
      v_direction || ':' ||
      to_char(v_abs_gap, 'FM999999999999990.00') || ':' ||
      COALESCE(v_allocation_identity, '')
    );

    v_proposals := v_proposals || jsonb_build_array(jsonb_build_object(
      'vat_return_run_id', p_vat_return_run_id,
      'target_box', v_gap.target_box,
      'box_label', v_gap.box_label,
      'direction', v_direction,
      'amount_gbp', v_abs_gap,
      'reason', COALESCE(v_group.adjustment_reason, 'Sage natural VAT does not match platform VAT position.'),
      'idempotency_key', v_idempotency_key,
      'endpoint_path', '/journals',
      'method', 'POST',
      'proposal_status', 'preview_only_not_posted',
      'source_allocation_version', 'multi_source_v1',
      'source_allocations', v_allocations,
      'source_count', jsonb_array_length(v_allocations),
      'proposed_vat_box_journal_line', jsonb_build_object(
        'line_no', 1,
        'line_role', 'vat_box_line',
        'account_role', v_account_role,
        'target_box', v_gap.target_box,
        'debit_amount_gbp', v_vat_box_debit,
        'credit_amount_gbp', v_vat_box_credit,
        'include_on_tax_return', true
      ),
      'proposed_balancing_journal_line', jsonb_build_object(
        'line_no', 2,
        'line_role', 'balancing_line',
        'account_role', 'vat_adjustment_suspense',
        'target_box', NULL,
        'debit_amount_gbp', v_balancing_debit,
        'credit_amount_gbp', v_balancing_credit,
        'include_on_tax_return', false
      )
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'run_status', v_run.status,
    'sage_reconstruction_id', v_recon.id,
    'tolerance_gbp', p_tolerance_gbp,
    'gap_summary', v_gap_summary,
    'proposal_count', jsonb_array_length(v_proposals),
    'proposals', v_proposals,
    'blocker_count', jsonb_array_length(v_blockers),
    'blockers', v_blockers,
    'preview_only', true,
    'shadow_mode', true,
    'posting_allowed', false,
    'contract_version', 'VAT_ADJUSTMENT_MULTI_SOURCE_ALLOCATION_ADDENDUM_v1'
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.staff_preview_vat_adjustment_journal_proposals_v2(uuid, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_preview_vat_adjustment_journal_proposals_v2(uuid, numeric)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
