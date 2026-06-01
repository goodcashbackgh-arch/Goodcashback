BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(p_vat_return_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_run record;
  v_purchase jsonb := '{}'::jsonb;
  v_box1 numeric(18,2) := 0;
  v_box2 numeric(18,2) := 0;
  v_box4 numeric(18,2) := 0;
  v_box6 numeric(18,2) := 0;
  v_box7 numeric(18,2) := 0;
  v_blockers integer := 0;
  v_sales_lines integer := 0;
  v_sales_credit_lines integer := 0;
  v_unproved_sales_lines integer := 0;
  v_now timestamptz := now();
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT source snapshot refresh action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.status IN ('admin_approved', 'sage_adjustment_journals_pending', 'sage_adjustment_journals_posted', 'sage_return_review_required', 'sage_return_submitted', 'matched_to_sage_locked', 'mismatch_needs_admin_review', 'superseded') THEN
    RAISE EXCEPTION 'Cannot refresh VAT source snapshot in status %.', v_run.status;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vat_return_adjustment_journals j
    WHERE j.vat_return_run_id = p_vat_return_run_id
      AND j.status IN ('platform_calculated', 'dry_run_validated', 'admin_approved', 'posting_to_sage', 'posted_to_sage', 'included_in_sage_return')
  ) THEN
    RAISE EXCEPTION 'Cannot refresh VAT source snapshot while active adjustment journal rows exist.';
  END IF;

  UPDATE public.vat_return_run_lines l
  SET status = 'superseded',
      adjustment_reason = COALESCE(l.adjustment_reason, 'superseded_by_strict_box6_sales_invoice_refresh_v1')
  WHERE l.vat_return_run_id = p_vat_return_run_id
    AND l.status = 'active'
    AND l.source_table = 'sales_invoices'
    AND l.line_kind = 'sales_invoice_box6_candidate';

  WITH source_sales AS (
    SELECT
      si.*,
      COALESCE(si.consideration_received_date, si.sage_invoice_date, si.created_at::date) AS vat_tax_point_date,
      (
        COALESCE(si.sage_status, '') = 'posted'
        AND NULLIF(trim(COALESCE(si.sage_invoice_id, '')), '') IS NOT NULL
      ) AS sage_proven_covered,
      CASE
        WHEN lower(COALESCE(si.invoice_type, '')) IN ('credit_note', 'credit note', 'sales_credit_note', 'sales credit note') THEN 'decrease'
        ELSE 'natural'
      END AS box6_direction
    FROM public.sales_invoices si
    WHERE COALESCE(si.consideration_received_date, si.sage_invoice_date, si.created_at::date)
      BETWEEN v_run.period_start_date AND v_run.period_end_date
  ), inserted_sales AS (
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
    )
    SELECT
      p_vat_return_run_id,
      'sales_invoice_box6_candidate',
      'sales_invoices',
      ss.id,
      COALESCE(ss.invoice_type, 'sales_invoice') || ':' || ss.id::text,
      to_jsonb(ss),
      jsonb_build_object(
        'sales_invoice_id', ss.id,
        'sage_invoice_id', ss.sage_invoice_id,
        'sage_status', ss.sage_status,
        'sage_posted_at', ss.sage_posted_at,
        'zero_rating_deadline_date', ss.zero_rating_deadline_date,
        'zero_rating_status', ss.zero_rating_status,
        'strict_sage_coverage_rule', 'sage_status_posted_and_sage_invoice_id_present',
        'box6_direction_rule', 'credit_note_decreases_box6'
      ),
      6,
      ss.box6_direction,
      abs(COALESCE(ss.amount_gbp, 0)),
      0,
      'sales_invoice_amount_gbp_strict_refresh_v1',
      ss.vat_tax_point_date,
      v_run.return_period_label,
      ss.sage_proven_covered,
      NOT ss.sage_proven_covered,
      CASE
        WHEN ss.sage_proven_covered THEN NULL
        WHEN COALESCE(ss.sage_status, '') = 'posted' AND NULLIF(trim(COALESCE(ss.sage_invoice_id, '')), '') IS NULL THEN 'box6_possible_sage_gap_sales_invoice_marked_posted_without_sage_invoice_id'
        ELSE 'box6_possible_sage_gap_sales_invoice_not_proven_in_sage'
      END,
      'active'
    FROM source_sales ss
    RETURNING direction, natural_sage_covered
  )
  SELECT
    count(*),
    count(*) FILTER (WHERE direction = 'decrease'),
    count(*) FILTER (WHERE natural_sage_covered IS DISTINCT FROM true)
  INTO v_sales_lines, v_sales_credit_lines, v_unproved_sales_lines
  FROM inserted_sales;

  v_purchase := public.staff_refresh_vat_purchase_source_lines_v1(p_vat_return_run_id);

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box1
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 1 AND status = 'active';

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box2
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 2 AND status = 'active';

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box4
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 4 AND status = 'active';

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box6
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 6 AND status = 'active';

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box7
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 7 AND status = 'active';

  SELECT count(*) INTO v_blockers
  FROM public.vat_return_blockers
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'open';

  UPDATE public.vat_return_runs
  SET expected_box1_gbp = v_box1,
      expected_box2_gbp = v_box2,
      expected_box3_gbp = v_box1 + v_box2,
      expected_box4_gbp = v_box4,
      expected_box5_gbp = (v_box1 + v_box2) - v_box4,
      expected_box6_gbp = v_box6,
      expected_box7_gbp = v_box7,
      expected_box8_gbp = 0,
      expected_box9_gbp = 0,
      source_counts_json = COALESCE(source_counts_json, '{}'::jsonb) || jsonb_build_object(
        'refresh_version', 'staff_refresh_vat_return_source_snapshot_v1_strict_box6_sales_invoice_v1',
        'sales_invoice_box6_candidate_lines', v_sales_lines,
        'sales_invoice_box6_credit_note_decrease_lines', v_sales_credit_lines,
        'sales_invoice_box6_unproved_sage_coverage_lines', v_unproved_sales_lines,
        'purchase_refresh', v_purchase
      ),
      blockers_summary_json = jsonb_build_object(
        'open_blockers', v_blockers,
        'refresh_version', 'staff_refresh_vat_return_source_snapshot_v1_strict_box6_sales_invoice_v1',
        'sage_posting_performed', false,
        'journal_approval_performed', false
      ),
      updated_at = v_now
  WHERE id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'expected_box1_gbp', v_box1,
    'expected_box2_gbp', v_box2,
    'expected_box3_gbp', v_box1 + v_box2,
    'expected_box4_gbp', v_box4,
    'expected_box5_gbp', (v_box1 + v_box2) - v_box4,
    'expected_box6_gbp', v_box6,
    'expected_box7_gbp', v_box7,
    'sales_invoice_box6_candidate_lines', v_sales_lines,
    'sales_invoice_box6_credit_note_decrease_lines', v_sales_credit_lines,
    'sales_invoice_box6_unproved_sage_coverage_lines', v_unproved_sales_lines,
    'purchase_refresh', v_purchase,
    'open_blockers', v_blockers
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) IS 'Admin-only VAT source refresh. Rebuilds Box 6 sales invoice lines using strict Sage coverage: posted status plus Sage object id; credit notes decrease Box 6.';

NOTIFY pgrst, 'reload schema';

COMMIT;
