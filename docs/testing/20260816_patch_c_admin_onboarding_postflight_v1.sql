-- PATCH_C_ADMIN_ONBOARDING_POSTFLIGHT_V1
-- READ ONLY. Run after 20260816_admin_created_operator_onboarding_v1.sql.

WITH target AS (
  SELECT p.oid,
         p.prosecdef,
         pg_get_functiondef(p.oid) AS definition,
         COALESCE(array_to_string(p.proconfig, ', '), '') AS config
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_create_operator_onboarding_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_auth_user_id uuid, p_email text, p_full_name text, p_phone text, p_importer_id uuid, p_relationship_type text, p_role_codes text[]'
),
password_columns AS (
  SELECT table_name, column_name
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN ('operators','operator_importers','platform_user_profiles','platform_user_memberships','platform_access_audit_log')
    AND lower(column_name) LIKE '%password%'
    AND column_name <> 'must_change_password'
),
checks AS (
  SELECT
    EXISTS (SELECT 1 FROM target) AS function_exists,
    COALESCE((SELECT prosecdef FROM target), false) AS security_definer,
    COALESCE((SELECT config FROM target), '') LIKE '%search_path=public, pg_temp%' AS search_path_locked,
    COALESCE((SELECT definition FROM target), '') ILIKE '%INSERT INTO public.platform_user_profiles%' AS creates_profile,
    COALESCE((SELECT definition FROM target), '') ILIKE '%must_change_password%' AS sets_password_change_flag,
    COALESCE((SELECT definition FROM target), '') ILIKE '%INSERT INTO public.operators%' AS creates_operator,
    COALESCE((SELECT definition FROM target), '') ILIKE '%internal_set_operator_importer_roles_v1%' AS reuses_patch_b_role_writer,
    COALESCE((SELECT definition FROM target), '') ILIKE '%operator_onboarding_created%' AS writes_onboarding_audit,
    COALESCE((SELECT definition FROM target), '') ILIKE '%operator_already_exists%' AS blocks_existing_operator,
    COALESCE((SELECT definition FROM target), '') ILIKE '%platform_user_profile_already_exists%' AS blocks_existing_profile,
    NOT has_function_privilege('anon', 'public.internal_create_operator_onboarding_v1(uuid,text,text,text,uuid,text,text[])', 'EXECUTE') AS anon_execute_revoked,
    has_function_privilege('authenticated', 'public.internal_create_operator_onboarding_v1(uuid,text,text,text,uuid,text,text[])', 'EXECUTE') AS authenticated_execute_granted,
    NOT EXISTS (SELECT 1 FROM password_columns) AS no_plaintext_password_column
)
SELECT jsonb_build_object(
  'probe', 'PATCH_C_ADMIN_ONBOARDING_POSTFLIGHT_V1',
  'read_only', true,
  'checks', to_jsonb(checks),
  'password_like_columns', COALESCE((SELECT jsonb_agg(to_jsonb(password_columns)) FROM password_columns), '[]'::jsonb),
  'ready', (
    SELECT function_exists
       AND security_definer
       AND search_path_locked
       AND creates_profile
       AND sets_password_change_flag
       AND creates_operator
       AND reuses_patch_b_role_writer
       AND writes_onboarding_audit
       AND blocks_existing_operator
       AND blocks_existing_profile
       AND anon_execute_revoked
       AND authenticated_execute_granted
       AND no_plaintext_password_column
    FROM checks
  ),
  'review_required', (
    SELECT CASE WHEN function_exists
       AND security_definer
       AND search_path_locked
       AND creates_profile
       AND sets_password_change_flag
       AND creates_operator
       AND reuses_patch_b_role_writer
       AND writes_onboarding_audit
       AND blocks_existing_operator
       AND blocks_existing_profile
       AND anon_execute_revoked
       AND authenticated_execute_granted
       AND no_plaintext_password_column
      THEN 0 ELSE 1 END
    FROM checks
  )
) AS result;
