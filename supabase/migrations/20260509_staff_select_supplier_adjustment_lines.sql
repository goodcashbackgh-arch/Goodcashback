-- Allow active admin/supervisor staff to see saved supplier invoice accounting adjustment rows.
-- This fixes supervisor reconciliation display only.
--
-- Deliberately narrow:
--   - SELECT policy only
--   - no direct INSERT/UPDATE/DELETE policy
--   - write/delete remains controlled by SECURITY DEFINER RPCs
--   - no invoice/order state changes

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_accounting_adjustment_lines'
      AND policyname = 'staff_select_supplier_invoice_accounting_adjustment_lines'
  ) THEN
    CREATE POLICY staff_select_supplier_invoice_accounting_adjustment_lines
      ON public.supplier_invoice_accounting_adjustment_lines
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1
          FROM public.staff s
          WHERE s.auth_user_id = auth.uid()
            AND s.active = true
            AND s.role_type IN ('admin', 'supervisor')
        )
      );
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
