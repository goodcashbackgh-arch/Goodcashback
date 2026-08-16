-- Patch B exact Customer / Importer / Both replacement probe v1
-- The behavioural mutations run inside a PL/pgSQL subtransaction that is
-- deliberately rolled back before the result is returned. No tested role,
-- membership history, operator/importer link, or audit row is persisted.
--
-- Governing authority:
-- docs/governing-pack/ui/MULTI_TENANT_ONBOARDING_ACCESS_MVP_COMPLETION_ADDENDUM_v1.md

BEGIN;
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION pg_temp.patch_b_exact_role_replacement_probe_v1()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_actor_auth_user_id uuid;
  v_operator_id uuid;
  v_target_auth_user_id uuid;
  v_importer_id uuid;
  v_relationship_type text;

  v_original_target_rows jsonb;
  v_restored_target_rows jsonb;
  v_unrelated_before jsonb;
  v_unrelated_now jsonb;
  v_unrelated_after jsonb;

  v_state_customer text[];
  v_state_importer text[];
  v_state_both text[];
  v_unrelated_unchanged_during boolean := true;

  v_audit_before_count bigint;
  v_audit_inside_count bigint;
  v_audit_after_count bigint;
  v_customer_audit jsonb;
  v_importer_audit jsonb;
  v_both_audit jsonb;
BEGIN
  IF to_regprocedure('public.internal_set_operator_importer_roles_v1(uuid,uuid,text,text[])') IS NULL THEN
    RETURN jsonb_build_object(
      'probe', 'PATCH_B_EXACT_ROLE_REPLACEMENT_V1',
      'ready', false,
      'review_required', 1,
      'reason', 'internal_set_operator_importer_roles_v1 is not installed'
    );
  END IF;

  SELECT s.auth_user_id
  INTO v_actor_auth_user_id
  FROM public.staff s
  JOIN auth.users au ON au.id = s.auth_user_id
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY
    CASE WHEN s.role_type::text = 'admin' THEN 0
         WHEN s.role_type::text = 'supervisor' THEN 1
         ELSE 2 END,
    s.id
  LIMIT 1;

  IF v_actor_auth_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'probe', 'PATCH_B_EXACT_ROLE_REPLACEMENT_V1',
      'ready', false,
      'review_required', 1,
      'reason', 'No active staff auth user is available to exercise the staff-only RPC'
    );
  END IF;

  SELECT
    o.id,
    o.auth_user_id,
    oi.importer_id,
    oi.relationship_type::text
  INTO
    v_operator_id,
    v_target_auth_user_id,
    v_importer_id,
    v_relationship_type
  FROM public.operators o
  JOIN public.operator_importers oi
    ON oi.operator_id = o.id
   AND oi.revoked_at IS NULL
  JOIN public.importers i
    ON i.id = oi.importer_id
   AND i.active = true
  WHERE o.active = true
    AND o.auth_user_id IS NOT NULL
    AND oi.relationship_type::text IN ('sole_owner', 'authorised_user')
  ORDER BY
    CASE
      WHEN lower(COALESCE(o.full_name::text, '')) LIKE '%test%' THEN 0
      WHEN lower(COALESCE(o.email::text, '')) LIKE '%test%' THEN 1
      ELSE 2
    END,
    o.id,
    oi.importer_id
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RETURN jsonb_build_object(
      'probe', 'PATCH_B_EXACT_ROLE_REPLACEMENT_V1',
      'ready', false,
      'review_required', 1,
      'reason', 'No eligible active operator/importer relationship exists for a rollback-only behavioural test'
    );
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
  INTO v_original_target_rows
  FROM public.platform_user_memberships m
  WHERE m.auth_user_id = v_target_auth_user_id
    AND m.importer_id = v_importer_id
    AND m.role_code IN ('customer', 'importer');

  SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
  INTO v_unrelated_before
  FROM public.platform_user_memberships m
  WHERE m.auth_user_id = v_target_auth_user_id
    AND NOT (
      m.importer_id = v_importer_id
      AND m.role_code IN ('customer', 'importer')
    );

  SELECT count(*)
  INTO v_audit_before_count
  FROM public.platform_access_audit_log a
  WHERE a.action_type = 'operator_importer_roles_replaced'
    AND a.target_auth_user_id = v_target_auth_user_id
    AND a.target_importer_id = v_importer_id;

  -- Make auth.uid() resolve to a real active staff user while exercising the
  -- SECURITY DEFINER RPC from the SQL editor/session.
  PERFORM set_config('request.jwt.claim.sub', v_actor_auth_user_id::text, true);

  BEGIN
    -- Establish a deterministic starting point: Both.
    PERFORM public.internal_set_operator_importer_roles_v1(
      v_operator_id,
      v_importer_id,
      v_relationship_type,
      ARRAY['customer', 'importer']::text[]
    );

    -- Both -> Customer only.
    PERFORM public.internal_set_operator_importer_roles_v1(
      v_operator_id,
      v_importer_id,
      v_relationship_type,
      ARRAY['customer']::text[]
    );

    SELECT COALESCE(array_agg(m.role_code ORDER BY m.role_code), ARRAY[]::text[])
    INTO v_state_customer
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_target_auth_user_id
      AND m.importer_id = v_importer_id
      AND m.role_code IN ('customer', 'importer')
      AND m.active = true
      AND m.revoked_at IS NULL;

    SELECT jsonb_build_object('before', a.before_json, 'after', a.after_json)
    INTO v_customer_audit
    FROM public.platform_access_audit_log a
    WHERE a.action_type = 'operator_importer_roles_replaced'
      AND a.target_auth_user_id = v_target_auth_user_id
      AND a.target_importer_id = v_importer_id
    ORDER BY a.created_at DESC, a.id DESC
    LIMIT 1;

    SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
    INTO v_unrelated_now
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_target_auth_user_id
      AND NOT (
        m.importer_id = v_importer_id
        AND m.role_code IN ('customer', 'importer')
      );
    v_unrelated_unchanged_during := v_unrelated_unchanged_during AND (v_unrelated_now = v_unrelated_before);

    -- Customer only -> Importer only.
    PERFORM public.internal_set_operator_importer_roles_v1(
      v_operator_id,
      v_importer_id,
      v_relationship_type,
      ARRAY['importer']::text[]
    );

    SELECT COALESCE(array_agg(m.role_code ORDER BY m.role_code), ARRAY[]::text[])
    INTO v_state_importer
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_target_auth_user_id
      AND m.importer_id = v_importer_id
      AND m.role_code IN ('customer', 'importer')
      AND m.active = true
      AND m.revoked_at IS NULL;

    SELECT jsonb_build_object('before', a.before_json, 'after', a.after_json)
    INTO v_importer_audit
    FROM public.platform_access_audit_log a
    WHERE a.action_type = 'operator_importer_roles_replaced'
      AND a.target_auth_user_id = v_target_auth_user_id
      AND a.target_importer_id = v_importer_id
    ORDER BY a.created_at DESC, a.id DESC
    LIMIT 1;

    SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
    INTO v_unrelated_now
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_target_auth_user_id
      AND NOT (
        m.importer_id = v_importer_id
        AND m.role_code IN ('customer', 'importer')
      );
    v_unrelated_unchanged_during := v_unrelated_unchanged_during AND (v_unrelated_now = v_unrelated_before);

    -- Importer only -> Both.
    PERFORM public.internal_set_operator_importer_roles_v1(
      v_operator_id,
      v_importer_id,
      v_relationship_type,
      ARRAY['customer', 'importer']::text[]
    );

    SELECT COALESCE(array_agg(m.role_code ORDER BY m.role_code), ARRAY[]::text[])
    INTO v_state_both
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_target_auth_user_id
      AND m.importer_id = v_importer_id
      AND m.role_code IN ('customer', 'importer')
      AND m.active = true
      AND m.revoked_at IS NULL;

    SELECT jsonb_build_object('before', a.before_json, 'after', a.after_json)
    INTO v_both_audit
    FROM public.platform_access_audit_log a
    WHERE a.action_type = 'operator_importer_roles_replaced'
      AND a.target_auth_user_id = v_target_auth_user_id
      AND a.target_importer_id = v_importer_id
    ORDER BY a.created_at DESC, a.id DESC
    LIMIT 1;

    SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
    INTO v_unrelated_now
    FROM public.platform_user_memberships m
    WHERE m.auth_user_id = v_target_auth_user_id
      AND NOT (
        m.importer_id = v_importer_id
        AND m.role_code IN ('customer', 'importer')
      );
    v_unrelated_unchanged_during := v_unrelated_unchanged_during AND (v_unrelated_now = v_unrelated_before);

    SELECT count(*)
    INTO v_audit_inside_count
    FROM public.platform_access_audit_log a
    WHERE a.action_type = 'operator_importer_roles_replaced'
      AND a.target_auth_user_id = v_target_auth_user_id
      AND a.target_importer_id = v_importer_id;

    -- Roll back every mutation made by all four RPC calls while retaining the
    -- captured PL/pgSQL variables for the returned proof.
    RAISE EXCEPTION USING ERRCODE = 'PB001', MESSAGE = 'rollback Patch B behavioural probe';
  EXCEPTION
    WHEN SQLSTATE 'PB001' THEN
      NULL;
  END;

  SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
  INTO v_restored_target_rows
  FROM public.platform_user_memberships m
  WHERE m.auth_user_id = v_target_auth_user_id
    AND m.importer_id = v_importer_id
    AND m.role_code IN ('customer', 'importer');

  SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
  INTO v_unrelated_after
  FROM public.platform_user_memberships m
  WHERE m.auth_user_id = v_target_auth_user_id
    AND NOT (
      m.importer_id = v_importer_id
      AND m.role_code IN ('customer', 'importer')
    );

  SELECT count(*)
  INTO v_audit_after_count
  FROM public.platform_access_audit_log a
  WHERE a.action_type = 'operator_importer_roles_replaced'
    AND a.target_auth_user_id = v_target_auth_user_id
    AND a.target_importer_id = v_importer_id;

  RETURN jsonb_build_object(
    'probe', 'PATCH_B_EXACT_ROLE_REPLACEMENT_V1',
    'ready', true,
    'target', jsonb_build_object(
      'operator_id', v_operator_id,
      'auth_user_id', v_target_auth_user_id,
      'importer_id', v_importer_id,
      'relationship_type', v_relationship_type
    ),
    'states', jsonb_build_object(
      'both_to_customer', to_jsonb(v_state_customer),
      'customer_to_importer', to_jsonb(v_state_importer),
      'importer_to_both', to_jsonb(v_state_both)
    ),
    'semantics_pass',
      v_state_customer = ARRAY['customer']::text[]
      AND v_state_importer = ARRAY['importer']::text[]
      AND v_state_both = ARRAY['customer', 'importer']::text[],
    'unrelated_memberships_unchanged_during_test', v_unrelated_unchanged_during,
    'rollback_restored_target_rows', v_restored_target_rows = v_original_target_rows,
    'rollback_restored_unrelated_rows', v_unrelated_after = v_unrelated_before,
    'rollback_restored_audit_count', v_audit_after_count = v_audit_before_count,
    'audit_rows_created_inside_test', v_audit_inside_count - v_audit_before_count,
    'audit_before_after_present',
      COALESCE(v_customer_audit ? 'before' AND v_customer_audit ? 'after', false)
      AND COALESCE(v_importer_audit ? 'before' AND v_importer_audit ? 'after', false)
      AND COALESCE(v_both_audit ? 'before' AND v_both_audit ? 'after', false),
    'captured_audit', jsonb_build_object(
      'both_to_customer', v_customer_audit,
      'customer_to_importer', v_importer_audit,
      'importer_to_both', v_both_audit
    ),
    'review_required', CASE
      WHEN v_state_customer = ARRAY['customer']::text[]
       AND v_state_importer = ARRAY['importer']::text[]
       AND v_state_both = ARRAY['customer', 'importer']::text[]
       AND v_unrelated_unchanged_during
       AND v_restored_target_rows = v_original_target_rows
       AND v_unrelated_after = v_unrelated_before
       AND v_audit_after_count = v_audit_before_count
       AND (v_audit_inside_count - v_audit_before_count) = 4
       AND COALESCE(v_customer_audit ? 'before' AND v_customer_audit ? 'after', false)
       AND COALESCE(v_importer_audit ? 'before' AND v_importer_audit ? 'after', false)
       AND COALESCE(v_both_audit ? 'before' AND v_both_audit ? 'after', false)
      THEN 0 ELSE 1 END
  );
END;
$$;

SELECT pg_temp.patch_b_exact_role_replacement_probe_v1() AS result;

ROLLBACK;
