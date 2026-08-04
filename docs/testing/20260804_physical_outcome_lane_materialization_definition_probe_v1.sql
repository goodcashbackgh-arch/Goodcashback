-- READ-ONLY discovery of the live functions/triggers responsible for physical outcome lane materialization.
-- No DML. Uses PostgreSQL catalogs only.

WITH matching_functions AS (
  SELECT
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    pg_get_function_result(p.oid) AS result_type,
    l.lanname AS language_name,
    p.prosecdef AS security_definer,
    pg_get_functiondef(p.oid) AS function_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND (
      pg_get_functiondef(p.oid) ILIKE '%physical_receipt_outcome_lanes%'
      OR pg_get_functiondef(p.oid) ILIKE '%physical_receipt_outcome_lane_items%'
      OR pg_get_functiondef(p.oid) ILIKE '%physical_exception_remedy_allocations%'
    )
),
matching_triggers AS (
  SELECT
    ns.nspname AS schema_name,
    c.relname AS relation_name,
    t.tgname AS trigger_name,
    p.proname AS trigger_function_name,
    pg_get_triggerdef(t.oid, true) AS trigger_definition,
    pg_get_functiondef(p.oid) AS trigger_function_definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE NOT t.tgisinternal
    AND ns.nspname = 'public'
    AND (
      pg_get_functiondef(p.oid) ILIKE '%physical_receipt_outcome_lanes%'
      OR pg_get_functiondef(p.oid) ILIKE '%physical_receipt_outcome_lane_items%'
      OR pg_get_functiondef(p.oid) ILIKE '%physical_exception_remedy_allocations%'
    )
)
SELECT jsonb_build_object(
  'probe', 'physical_outcome_lane_materialization_definition_probe_v1',
  'result', 'READY',
  'functions', COALESCE((
    SELECT jsonb_agg(to_jsonb(f) ORDER BY f.schema_name, f.function_name, f.identity_arguments)
    FROM matching_functions f
  ), '[]'::jsonb),
  'triggers', COALESCE((
    SELECT jsonb_agg(to_jsonb(t) ORDER BY t.schema_name, t.relation_name, t.trigger_name)
    FROM matching_triggers t
  ), '[]'::jsonb)
) AS result;
