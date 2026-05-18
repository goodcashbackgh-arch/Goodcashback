BEGIN;

-- Follow-up fix: live sage_businesses.sage_business_id may be uuid, so aggregate as text.
-- Scope: read-only Sage connection status RPC only. No OAuth/token/posting changes.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_sage_connection_status_v1()
RETURNS TABLE (
  connection_id uuid,
  connection_ref varchar,
  platform_tenant_id uuid,
  provider varchar,
  environment varchar,
  connection_status varchar,
  sage_business_count bigint,
  primary_sage_business_id text,
  primary_sage_business_name text,
  token_status varchar,
  token_expires_at timestamptz,
  token_health text,
  connected_by_staff_id uuid,
  connected_at timestamptz,
  last_refresh_at timestamptz,
  disabled_at timestamptz,
  last_error_code text,
  last_error_message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage connection status requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for Sage connection status.';
  END IF;

  RETURN QUERY
  SELECT
    c.id AS connection_id,
    c.connection_ref,
    c.platform_tenant_id,
    c.provider,
    c.environment,
    c.status AS connection_status,
    COUNT(b.id) FILTER (WHERE b.status = 'active') AS sage_business_count,
    MAX(b.sage_business_id::text) FILTER (WHERE b.is_primary = true AND b.status = 'active') AS primary_sage_business_id,
    MAX(b.sage_business_name::text) FILTER (WHERE b.is_primary = true AND b.status = 'active') AS primary_sage_business_name,
    MAX(t.status::text) FILTER (WHERE t.status = 'active')::varchar AS token_status,
    MAX(t.expires_at) FILTER (WHERE t.status = 'active') AS token_expires_at,
    CASE
      WHEN c.status = 'disabled' THEN 'disabled'
      WHEN COUNT(t.id) FILTER (WHERE t.status = 'active') = 0 THEN 'no_active_token'
      WHEN MAX(t.expires_at) FILTER (WHERE t.status = 'active') <= now() THEN 'expired'
      WHEN MAX(t.expires_at) FILTER (WHERE t.status = 'active') <= now() + interval '15 minutes' THEN 'expires_soon'
      ELSE 'healthy'
    END::text AS token_health,
    c.connected_by_staff_id,
    c.connected_at,
    c.last_refresh_at,
    c.disabled_at,
    c.last_error_code,
    c.last_error_message
  FROM public.sage_connections c
  LEFT JOIN public.sage_businesses b
    ON b.connection_id = c.id
  LEFT JOIN public.sage_oauth_tokens t
    ON t.connection_id = c.id
  GROUP BY
    c.id,
    c.connection_ref,
    c.platform_tenant_id,
    c.provider,
    c.environment,
    c.status,
    c.connected_by_staff_id,
    c.connected_at,
    c.last_refresh_at,
    c.disabled_at,
    c.last_error_code,
    c.last_error_message
  ORDER BY c.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_connection_status_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_connection_status_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
