-- PATCH_C2_DISPOSABLE_USER_VERIFIER_V1
-- READ ONLY.
-- Replace the email below with the exact disposable test email used in the onboarding screen.

WITH input AS (
  SELECT lower(btrim('patch-c-test-20260816-2205@example.com'))::text AS test_email
),
auth_row AS (
  SELECT
    u.id AS auth_user_id,
    lower(u.email) AS email,
    u.created_at,
    u.updated_at,
    u.last_sign_in_at
  FROM auth.users u
  JOIN input i ON lower(u.email) = i.test_email
),
profile_row AS (
  SELECT
    p.auth_user_id,
    p.email,
    p.display_name,
    p.active,
    p.must_change_password,
    p.created_at,
    p.updated_at
  FROM public.platform_user_profiles p
  JOIN input i ON lower(p.email) = i.test_email
),
operator_row AS (
  SELECT
    o.id AS operator_id,
    o.auth_user_id,
    o.email,
    o.full_name,
    o.active,
    o.created_at
  FROM public.operators o
  JOIN input i ON lower(o.email) = i.test_email
),
active_links AS (
  SELECT
    oi.operator_id,
    oi.importer_id,
    oi.relationship_type,
    oi.granted_at
  FROM public.operator_importers oi
  JOIN operator_row o ON o.operator_id = oi.operator_id
  WHERE oi.revoked_at IS NULL
),
active_roles AS (
  SELECT
    m.auth_user_id,
    m.role_code,
    m.importer_id,
    m.created_at
  FROM public.platform_user_memberships m
  JOIN auth_row a ON a.auth_user_id = m.auth_user_id
  WHERE m.active = true
    AND m.revoked_at IS NULL
    AND m.role_code IN ('customer','importer')
),
audit_rows AS (
  SELECT
    a.action_type,
    a.actor_auth_user_id,
    a.target_auth_user_id,
    a.target_importer_id,
    a.created_at
  FROM public.platform_access_audit_log a
  JOIN auth_row u ON u.auth_user_id = a.target_auth_user_id
  WHERE a.action_type IN (
    'operator_onboarding_created',
    'operator_importer_roles_replaced',
    'required_password_change_completed'
  )
),
checks AS (
  SELECT
    (SELECT count(*) FROM auth_row) = 1 AS exactly_one_auth_user,
    (SELECT count(*) FROM profile_row) = 1 AS exactly_one_profile,
    (SELECT count(*) FROM operator_row) = 1 AS exactly_one_operator,
    EXISTS (SELECT 1 FROM active_links) AS active_operator_importer_link,
    EXISTS (SELECT 1 FROM active_roles) AS active_customer_or_importer_role,
    COALESCE((SELECT active FROM profile_row LIMIT 1), false) AS profile_active,
    COALESCE((SELECT active FROM operator_row LIMIT 1), false) AS operator_active,
    COALESCE((SELECT must_change_password = false FROM profile_row LIMIT 1), false) AS password_change_flag_cleared,
    COALESCE((SELECT a.auth_user_id = p.auth_user_id FROM auth_row a CROSS JOIN profile_row p LIMIT 1), false) AS auth_profile_identity_same,
    COALESCE((SELECT a.auth_user_id = o.auth_user_id FROM auth_row a CROSS JOIN operator_row o LIMIT 1), false) AS auth_operator_identity_same,
    EXISTS (
      SELECT 1 FROM audit_rows
      WHERE action_type = 'operator_onboarding_created'
    ) AS onboarding_audit_present,
    EXISTS (
      SELECT 1 FROM audit_rows
      WHERE action_type = 'required_password_change_completed'
    ) AS password_change_audit_present,
    (SELECT last_sign_in_at IS NOT NULL FROM auth_row LIMIT 1) IS TRUE AS auth_login_observed
)
SELECT jsonb_build_object(
  'probe', 'PATCH_C2_DISPOSABLE_USER_VERIFIER_V1',
  'read_only', true,
  'test_email', (SELECT test_email FROM input),
  'checks', (SELECT to_jsonb(c) FROM checks c),
  'auth', COALESCE((SELECT to_jsonb(a) FROM auth_row a), '{}'::jsonb),
  'profile', COALESCE((SELECT to_jsonb(p) FROM profile_row p), '{}'::jsonb),
  'operator', COALESCE((SELECT to_jsonb(o) FROM operator_row o), '{}'::jsonb),
  'active_links', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.importer_id) FROM active_links l), '[]'::jsonb),
  'active_roles', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.importer_id, r.role_code) FROM active_roles r), '[]'::jsonb),
  'audit_rows', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at) FROM audit_rows a), '[]'::jsonb),
  'ready', (
    SELECT exactly_one_auth_user
       AND exactly_one_profile
       AND exactly_one_operator
       AND active_operator_importer_link
       AND active_customer_or_importer_role
       AND profile_active
       AND operator_active
       AND password_change_flag_cleared
       AND auth_profile_identity_same
       AND auth_operator_identity_same
       AND onboarding_audit_present
       AND password_change_audit_present
       AND auth_login_observed
    FROM checks
  ),
  'review_required', (
    SELECT CASE WHEN exactly_one_auth_user
       AND exactly_one_profile
       AND exactly_one_operator
       AND active_operator_importer_link
       AND active_customer_or_importer_role
       AND profile_active
       AND operator_active
       AND password_change_flag_cleared
       AND auth_profile_identity_same
       AND auth_operator_identity_same
       AND onboarding_audit_present
       AND password_change_audit_present
       AND auth_login_observed
      THEN 0 ELSE 1 END
    FROM checks
  )
) AS result;
