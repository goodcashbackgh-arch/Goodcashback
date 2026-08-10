BEGIN;

-- Superseded branch-only draft retained as a no-op. Terminal/accounting/VAT
-- boundaries are already contained in the corrected primary migration.

DO $$
BEGIN
  IF to_regprocedure('public.protect_order_bundle_limit_breach_resolution_v1()') IS NULL
     OR to_regprocedure('public.flag_order_bundle_limit_after_summary_update_v1()') IS NULL
     OR to_regprocedure('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Corrected same-order supplier price increase v1 migration must run first.';
  END IF;
END $$;

COMMIT;
