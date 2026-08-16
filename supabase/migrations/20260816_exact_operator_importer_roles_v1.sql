BEGIN;

CREATE OR REPLACE FUNCTION public.internal_set_operator_importer_roles_v1(
  p_operator_id uuid,
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
  v_auth_user_id uuid;
  v_shipper_id uuid;
  v_role_codes text[];
  v_before jsonb := '[]'::jsonb;
  v_after jsonb := '[]'::jsonb;
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

  IF p_relationship_type NOT IN ('sole_owner', 'authorised_user') THEN
    RAISE EXCEPTION 'invalid_relationship_type';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(COALESCE(p_role_codes, ARRAY[]::text[])) AS r(role_code)
    WHERE r.role_code IS NULL
       OR btrim(r.role_code) NOT IN ('customer', 'importer')
  ) THEN
    RAISE EXCEPTION 'invalid_role_code';
  END IF;

  SELECT COALESCE(array_agg(x.role_code ORDER BY x.role_code), ARRAY[]::text[])
  INTO v_role_codes
  FROM (
    SELECT DISTINCT btrim(r.role_code) AS role_code
    FROM unnest(COALESCE(p_role_codes, ARRAY[]::text[])) AS r(role_code)
    WHERE r.role_code IS NOT NULL
  ) x;

  IF cardinality(v_role_codes) = 0 THEN
    RAISE EXCEPTION 'portal_role_required';
  END IF;

  -- Serialize role replacement for this operator so concurrent exact-role saves
  -- cannot leave the target branch with the union of two conflicting choices.
  SELECT o.auth_user_id
  INTO v_auth_user_id
  FROM public.operators o
  WHERE o.id = p_operator_id
    AND o.active = true
  FOR UPDATE;

  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'operator_has_no_auth_user_id';
  END IF;

  SELECT i.shipper_id
  INTO v_shipper_id
  FROM public.importers i
  WHERE i.id = p_importer_id
    AND i.active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'importer_not_found';
  END IF;

  -- Preserve the existing operator/importer branch relationship. Portal role
  -- semantics live in platform_user_memberships and must not rewrite legacy links.
  INSERT INTO public.operator_importers (operator_id, importer_id, relationship_type)
  SELECT p_operator_id, p_importer_id, p_relationship_type
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = p_operator_id
      AND oi.importer_id = p_importer_id
      AND oi.revoked_at IS NULL
  );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', m.id,
        'role_code', m.role_code,
        'importer_id', m.importer_id,
        'active', m.active,
        'created_at', m.created_at,
        'revoked_at', m.revoked_at
      )
      ORDER BY m.role_code, m.created_at, m.id
    ),
    '[]'::jsonb
  )
  INTO v_before
  FROM public.platform_user_memberships m
  WHERE m.auth_user_id = v_auth_user_id
    AND m.importer_id = p_importer_id
    AND m.role_code IN ('customer', 'importer')
    AND m.active = true
    AND m.revoked_at IS NULL;

  -- Revoke only unticked customer/importer roles for this exact importer branch.
  UPDATE public.platform_user_memberships m
  SET active = false,
      revoked_at = now()
  WHERE m.auth_user_id = v_auth_user_id
    AND m.importer_id = p_importer_id
    AND m.role_code IN ('customer', 'importer')
    AND m.active = true
    AND m.revoked_at IS NULL
    AND NOT (m.role_code = ANY(v_role_codes));

  -- Add only the selected roles that are not already active. Historical revoked
  -- rows stay immutable, preserving membership history.
  INSERT INTO public.platform_user_memberships (
    auth_user_id,
    role_code,
    importer_id,
    active
  )
  SELECT
    v_auth_user_id,
    r.role_code,
    p_importer_id,
    true
  FROM unnest(v_role_codes) AS r(role_code)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_auth_user_id
      AND m.importer_id = p_importer_id
      AND m.role_code = r.role_code
      AND m.active = true
      AND m.revoked_at IS NULL
  );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', m.id,
        'role_code', m.role_code,
        'importer_id', m.importer_id,
        'active', m.active,
        'created_at', m.created_at,
        'revoked_at', m.revoked_at
      )
      ORDER BY m.role_code, m.created_at, m.id
    ),
    '[]'::jsonb
  )
  INTO v_after
  FROM public.platform_user_memberships m
  WHERE m.auth_user_id = v_auth_user_id
    AND m.importer_id = p_importer_id
    AND m.role_code IN ('customer', 'importer')
    AND m.active = true
    AND m.revoked_at IS NULL;

  INSERT INTO public.platform_access_audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action_type,
    target_auth_user_id,
    target_shipper_id,
    target_importer_id,
    before_json,
    after_json
  )
  VALUES (
    auth.uid(),
    v_staff_id,
    'operator_importer_roles_replaced',
    v_auth_user_id,
    v_shipper_id,
    p_importer_id,
    jsonb_build_object(
      'operator_id', p_operator_id,
      'relationship_type', p_relationship_type,
      'memberships', v_before
    ),
    jsonb_build_object(
      'operator_id', p_operator_id,
      'relationship_type', p_relationship_type,
      'memberships', v_after
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'operator_id', p_operator_id,
    'auth_user_id', v_auth_user_id,
    'importer_id', p_importer_id,
    'selected_roles', to_jsonb(v_role_codes),
    'before', v_before,
    'after', v_after
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_set_operator_importer_roles_v1(uuid, uuid, text, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.internal_set_operator_importer_roles_v1(uuid, uuid, text, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_set_operator_importer_roles_v1(uuid, uuid, text, text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
