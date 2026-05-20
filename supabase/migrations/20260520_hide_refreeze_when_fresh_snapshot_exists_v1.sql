BEGIN;

-- Once a cancelled/superseded source has been re-frozen, Actionable must show
-- the fresh frozen snapshot only. The old cancelled row remains audit history,
-- but it must not remain visible as another refreeze action in the Actionable queue.
--
-- This only changes grid presentation for Queue = actionable. It does not delete
-- history, change source data, or call Sage.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $do$
DECLARE
  v_oid oid := to_regprocedure('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)');
  v_sql text;
  v_before text;
  v_after text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  IF position('actionable_refreeze_filtered AS' in v_sql) = 0 THEN
    v_before := $needle$  ), counted AS (
    SELECT q.*, COUNT(*) OVER () AS out_total_count
    FROM queued q
  ), paged AS ($needle$;

    v_after := $replacement$  ), actionable_refreeze_filtered AS (
    SELECT q.*
    FROM queued q
    WHERE NOT (
      v_queue = 'actionable'
      AND q.out_work_queue = 'cancelled_or_superseded'
      AND EXISTS (
        SELECT 1
        FROM public.sage_posting_snapshots sps
        WHERE sps.active = true
          AND sps.source_table = q.out_source_table
          AND sps.source_id = q.out_source_id
          AND sps.document_lane = q.out_document_lane
          AND sps.approval_status = 'approved_frozen'
          AND sps.sage_posting_status <> 'posted'
      )
    )
  ), counted AS (
    SELECT q.*, COUNT(*) OVER () AS out_total_count
    FROM actionable_refreeze_filtered q
  ), paged AS ($replacement$;

    IF position(v_before in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find counted CTE insertion point in internal_accounting_command_centre_grid_v1';
    END IF;

    v_sql := replace(v_sql, v_before, v_after);
    EXECUTE v_sql;
  END IF;
END
$do$;

NOTIFY pgrst, 'reload schema';
COMMIT;
