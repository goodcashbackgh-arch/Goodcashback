BEGIN;

-- Fail before changing anything if the live identity/access shape is not the one this
-- surgical extension was designed against.
DO $$
BEGIN
  IF to_regclass('public.shipper_users') IS NULL
     OR to_regclass('public.platform_user_profiles') IS NULL
     OR to_regclass('public.platform_user_memberships') IS NULL
     OR to_regclass('public.platform_access_audit_log') IS NULL
     OR to_regclass('public.shippers') IS NULL
     OR to_regclass('public.staff') IS NULL
     OR to_regclass('public.operators') IS NULL
     OR to_regclass('auth.users') IS NULL THEN
    RAISE EXCEPTION 'shipper_login_onboarding_schema_not_ready';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('shipper_users','id'),
      ('shipper_users','shipper_id'),
      ('shipper_users','auth_user_id'),
      ('shipper_users','full_name'),
      ('shipper_users','email'),
      ('shipper_users','phone'),
      ('shipper_users','role_at_shipper'),
      ('shipper_users','permissions_json'),
      ('shipper_users','active'),
      ('platform_user_profiles','auth_user_id'),
      ('platform_user_profiles','email'),
      ('platform_user_profiles','display_name'),
      ('platform_user_profiles','active'),
      ('platform_user_profiles','must_change_password'),
      ('platform_user_profiles','created_by_staff_id'),
      ('platform_user_memberships','id'),
      ('platform_user_memberships','auth_user_id'),
      ('platform_user_memberships','role_code'),
      ('platform_user_memberships','shipper_id'),
      ('platform_user_memberships','active'),
      ('platform_user_memberships','revoked_at'),
      ('platform_access_audit_log','actor_auth_user_id'),
      ('platform_access_audit_log','actor_staff_id'),
      ('platform_access_audit_log','action_type'),
      ('platform_access_audit_log','target_auth_user_id'),
      ('platform_access_audit_log','target_shipper_id'),
      ('platform_access_audit_log','before_json'),
      ('platform_access_audit_log','after_json'),
      ('shippers','id'),
      ('shippers','active'),
      ('staff','id'),
      ('staff','auth_user_id'),
      ('staff','email'),
      ('staff','role_type'),
      ('staff','active'),
      ('operators','auth_user_id'),
      ('operators','email')
    ) AS required(table_name, column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = required.table_name
        AND c.column_name = required.column_name
    )
  ) THEN
    RAISE EXCEPTION 'shipper_login_onboarding_required_column_missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = 'auth' AND c.table_name = 'users' AND c.column_name = 'id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = 'auth' AND c.table_name = 'users' AND c.column_name = 'email'
  ) THEN
    RAISE EXCEPTION 'shipper_login_onboarding_auth_shape_unexpected';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'shipper_users'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%shipper_admin%'
      AND pg_get_constraintdef(c.oid) ILIKE '%shipper_operator%'
      AND pg_get_constraintdef(c.oid) ILIKE '%shipper_readonly%'
  ) THEN
    RAISE EXCEPTION 'shipper_login_onboarding_shipper_role_constraint_unexpected';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'platform_user_memberships'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%shipper_admin%'
      AND pg_get_constraintdef(c.oid) ILIKE '%shipper_operator%'
      AND pg_get_constraintdef(c.oid) ILIKE '%shipper_readonly%'
  ) THEN
    RAISE EXCEPTION 'shipper_login_onboarding_membership_role_constraint_unexpected';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_create_shipper_user_onboarding_v1(
  p_auth_user_id uuid,
  p_email text,
  p_full_name text,
  p_phone text,
  p_shipper_id uuid,
  p_role_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_shipper_user_id uuid;
  v_membership_id uuid;
  v_email text := lower(btrim(COALESCE(p_email, '')));
  v_full_name text := btrim(COALESCE(p_full_name, ''));
  v_phone text := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_role_code text := btrim(COALESCE(p_role_code, ''));
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  IF p_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_user_id_required';
  END IF;

  IF v_email = '' OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'valid_email_required';
  END IF;

  IF v_full_name = '' THEN
    RAISE EXCEPTION 'full_name_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM auth.users u
    WHERE u.id = p_auth_user_id
      AND lower(btrim(COALESCE(u.email, ''))) = v_email
  ) THEN
    RAISE EXCEPTION 'auth_identity_mismatch';
  END IF;

  IF v_role_code NOT IN ('shipper_admin','shipper_operator','shipper_readonly') THEN
    RAISE EXCEPTION 'valid_shipper_role_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shippers sh
    WHERE sh.id = p_shipper_id
      AND sh.active = true
  ) THEN
    RAISE EXCEPTION 'active_shipper_not_found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.platform_user_profiles p
    WHERE p.auth_user_id = p_auth_user_id
       OR lower(btrim(p.email)) = v_email
  ) OR EXISTS (
    SELECT 1 FROM public.shipper_users su
    WHERE su.auth_user_id = p_auth_user_id
       OR lower(btrim(su.email)) = v_email
  ) OR EXISTS (
    SELECT 1 FROM public.operators o
    WHERE o.auth_user_id = p_auth_user_id
       OR lower(btrim(o.email)) = v_email
  ) OR EXISTS (
    SELECT 1 FROM public.staff s
    WHERE s.auth_user_id = p_auth_user_id
       OR lower(btrim(s.email)) = v_email
  ) OR EXISTS (
    SELECT 1 FROM public.platform_user_memberships m
    WHERE m.auth_user_id = p_auth_user_id
      AND m.active = true
  ) THEN
    RAISE EXCEPTION 'platform_identity_already_exists';
  END IF;

  INSERT INTO public.platform_user_profiles (
    auth_user_id,
    email,
    display_name,
    active,
    must_change_password,
    created_by_staff_id
  ) VALUES (
    p_auth_user_id,
    v_email,
    v_full_name,
    true,
    true,
    v_staff_id
  );

  INSERT INTO public.shipper_users (
    shipper_id,
    auth_user_id,
    full_name,
    email,
    phone,
    role_at_shipper,
    permissions_json,
    active
  ) VALUES (
    p_shipper_id,
    p_auth_user_id,
    v_full_name,
    v_email,
    v_phone,
    v_role_code,
    '{}'::jsonb,
    true
  )
  RETURNING id INTO v_shipper_user_id;

  INSERT INTO public.platform_user_memberships (
    auth_user_id,
    role_code,
    shipper_id,
    active
  ) VALUES (
    p_auth_user_id,
    v_role_code,
    p_shipper_id,
    true
  )
  RETURNING id INTO v_membership_id;

  INSERT INTO public.platform_access_audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action_type,
    target_auth_user_id,
    target_shipper_id,
    before_json,
    after_json
  ) VALUES (
    auth.uid(),
    v_staff_id,
    'shipper_user_onboarding_created',
    p_auth_user_id,
    p_shipper_id,
    '{}'::jsonb,
    jsonb_build_object(
      'shipper_user_id', v_shipper_user_id,
      'membership_id', v_membership_id,
      'email', v_email,
      'display_name', v_full_name,
      'must_change_password', true,
      'role_code', v_role_code
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'auth_user_id', p_auth_user_id,
    'shipper_user_id', v_shipper_user_id,
    'membership_id', v_membership_id,
    'shipper_id', p_shipper_id,
    'email', v_email,
    'role_code', v_role_code,
    'must_change_password', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_shipper_user_onboarding_v1(uuid, text, text, text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.internal_create_shipper_user_onboarding_v1(uuid, text, text, text, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_create_shipper_user_onboarding_v1(uuid, text, text, text, uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
