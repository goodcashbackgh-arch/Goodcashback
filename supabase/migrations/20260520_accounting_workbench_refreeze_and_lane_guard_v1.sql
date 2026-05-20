BEGIN;

-- Surgical workbench fix.
-- 1) Queue = Actionable should include selectable cancelled/superseded rows as
--    refreeze pointers, so after superseding a local batch the user can freeze
--    the source again without hunting in All documents.
-- 2) Posting batch creation must require an explicit lane. This prevents
--    customer sales AR and AP invoices being batched together by accident.
--
-- This patch edits only the relevant predicate/check inside the existing
-- SECURITY DEFINER functions. It does not rename columns, delete data, or call Sage.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_grid_oid oid := to_regprocedure('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)');
  v_batch_oid oid := to_regprocedure('public.internal_create_sage_posting_batch_from_filter_v1(text,text,text,text,boolean,text,integer)');
  v_sql text;
  v_before text;
  v_after text;
BEGIN
  IF v_grid_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)';
  END IF;

  IF v_batch_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_create_sage_posting_batch_from_filter_v1(text,text,text,text,boolean,text,integer)';
  END IF;

  v_sql := pg_get_functiondef(v_grid_oid);
  v_before := $$OR (v_queue = 'actionable' AND s.out_work_queue IN ('live_ready_not_frozen', 'frozen_ready_to_post', 'requires_revalidation', 'blocked_before_posting', 'posting_failed'))$$;
  v_after := $$OR (v_queue = 'actionable' AND (
        s.out_work_queue IN ('live_ready_not_frozen', 'frozen_ready_to_post', 'requires_revalidation', 'blocked_before_posting', 'posting_failed')
        OR (s.out_work_queue = 'cancelled_or_superseded' AND s.out_selectable = true)
      ))$$;

  IF position(v_before in v_sql) = 0 AND position(v_after in v_sql) = 0 THEN
    RAISE EXCEPTION 'Could not find actionable queue predicate to patch in internal_accounting_command_centre_grid_v1';
  END IF;

  IF position(v_before in v_sql) > 0 THEN
    v_sql := replace(v_sql, v_before, v_after);
    EXECUTE v_sql;
  END IF;

  v_sql := pg_get_functiondef(v_batch_oid);
  v_before := $$SELECT public.internal_current_staff_id_v1() INTO v_staff_id;$$;
  v_after := $$SELECT public.internal_current_staff_id_v1() INTO v_staff_id;

  IF v_lane NOT IN ('customer_sales', 'supplier_goods_ap', 'shipper_ap') THEN
    RAISE EXCEPTION 'Choose exactly one posting lane before creating a Sage posting batch. Mixed customer/AP batches are blocked.';
  END IF;$$;

  IF position(v_after in v_sql) = 0 THEN
    IF position(v_before in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find staff lookup insertion point to patch in internal_create_sage_posting_batch_from_filter_v1';
    END IF;
    v_sql := replace(v_sql, v_before, v_after);
    EXECUTE v_sql;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
