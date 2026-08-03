-- Read-only probe: return the live grouped refund authority definition and
-- the exact coverage-guard context. No fixture or production data is changed.

WITH fn AS (
  SELECT
    p.oid,
    md5(pg_get_functiondef(p.oid)) AS function_md5,
    pg_get_functiondef(p.oid) AS function_definition
  FROM pg_proc p
  WHERE p.oid='public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)'::regprocedure
), guard_tables AS (
  SELECT jsonb_agg(jsonb_build_object(
    'table_name',c.relname,
    'rls_enabled',c.relrowsecurity,
    'force_rls',c.relforcerowsecurity
  ) ORDER BY c.relname) AS tables
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public'
    AND c.relname IN (
      'physical_receipt_outcome_lane_items',
      'physical_exception_remedy_allocations',
      'dispute_lines',
      'shipper_package_receipt_line_dispositions',
      'supplier_invoice_lines'
    )
)
SELECT jsonb_build_object(
  'probe','grouped_refund_exact_coverage_guard_v1',
  'result',CASE WHEN fn.oid IS NOT NULL THEN 'READY' ELSE 'BLOCKED' END,
  'function_md5',fn.function_md5,
  'function_definition',fn.function_definition,
  'guard_table_metadata',guard_tables.tables
) AS result
FROM fn
CROSS JOIN guard_tables;
