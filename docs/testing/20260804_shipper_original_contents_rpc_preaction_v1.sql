-- Read-only diagnostic for the shipper dashboard message:
-- "Unavailable until latest migration is applied"
--
-- This checks the exact RPC used by app/shipper/OriginalPackageContentsPreview.tsx.
-- It does not modify data or functions.

WITH constants AS (
  SELECT '8d6fbf0f-4d1f-4aa7-9f0a-000000000000'::uuid AS placeholder_tracking_id
), function_match AS (
  SELECT
    p.oid,
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    pg_get_function_result(p.oid) AS result_type,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'shipper_package_original_contents_preview_v1'
), migration_presence AS (
  SELECT EXISTS (
    SELECT 1
    FROM public.supabase_migrations_schema_migrations sm
    WHERE sm.version LIKE '%shipper%original%contents%'
       OR sm.name ILIKE '%shipper%original%contents%'
  ) AS matching_migration_record
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN (SELECT count(*) FROM function_match) = 0 THEN 'rpc_missing' END,
    CASE WHEN (SELECT count(*) FROM function_match) > 1 THEN 'rpc_overloaded_or_duplicated' END,
    CASE WHEN EXISTS (SELECT 1 FROM function_match WHERE identity_arguments <> 'p_tracking_submission_id uuid') THEN 'unexpected_signature' END,
    CASE WHEN EXISTS (SELECT 1 FROM function_match WHERE NOT authenticated_can_execute) THEN 'authenticated_execute_missing' END
  ], NULL) AS blockers
)
SELECT jsonb_build_object(
  'probe', 'shipper_original_contents_rpc_preaction_v1',
  'result', CASE WHEN COALESCE(array_length(blockers, 1), 0) = 0 THEN 'PASS' ELSE 'FAIL' END,
  'blockers', blockers,
  'functions', COALESCE((SELECT jsonb_agg(to_jsonb(function_match)) FROM function_match), '[]'::jsonb),
  'migration_record', to_jsonb(migration_presence)
) AS result
FROM blockers
CROSS JOIN migration_presence;