BEGIN;

-- Sage Cloud Accounting connection foundation v1
-- Contract: docs/governing-pack/ui/COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v4.md Phase 5
-- Scope: DB foundation only. No OAuth routes, no Sage adapter, no posting batch model, no live Sage calls.
-- Security: no token/client secret exposure to browser. Token/log tables are RLS-enabled with no direct authenticated table policies.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;

  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.sage_connections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_ref varchar NOT NULL UNIQUE DEFAULT ('SAGECON-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))),
  platform_tenant_id uuid,
  provider varchar NOT NULL DEFAULT 'sage_cloud_accounting' CHECK (provider = 'sage_cloud_accounting'),
  environment varchar NOT NULL DEFAULT 'production' CHECK (environment IN ('production','sandbox','test')),
  status varchar NOT NULL DEFAULT 'pending_oauth' CHECK (status IN (
    'pending_oauth',
    'connected',
    'token_expired',
    'refresh_failed',
    'revoked',
    'disabled',
    'error'
  )),
  connected_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  connected_at timestamptz,
  last_refresh_at timestamptz,
  disabled_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  disabled_at timestamptz,
  disable_reason text,
  last_error_code text,
  last_error_message text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sage_connections_disabled_fields_check CHECK (
    (status <> 'disabled') OR disabled_at IS NOT NULL
  )
);

COMMENT ON TABLE public.sage_connections IS
'Server-side Sage Cloud Accounting connection records. No browser-to-Sage calls. OAuth/token work is handled by future server routes only.';

COMMENT ON COLUMN public.sage_connections.platform_tenant_id IS
'Nullable until the platform tenant table/key is locked. Do not infer tenant structure from this column.';

CREATE TABLE IF NOT EXISTS public.sage_businesses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id uuid NOT NULL REFERENCES public.sage_connections(id) ON DELETE CASCADE,
  platform_tenant_id uuid,
  sage_business_id text NOT NULL,
  sage_business_name text NOT NULL,
  business_country_code varchar,
  business_currency_code varchar,
  is_primary boolean NOT NULL DEFAULT false,
  status varchar NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','disconnected','disabled')),
  selected_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  selected_at timestamptz,
  raw_business_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connection_id, sage_business_id)
);

COMMENT ON TABLE public.sage_businesses IS
'Sage businesses discovered/selected under a Sage connection. Business selection is consumed later by Accounting Command Centre settings and posting batches.';

CREATE TABLE IF NOT EXISTS public.sage_oauth_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id uuid NOT NULL REFERENCES public.sage_connections(id) ON DELETE CASCADE,
  sage_business_row_id uuid REFERENCES public.sage_businesses(id) ON DELETE SET NULL,
  access_token_encrypted text NOT NULL,
  refresh_token_encrypted text NOT NULL,
  token_type varchar NOT NULL DEFAULT 'Bearer',
  expires_at timestamptz NOT NULL,
  scopes text[] NOT NULL DEFAULT ARRAY[]::text[],
  status varchar NOT NULL DEFAULT 'active' CHECK (status IN (
    'active',
    'superseded',
    'refresh_failed',
    'revoked',
    'disabled'
  )),
  encryption_key_ref text,
  issued_at timestamptz NOT NULL DEFAULT now(),
  last_refresh_at timestamptz,
  superseded_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sage_oauth_tokens_active_expiry_check CHECK (
    status <> 'active' OR expires_at > created_at
  )
);

COMMENT ON TABLE public.sage_oauth_tokens IS
'Encrypted Sage OAuth tokens. Never expose this table directly to browser/client code. Future OAuth refresh must be server-side only.';

CREATE TABLE IF NOT EXISTS public.sage_api_request_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id uuid REFERENCES public.sage_connections(id) ON DELETE SET NULL,
  sage_business_row_id uuid REFERENCES public.sage_businesses(id) ON DELETE SET NULL,
  posting_batch_id uuid,
  posting_batch_row_id uuid,
  connection_event_type varchar CHECK (connection_event_type IS NULL OR connection_event_type IN (
    'oauth_start',
    'oauth_callback',
    'token_refresh',
    'test_connection',
    'business_discovery',
    'disable_connection',
    'posting_batch',
    'other'
  )),
  request_kind varchar NOT NULL CHECK (request_kind IN (
    'oauth',
    'token_refresh',
    'business_discovery',
    'test_connection',
    'posting',
    'other'
  )),
  http_method varchar NOT NULL CHECK (http_method IN ('GET','POST','PUT','PATCH','DELETE')),
  endpoint_path text NOT NULL,
  idempotency_key text,
  request_payload_redacted jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_headers_redacted jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_payload_hash text,
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sage_api_request_log_has_context_check CHECK (
    connection_id IS NOT NULL
    OR posting_batch_id IS NOT NULL
    OR posting_batch_row_id IS NOT NULL
    OR connection_event_type IS NOT NULL
  ),
  CONSTRAINT sage_api_request_log_no_full_url_check CHECK (
    endpoint_path !~* '^https?://'
  )
);

COMMENT ON TABLE public.sage_api_request_log IS
'Redacted Sage API request audit log. Stores endpoint paths and redacted payloads only; never store OAuth secrets or bearer tokens here.';

CREATE TABLE IF NOT EXISTS public.sage_api_response_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_log_id uuid NOT NULL REFERENCES public.sage_api_request_log(id) ON DELETE CASCADE,
  connection_id uuid REFERENCES public.sage_connections(id) ON DELETE SET NULL,
  sage_business_row_id uuid REFERENCES public.sage_businesses(id) ON DELETE SET NULL,
  http_status integer,
  success_yn boolean NOT NULL DEFAULT false,
  sage_object_type text,
  sage_object_id text,
  sage_reference text,
  response_payload_redacted jsonb NOT NULL DEFAULT '{}'::jsonb,
  response_headers_redacted jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_code text,
  error_message text,
  duration_ms integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sage_api_response_log_http_status_check CHECK (
    http_status IS NULL OR (http_status >= 100 AND http_status <= 599)
  ),
  CONSTRAINT sage_api_response_log_success_check CHECK (
    success_yn = false OR (http_status BETWEEN 200 AND 299)
  )
);

COMMENT ON TABLE public.sage_api_response_log IS
'Redacted Sage API response audit log. Future posting must confirm Sage object ids before platform rows are marked posted.';

CREATE INDEX IF NOT EXISTS idx_sage_connections_status
  ON public.sage_connections(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sage_connections_platform_tenant
  ON public.sage_connections(platform_tenant_id)
  WHERE platform_tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sage_businesses_connection
  ON public.sage_businesses(connection_id, status, is_primary DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sage_businesses_one_primary_per_connection
  ON public.sage_businesses(connection_id)
  WHERE is_primary = true AND status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_sage_oauth_tokens_one_active_per_connection
  ON public.sage_oauth_tokens(connection_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_sage_oauth_tokens_expires
  ON public.sage_oauth_tokens(expires_at)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_sage_api_request_log_connection
  ON public.sage_api_request_log(connection_id, created_at DESC)
  WHERE connection_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sage_api_request_log_posting_batch
  ON public.sage_api_request_log(posting_batch_id, posting_batch_row_id)
  WHERE posting_batch_id IS NOT NULL OR posting_batch_row_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sage_api_response_log_request
  ON public.sage_api_response_log(request_log_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sage_api_response_log_sage_object
  ON public.sage_api_response_log(sage_object_type, sage_object_id)
  WHERE sage_object_id IS NOT NULL;

ALTER TABLE public.sage_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sage_businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sage_oauth_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sage_api_request_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sage_api_response_log ENABLE ROW LEVEL SECURITY;

-- Intentionally no direct authenticated table policies for these objects.
-- Browser/client access must go through SECURITY DEFINER RPCs or future server routes.
REVOKE ALL ON TABLE public.sage_connections FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sage_businesses FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sage_oauth_tokens FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sage_api_request_log FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sage_api_response_log FROM PUBLIC, anon, authenticated;

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
    MAX(b.sage_business_id) FILTER (WHERE b.is_primary = true AND b.status = 'active') AS primary_sage_business_id,
    MAX(b.sage_business_name) FILTER (WHERE b.is_primary = true AND b.status = 'active') AS primary_sage_business_name,
    MAX(t.status) FILTER (WHERE t.status = 'active') AS token_status,
    MAX(t.expires_at) FILTER (WHERE t.status = 'active') AS token_expires_at,
    CASE
      WHEN c.status = 'disabled' THEN 'disabled'
      WHEN MAX(t.id) FILTER (WHERE t.status = 'active') IS NULL THEN 'no_active_token'
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
