BEGIN;

-- VAT Return Workbench sequence guard v1
-- Prevents generating or inserting a new open VAT run while any earlier/current run is still unlocked.
-- Also prevents creating a draft/open VAT run for a future monthly period.
-- Controlling contract: docs/governing-pack/ui/VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1.md

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
  -- Locked historical/correction records can exist, but any open/draft workflow must be sequential.
  IF NEW.status <> 'matched_to_sage_locked' THEN
    IF NEW.period_start_date > v_latest_allowed_start THEN
      RAISE EXCEPTION 'Cannot create VAT return run for future/incomplete period %. Latest eligible completed monthly period starts %.', NEW.period_start_date, v_latest_allowed_start;
    END IF;

    SELECT r.id, r.return_period_label, r.period_start_date, r.period_end_date, r.status
    INTO v_existing_open
    FROM public.vat_return_runs r
    WHERE r.status <> 'matched_to_sage_locked'
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

DROP TRIGGER IF EXISTS trg_enforce_vat_return_run_sequence_v1 ON public.vat_return_runs;
CREATE TRIGGER trg_enforce_vat_return_run_sequence_v1
BEFORE INSERT ON public.vat_return_runs
FOR EACH ROW
EXECUTE FUNCTION public.enforce_vat_return_run_sequence_v1();

COMMENT ON FUNCTION public.enforce_vat_return_run_sequence_v1() IS 'Blocks out-of-sequence and future/incomplete open VAT return runs. Existing historical anomalies must be reviewed separately.';

NOTIFY pgrst, 'reload schema';

COMMIT;
