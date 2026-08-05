-- Read-only database probe for the grouped fixture exact-receipt display.
-- No auth-dependent RPCs are executed and no data is modified.
--
-- Purpose:
-- 1. show the live definition of shipper_physical_receipt_entry_v1;
-- 2. identify the physical-receipt tables and columns that hold saved line truth;
-- 3. confirm which relations the live RPC reads.

WITH target_function AS (
  SELECT
    p.oid,
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    pg_get_function_result(p.oid) AS result_type,
    pg_get_functiondef(p.oid) AS function_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'shipper_physical_receipt_entry_v1'
), candidate_relations AS (
  SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    CASE c.relkind
      WHEN 'r' THEN 'table'
      WHEN 'v' THEN 'view'
      WHEN 'm' THEN 'materialized_view'
      WHEN 'p' THEN 'partitioned_table'
      ELSE c.relkind::text
    END AS relation_type
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND (
      c.relname ILIKE '%physical%receipt%'
      OR c.relname ILIKE '%receipt%review%'
      OR c.relname ILIKE '%tracking%line%allocation%'
    )
), candidate_columns AS (
  SELECT
    cols.table_schema AS schema_name,
    cols.table_name AS relation_name,
    cols.ordinal_position,
    cols.column_name,
    cols.data_type,
    cols.udt_name
  FROM information_schema.columns cols
  JOIN candidate_relations r
    ON r.schema_name = cols.table_schema
   AND r.relation_name = cols.table_name
  ORDER BY cols.table_name, cols.ordinal_position
), referenced_relations AS (
  SELECT r.*
  FROM candidate_relations r
  WHERE EXISTS (
    SELECT 1
    FROM target_function f
    WHERE position(r.relation_name in f.function_definition) > 0
  )
)
SELECT jsonb_build_object(
  'probe', 'exact_receipt_terminal_state_db_probe_v1',
  'function', COALESCE((SELECT jsonb_agg(to_jsonb(f)) FROM target_function f), '[]'::jsonb),
  'referenced_relations', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.relation_name) FROM referenced_relations r), '[]'::jsonb),
  'candidate_relations', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.relation_name) FROM candidate_relations r), '[]'::jsonb),
  'candidate_columns', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.relation_name, c.ordinal_position) FROM candidate_columns c), '[]'::jsonb)
) AS result;