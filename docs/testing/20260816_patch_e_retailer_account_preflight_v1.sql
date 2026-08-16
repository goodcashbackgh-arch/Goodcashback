-- PATCH_E_RETAILER_ACCOUNT_PREFLIGHT_V1
-- READ ONLY. No writes.
-- Governing authority: MULTI_TENANT_ONBOARDING_ACCESS_MVP_COMPLETION_ADDENDUM_v1 section 7 / Patch E.

WITH wanted_tables AS (
  SELECT unnest(ARRAY[
    'retailers',
    'shipper_retailers',
    'retailer_accounts',
    'orders',
    'importers'
  ]) AS table_name
),
columns AS (
  SELECT
    c.table_name,
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.is_nullable
  FROM information_schema.columns c
  JOIN wanted_tables w ON w.table_name = c.table_name
  WHERE c.table_schema = 'public'
),
relevant_functions AS (
  SELECT
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    p.prosecdef AS security_definer,
    COALESCE(array_to_string(p.proconfig, ','), '') AS config,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND (
      pg_get_functiondef(p.oid) ILIKE '%retailer_accounts%'
      OR pg_get_functiondef(p.oid) ILIKE '%shipper_retailers%'
    )
),
indexes AS (
  SELECT
    tablename,
    indexname,
    indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename IN ('retailer_accounts', 'shipper_retailers')
),
retailer_rows AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]'::jsonb) AS rows
  FROM public.retailers r
),
shipper_retailer_rows AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(sr) ORDER BY sr.id), '[]'::jsonb) AS rows
  FROM public.shipper_retailers sr
),
retailer_account_rows AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(ra) ORDER BY ra.id), '[]'::jsonb) AS rows
  FROM public.retailer_accounts ra
),
counts AS (
  SELECT jsonb_build_object(
    'retailers', (SELECT count(*) FROM public.retailers),
    'shipper_retailers', (SELECT count(*) FROM public.shipper_retailers),
    'retailer_accounts', (SELECT count(*) FROM public.retailer_accounts),
    'orders', (SELECT count(*) FROM public.orders),
    'importers', (SELECT count(*) FROM public.importers)
  ) AS value
)
SELECT jsonb_build_object(
  'probe', 'PATCH_E_RETAILER_ACCOUNT_PREFLIGHT_V1',
  'read_only', true,
  'counts', (SELECT value FROM counts),
  'columns', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.table_name, c.ordinal_position) FROM columns c), '[]'::jsonb),
  'indexes', COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.tablename, i.indexname) FROM indexes i), '[]'::jsonb),
  'relevant_functions', COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.function_name, f.arguments) FROM relevant_functions f), '[]'::jsonb),
  'retailers', (SELECT rows FROM retailer_rows),
  'shipper_retailers', (SELECT rows FROM shipper_retailer_rows),
  'retailer_accounts', (SELECT rows FROM retailer_account_rows),
  'historical_rows_modified_by_probe', false
) AS result;
