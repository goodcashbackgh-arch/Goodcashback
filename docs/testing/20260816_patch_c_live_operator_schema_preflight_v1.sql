-- PATCH_C_LIVE_OPERATOR_SCHEMA_PREFLIGHT_V1
-- READ ONLY. No DDL/DML. No auth/admin calls. Safe to run against live DB.

WITH
operator_columns AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'operators'
  ORDER BY c.ordinal_position
),
operator_importer_columns AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'operator_importers'
  ORDER BY c.ordinal_position
),
relevant_constraints AS (
  SELECT
    con.conname AS constraint_name,
    con.contype AS constraint_type,
    rel.relname AS table_name,
    pg_get_constraintdef(con.oid, true) AS definition
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
  JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
  WHERE nsp.nspname = 'public'
    AND rel.relname IN ('operators', 'operator_importers')
  ORDER BY rel.relname, con.conname
),
relevant_indexes AS (
  SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename IN ('operators', 'operator_importers')
  ORDER BY tablename, indexname
),
relevant_functions AS (
  SELECT
    n.nspname AS function_schema,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    p.prosecdef AS security_definer,
    COALESCE(array_to_string(p.proconfig, ', '), '') AS config,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND (
      pg_get_functiondef(p.oid) ILIKE '%public.operators%'
      OR pg_get_functiondef(p.oid) ILIKE '% operators %'
      OR pg_get_functiondef(p.oid) ILIKE '%operator_importers%'
    )
  ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)
),
access_profile_columns AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'platform_user_profiles'
  ORDER BY c.ordinal_position
),
membership_columns AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'platform_user_memberships'
  ORDER BY c.ordinal_position
),
counts AS (
  SELECT
    (SELECT count(*) FROM public.operators) AS operators_count,
    (SELECT count(*) FROM public.operator_importers) AS operator_importers_count,
    (SELECT count(*) FROM public.platform_user_profiles) AS platform_user_profiles_count,
    (SELECT count(*) FROM public.platform_user_memberships) AS platform_user_memberships_count
)
SELECT jsonb_build_object(
  'probe', 'PATCH_C_LIVE_OPERATOR_SCHEMA_PREFLIGHT_V1',
  'read_only', true,
  'tables_present', jsonb_build_object(
    'operators', to_regclass('public.operators') IS NOT NULL,
    'operator_importers', to_regclass('public.operator_importers') IS NOT NULL,
    'platform_user_profiles', to_regclass('public.platform_user_profiles') IS NOT NULL,
    'platform_user_memberships', to_regclass('public.platform_user_memberships') IS NOT NULL
  ),
  'counts', (SELECT to_jsonb(counts) FROM counts),
  'operators_columns', COALESCE((SELECT jsonb_agg(to_jsonb(operator_columns) ORDER BY ordinal_position) FROM operator_columns), '[]'::jsonb),
  'operator_importers_columns', COALESCE((SELECT jsonb_agg(to_jsonb(operator_importer_columns) ORDER BY ordinal_position) FROM operator_importer_columns), '[]'::jsonb),
  'platform_user_profiles_columns', COALESCE((SELECT jsonb_agg(to_jsonb(access_profile_columns) ORDER BY ordinal_position) FROM access_profile_columns), '[]'::jsonb),
  'platform_user_memberships_columns', COALESCE((SELECT jsonb_agg(to_jsonb(membership_columns) ORDER BY ordinal_position) FROM membership_columns), '[]'::jsonb),
  'constraints', COALESCE((SELECT jsonb_agg(to_jsonb(relevant_constraints) ORDER BY table_name, constraint_name) FROM relevant_constraints), '[]'::jsonb),
  'indexes', COALESCE((SELECT jsonb_agg(to_jsonb(relevant_indexes) ORDER BY tablename, indexname) FROM relevant_indexes), '[]'::jsonb),
  'functions', COALESCE((SELECT jsonb_agg(to_jsonb(relevant_functions) ORDER BY function_name, identity_arguments) FROM relevant_functions), '[]'::jsonb)
) AS result;
