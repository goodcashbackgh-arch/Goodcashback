-- READ-ONLY probe for the order insert quote-lock trigger.
-- No DML. Safe to run repeatedly.

WITH fn AS (
  SELECT
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='trg_lock_quote_snapshot_on_order_submit'
), order_trigger AS (
  SELECT
    c.relname AS table_name,
    t.tgname AS trigger_name,
    pg_get_triggerdef(t.oid,true) AS definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public'
    AND c.relname='orders'
    AND t.tgname='trg_lock_quote_snapshot_on_order_submit'
    AND NOT t.tgisinternal
), candidate_statuses AS (
  SELECT to_jsonb(st) AS transition
  FROM public.status_transitions st
  WHERE st.entity_type='order'
    AND st.active=true
    AND (
      st.from_status='evidence_collecting'
      OR st.to_status='evidence_collecting'
      OR st.from_status='reconciling'
      OR st.to_status='reconciling'
    )
)
SELECT jsonb_build_object(
  'probe','order_insert_quote_lock_probe_v1',
  'result','READY',
  'function',(SELECT to_jsonb(fn) FROM fn),
  'trigger',(SELECT to_jsonb(order_trigger) FROM order_trigger),
  'candidate_transitions',COALESCE((SELECT jsonb_agg(transition) FROM candidate_statuses),'[]'::jsonb)
) AS result;
