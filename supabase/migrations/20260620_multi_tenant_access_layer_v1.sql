BEGIN;

CREATE TABLE IF NOT EXISTS public.platform_user_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE,
  email text NOT NULL,
  display_name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  must_change_password boolean NOT NULL DEFAULT false,
  created_by_staff_id uuid REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  disabled_at timestamptz,
  disabled_by_staff_id uuid REFERENCES public.staff(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.platform_user_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL,
  role_code text NOT NULL CHECK (role_code IN ('admin','supervisor','shipper_admin','shipper_operator','shipper_readonly','customer','importer')),
  shipper_id uuid REFERENCES public.shippers(id),
  importer_id uuid REFERENCES public.importers(id),
  staff_id uuid REFERENCES public.staff(id),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CONSTRAINT platform_user_memberships_role_target_check CHECK (
    (role_code IN ('admin','supervisor') AND staff_id IS NOT NULL AND shipper_id IS NULL AND importer_id IS NULL)
    OR (role_code IN ('shipper_admin','shipper_operator','shipper_readonly') AND shipper_id IS NOT NULL AND staff_id IS NULL AND importer_id IS NULL)
    OR (role_code IN ('customer','importer') AND importer_id IS NOT NULL AND staff_id IS NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.supervisor_access_scopes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supervisor_staff_id uuid NOT NULL REFERENCES public.staff(id),
  scope_mode text NOT NULL CHECK (scope_mode IN ('all','assigned')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.supervisor_branch_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supervisor_staff_id uuid NOT NULL REFERENCES public.staff(id),
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.platform_access_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_auth_user_id uuid,
  actor_staff_id uuid REFERENCES public.staff(id),
  action_type text NOT NULL,
  target_auth_user_id uuid,
  target_shipper_id uuid REFERENCES public.shippers(id),
  target_importer_id uuid REFERENCES public.importers(id),
  before_json jsonb,
  after_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_platform_user_profiles_active ON public.platform_user_profiles(active);
CREATE INDEX IF NOT EXISTS idx_platform_user_memberships_auth_user_id ON public.platform_user_memberships(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_platform_user_memberships_role_code ON public.platform_user_memberships(role_code);
CREATE INDEX IF NOT EXISTS idx_platform_user_memberships_shipper_id ON public.platform_user_memberships(shipper_id);
CREATE INDEX IF NOT EXISTS idx_platform_user_memberships_importer_id ON public.platform_user_memberships(importer_id);
CREATE INDEX IF NOT EXISTS idx_supervisor_access_scopes_staff ON public.supervisor_access_scopes(supervisor_staff_id);
CREATE INDEX IF NOT EXISTS idx_supervisor_branch_assignments_staff ON public.supervisor_branch_assignments(supervisor_staff_id);
CREATE INDEX IF NOT EXISTS idx_supervisor_branch_assignments_shipper ON public.supervisor_branch_assignments(shipper_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_platform_user_memberships_active_target
ON public.platform_user_memberships (
  auth_user_id,
  role_code,
  COALESCE(shipper_id, '00000000-0000-0000-0000-000000000000'::uuid),
  COALESCE(importer_id, '00000000-0000-0000-0000-000000000000'::uuid),
  COALESCE(staff_id, '00000000-0000-0000-0000-000000000000'::uuid)
)
WHERE active = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_supervisor_access_scopes_active_staff
ON public.supervisor_access_scopes(supervisor_staff_id)
WHERE active = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_supervisor_branch_assignments_active
ON public.supervisor_branch_assignments(supervisor_staff_id, shipper_id)
WHERE active = true;

INSERT INTO public.platform_user_profiles (auth_user_id, email, display_name, active, must_change_password)
SELECT s.auth_user_id, s.email::text, s.full_name::text, s.active, false
FROM public.staff s
WHERE s.auth_user_id IS NOT NULL
ON CONFLICT (auth_user_id) DO UPDATE SET
  email = EXCLUDED.email,
  display_name = EXCLUDED.display_name,
  active = public.platform_user_profiles.active OR EXCLUDED.active,
  updated_at = now();

INSERT INTO public.platform_user_profiles (auth_user_id, email, display_name, active, must_change_password)
SELECT su.auth_user_id, su.email::text, su.full_name::text, su.active, false
FROM public.shipper_users su
WHERE su.auth_user_id IS NOT NULL
ON CONFLICT (auth_user_id) DO UPDATE SET
  email = COALESCE(NULLIF(public.platform_user_profiles.email, ''), EXCLUDED.email),
  display_name = COALESCE(NULLIF(public.platform_user_profiles.display_name, ''), EXCLUDED.display_name),
  active = public.platform_user_profiles.active OR EXCLUDED.active,
  updated_at = now();

INSERT INTO public.platform_user_profiles (auth_user_id, email, display_name, active, must_change_password)
SELECT o.auth_user_id, o.email::text, o.full_name::text, o.active, false
FROM public.operators o
WHERE o.auth_user_id IS NOT NULL
ON CONFLICT (auth_user_id) DO UPDATE SET
  email = COALESCE(NULLIF(public.platform_user_profiles.email, ''), EXCLUDED.email),
  display_name = COALESCE(NULLIF(public.platform_user_profiles.display_name, ''), EXCLUDED.display_name),
  active = public.platform_user_profiles.active OR EXCLUDED.active,
  updated_at = now();

INSERT INTO public.platform_user_memberships (auth_user_id, role_code, staff_id, active)
SELECT s.auth_user_id, s.role_type::text, s.id, s.active
FROM public.staff s
WHERE s.auth_user_id IS NOT NULL
  AND s.active = true
  AND NOT EXISTS (
    SELECT 1 FROM public.platform_user_memberships m
    WHERE m.auth_user_id = s.auth_user_id AND m.role_code = s.role_type::text AND m.staff_id = s.id AND m.active = true
  );

INSERT INTO public.platform_user_memberships (auth_user_id, role_code, shipper_id, active)
SELECT su.auth_user_id, su.role_at_shipper::text, su.shipper_id, su.active
FROM public.shipper_users su
WHERE su.auth_user_id IS NOT NULL
  AND su.active = true
  AND NOT EXISTS (
    SELECT 1 FROM public.platform_user_memberships m
    WHERE m.auth_user_id = su.auth_user_id AND m.role_code = su.role_at_shipper::text AND m.shipper_id = su.shipper_id AND m.active = true
  );

INSERT INTO public.platform_user_memberships (auth_user_id, role_code, importer_id, active)
SELECT o.auth_user_id, 'importer', oi.importer_id, true
FROM public.operators o
JOIN public.operator_importers oi ON oi.operator_id = o.id
WHERE o.auth_user_id IS NOT NULL
  AND o.active = true
  AND oi.revoked_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.platform_user_memberships m
    WHERE m.auth_user_id = o.auth_user_id AND m.role_code = 'importer' AND m.importer_id = oi.importer_id AND m.active = true
  );

INSERT INTO public.supervisor_access_scopes (supervisor_staff_id, scope_mode, active)
SELECT s.id, 'all', true
FROM public.staff s
WHERE s.role_type = 'supervisor'
  AND s.active = true
  AND NOT EXISTS (
    SELECT 1 FROM public.supervisor_access_scopes sas
    WHERE sas.supervisor_staff_id = s.id AND sas.active = true
  );

CREATE OR REPLACE FUNCTION public.internal_access_control_diagnostic_v1()
RETURNS TABLE(section text, severity text, data jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_staff boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
  ) INTO v_is_staff;

  IF NOT v_is_staff THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT '01_current_source_counts'::text, 'info'::text, jsonb_build_object(
    'active_staff', (SELECT count(*) FROM public.staff WHERE active = true AND auth_user_id IS NOT NULL),
    'active_shipper_users', (SELECT count(*) FROM public.shipper_users WHERE active = true AND auth_user_id IS NOT NULL),
    'active_operators', (SELECT count(*) FROM public.operators WHERE active = true AND auth_user_id IS NOT NULL),
    'active_operator_importer_links', (SELECT count(*) FROM public.operator_importers WHERE revoked_at IS NULL),
    'platform_profiles', (SELECT count(*) FROM public.platform_user_profiles),
    'active_platform_memberships', (SELECT count(*) FROM public.platform_user_memberships WHERE active = true),
    'active_supervisor_scopes', (SELECT count(*) FROM public.supervisor_access_scopes WHERE active = true)
  );

  RETURN QUERY
  WITH missing AS (
    SELECT 'staff' AS source, s.auth_user_id, s.email::text, s.full_name::text AS display_name
    FROM public.staff s
    LEFT JOIN public.platform_user_profiles p ON p.auth_user_id = s.auth_user_id
    WHERE s.active = true AND s.auth_user_id IS NOT NULL AND p.id IS NULL
    UNION ALL
    SELECT 'shipper_users', su.auth_user_id, su.email::text, su.full_name::text
    FROM public.shipper_users su
    LEFT JOIN public.platform_user_profiles p ON p.auth_user_id = su.auth_user_id
    WHERE su.active = true AND su.auth_user_id IS NOT NULL AND p.id IS NULL
    UNION ALL
    SELECT 'operators', o.auth_user_id, o.email::text, o.full_name::text
    FROM public.operators o
    LEFT JOIN public.platform_user_profiles p ON p.auth_user_id = o.auth_user_id
    WHERE o.active = true AND o.auth_user_id IS NOT NULL AND p.id IS NULL
  )
  SELECT '02_missing_profiles'::text,
         CASE WHEN count(*) = 0 THEN 'ok' ELSE 'blocker' END::text,
         COALESCE(jsonb_agg(to_jsonb(missing)), '[]'::jsonb)
  FROM missing;

  RETURN QUERY
  WITH missing AS (
    SELECT 'staff' AS source, s.auth_user_id, s.role_type::text AS expected_role, null::uuid AS shipper_id, null::uuid AS importer_id, s.id AS staff_id
    FROM public.staff s
    LEFT JOIN public.platform_user_memberships m ON m.auth_user_id = s.auth_user_id AND m.role_code = s.role_type::text AND m.staff_id = s.id AND m.active = true
    WHERE s.active = true AND s.auth_user_id IS NOT NULL AND m.id IS NULL
    UNION ALL
    SELECT 'shipper_users', su.auth_user_id, su.role_at_shipper::text, su.shipper_id, null::uuid, null::uuid
    FROM public.shipper_users su
    LEFT JOIN public.platform_user_memberships m ON m.auth_user_id = su.auth_user_id AND m.role_code = su.role_at_shipper::text AND m.shipper_id = su.shipper_id AND m.active = true
    WHERE su.active = true AND su.auth_user_id IS NOT NULL AND m.id IS NULL
    UNION ALL
    SELECT 'operator_importers', o.auth_user_id, 'importer', null::uuid, oi.importer_id, null::uuid
    FROM public.operators o
    JOIN public.operator_importers oi ON oi.operator_id = o.id
    LEFT JOIN public.platform_user_memberships m ON m.auth_user_id = o.auth_user_id AND m.role_code = 'importer' AND m.importer_id = oi.importer_id AND m.active = true
    WHERE o.active = true AND o.auth_user_id IS NOT NULL AND oi.revoked_at IS NULL AND m.id IS NULL
  )
  SELECT '03_missing_memberships'::text,
         CASE WHEN count(*) = 0 THEN 'ok' ELSE 'blocker' END::text,
         COALESCE(jsonb_agg(to_jsonb(missing)), '[]'::jsonb)
  FROM missing;

  RETURN QUERY
  WITH missing AS (
    SELECT s.id AS supervisor_staff_id, s.auth_user_id, s.full_name, s.email
    FROM public.staff s
    LEFT JOIN public.supervisor_access_scopes sas ON sas.supervisor_staff_id = s.id AND sas.active = true
    WHERE s.active = true AND s.role_type = 'supervisor' AND sas.id IS NULL
  )
  SELECT '04_supervisors_missing_scope'::text,
         CASE WHEN count(*) = 0 THEN 'ok' ELSE 'blocker' END::text,
         COALESCE(jsonb_agg(to_jsonb(missing)), '[]'::jsonb)
  FROM missing;

  RETURN QUERY
  SELECT '05_enforcement_readiness'::text,
         CASE WHEN (
           (SELECT count(*) FROM public.staff s LEFT JOIN public.platform_user_profiles p ON p.auth_user_id = s.auth_user_id WHERE s.active = true AND s.auth_user_id IS NOT NULL AND p.id IS NULL) = 0
           AND (SELECT count(*) FROM public.shipper_users su LEFT JOIN public.platform_user_profiles p ON p.auth_user_id = su.auth_user_id WHERE su.active = true AND su.auth_user_id IS NOT NULL AND p.id IS NULL) = 0
           AND (SELECT count(*) FROM public.operators o LEFT JOIN public.platform_user_profiles p ON p.auth_user_id = o.auth_user_id WHERE o.active = true AND o.auth_user_id IS NOT NULL AND p.id IS NULL) = 0
           AND (SELECT count(*) FROM public.staff s LEFT JOIN public.supervisor_access_scopes sas ON sas.supervisor_staff_id = s.id AND sas.active = true WHERE s.active = true AND s.role_type = 'supervisor' AND sas.id IS NULL) = 0
         ) THEN 'ok' ELSE 'blocker' END::text,
         jsonb_build_object(
           'safe_to_enable_platform_access_enforcement', false,
           'reason', 'Contract requires UI and auth-check fallback to be built and tested before enabling enforcement. This diagnostic only proves backfill coverage.'
         );
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_access_control_diagnostic_v1() TO authenticated;

ALTER TABLE public.platform_user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_user_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supervisor_access_scopes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supervisor_branch_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_access_audit_log ENABLE ROW LEVEL SECURITY;

NOTIFY pgrst, 'reload schema';

COMMIT;
