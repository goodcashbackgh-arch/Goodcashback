BEGIN;

-- Prevent a VAT return run from being marked as Sage-adjustment-posted while any
-- required adjustment journal is still calculated, validated, approved, posting, or failed.
-- This fixes the premature close case where one posted journal closed the run while a
-- matching reversal/remaining journal was still waiting for approval/posting.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.guard_vat_adjustment_journal_posted_close_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_unfinished_count integer := 0;
BEGIN
  IF NEW.status = 'sage_adjustment_journals_posted'
     AND OLD.status IS DISTINCT FROM NEW.status THEN
    SELECT count(*)
    INTO v_unfinished_count
    FROM public.vat_return_adjustment_journals j
    WHERE j.vat_return_run_id = NEW.id
      AND j.status IN (
        'platform_calculated',
        'dry_run_validated',
        'dry_run_failed',
        'admin_approved',
        'posting_to_sage',
        'failed_retryable',
        'failed_terminal'
      );

    IF v_unfinished_count > 0 THEN
      NEW.status := OLD.status;
      NEW.blockers_summary_json := COALESCE(NEW.blockers_summary_json, '{}'::jsonb)
        || jsonb_build_object(
          'sage_adjustment_posted_close_guard',
          jsonb_build_object(
            'blocked_at', now(),
            'attempted_status', 'sage_adjustment_journals_posted',
            'kept_status', OLD.status,
            'unfinished_adjustment_journals', v_unfinished_count,
            'guard_version', '20260601_vat_adjustment_journal_posted_close_guard_v1'
          )
        );
    END IF;
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_guard_vat_adjustment_journal_posted_close_v1
ON public.vat_return_runs;

CREATE TRIGGER trg_guard_vat_adjustment_journal_posted_close_v1
BEFORE UPDATE OF status
ON public.vat_return_runs
FOR EACH ROW
EXECUTE FUNCTION public.guard_vat_adjustment_journal_posted_close_v1();

COMMENT ON FUNCTION public.guard_vat_adjustment_journal_posted_close_v1() IS
'Prevents premature VAT run closure to sage_adjustment_journals_posted while any adjustment journal remains unfinished.';

NOTIFY pgrst, 'reload schema';

COMMIT;
