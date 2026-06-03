BEGIN;

CREATE OR REPLACE FUNCTION public.staff_approve_direct_sage_purchase_posting_lines_into_vat_return_v1(
  p_vat_return_run_id uuid,
  p_sage_snapshot_id uuid,
  p_selected_line_indexes int[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_run public.vat_return_runs%rowtype;
  v_snapshot public.vat_return_sage_reconstruction_snapshots%rowtype;
  v_latest_snapshot_id uuid;
  v_lines jsonb;
  v_selected_count integer;
  v_duplicate_count integer;
  v_invalid_count integer;
  v_line record;
  v_base_box4 numeric(18,2) := 0;
  v_base_box7 numeric(18,2) := 0;
  v_selected_box4 numeric(18,2) := 0;
  v_selected_box7 numeric(18,2) := 0;
  v_expected_box4 numeric(18,2) := 0;
  v_expected_box7 numeric(18,2) := 0;
  v_remaining_box4 numeric(18,2) := 0;
  v_remaining_box7 numeric(18,2) := 0;
  v_now timestamptz := now();
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only direct Sage purchase posting approval action.';
  END IF;

  IF p_selected_line_indexes IS NULL OR array_length(p_selected_line_indexes, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one direct Sage posting line to approve.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot approve direct Sage postings because VAT return run is locked.';
  END IF;

  IF v_run.status IN ('admin_approved', 'sage_adjustment_journals_pending', 'sage_adjustment_journals_posted', 'sage_return_review_required', 'sage_return_submitted', 'matched_to_sage_locked', 'mismatch_needs_admin_review', 'reopened_for_correction') THEN
    RAISE EXCEPTION 'Cannot approve direct Sage postings for VAT run in status %.', v_run.status;
  END IF;

  SELECT * INTO v_snapshot
  FROM public.vat_return_sage_reconstruction_snapshots
  WHERE id = p_sage_snapshot_id
    AND vat_return_run_id = p_vat_return_run_id
  LIMIT 1;

  IF v_snapshot.id IS NULL THEN
    RAISE EXCEPTION 'Sage reconstruction snapshot not found for this VAT return run.';
  END IF;

  IF COALESCE(v_snapshot.source_summary #>> '{purchase_vat_line_review,version}', '') <> 'direct_sage_purchase_postings_review_v1' THEN
    RAISE EXCEPTION 'Selected Sage snapshot is not a direct Sage purchase postings review snapshot.';
  END IF;

  SELECT s.id INTO v_latest_snapshot_id
  FROM public.vat_return_sage_reconstruction_snapshots s
  WHERE s.vat_return_run_id = p_vat_return_run_id
    AND COALESCE(s.source_summary #>> '{purchase_vat_line_review,version}', '') = 'direct_sage_purchase_postings_review_v1'
    AND NOT (COALESCE(s.source_basis, '') LIKE 'sage_draft_vat_return_totals_import%')
    AND COALESCE(s.source_summary ->> 'source_mode', '') = ''
    AND NOT (COALESCE(s.source_summary ->> 'version', '') LIKE 'sage_draft_vat_return_totals_import%')
  ORDER BY s.created_at DESC, s.id DESC
  LIMIT 1;

  IF v_latest_snapshot_id IS NULL OR v_latest_snapshot_id <> p_sage_snapshot_id THEN
    RAISE EXCEPTION 'Selected Sage snapshot is not the latest applicable direct Sage purchase postings review snapshot.';
  END IF;

  v_lines := v_snapshot.source_summary #> '{purchase_vat_line_review,direct_sage_purchase_postings_not_on_platform}';

  IF v_lines IS NULL OR jsonb_typeof(v_lines) <> 'array' THEN
    RAISE EXCEPTION 'Selected Sage snapshot has no line-level direct Sage purchase postings review array.';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS selected_direct_sage_purchase_lines(
    selected_line_index integer PRIMARY KEY,
    line_json jsonb NOT NULL
  ) ON COMMIT DROP;
  TRUNCATE selected_direct_sage_purchase_lines;

  SELECT count(*) INTO v_selected_count FROM unnest(p_selected_line_indexes) AS idx;
  SELECT count(*) INTO v_duplicate_count
  FROM (
    SELECT idx
    FROM unnest(p_selected_line_indexes) AS idx
    GROUP BY idx
    HAVING count(*) > 1
  ) d;

  IF v_selected_count = 0 THEN
    RAISE EXCEPTION 'Select at least one direct Sage posting line to approve.';
  END IF;

  IF v_duplicate_count > 0 THEN
    RAISE EXCEPTION 'Selected direct Sage posting line indexes contain duplicates.';
  END IF;

  SELECT count(*) INTO v_invalid_count
  FROM unnest(p_selected_line_indexes) AS idx
  WHERE idx < 0 OR idx >= jsonb_array_length(v_lines);

  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION 'One or more selected direct Sage posting line indexes are out of range.';
  END IF;

  INSERT INTO selected_direct_sage_purchase_lines(selected_line_index, line_json)
  SELECT idx, v_lines -> idx
  FROM unnest(p_selected_line_indexes) AS idx;

  SELECT count(*) INTO v_invalid_count
  FROM selected_direct_sage_purchase_lines l
  WHERE l.line_json IS NULL
     OR jsonb_typeof(l.line_json) <> 'object'
     OR COALESCE(l.line_json ->> 'classification', '') <> 'direct_sage_purchase_posting_not_on_platform'
     OR lower(COALESCE(l.line_json ->> 'platform_controlled', 'false')) = 'true'
     OR COALESCE(l.line_json ->> 'classification', '') = 'review_required_purchase_posting'
     OR lower(COALESCE(l.line_json ->> 'review_required', 'false')) = 'true'
     OR COALESCE(NULLIF(l.line_json ->> 'sage_document_id', ''), '') = ''
     OR COALESCE(NULLIF(l.line_json ->> 'document_label', ''), '') = '';

  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION 'One or more selected direct Sage posting lines are not valid approval candidates.';
  END IF;

  UPDATE public.vat_return_run_lines
  SET status = 'superseded'
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND line_kind IN ('direct_sage_purchase_posting_not_via_platform_box4', 'direct_sage_purchase_posting_not_via_platform_box7');

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_base_box4
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND box_number = 4
    AND status = 'active';

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_base_box7
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND box_number = 7
    AND status = 'active';

  SELECT round(COALESCE(sum(COALESCE(NULLIF(line_json ->> 'effective_box4_amount', '')::numeric, 0)), 0)::numeric, 2),
         round(COALESCE(sum(COALESCE(NULLIF(line_json ->> 'effective_box7_amount', '')::numeric, 0)), 0)::numeric, 2)
  INTO v_selected_box4, v_selected_box7
  FROM selected_direct_sage_purchase_lines;

  v_expected_box4 := round((v_base_box4 + v_selected_box4)::numeric, 2);
  v_expected_box7 := round((v_base_box7 + v_selected_box7)::numeric, 2);
  v_remaining_box4 := round((v_expected_box4 - COALESCE(v_snapshot.box4_gbp, 0))::numeric, 2);
  v_remaining_box7 := round((v_expected_box7 - COALESCE(v_snapshot.box7_gbp, 0))::numeric, 2);

  IF abs(v_remaining_box4) > 0.01 OR abs(v_remaining_box7) > 0.01 THEN
    RAISE EXCEPTION 'Selected direct Sage postings do not reconcile to nil. Remaining Box 4: %, remaining Box 7: %.', v_remaining_box4, v_remaining_box7;
  END IF;

  FOR v_line IN SELECT selected_line_index, line_json FROM selected_direct_sage_purchase_lines ORDER BY selected_line_index LOOP
    IF round(COALESCE(NULLIF(v_line.line_json ->> 'effective_box4_amount', '')::numeric, 0), 2) <> 0 THEN
      INSERT INTO public.vat_return_run_lines (
        vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
        box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
        natural_sage_covered, adjustment_required, adjustment_reason, status
      ) VALUES (
        p_vat_return_run_id,
        'direct_sage_purchase_posting_not_via_platform_box4',
        'vat_return_sage_reconstruction_snapshots',
        p_sage_snapshot_id,
        COALESCE(NULLIF(v_line.line_json ->> 'document_label', ''), v_line.line_json ->> 'sage_document_id'),
        v_line.line_json,
        jsonb_build_object(
          'sage_snapshot_id', p_sage_snapshot_id,
          'selected_line_index', v_line.selected_line_index,
          'sage_document_id', v_line.line_json ->> 'sage_document_id',
          'sage_api_path', v_line.line_json ->> 'sage_api_path',
          'approval_type', 'direct_sage_purchase_posting_not_via_platform',
          'approved_by_staff_id', v_staff_id,
          'approved_at', v_now
        ),
        4,
        CASE WHEN round(COALESCE(NULLIF(v_line.line_json ->> 'effective_box4_amount', '')::numeric, 0), 2) < 0 THEN 'decrease' ELSE 'increase' END,
        abs(round(COALESCE(NULLIF(v_line.line_json ->> 'effective_box4_amount', '')::numeric, 0), 2)),
        abs(round(COALESCE(NULLIF(v_line.line_json ->> 'effective_box4_amount', '')::numeric, 0), 2)),
        'direct_sage_purchase_posting_not_via_platform_box4',
        CASE WHEN COALESCE(v_line.line_json ->> 'document_date', '') ~ '^\d{4}-\d{2}-\d{2}' THEN substring(v_line.line_json ->> 'document_date' from 1 for 10)::date ELSE v_run.period_end_date END,
        v_run.return_period_label,
        true,
        false,
        'admin_accepted_direct_sage_posting_not_via_platform',
        'active'
      );
    END IF;

    IF round(COALESCE(NULLIF(v_line.line_json ->> 'effective_box7_amount', '')::numeric, 0), 2) <> 0 THEN
      INSERT INTO public.vat_return_run_lines (
        vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
        box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
        natural_sage_covered, adjustment_required, adjustment_reason, status
      ) VALUES (
        p_vat_return_run_id,
        'direct_sage_purchase_posting_not_via_platform_box7',
        'vat_return_sage_reconstruction_snapshots',
        p_sage_snapshot_id,
        COALESCE(NULLIF(v_line.line_json ->> 'document_label', ''), v_line.line_json ->> 'sage_document_id'),
        v_line.line_json,
        jsonb_build_object(
          'sage_snapshot_id', p_sage_snapshot_id,
          'selected_line_index', v_line.selected_line_index,
          'sage_document_id', v_line.line_json ->> 'sage_document_id',
          'sage_api_path', v_line.line_json ->> 'sage_api_path',
          'approval_type', 'direct_sage_purchase_posting_not_via_platform',
          'approved_by_staff_id', v_staff_id,
          'approved_at', v_now
        ),
        7,
        CASE WHEN round(COALESCE(NULLIF(v_line.line_json ->> 'effective_box7_amount', '')::numeric, 0), 2) < 0 THEN 'decrease' ELSE 'increase' END,
        abs(round(COALESCE(NULLIF(v_line.line_json ->> 'effective_box7_amount', '')::numeric, 0), 2)),
        0,
        'direct_sage_purchase_posting_not_via_platform_box7',
        CASE WHEN COALESCE(v_line.line_json ->> 'document_date', '') ~ '^\d{4}-\d{2}-\d{2}' THEN substring(v_line.line_json ->> 'document_date' from 1 for 10)::date ELSE v_run.period_end_date END,
        v_run.return_period_label,
        true,
        false,
        'admin_accepted_direct_sage_posting_not_via_platform',
        'active'
      );
    END IF;
  END LOOP;

  UPDATE public.vat_return_runs
  SET expected_box4_gbp = v_expected_box4,
      expected_box7_gbp = v_expected_box7,
      expected_box5_gbp = round((COALESCE(expected_box3_gbp, 0) - v_expected_box4)::numeric, 2),
      source_counts_json = COALESCE(source_counts_json, '{}'::jsonb) || jsonb_build_object(
        'direct_sage_purchase_posting_line_approval', jsonb_build_object(
          'snapshot_id', p_sage_snapshot_id,
          'selected_line_indexes', to_jsonb(p_selected_line_indexes),
          'selected_line_count', v_selected_count,
          'approved_box4_gbp', v_selected_box4,
          'approved_box7_gbp', v_selected_box7,
          'approved_by_staff_id', v_staff_id,
          'approved_at', v_now
        )
      ),
      updated_at = v_now
  WHERE id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'sage_snapshot_id', p_sage_snapshot_id,
    'selected_line_count', v_selected_count,
    'approved_box4_gbp', v_selected_box4,
    'approved_box7_gbp', v_selected_box7,
    'expected_box4_gbp', v_expected_box4,
    'expected_box7_gbp', v_expected_box7
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_approve_direct_sage_purchase_posting_lines_into_vat_return_v1(uuid, uuid, int[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_approve_direct_sage_purchase_posting_lines_into_vat_return_v1(uuid, uuid, int[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
