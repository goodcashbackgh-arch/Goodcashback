BEGIN;

-- Tighten VAT supersede RPC so the earliest open/current return cannot be superseded.
-- Only later out-of-sequence packs may be removed from the active sequence.

CREATE OR REPLACE FUNCTION public.staff_supersede_vat_return_run_v1(
  p_vat_return_run_id uuid,
  p_reason text DEFAULT 'Out-of-sequence draft superseded by admin'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_run record;
  v_earlier_open record;
  v_posted_journals integer := 0;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT supersede action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.status IN ('matched_to_sage_locked', 'sage_return_submitted', 'sage_adjustment_journals_posted', 'superseded') THEN
    RAISE EXCEPTION 'Cannot supersede VAT return run in status %.', v_run.status;
  END IF;

  SELECT r.id, r.return_period_label, r.period_start_date, r.period_end_date, r.status
  INTO v_earlier_open
  FROM public.vat_return_runs r
  WHERE r.status NOT IN ('matched_to_sage_locked', 'superseded')
    AND r.id IS DISTINCT FROM p_vat_return_run_id
    AND r.period_start_date < v_run.period_start_date
  ORDER BY r.period_start_date ASC, r.created_at ASC
  LIMIT 1;

  IF v_earlier_open.id IS NULL THEN
    RAISE EXCEPTION 'Only later out-of-sequence VAT draft packs can be superseded. Finish or correct the earliest open period first.';
  END IF;

  SELECT count(*) INTO v_posted_journals
  FROM public.vat_return_adjustment_journals j
  WHERE j.vat_return_run_id = p_vat_return_run_id
    AND j.status IN ('posting_to_sage', 'posted_to_sage', 'included_in_sage_return', 'requires_reversal', 'reversed');

  IF v_posted_journals > 0 THEN
    RAISE EXCEPTION 'Cannot supersede VAT return run with posted/in-flight Sage journal rows.';
  END IF;

  UPDATE public.vat_return_runs
  SET status = 'superseded',
      superseded_by_staff_id = v_staff_id,
      superseded_at = now(),
      superseded_reason = nullif(trim(coalesce(p_reason, '')), ''),
      updated_at = now()
  WHERE id = p_vat_return_run_id;

  UPDATE public.vat_return_run_lines
  SET status = 'superseded'
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active';

  UPDATE public.vat_return_blockers
  SET status = 'waived',
      resolved_by_staff_id = v_staff_id,
      resolved_at = now(),
      resolution_notes = concat_ws(E'\n', resolution_notes, 'Waived because VAT return pack was superseded.')
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'open';

  RETURN jsonb_build_object('vat_return_run_id', p_vat_return_run_id, 'status', 'superseded');
END;
$$;

REVOKE ALL ON FUNCTION public.staff_supersede_vat_return_run_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_supersede_vat_return_run_v1(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
