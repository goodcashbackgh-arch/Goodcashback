BEGIN;

-- Accounting admin access helper v1
-- Production intent: admin-only accounting command centre.
-- Testing exception: a supervisor can be granted a narrow accounting_admin_testing flag in staff.permissions_json.
-- This avoids changing their primary role_type away from supervisor while allowing controlled access to admin accounting pages.

CREATE OR REPLACE FUNCTION public.internal_has_accounting_admin_access_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
      AND (
        s.role_type = 'admin'
        OR COALESCE((s.permissions_json->>'accounting_admin_testing')::boolean, false) = true
        OR COALESCE((s.permissions_json->>'admin_testing')::boolean, false) = true
      )
  )
$$;

REVOKE ALL ON FUNCTION public.internal_has_accounting_admin_access_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_has_accounting_admin_access_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
