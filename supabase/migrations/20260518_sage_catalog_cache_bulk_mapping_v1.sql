BEGIN;

-- Persist read-only Sage discovery so admins do not need to rerun the Sage API check
-- after every mapping save. This is catalogue/cache data only. No Sage posting.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_connections') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_connections';
  END IF;
  IF to_regclass('public.sage_businesses') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_businesses';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.sage_catalog_category_cache (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sage_connection_id uuid NOT NULL REFERENCES public.sage_connections(id) ON DELETE CASCADE,
  sage_business_row_id uuid REFERENCES public.sage_businesses(id) ON DELETE CASCADE,
  sage_business_id text,
  category_key text NOT NULL,
  category_label text NOT NULL,
  endpoint_path text NOT NULL,
  http_status integer,
  ok boolean NOT NULL DEFAULT false,
  row_count integer NOT NULL DEFAULT 0,
  last_error text,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sage_catalog_category_cache_unique UNIQUE (sage_connection_id, sage_business_row_id, category_key)
);

CREATE TABLE IF NOT EXISTS public.sage_catalog_cache (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sage_connection_id uuid NOT NULL REFERENCES public.sage_connections(id) ON DELETE CASCADE,
  sage_business_row_id uuid REFERENCES public.sage_businesses(id) ON DELETE CASCADE,
  sage_business_id text,
  category_key text NOT NULL,
  sage_external_id text NOT NULL,
  display_name text NOT NULL,
  reference_text text,
  code_text text,
  sage_type text,
  active_status text,
  raw_preview_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sage_catalog_cache_unique_external UNIQUE (sage_connection_id, sage_business_row_id, category_key, sage_external_id)
);

CREATE INDEX IF NOT EXISTS idx_sage_catalog_cache_category
ON public.sage_catalog_cache(sage_connection_id, sage_business_row_id, category_key, display_name);

CREATE INDEX IF NOT EXISTS idx_sage_catalog_cache_external
ON public.sage_catalog_cache(sage_external_id);

ALTER TABLE public.sage_catalog_category_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sage_catalog_cache ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.sage_catalog_category_cache FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sage_catalog_cache FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.sage_catalog_cache IS
'Read-only cached Sage catalogue objects discovered from the active Sage connection. Used for admin mapping selects. Does not create or update Sage objects.';

COMMENT ON TABLE public.sage_catalog_category_cache IS
'Read-only Sage catalogue discovery status by category. Allows the UI to show cached discovery without rerunning Sage API calls.';

NOTIFY pgrst, 'reload schema';

COMMIT;
