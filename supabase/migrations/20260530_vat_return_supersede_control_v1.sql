BEGIN;

-- VAT return supersede control v1
-- Purpose: safely remove wrongly generated draft packs from the active VAT sequence without deleting audit history.
-- This is needed for accidental duplicate/future draft packs such as June/July generated before May was filed.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

ALTER TABLE public.vat_return_runs
  ADD COLUMN IF NOT EXISTS superseded_by_staff_id uuid NULL REFERENCES public.staff(id),
  ADD COLUMN IF NOT EXISTS superseded_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS superseded_reason text NULL;

ALTER TABLE public.vat_return_runs DROP CONSTRAINT IF EXISTS vat_return_runs_status_chk;
ALTER TABLE public.vat_return_runs
  ADD CONSTRAINT vat_return_runs_status_chk CHECK (status IN (
    'draft',
    'calculated',
    'admin_review_required',
    'blocked',
    'admin_approved',
    'sage_adjustment_journals_pending',
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review',
    'reopened_for_correction',
    'superseded'
  ));

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
  v_posted_journals integer := 0;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT supersede action.';
  END IF;

  SELECT *
  INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.status IN ('matched_to_sage_locked', 'sage_return_submitted', 'sage_adjustment_journals_posted') THEN
    RAISE EXCEPTION 'Cannot supersede VAT return run in status %.', v_run.status;
  END IF;

  SELECT count(*)
  INTO v_posted_journals
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
      notes = concat_ws(E'\n', notes, concat('Superseded: ', coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Out-of-sequence draft superseded by admin'))),
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

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'status', 'superseded'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_supersede_vat_return_run_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_supersede_vat_return_run_v1(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_vat_return_run_sequence_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing_open record;
  v_latest_allowed_start date := date_trunc('month', current_date - interval '1 month')::date;
BEGIN
  IF NEW.status NOT IN ('matched_to_sage_locked', 'superseded') THEN
    IF NEW.period_start_date > v_latest_allowed_start THEN
      RAISE EXCEPTION 'Cannot create VAT return run for future/incomplete period %. Latest eligible completed monthly period starts %.', NEW.period_start_date, v_latest_allowed_start;
    END IF;

    SELECT r.id, r.return_period_label, r.period_start_date, r.period_end_date, r.status
    INTO v_existing_open
    FROM public.vat_return_runs r
    WHERE r.status NOT IN ('matched_to_sage_locked', 'superseded')
      AND r.id IS DISTINCT FROM NEW.id
    ORDER BY r.period_start_date ASC, r.created_at ASC
    LIMIT 1;

    IF v_existing_open.id IS NOT NULL THEN
      RAISE EXCEPTION 'Cannot create VAT return run while prior/open VAT run remains unlocked: % (% to %, status %).',
        COALESCE(v_existing_open.return_period_label, v_existing_open.id::text),
        v_existing_open.period_start_date,
        v_existing_open.period_end_date,
        v_existing_open.status;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
