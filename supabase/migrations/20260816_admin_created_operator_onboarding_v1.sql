BEGIN;

CREATE OR REPLACE FUNCTION public.internal_create_operator_onboarding_v1(
  p_auth_user_id uuid,
  p_email text,
  p_full_name text,
  p_phone text,
  p_importer_id uuid,
  p_relationship_type text,
  p_role_codes text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_operator_id uuid;
  v_email text := lower(btrim(COALESCE(p_email, '')));
  v_full_name text := btrim(COALESCE(p_full_name, ''));
  v_phone text := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_roles_result jsonb;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'not_authorised';
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

  IF EXISTS (
    SELECT 1 FROM public.operators o
    WHERE o.auth_user_id = p_auth_user_id
       OR lower(btrim(o.email)) = v_email
  ) THEN
    RAISE EXCEPTION 'operator_already_exists';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.platform_user_profiles p
    WHERE p.auth_user_id = p_auth_user_id
       OR lower(btrim(p.email)) = v_email
  ) THEN
    RAISE EXCEPTION 'platform_user_profile_already_exists';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.importers i
    WHERE i.id = p_importer_id
      AND i.active = true
  ) THEN
    RAISE EXCEPTION 'importer_not_found';
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

  INSERT INTO public.operators (
    email,
    phone,
    full_name,
    auth_user_id,
    active
  ) VALUES (
    v_email,
    v_phone,
    v_full_name,
    p_auth_user_id,
    true
  )
  RETURNING id INTO v_operator_id;

  -- Reuse Patch B as the sole Customer / Importer membership authority.
  v_roles_result := public.internal_set_operator_importer_roles_v1(
    v_operator_id,
    p_importer_id,
    p_relationship_type,
    p_role_codes
  );

  INSERT INTO public.platform_access_audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action_type,
    target_auth_user_id,
    target_importer_id,
    before_json,
    after_json
  ) VALUES (
    auth.uid(),
    v_staff_id,
    'operator_onboarding_created',
    p_auth_user_id,
    p_importer_id,
    '{}'::jsonb,
    jsonb_build_object(
      'operator_id', v_operator_id,
      'email', v_email,
      'display_name', v_full_name,
      'must_change_password', true,
      'relationship_type', p_relationship_type,
      'selected_roles', COALESCE(v_roles_result->'selected_roles', '[]'::jsonb)
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'auth_user_id', p_auth_user_id,
    'operator_id', v_operator_id,
    'importer_id', p_importer_id,
    'email', v_email,
    'must_change_password', true,
    'selected_roles', COALESCE(v_roles_result->'selected_roles', '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_operator_onboarding_v1(uuid, text, text, text, uuid, text, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.internal_create_operator_onboarding_v1(uuid, text, text, text, uuid, text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_create_operator_onboarding_v1(uuid, text, text, text, uuid, text, text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
