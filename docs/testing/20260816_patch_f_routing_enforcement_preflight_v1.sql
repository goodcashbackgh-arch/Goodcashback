-- PATCH_F_ROUTING_ENFORCEMENT_PREFLIGHT_V1
-- READ ONLY. No writes.
-- Governing authority: MULTI_TENANT_ONBOARDING_ACCESS_MVP_COMPLETION_ADDENDUM_v1 section 4 / Patch F.

WITH actors AS (
  SELECT auth_user_id FROM public.platform_user_profiles WHERE active = true
  UNION
  SELECT auth_user_id FROM public.staff WHERE active = true AND auth_user_id IS NOT NULL
  UNION
  SELECT auth_user_id FROM public.shipper_users WHERE active = true AND auth_user_id IS NOT NULL
  UNION
  SELECT auth_user_id FROM public.operators WHERE active = true AND auth_user_id IS NOT NULL
),
base AS (
  SELECT
    a.auth_user_id,
    u.email AS auth_email,
    (u.id IS NOT NULL) AS auth_user_present,
    p.display_name,
    COALESCE(p.must_change_password, false) AS must_change_password,
    EXISTS (
      SELECT 1 FROM public.platform_user_memberships m
      WHERE m.auth_user_id = a.auth_user_id
        AND m.active = true AND m.revoked_at IS NULL
        AND m.role_code IN ('admin','supervisor')
    ) AS has_internal,
    EXISTS (
      SELECT 1 FROM public.platform_user_memberships m
      WHERE m.auth_user_id = a.auth_user_id
        AND m.active = true AND m.revoked_at IS NULL
        AND m.role_code IN ('shipper_admin','shipper_operator','shipper_readonly')
    ) AS has_shipper,
    EXISTS (
      SELECT 1 FROM public.platform_user_memberships m
      WHERE m.auth_user_id = a.auth_user_id
        AND m.active = true AND m.revoked_at IS NULL
        AND m.role_code = 'customer'
    ) AS has_customer,
    EXISTS (
      SELECT 1 FROM public.platform_user_memberships m
      WHERE m.auth_user_id = a.auth_user_id
        AND m.active = true AND m.revoked_at IS NULL
        AND m.role_code = 'importer'
    ) AS has_importer,
    EXISTS (SELECT 1 FROM public.staff s WHERE s.auth_user_id = a.auth_user_id AND s.active = true) AS legacy_staff,
    EXISTS (SELECT 1 FROM public.shipper_users su WHERE su.auth_user_id = a.auth_user_id AND su.active = true) AS legacy_shipper,
    EXISTS (SELECT 1 FROM public.operators o WHERE o.auth_user_id = a.auth_user_id AND o.active = true) AS legacy_operator,
    COALESCE((
      SELECT jsonb_agg(m.role_code ORDER BY m.role_code)
      FROM public.platform_user_memberships m
      WHERE m.auth_user_id = a.auth_user_id
        AND m.active = true AND m.revoked_at IS NULL
    ), '[]'::jsonb) AS active_roles
  FROM actors a
  LEFT JOIN auth.users u ON u.id = a.auth_user_id
  LEFT JOIN public.platform_user_profiles p ON p.auth_user_id = a.auth_user_id AND p.active = true
),
routes AS (
  SELECT
    b.*,
    CASE
      WHEN has_internal THEN 'internal'
      WHEN has_shipper THEN 'shipper'
      WHEN has_customer AND has_importer THEN 'workspace_select'
      WHEN has_customer THEN 'customer'
      WHEN has_importer THEN 'importer'
      ELSE NULL
    END AS membership_workspace,
    CASE
      WHEN legacy_staff THEN 'internal'
      WHEN legacy_shipper THEN 'shipper'
      WHEN legacy_operator THEN 'importer'
      ELSE NULL
    END AS legacy_workspace
  FROM base b
),
final_rows AS (
  SELECT
    r.*,
    COALESCE(r.membership_workspace, r.legacy_workspace) AS resolved_workspace,
    CASE COALESCE(r.membership_workspace, r.legacy_workspace)
      WHEN 'internal' THEN '/internal'
      WHEN 'shipper' THEN '/shipper'
      WHEN 'customer' THEN '/customer'
      WHEN 'importer' THEN '/importer'
      WHEN 'workspace_select' THEN '/workspace/select'
      ELSE NULL
    END AS resolved_path,
    CASE
      WHEN r.auth_user_present = false THEN 'stale_or_test_auth_id'
      WHEN COALESCE(r.membership_workspace, r.legacy_workspace) IS NULL THEN 'no_resolved_workspace'
      ELSE NULL
    END AS review_reason
  FROM routes r
),
resolver AS (
  SELECT
    p.prosecdef AS security_definer,
    COALESCE(array_to_string(p.proconfig, ','), '') AS config,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'current_platform_access_context_v1'
)
SELECT jsonb_build_object(
  'probe', 'PATCH_F_ROUTING_ENFORCEMENT_PREFLIGHT_V1',
  'read_only', true,
  'resolver', jsonb_build_object(
    'count', (SELECT count(*) FROM resolver),
    'security_definer', COALESCE((SELECT security_definer FROM resolver LIMIT 1), false),
    'search_path_locked', COALESCE((SELECT config ILIKE '%search_path=public, pg_temp%' FROM resolver LIMIT 1), false),
    'authenticated_execute', COALESCE((SELECT authenticated_execute FROM resolver LIMIT 1), false),
    'anon_execute_revoked', NOT COALESCE((SELECT anon_execute FROM resolver LIMIT 1), true)
  ),
  'auth_present_users_checked', (SELECT count(*) FROM final_rows WHERE auth_user_present = true),
  'stale_or_test_auth_ids', (SELECT count(*) FROM final_rows WHERE auth_user_present = false),
  'review_required', (SELECT count(*) FROM final_rows WHERE auth_user_present = true AND review_reason IS NOT NULL),
  'routing_changes_from_legacy', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'auth_user_id', auth_user_id,
      'email', auth_email,
      'display_name', display_name,
      'active_roles', active_roles,
      'legacy_workspace', legacy_workspace,
      'membership_workspace', membership_workspace,
      'resolved_path', resolved_path
    ) ORDER BY auth_email NULLS LAST, auth_user_id)
    FROM final_rows
    WHERE auth_user_present = true
      AND membership_workspace IS NOT NULL
      AND membership_workspace IS DISTINCT FROM legacy_workspace
  ), '[]'::jsonb),
  'users', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'auth_user_id', auth_user_id,
      'email', auth_email,
      'display_name', display_name,
      'auth_user_present', auth_user_present,
      'must_change_password', must_change_password,
      'active_roles', active_roles,
      'membership_workspace', membership_workspace,
      'legacy_workspace', legacy_workspace,
      'resolved_workspace', resolved_workspace,
      'resolved_path', resolved_path,
      'review_reason', review_reason
    ) ORDER BY auth_user_present DESC, auth_email NULLS LAST, auth_user_id)
    FROM final_rows
  ), '[]'::jsonb),
  'historical_rows_modified_by_probe', false
) AS result;
