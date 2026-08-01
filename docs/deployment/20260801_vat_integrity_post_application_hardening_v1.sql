-- Run only after the production application is confirmed to call
-- staff_record_vat_sage_submission_and_lock_v2.
-- Do not include this file in database-first automated migrations.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '60s';

DO $$
DECLARE
  v_expected text := '8a5f7590500abc1b16a8717e9075da45';
  v_actual text;
BEGIN
  SELECT md5(pg_get_functiondef(to_regprocedure(
    'public.staff_record_vat_sage_submission_and_lock_v1(uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamp with time zone,text,jsonb,numeric,text)'
  ))) INTO v_actual;

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Lock v1 fingerprint changed; stop rather than revoke against an unreviewed function. Expected %, found %.', v_expected, v_actual;
  END IF;

  IF to_regprocedure(
    'public.staff_record_vat_sage_submission_and_lock_v2(uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamp with time zone,text,jsonb,numeric,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Lock v2 is not installed.';
  END IF;
END $$;

REVOKE EXECUTE ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v1(
  uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamptz,text,jsonb,numeric,text
) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v1(
  uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamptz,text,jsonb,numeric,text
) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
