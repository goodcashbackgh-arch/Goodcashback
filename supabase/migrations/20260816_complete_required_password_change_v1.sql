BEGIN;

CREATE OR REPLACE FUNCTION public.current_user_complete_required_password_change_v1()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_user_id uuid := auth.uid();
  v_profile public.platform_user_profiles%ROWTYPE;
BEGIN
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required';
  END IF;

  SELECT p.*
  INTO v_profile
  FROM public.platform_user_profiles p
  WHERE p.auth_user_id = v_auth_user_id
    AND p.active = true
  FOR UPDATE;

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'active_platform_profile_not_found';
  END IF;

  IF v_profile.must_change_password IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'ok', true,
      'auth_user_id', v_auth_user_id,
      'already_complete', true,
      'must_change_password', false
    );
  END IF;

  UPDATE public.platform_user_profiles
  SET must_change_password = false,
      updated_at = now()
  WHERE id = v_profile.id;

  INSERT INTO public.platform_access_audit_log (
    actor_auth_user_id,
    action_type,
    target_auth_user_id,
    before_json,
    after_json
  ) VALUES (
    v_auth_user_id,
    'required_password_change_completed',
    v_auth_user_id,
    jsonb_build_object('must_change_password', true),
    jsonb_build_object('must_change_password', false)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'auth_user_id', v_auth_user_id,
    'already_complete', false,
    'must_change_password', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.current_user_complete_required_password_change_v1() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.current_user_complete_required_password_change_v1() FROM anon;
GRANT EXECUTE ON FUNCTION public.current_user_complete_required_password_change_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
