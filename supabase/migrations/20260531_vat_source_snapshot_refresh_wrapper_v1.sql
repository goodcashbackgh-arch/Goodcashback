BEGIN;

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
        'refresh_version', 'staff_refresh_vat_return_source_snapshot_v1',
        'purchase_refresh', v_purchase
      ),
      blockers_summary_json = jsonb_build_object(
        'open_blockers', v_blockers,
        'refresh_version', 'staff_refresh_vat_return_source_snapshot_v1',
        'sage_posting_performed', false,
        'journal_approval_performed', false
      ),
      updated_at = now()
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
    'purchase_refresh', v_purchase,
    'open_blockers', v_blockers
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
