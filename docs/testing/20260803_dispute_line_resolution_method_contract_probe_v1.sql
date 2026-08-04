-- Read-only probe for the live dispute_lines resolution-method contract and writers.

WITH constraint_row AS (
  SELECT
    con.conname,
    pg_get_constraintdef(con.oid,true) AS definition
  FROM pg_constraint con
  JOIN pg_class cls ON cls.oid=con.conrelid
  JOIN pg_namespace nsp ON nsp.oid=cls.relnamespace
  WHERE nsp.nspname='public'
    AND cls.relname='dispute_lines'
    AND con.conname='dispute_lines_resolution_method_check'
), writers AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    md5(pg_get_functiondef(p.oid)) AS md5,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND pg_get_functiondef(p.oid) ILIKE '%resolution_method%'
    AND pg_get_functiondef(p.oid) ILIKE '%dispute_lines%'
)
SELECT jsonb_build_object(
  'probe','dispute_line_resolution_method_contract_v1',
  'result',CASE WHEN EXISTS(SELECT 1 FROM constraint_row) THEN 'READY' ELSE 'BLOCKED' END,
  'constraint',(SELECT to_jsonb(constraint_row) FROM constraint_row),
  'observed_values',(
    SELECT jsonb_agg(jsonb_build_object(
      'resolution_method',resolution_method,
      'count',count
    ) ORDER BY resolution_method)
    FROM (
      SELECT resolution_method,COUNT(*) AS count
      FROM public.dispute_lines
      GROUP BY resolution_method
    ) x
  ),
  'writers',(SELECT jsonb_agg(jsonb_build_object(
    'signature',signature,'md5',md5,'definition',definition
  ) ORDER BY signature) FROM writers)
) AS result;
