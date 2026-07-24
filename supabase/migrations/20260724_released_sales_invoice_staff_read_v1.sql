BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_rls_enabled boolean;
BEGIN
  IF to_regclass('public.sales_invoices') IS NULL THEN
    RAISE EXCEPTION 'Required table missing: public.sales_invoices';
  END IF;

  IF to_regclass('public.customer_sales_release_lines') IS NULL THEN
    RAISE EXCEPTION 'Required Mini-build 3 table missing: public.customer_sales_release_lines';
  END IF;

  IF to_regprocedure('public.is_active_staff()') IS NULL THEN
    RAISE EXCEPTION 'Required function missing: public.is_active_staff()';
  END IF;

  SELECT c.relrowsecurity
  INTO v_rls_enabled
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'sales_invoices';

  IF COALESCE(v_rls_enabled, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'sales_invoices RLS is not enabled; refusing to change the table security model implicitly';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_staff_can_read_released_sales_invoice_v1(
  p_sales_invoice_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND public.is_active_staff()
    AND EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.sales_invoice_id = p_sales_invoice_id
        AND release_line.release_status = 'active'
    );
$$;

REVOKE ALL ON FUNCTION public.internal_staff_can_read_released_sales_invoice_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_staff_can_read_released_sales_invoice_v1(uuid) TO authenticated;

DROP POLICY IF EXISTS sales_invoices_released_staff_select_v1 ON public.sales_invoices;
CREATE POLICY sales_invoices_released_staff_select_v1
ON public.sales_invoices
FOR SELECT
TO authenticated
USING (public.internal_staff_can_read_released_sales_invoice_v1(id));

COMMENT ON POLICY sales_invoices_released_staff_select_v1 ON public.sales_invoices IS
'Allows active staff to read only customer sales invoices that already have active durable Mini-build 3 release membership. No write access and no unreleased invoice visibility is added.';

NOTIFY pgrst, 'reload schema';
COMMIT;
