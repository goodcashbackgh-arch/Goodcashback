BEGIN;

-- Fix workbench selected/all-matching freeze support for refreeze pointers.
-- Superseded/cancelled batch rows can be selectable pointers back to the current
-- source. This patch makes the bulk candidate RPC include exactly one such
-- pointer per source/lane when candidate_kind = freeze.
--
-- No data mutation. No Sage call. No schema change.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $do$
DECLARE
  v_oid oid := to_regprocedure('public.internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)');
  v_sql text;
  v_before text;
  v_after text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  v_before := $needle$WHERE row_is_candidate = true$needle$;
  v_after := $replacement$WHERE row_is_candidate = true
    OR (
      v_candidate_kind = 'freeze'
      AND out_work_queue = 'cancelled_or_superseded'
      AND out_selectable = true
    )$replacement$;

  IF position(v_after in v_sql) = 0 THEN
    IF position(v_before in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find candidate filter in internal_accounting_command_centre_bulk_candidates_v1';
    END IF;
    v_sql := replace(v_sql, v_before, v_after);
    EXECUTE v_sql;
  END IF;
END
$do$;

NOTIFY pgrst, 'reload schema';
COMMIT;
