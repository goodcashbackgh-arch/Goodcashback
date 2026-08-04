-- Read-only live contract probe for the supervisor outcome-lane UI build.
-- No data or function is changed.

WITH fn AS (
  SELECT
    p.oid,
    md5(pg_get_functiondef(p.oid)) AS function_md5,
    pg_get_functiondef(p.oid) AS function_definition,
    p.prosecdef AS security_definer
  FROM pg_proc p
  WHERE p.oid='public.staff_physical_receipt_reviews_v1(uuid)'::regprocedure
), columns AS (
  SELECT jsonb_agg(jsonb_build_object(
    'table_name',table_name,
    'column_name',column_name,
    'data_type',data_type,
    'udt_name',udt_name,
    'nullable',is_nullable
  ) ORDER BY table_name,ordinal_position) AS value
  FROM information_schema.columns
  WHERE table_schema='public'
    AND table_name IN (
      'physical_receipt_outcome_lanes',
      'physical_receipt_outcome_lane_items',
      'physical_receipt_outcome_lane_decisions',
      'physical_receipt_outcome_lane_decision_items',
      'physical_exception_remedy_allocations',
      'dispute_lines',
      'disputes',
      'staff'
    )
), policies AS (
  SELECT jsonb_agg(jsonb_build_object(
    'table_name',tablename,
    'policy_name',policyname,
    'command',cmd,
    'roles',roles,
    'using',qual
  ) ORDER BY tablename,policyname) AS value
  FROM pg_policies
  WHERE schemaname='public'
    AND tablename IN (
      'physical_receipt_outcome_lanes',
      'physical_receipt_outcome_lane_items',
      'physical_receipt_outcome_lane_decisions',
      'physical_receipt_outcome_lane_decision_items'
    )
)
SELECT jsonb_build_object(
  'probe','staff_physical_outcome_lane_ui_contract_v1',
  'result',CASE WHEN fn.oid IS NOT NULL THEN 'READY' ELSE 'BLOCKED' END,
  'staff_read_function',jsonb_build_object(
    'md5',fn.function_md5,
    'security_definer',fn.security_definer,
    'definition',fn.function_definition
  ),
  'columns',columns.value,
  'policies',policies.value,
  'grouped_decision_function_md5',md5(pg_get_functiondef('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)'::regprocedure))
) AS result
FROM fn
CROSS JOIN columns
CROSS JOIN policies;
