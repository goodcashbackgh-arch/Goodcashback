BEGIN;

CREATE OR REPLACE FUNCTION public.current_platform_access_context_v1()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_user_id uuid := auth.uid();
  v_profile jsonb;
  v_memberships jsonb := '[]'::jsonb;
  v_operator_importer_ids jsonb := '[]'::jsonb;
  v_legacy_staff boolean := false;
  v_legacy_shipper boolean := false;
  v_legacy_operator boolean := false;
  v_has_internal boolean := false;
  v_has_shipper boolean := false;
  v_has_customer boolean := false;
  v_has_importer boolean := false;
  v_membership_workspace text;
  v_legacy_workspace text;
  v_resolved_workspace text;
  v_resolution_source text := 'none';
BEGIN
  IF v_auth_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'authenticated', false,
      'auth_user_id', null,
      'profile', null,
      'memberships', '[]'::jsonb,
      'operator_importer_ids', '[]'::jsonb,
      'membership_workspace', null,
      'legacy_workspace', null,
      'resolved_workspace', null,
      'resolution_source', 'none'
    );
  END IF;

  SELECT to_jsonb(p)
  INTO v_profile
  FROM public.platform_user_profiles p
  WHERE p.auth_user_id = v_auth_user_id
  LIMIT 1;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', m.id,
        'role_code', m.role_code,
        'shipper_id', m.shipper_id,
        'importer_id', m.importer_id,
        'staff_id', m.staff_id,
        'active', m.active,
        'created_at', m.created_at,
        'revoked_at', m.revoked_at
      )
      ORDER BY m.created_at, m.id
    ),
    '[]'::jsonb
  )
  INTO v_memberships
  FROM public.platform_user_memberships m
  WHERE m.auth_user_id = v_auth_user_id
    AND m.active = true
    AND m.revoked_at IS NULL;

  SELECT EXISTS (
    SELECT 1
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_auth_user_id
      AND m.active = true
      AND m.revoked_at IS NULL
      AND m.role_code IN ('admin', 'supervisor')
  ) INTO v_has_internal;

  SELECT EXISTS (
    SELECT 1
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_auth_user_id
      AND m.active = true
      AND m.revoked_at IS NULL
      AND m.role_code IN ('shipper_admin', 'shipper_operator', 'shipper_readonly')
  ) INTO v_has_shipper;

  SELECT EXISTS (
    SELECT 1
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_auth_user_id
      AND m.active = true
      AND m.revoked_at IS NULL
      AND m.role_code = 'customer'
  ) INTO v_has_customer;

  SELECT EXISTS (
    SELECT 1
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_auth_user_id
      AND m.active = true
      AND m.revoked_at IS NULL
      AND m.role_code = 'importer'
  ) INTO v_has_importer;

  IF v_has_internal THEN
    v_membership_workspace := 'internal';
  ELSIF v_has_shipper THEN
    v_membership_workspace := 'shipper';
  ELSIF v_has_customer AND v_has_importer THEN
    v_membership_workspace := 'workspace_select';
  ELSIF v_has_customer THEN
    v_membership_workspace := 'customer';
  ELSIF v_has_importer THEN
    v_membership_workspace := 'importer';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = v_auth_user_id
      AND s.active = true
  ) INTO v_legacy_staff;

  SELECT EXISTS (
    SELECT 1
    FROM public.shipper_users su
    WHERE su.auth_user_id = v_auth_user_id
      AND su.active = true
  ) INTO v_legacy_shipper;

  SELECT EXISTS (
    SELECT 1
    FROM public.operators o
    WHERE o.auth_user_id = v_auth_user_id
      AND o.active = true
  ) INTO v_legacy_operator;

  SELECT COALESCE(jsonb_agg(x.importer_id ORDER BY x.importer_id), '[]'::jsonb)
  INTO v_operator_importer_ids
  FROM (
    SELECT DISTINCT oi.importer_id
    FROM public.operators o
    JOIN public.operator_importers oi
      ON oi.operator_id = o.id
     AND oi.revoked_at IS NULL
    WHERE o.auth_user_id = v_auth_user_id
      AND o.active = true
  ) x;

  -- Preserve the exact current /auth/check legacy precedence for rollback/parity.
  IF v_legacy_staff THEN
    v_legacy_workspace := 'internal';
  ELSIF v_legacy_shipper THEN
    v_legacy_workspace := 'shipper';
  ELSIF v_legacy_operator THEN
    v_legacy_workspace := 'importer';
  END IF;

  IF v_membership_workspace IS NOT NULL THEN
    v_resolved_workspace := v_membership_workspace;
    v_resolution_source := 'membership';
  ELSIF v_legacy_workspace IS NOT NULL THEN
    v_resolved_workspace := v_legacy_workspace;
    v_resolution_source := 'legacy_fallback';
  END IF;

  RETURN jsonb_build_object(
    'authenticated', true,
    'auth_user_id', v_auth_user_id,
    'profile', v_profile,
    'memberships', v_memberships,
    'operator_importer_ids', v_operator_importer_ids,
    'has_internal_membership', v_has_internal,
    'has_shipper_membership', v_has_shipper,
    'has_customer_membership', v_has_customer,
    'has_importer_membership', v_has_importer,
    'legacy_staff', v_legacy_staff,
    'legacy_shipper', v_legacy_shipper,
    'legacy_operator', v_legacy_operator,
    'membership_workspace', v_membership_workspace,
    'legacy_workspace', v_legacy_workspace,
    'resolved_workspace', v_resolved_workspace,
    'resolution_source', v_resolution_source,
    'must_change_password', COALESCE((v_profile ->> 'must_change_password')::boolean, false),
    'profile_active', COALESCE((v_profile ->> 'active')::boolean, false)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.current_platform_access_context_v1() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.current_platform_access_context_v1() FROM anon;
GRANT EXECUTE ON FUNCTION public.current_platform_access_context_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
