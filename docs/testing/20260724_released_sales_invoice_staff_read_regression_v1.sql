BEGIN;

DO $$
DECLARE
  v_policy_qual text;
  v_function_def text;
  v_authenticated_select boolean;
  v_authenticated_insert boolean;
  v_authenticated_update boolean;
  v_authenticated_delete boolean;
BEGIN
  IF to_regprocedure('public.internal_staff_can_read_released_sales_invoice_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: released sales-invoice staff-read helper is missing';
  END IF;

  SELECT pg_get_functiondef('public.internal_staff_can_read_released_sales_invoice_v1(uuid)'::regprocedure)
  INTO v_function_def;

  IF v_function_def NOT ILIKE '%SECURITY DEFINER%' THEN
    RAISE EXCEPTION 'FAIL: staff-read helper must be SECURITY DEFINER so the policy can verify durable membership without broad table exposure';
  END IF;

  IF v_function_def NOT ILIKE '%public.is_active_staff()%' THEN
    RAISE EXCEPTION 'FAIL: staff-read helper does not require an active staff account';
  END IF;

  IF v_function_def NOT ILIKE '%customer_sales_release_lines%'
     OR v_function_def NOT ILIKE '%release_status = ''active''%' THEN
    RAISE EXCEPTION 'FAIL: staff-read helper is not restricted to active durable release membership';
  END IF;

  SELECT policy.qual
  INTO v_policy_qual
  FROM pg_policies policy
  WHERE policy.schemaname = 'public'
    AND policy.tablename = 'sales_invoices'
    AND policy.policyname = 'sales_invoices_released_staff_select_v1'
    AND policy.cmd = 'SELECT';

  IF v_policy_qual IS NULL THEN
    RAISE EXCEPTION 'FAIL: released sales-invoice SELECT policy is missing';
  END IF;

  IF v_policy_qual NOT ILIKE '%internal_staff_can_read_released_sales_invoice_v1%'
  THEN
    RAISE EXCEPTION 'FAIL: released sales-invoice policy does not use the exact durable-membership helper';
  END IF;

  SELECT
    has_table_privilege('authenticated', 'public.sales_invoices', 'SELECT'),
    has_table_privilege('authenticated', 'public.sales_invoices', 'INSERT'),
    has_table_privilege('authenticated', 'public.sales_invoices', 'UPDATE'),
    has_table_privilege('authenticated', 'public.sales_invoices', 'DELETE')
  INTO
    v_authenticated_select,
    v_authenticated_insert,
    v_authenticated_update,
    v_authenticated_delete;

  IF NOT v_authenticated_select THEN
    RAISE EXCEPTION 'FAIL: authenticated role lacks the pre-existing SELECT privilege required for RLS evaluation';
  END IF;

  IF v_authenticated_insert OR v_authenticated_update OR v_authenticated_delete THEN
    RAISE EXCEPTION 'FAIL: patch must not add authenticated write privileges to sales_invoices';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class table_class
    JOIN pg_namespace namespace_row ON namespace_row.oid = table_class.relnamespace
    WHERE namespace_row.nspname = 'public'
      AND table_class.relname = 'sales_invoices'
      AND table_class.relrowsecurity = true
  ) THEN
    RAISE EXCEPTION 'FAIL: sales_invoices RLS is not enabled';
  END IF;
END $$;

ROLLBACK;

SELECT 'PASS: active staff can read only customer sales invoices with active durable Mini-build 3 membership; no write privilege or workflow change was introduced' AS regression_result;
