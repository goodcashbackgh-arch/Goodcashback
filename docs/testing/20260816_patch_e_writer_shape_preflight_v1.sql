-- PATCH_E_WRITER_SHAPE_PREFLIGHT_V1
-- READ ONLY. No writes.
-- Governing authority: MULTI_TENANT_ONBOARDING_ACCESS_MVP_COMPLETION_ADDENDUM_v1 section 7 / Patch E.

WITH retailer_account_columns AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'retailer_accounts'
),
retailer_account_constraints AS (
  SELECT
    con.conname AS constraint_name,
    con.contype AS constraint_type,
    pg_get_constraintdef(con.oid, true) AS definition
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = rel.relnamespace
  WHERE n.nspname = 'public'
    AND rel.relname = 'retailer_accounts'
),
shipper_retailer_constraints AS (
  SELECT
    con.conname AS constraint_name,
    con.contype AS constraint_type,
    pg_get_constraintdef(con.oid, true) AS definition
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = rel.relnamespace
  WHERE n.nspname = 'public'
    AND rel.relname = 'shipper_retailers'
),
overview_fn AS (
  SELECT
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    p.prosecdef AS security_definer,
    COALESCE(array_to_string(p.proconfig, ','), '') AS config,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_onboarding_overview_v1'
),
active_hubs AS (
  SELECT
    h.id,
    h.shipper_id,
    h.name,
    h.country_id,
    h.full_address,
    h.postcode,
    h.active
  FROM public.hubs h
  WHERE h.active = true
),
observed_statuses AS (
  SELECT DISTINCT status
  FROM public.retailer_accounts
  ORDER BY status
),
delivery_methods AS (
  SELECT DISTINCT credential_delivery_method
  FROM public.retailer_accounts
  ORDER BY credential_delivery_method
),
rls AS (
  SELECT
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS force_rls
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'retailer_accounts'
)
SELECT jsonb_build_object(
  'probe', 'PATCH_E_WRITER_SHAPE_PREFLIGHT_V1',
  'read_only', true,
  'retailer_account_columns', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.ordinal_position) FROM retailer_account_columns c), '[]'::jsonb),
  'retailer_account_constraints', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.constraint_name) FROM retailer_account_constraints c), '[]'::jsonb),
  'shipper_retailer_constraints', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.constraint_name) FROM shipper_retailer_constraints c), '[]'::jsonb),
  'observed_statuses', COALESCE((SELECT jsonb_agg(status) FROM observed_statuses), '[]'::jsonb),
  'observed_credential_delivery_methods', COALESCE((SELECT jsonb_agg(credential_delivery_method) FROM delivery_methods), '[]'::jsonb),
  'onboarding_overview_function', COALESCE((SELECT to_jsonb(f) FROM overview_fn f LIMIT 1), '{}'::jsonb),
  'onboarding_overview_function_count', (SELECT count(*) FROM overview_fn),
  'active_hubs', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.name, h.id) FROM active_hubs h), '[]'::jsonb),
  'retailer_accounts_rls', COALESCE((SELECT to_jsonb(r) FROM rls r LIMIT 1), '{}'::jsonb),
  'historical_rows_modified_by_probe', false
) AS result;
