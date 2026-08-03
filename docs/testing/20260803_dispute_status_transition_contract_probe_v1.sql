-- Read-only probe for the live disputes status-transition authority.

WITH trigger_rows AS (
  SELECT
    t.tgname AS trigger_name,
    p.oid::regprocedure::text AS function_signature,
    md5(pg_get_functiondef(p.oid)) AS function_md5,
    pg_get_functiondef(p.oid) AS function_definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN pg_proc p ON p.oid=t.tgfoid
  WHERE n.nspname='public'
    AND c.relname='disputes'
    AND NOT t.tgisinternal
), observed AS (
  SELECT status,COUNT(*) AS count
  FROM public.disputes
  GROUP BY status
)
SELECT jsonb_build_object(
  'probe','dispute_status_transition_contract_v1',
  'result',CASE WHEN EXISTS(
    SELECT 1 FROM trigger_rows
    WHERE function_signature LIKE 'enforce_status_transition%'
  ) THEN 'READY' ELSE 'BLOCKED' END,
  'triggers',(SELECT jsonb_agg(jsonb_build_object(
    'trigger_name',trigger_name,
    'function_signature',function_signature,
    'function_md5',function_md5,
    'function_definition',function_definition
  ) ORDER BY trigger_name) FROM trigger_rows),
  'observed_statuses',(SELECT jsonb_agg(jsonb_build_object(
    'status',status,'count',count
  ) ORDER BY status) FROM observed),
  'refund_closure_function',jsonb_build_object(
    'md5',md5(pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure)),
    'definition',pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure)
  )
) AS result;
