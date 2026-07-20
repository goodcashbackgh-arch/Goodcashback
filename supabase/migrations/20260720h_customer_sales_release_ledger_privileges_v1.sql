BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $$
BEGIN
  IF to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.customer_sales_release_legacy_issues') IS NULL
  THEN
    RAISE EXCEPTION 'Customer sales release ledger tables missing';
  END IF;
END $$;

REVOKE ALL PRIVILEGES ON TABLE public.customer_sales_release_lines
  FROM PUBLIC, anon, authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.customer_sales_release_legacy_issues
  FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.customer_sales_release_lines TO authenticated;
GRANT SELECT ON TABLE public.customer_sales_release_legacy_issues TO authenticated;

GRANT SELECT, INSERT, UPDATE ON TABLE public.customer_sales_release_lines TO service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.customer_sales_release_legacy_issues TO service_role;

NOTIFY pgrst,'reload schema';
COMMIT;
