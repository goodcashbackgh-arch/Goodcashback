BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $do$
DECLARE
  v_oid oid := to_regprocedure('public.internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[],text)');
  v_sql text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[],text)';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  IF position('FROM public.internal_supplier_goods_ap_ready_rows_v1() live_q' in v_sql) = 0 THEN
    IF position('FROM public.internal_ready_for_sage_queue_v2() live_q' in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find supplier AP freeze resolver source to patch';
    END IF;

    v_sql := replace(
      v_sql,
      'FROM public.internal_ready_for_sage_queue_v2() live_q',
      'FROM public.internal_supplier_goods_ap_ready_rows_v1() live_q'
    );

    EXECUTE v_sql;
  END IF;
END
$do$;

NOTIFY pgrst, 'reload schema';
COMMIT;
