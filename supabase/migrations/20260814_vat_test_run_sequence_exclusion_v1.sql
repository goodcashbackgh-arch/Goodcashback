BEGIN;

-- VAT test-run sequence exclusion v1
-- Governing authority:
-- docs/governing-pack/architecture/VAT_TEST_RUN_SEQUENCE_EXCLUSION_ADDENDUM_v1.md
--
-- Narrow purpose: preserve the historical posted Sage journal test run exactly as
-- accounting/audit history while excluding it from the monthly VAT run sequence.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.vat_return_runs
  ADD COLUMN IF NOT EXISTS sequence_excluded_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS sequence_excluded_reason text NULL;

DO $guard$
DECLARE
  v_sequence_guard_hash text;
  v_target_count integer;
  v_target_journal_count integer;
BEGIN
  SELECT md5(pg_get_functiondef(p.oid))
  INTO v_sequence_guard_hash
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'enforce_vat_return_run_sequence_v1'
    AND pg_get_function_identity_arguments(p.oid) = ''
  LIMIT 1;

  IF v_sequence_guard_hash IS NULL THEN
    RAISE EXCEPTION 'VAT sequence guard function is missing; refusing sequence-exclusion migration.';
  END IF;

  IF v_sequence_guard_hash <> 'b9c58dc96096999f0066a63dc5fc796e' THEN
    RAISE EXCEPTION 'VAT sequence guard fingerprint drift: expected b9c58dc96096999f0066a63dc5fc796e, got %. Refusing overwrite.', v_sequence_guard_hash;
  END IF;

  SELECT count(*)
  INTO v_target_count
  FROM public.vat_return_runs r
  WHERE r.id = '87b23d75-3729-4695-bef0-d8c5d34cdf06'::uuid
    AND r.run_ref = 'VAT-JOURNAL-TEST-65c54eaea6b24cc6a3a23d9657ac00cd'
    AND r.return_period_label = 'Journal adjustment test only'
    AND r.status = 'sage_adjustment_journals_posted'
    AND r.period_start_date = DATE '2026-05-01'
    AND r.period_end_date = DATE '2026-05-31';

  IF v_target_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one governed journal-test VAT run; found %. No exclusion applied.', v_target_count;
  END IF;

  SELECT count(*)
  INTO v_target_journal_count
  FROM public.vat_return_adjustment_journals j
  WHERE j.id = 'bfcc0531-ecfd-4f23-b64a-c1c9e5f1ae55'::uuid
    AND j.vat_return_run_id = '87b23d75-3729-4695-bef0-d8c5d34cdf06'::uuid
    AND j.status = 'posted_to_sage'
    AND j.sage_journal_id = '6098fed5102947a38191e4767648f3ed';

  IF v_target_journal_count <> 1 THEN
    RAISE EXCEPTION 'Expected governed posted Sage test journal is missing or drifted. No exclusion applied.';
  END IF;
END
$guard$;

UPDATE public.vat_return_runs r
SET sequence_excluded_at = COALESCE(r.sequence_excluded_at, now()),
    sequence_excluded_reason = COALESCE(
      NULLIF(trim(r.sequence_excluded_reason), ''),
      'TEST ONLY: historical posted Sage journal test run retained for audit but excluded from VAT monthly sequence.'
    ),
    updated_at = now()
WHERE r.id = '87b23d75-3729-4695-bef0-d8c5d34cdf06'::uuid
  AND r.run_ref = 'VAT-JOURNAL-TEST-65c54eaea6b24cc6a3a23d9657ac00cd'
  AND r.return_period_label = 'Journal adjustment test only'
  AND r.status = 'sage_adjustment_journals_posted'
  AND r.period_start_date = DATE '2026-05-01'
  AND r.period_end_date = DATE '2026-05-31';

DO $post_seed$
DECLARE
  v_excluded_count integer;
  v_target_status text;
  v_journal_status text;
  v_sage_journal_id text;
BEGIN
  SELECT count(*)
  INTO v_excluded_count
  FROM public.vat_return_runs
  WHERE sequence_excluded_at IS NOT NULL;

  IF v_excluded_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one sequence-excluded VAT run after seed; found %.', v_excluded_count;
  END IF;

  SELECT status INTO v_target_status
  FROM public.vat_return_runs
  WHERE id = '87b23d75-3729-4695-bef0-d8c5d34cdf06'::uuid;

  IF v_target_status IS DISTINCT FROM 'sage_adjustment_journals_posted' THEN
    RAISE EXCEPTION 'Journal-test VAT run status changed unexpectedly to %.', v_target_status;
  END IF;

  SELECT status, sage_journal_id
  INTO v_journal_status, v_sage_journal_id
  FROM public.vat_return_adjustment_journals
  WHERE id = 'bfcc0531-ecfd-4f23-b64a-c1c9e5f1ae55'::uuid;

  IF v_journal_status IS DISTINCT FROM 'posted_to_sage'
     OR v_sage_journal_id IS DISTINCT FROM '6098fed5102947a38191e4767648f3ed' THEN
    RAISE EXCEPTION 'Posted Sage test journal changed unexpectedly.';
  END IF;
END
$post_seed$;

CREATE OR REPLACE FUNCTION public.enforce_vat_return_run_sequence_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_existing_open record;
  v_latest_allowed_start date := date_trunc('month', current_date - interval '1 month')::date;
BEGIN
  -- Sequence-excluded rows retain their accounting status/history but do not
  -- participate in monthly run ordering.
  IF NEW.sequence_excluded_at IS NULL
     AND NEW.status NOT IN ('matched_to_sage_locked', 'superseded') THEN
    IF NEW.period_start_date > v_latest_allowed_start THEN
      RAISE EXCEPTION 'Cannot create VAT return run for future/incomplete period %. Latest eligible completed monthly period starts %.', NEW.period_start_date, v_latest_allowed_start;
    END IF;

    SELECT r.id, r.return_period_label, r.period_start_date, r.period_end_date, r.status
    INTO v_existing_open
    FROM public.vat_return_runs r
    WHERE r.sequence_excluded_at IS NULL
      AND r.status NOT IN ('matched_to_sage_locked', 'superseded')
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
$fn$;

COMMENT ON FUNCTION public.enforce_vat_return_run_sequence_v1() IS
  'Blocks out-of-sequence and future/incomplete active VAT runs while ignoring explicitly audited sequence-excluded test/history rows.';

NOTIFY pgrst, 'reload schema';

COMMIT;
