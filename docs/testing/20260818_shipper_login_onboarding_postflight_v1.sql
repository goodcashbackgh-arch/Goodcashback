-- SHIPPER_LOGIN_ONBOARDING_POSTFLIGHT_V1
-- READ ONLY. No writes.

WITH writer AS (
  SELECT
    p.oid,
    p.prosecdef AS security_definer,
    COALESCE(array_to_string(p.proconfig, ','), '') AS config,
    pg_get_functiondef(p.oid) AS definition,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_create_shipper_user_onboarding_v1'
),
active_shipper_users AS (
  SELECT
    su.id AS shipper_user_id,
    su.auth_user_id,
    su.shipper_id,
    su.email,
    su.role_at_shipper,
    EXISTS (SELECT 1 FROM auth.users u WHERE u.id = su.auth_user_id) AS auth_user_present,
    EXISTS (
      SELECT 1 FROM public.platform_user_profiles p
      WHERE p.auth_user_id = su.auth_user_id
        AND p.active = true
    ) AS active_profile_present,
    (
      SELECT count(*)
      FROM public.platform_user_memberships m
      WHERE m.auth_user_id = su.auth_user_id
        AND m.shipper_id = su.shipper_id
        AND m.role_code = su.role_at_shipper
        AND m.active = true
        AND m.revoked_at IS NULL
    )::int AS matching_active_memberships
  FROM public.shipper_users su
  WHERE su.active = true
),
auth_present_defects AS (
  SELECT *
  FROM active_shipper_users
  WHERE auth_user_present = true
    AND (active_profile_present = false OR matching_active_memberships <> 1)
),
duplicate_active_shipper_memberships AS (
  SELECT m.auth_user_id, m.shipper_id, count(*)::int AS membership_count
  FROM public.platform_user_memberships m
  WHERE m.active = true
    AND m.revoked_at IS NULL
    AND m.role_code IN ('shipper_admin','shipper_operator','shipper_readonly')
  GROUP BY m.auth_user_id, m.shipper_id
  HAVING count(*) > 1
)
SELECT jsonb_build_object(
  'probe','SHIPPER_LOGIN_ONBOARDING_POSTFLIGHT_V1',
  'read_only',true,
  'ready',
    (SELECT count(*) = 1 FROM writer)
    AND COALESCE((SELECT security_definer FROM writer LIMIT 1),false)
    AND COALESCE((SELECT config ILIKE '%search_path=public, pg_temp%' FROM writer LIMIT 1),false)
    AND COALESCE((SELECT authenticated_execute FROM writer LIMIT 1),false)
    AND NOT COALESCE((SELECT anon_execute FROM writer LIMIT 1),true)
    AND COALESCE((SELECT definition ILIKE '%shipper_user_onboarding_created%' FROM writer LIMIT 1),false)
    AND COALESCE((SELECT definition ILIKE '%platform_user_profiles%' FROM writer LIMIT 1),false)
    AND COALESCE((SELECT definition ILIKE '%shipper_users%' FROM writer LIMIT 1),false)
    AND COALESCE((SELECT definition ILIKE '%platform_user_memberships%' FROM writer LIMIT 1),false)
    AND NOT EXISTS (SELECT 1 FROM auth_present_defects)
    AND NOT EXISTS (SELECT 1 FROM duplicate_active_shipper_memberships),
  'review_required',
    (SELECT count(*) FROM auth_present_defects)
    + (SELECT count(*) FROM duplicate_active_shipper_memberships),
  'writer',jsonb_build_object(
    'count',(SELECT count(*) FROM writer),
    'security_definer',COALESCE((SELECT security_definer FROM writer LIMIT 1),false),
    'search_path_locked',COALESCE((SELECT config ILIKE '%search_path=public, pg_temp%' FROM writer LIMIT 1),false),
    'authenticated_execute',COALESCE((SELECT authenticated_execute FROM writer LIMIT 1),false),
    'anon_execute_revoked',NOT COALESCE((SELECT anon_execute FROM writer LIMIT 1),true),
    'writes_profile',COALESCE((SELECT definition ILIKE '%platform_user_profiles%' FROM writer LIMIT 1),false),
    'writes_shipper_user',COALESCE((SELECT definition ILIKE '%shipper_users%' FROM writer LIMIT 1),false),
    'writes_membership',COALESCE((SELECT definition ILIKE '%platform_user_memberships%' FROM writer LIMIT 1),false),
    'writes_audit',COALESCE((SELECT definition ILIKE '%shipper_user_onboarding_created%' FROM writer LIMIT 1),false)
  ),
  'active_shipper_users',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.email) FROM active_shipper_users s),'[]'::jsonb),
  'auth_present_shipper_user_defects',COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.email) FROM auth_present_defects d),'[]'::jsonb),
  'duplicate_active_shipper_memberships',COALESCE((SELECT jsonb_agg(to_jsonb(d)) FROM duplicate_active_shipper_memberships d),'[]'::jsonb),
  'existing_rows_modified_by_probe',false
) AS result;
