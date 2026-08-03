-- Read-only schema probe for the rollback-only grouped supervisor refund regression.

WITH target_tables AS (
  SELECT unnest(ARRAY['order_funding_events','sales_invoices']) AS table_name
), columns AS (
  SELECT
    c.table_name,
    jsonb_agg(jsonb_build_object(
      'column',c.column_name,
      'type',c.data_type,
      'nullable',c.is_nullable,
      'default',c.column_default
    ) ORDER BY c.ordinal_position) AS columns
  FROM information_schema.columns c
  JOIN target_tables t ON t.table_name=c.table_name
  WHERE c.table_schema='public'
  GROUP BY c.table_name
), constraints AS (
  SELECT
    cls.relname AS table_name,
    jsonb_agg(jsonb_build_object(
      'name',con.conname,
      'type',con.contype,
      'definition',pg_get_constraintdef(con.oid,true)
    ) ORDER BY con.conname) AS constraints
  FROM pg_constraint con
  JOIN pg_class cls ON cls.oid=con.conrelid
  JOIN pg_namespace nsp ON nsp.oid=cls.relnamespace
  JOIN target_tables t ON t.table_name=cls.relname
  WHERE nsp.nspname='public'
  GROUP BY cls.relname
), triggers AS (
  SELECT
    event_object_table AS table_name,
    jsonb_agg(jsonb_build_object(
      'trigger',trigger_name,
      'timing',action_timing,
      'event',event_manipulation,
      'statement',action_statement
    ) ORDER BY trigger_name,event_manipulation) AS triggers
  FROM information_schema.triggers
  WHERE trigger_schema='public'
    AND event_object_table IN ('order_funding_events','sales_invoices')
  GROUP BY event_object_table
), samples AS (
  SELECT jsonb_build_object(
    'order_funding_events',(
      SELECT to_jsonb(x)
      FROM public.order_funding_events x
      ORDER BY x.created_at,x.id
      LIMIT 1
    ),
    'sales_invoices',(
      SELECT to_jsonb(x)
      FROM public.sales_invoices x
      ORDER BY x.created_at,x.id
      LIMIT 1
    )
  ) AS sample_rows
)
SELECT jsonb_build_object(
  'probe','physical_outcome_lane_supervisor_refund_schema_v1',
  'result',CASE
    WHEN to_regclass('public.order_funding_events') IS NULL
      OR to_regclass('public.sales_invoices') IS NULL
    THEN 'BLOCKED'
    ELSE 'READY'
  END,
  'columns',(
    SELECT jsonb_object_agg(table_name,columns) FROM columns
  ),
  'constraints',(
    SELECT jsonb_object_agg(table_name,constraints) FROM constraints
  ),
  'triggers',(
    SELECT jsonb_object_agg(table_name,triggers) FROM triggers
  ),
  'sample_rows',(SELECT sample_rows FROM samples)
) AS result;
