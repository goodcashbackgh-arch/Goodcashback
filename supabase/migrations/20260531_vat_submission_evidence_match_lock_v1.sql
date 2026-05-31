BEGIN;

-- VAT submission evidence + Sage match/lock RPC
-- SQL-first tested in Supabase on May 2026 VAT run.
-- Result proved:
-- matched = true
-- locked = true
-- all submitted_minus_expected boxes = 0
-- status = matched_to_sage_locked
-- evidence_id = 78ac952b-1c60-4caf-a146-99bbeb3a2e53

CREATE OR REPLACE FUNCTION public.staff_record_vat_sage_submission_and_lock_v1(
  p_vat_return_run_id uuid,
  p_sage_return_reference text,
  p_sage_submitted_box1_gbp numeric,
  p_sage_submitted_box2_gbp numeric,
  p_sage_submitted_box3_gbp numeric,
  p_sage_submitted_box4_gbp numeric,
  p_sage_submitted_box5_gbp numeric,
  p_sage_submitted_box6_gbp numeric,
  p_sage_submitted_box7_gbp numeric,
  p_sage_submitted_box8_gbp numeric DEFAULT 0,
  p_sage_submitted_box9_gbp numeric DEFAULT 0,
  p_sage_submission_timestamp timestamptz DEFAULT now(),
  p_evidence_url text DEFAULT NULL,
  p_evidence_json jsonb DEFAULT '{}'::jsonb,
  p_tolerance_gbp numeric DEFAULT 0.01,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_run public.vat_return_runs%rowtype;
  v_open_blockers integer := 0;
  v_unfinished_journals integer := 0;
  v_evidence_id uuid;
  v_match boolean;
  v_diff jsonb;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT submission match/lock action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.locked_at IS NOT NULL OR v_run.status = 'matched_to_sage_locked' THEN
    RAISE EXCEPTION 'VAT return is already locked.';
  END IF;

  SELECT count(*) INTO v_open_blockers
  FROM public.vat_return_blockers b
  WHERE b.vat_return_run_id = p_vat_return_run_id
    AND b.status = 'open'
    AND b.severity = 'blocker';

  IF v_open_blockers > 0 THEN
    RAISE EXCEPTION 'Cannot lock VAT return: % open blocker(s).', v_open_blockers;
  END IF;

  SELECT count(*) INTO v_unfinished_journals
  FROM public.vat_return_adjustment_journals j
  WHERE j.vat_return_run_id = p_vat_return_run_id
    AND j.status NOT IN ('posted_to_sage', 'included_in_sage_return', 'reversed');

  IF v_unfinished_journals > 0 THEN
    RAISE EXCEPTION 'Cannot lock VAT return: % adjustment journal(s) not posted/included/reversed.', v_unfinished_journals;
  END IF;

  v_diff := jsonb_build_object(
    'box1', round((p_sage_submitted_box1_gbp - v_run.expected_box1_gbp)::numeric, 2),
    'box2', round((p_sage_submitted_box2_gbp - v_run.expected_box2_gbp)::numeric, 2),
    'box3', round((p_sage_submitted_box3_gbp - v_run.expected_box3_gbp)::numeric, 2),
    'box4', round((p_sage_submitted_box4_gbp - v_run.expected_box4_gbp)::numeric, 2),
    'box5', round((p_sage_submitted_box5_gbp - v_run.expected_box5_gbp)::numeric, 2),
    'box6', round((p_sage_submitted_box6_gbp - v_run.expected_box6_gbp)::numeric, 2),
    'box7', round((p_sage_submitted_box7_gbp - v_run.expected_box7_gbp)::numeric, 2),
    'box8', round((p_sage_submitted_box8_gbp - v_run.expected_box8_gbp)::numeric, 2),
    'box9', round((p_sage_submitted_box9_gbp - v_run.expected_box9_gbp)::numeric, 2)
  );

  v_match :=
    abs(p_sage_submitted_box1_gbp - v_run.expected_box1_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box2_gbp - v_run.expected_box2_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box3_gbp - v_run.expected_box3_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box4_gbp - v_run.expected_box4_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box5_gbp - v_run.expected_box5_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box6_gbp - v_run.expected_box6_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box7_gbp - v_run.expected_box7_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box8_gbp - v_run.expected_box8_gbp) <= p_tolerance_gbp
    and abs(p_sage_submitted_box9_gbp - v_run.expected_box9_gbp) <= p_tolerance_gbp;

  INSERT INTO public.vat_return_sage_match_evidence (
    vat_return_run_id,
    sage_submitted_box1_gbp,
    sage_submitted_box2_gbp,
    sage_submitted_box3_gbp,
    sage_submitted_box4_gbp,
    sage_submitted_box5_gbp,
    sage_submitted_box6_gbp,
    sage_submitted_box7_gbp,
    sage_submitted_box8_gbp,
    sage_submitted_box9_gbp,
    sage_return_reference,
    sage_submission_timestamp,
    evidence_url,
    evidence_json,
    match_status,
    tolerance_gbp,
    matched_by_staff_id,
    matched_at,
    locked_by_staff_id,
    locked_at,
    notes
  )
  VALUES (
    p_vat_return_run_id,
    p_sage_submitted_box1_gbp,
    p_sage_submitted_box2_gbp,
    p_sage_submitted_box3_gbp,
    p_sage_submitted_box4_gbp,
    p_sage_submitted_box5_gbp,
    p_sage_submitted_box6_gbp,
    p_sage_submitted_box7_gbp,
    p_sage_submitted_box8_gbp,
    p_sage_submitted_box9_gbp,
    p_sage_return_reference,
    p_sage_submission_timestamp,
    p_evidence_url,
    COALESCE(p_evidence_json, '{}'::jsonb) || jsonb_build_object(
      'expected_boxes', jsonb_build_object(
        'box1', v_run.expected_box1_gbp,
        'box2', v_run.expected_box2_gbp,
        'box3', v_run.expected_box3_gbp,
        'box4', v_run.expected_box4_gbp,
        'box5', v_run.expected_box5_gbp,
        'box6', v_run.expected_box6_gbp,
        'box7', v_run.expected_box7_gbp,
        'box8', v_run.expected_box8_gbp,
        'box9', v_run.expected_box9_gbp
      ),
      'submitted_minus_expected', v_diff
    ),
    CASE WHEN v_match THEN 'locked' ELSE 'mismatch_needs_admin_review' END,
    p_tolerance_gbp,
    CASE WHEN v_match THEN v_staff_id ELSE NULL END,
    CASE WHEN v_match THEN now() ELSE NULL END,
    CASE WHEN v_match THEN v_staff_id ELSE NULL END,
    CASE WHEN v_match THEN now() ELSE NULL END,
    p_notes
  )
  RETURNING id INTO v_evidence_id;

  IF v_match THEN
    UPDATE public.vat_return_runs
    SET status = 'matched_to_sage_locked',
        locked_by_staff_id = v_staff_id,
        locked_at = now(),
        updated_at = now(),
        notes = COALESCE(notes, '') || E'\nMatched and locked to Sage VAT submission: ' || COALESCE(p_sage_return_reference, v_evidence_id::text)
    WHERE id = p_vat_return_run_id;
  ELSE
    UPDATE public.vat_return_runs
    SET status = 'mismatch_needs_admin_review',
        updated_at = now()
    WHERE id = p_vat_return_run_id;
  END IF;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'evidence_id', v_evidence_id,
    'matched', v_match,
    'locked', v_match,
    'submitted_minus_expected', v_diff,
    'new_status', CASE WHEN v_match THEN 'matched_to_sage_locked' ELSE 'mismatch_needs_admin_review' END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v1(
  uuid, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, timestamptz, text, jsonb, numeric, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v1(
  uuid, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, timestamptz, text, jsonb, numeric, text
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
