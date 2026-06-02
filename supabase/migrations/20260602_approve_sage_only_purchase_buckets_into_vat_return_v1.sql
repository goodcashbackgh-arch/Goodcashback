BEGIN;

-- Thin approval overlay for the existing VAT source-line model.
-- Purpose: after admin reviews Sage-only purchase-side differences, approved buckets are
-- added into vat_return_run_lines so the platform VAT return reconciles to Sage natural VAT.
-- No Sage journal posting. No change to source refresh rules, evidence breach, prepayment,
-- no-invoice timing, journal validation, approval, or posting.

CREATE OR REPLACE FUNCTION public.staff_approve_sage_only_purchase_buckets_into_vat_return_v1(
  p_vat_return_run_id uuid,
  p_sage_snapshot_id uuid,
  p_bucket_keys text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_run record;
  v_snapshot record;
  v_buckets jsonb;
  v_bucket_key text;
  v_bucket jsonb;
  v_box4 numeric(18,2);
  v_box7 numeric(18,2);
  v_total_box4 numeric(18,2) := 0;
  v_total_box7 numeric(18,2) := 0;
  v_approved jsonb := '[]'::jsonb;
  v_expected_box4 numeric(18,2) := 0;
  v_expected_box7 numeric(18,2) := 0;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only Sage-only purchase approval action.';
  END IF;

  IF p_bucket_keys IS NULL OR array_length(p_bucket_keys, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one Sage-only purchase bucket to approve.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.status IN ('admin_approved', 'sage_adjustment_journals_pending', 'sage_adjustment_journals_posted', 'sage_return_review_required', 'sage_return_submitted', 'matched_to_sage_locked', 'mismatch_needs_admin_review', 'reopened_for_correction')
     OR v_run.locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot approve Sage-only purchase buckets for VAT run in status %.', v_run.status;
  END IF;

  SELECT * INTO v_snapshot
  FROM public.vat_return_sage_reconstruction_snapshots
  WHERE id = p_sage_snapshot_id
    AND vat_return_run_id = p_vat_return_run_id
  LIMIT 1;

  IF v_snapshot.id IS NULL THEN
    RAISE EXCEPTION 'Sage reconstruction/import snapshot not found for this VAT return run.';
  END IF;

  v_buckets := v_snapshot.source_summary #> '{purchase_vat_line_review,buckets}';

  IF v_buckets IS NULL OR jsonb_typeof(v_buckets) <> 'object' THEN
    RAISE EXCEPTION 'Selected Sage snapshot has no Sage-only purchase review buckets.';
  END IF;

  -- Preserve audit by superseding only prior approved Sage-only purchase overlay rows.
  UPDATE public.vat_return_run_lines
  SET status = 'superseded'
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND line_kind IN ('sage_only_purchase_approved_box4', 'sage_only_purchase_approved_box7');

  FOREACH v_bucket_key IN ARRAY p_bucket_keys
  LOOP
    IF v_bucket_key LIKE 'platform_controlled%' THEN
      RAISE EXCEPTION 'Cannot approve platform-controlled bucket % as Sage-only.', v_bucket_key;
    END IF;

    v_bucket := v_buckets -> v_bucket_key;

    IF v_bucket IS NULL THEN
      RAISE EXCEPTION 'Bucket % was not found in the visible Sage-only purchase review.', v_bucket_key;
    END IF;

    v_box4 := round(COALESCE(NULLIF(v_bucket ->> 'box4', '')::numeric, 0), 2);
    v_box7 := round(COALESCE(NULLIF(v_bucket ->> 'box7', '')::numeric, 0), 2);

    IF v_box4 <> 0 THEN
      INSERT INTO public.vat_return_run_lines (
        vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
        box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
        natural_sage_covered, adjustment_required, adjustment_reason, status
      ) VALUES (
        p_vat_return_run_id,
        'sage_only_purchase_approved_box4',
        'vat_return_sage_reconstruction_snapshots',
        p_sage_snapshot_id,
        'sage_only_purchase_bucket:' || v_bucket_key || ':box4',
        jsonb_build_object('bucket', v_bucket_key, 'bucket_summary', v_bucket, 'approved_by_staff_id', v_staff_id, 'approved_at', now()),
        jsonb_build_object('sage_snapshot_id', p_sage_snapshot_id, 'source_basis', v_snapshot.source_basis, 'approval_type', 'sage_only_purchase_bucket_approval'),
        4,
        CASE WHEN v_box4 < 0 THEN 'decrease' ELSE 'increase' END,
        abs(v_box4),
        abs(v_box4),
        'approved_sage_only_purchase_bucket_box4',
        v_run.period_end_date,
        v_run.return_period_label,
        true,
        false,
        'admin_approved_sage_only_purchase_difference',
        'active'
      );
    END IF;

    IF v_box7 <> 0 THEN
      INSERT INTO public.vat_return_run_lines (
        vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
        box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
        natural_sage_covered, adjustment_required, adjustment_reason, status
      ) VALUES (
        p_vat_return_run_id,
        'sage_only_purchase_approved_box7',
        'vat_return_sage_reconstruction_snapshots',
        p_sage_snapshot_id,
        'sage_only_purchase_bucket:' || v_bucket_key || ':box7',
        jsonb_build_object('bucket', v_bucket_key, 'bucket_summary', v_bucket, 'approved_by_staff_id', v_staff_id, 'approved_at', now()),
        jsonb_build_object('sage_snapshot_id', p_sage_snapshot_id, 'source_basis', v_snapshot.source_basis, 'approval_type', 'sage_only_purchase_bucket_approval'),
        7,
        CASE WHEN v_box7 < 0 THEN 'decrease' ELSE 'increase' END,
        abs(v_box7),
        0,
        'approved_sage_only_purchase_bucket_box7',
        v_run.period_end_date,
        v_run.return_period_label,
        true,
        false,
        'admin_approved_sage_only_purchase_difference',
        'active'
      );
    END IF;

    v_total_box4 := round((v_total_box4 + v_box4)::numeric, 2);
    v_total_box7 := round((v_total_box7 + v_box7)::numeric, 2);
    v_approved := v_approved || jsonb_build_array(jsonb_build_object('bucket', v_bucket_key, 'box4', v_box4, 'box7', v_box7));
  END LOOP;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_expected_box4
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND box_number = 4
    AND status = 'active';

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_expected_box7
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND box_number = 7
    AND status = 'active';

  UPDATE public.vat_return_runs
  SET expected_box4_gbp = round(v_expected_box4::numeric, 2),
      expected_box5_gbp = round((COALESCE(expected_box3_gbp, 0) - v_expected_box4)::numeric, 2),
      expected_box7_gbp = round(v_expected_box7::numeric, 2),
      source_counts_json = COALESCE(source_counts_json, '{}'::jsonb) || jsonb_build_object(
        'sage_only_purchase_approval', jsonb_build_object(
          'snapshot_id', p_sage_snapshot_id,
          'approved_buckets', v_approved,
          'approved_box4_gbp', v_total_box4,
          'approved_box7_gbp', v_total_box7,
          'approved_by_staff_id', v_staff_id,
          'approved_at', now()
        )
      ),
      updated_at = now()
  WHERE id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'sage_snapshot_id', p_sage_snapshot_id,
    'approved_buckets', v_approved,
    'approved_box4_gbp', v_total_box4,
    'approved_box7_gbp', v_total_box7,
    'expected_box4_gbp', v_expected_box4,
    'expected_box7_gbp', v_expected_box7
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_approve_sage_only_purchase_buckets_into_vat_return_v1(uuid, uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_approve_sage_only_purchase_buckets_into_vat_return_v1(uuid, uuid, text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
