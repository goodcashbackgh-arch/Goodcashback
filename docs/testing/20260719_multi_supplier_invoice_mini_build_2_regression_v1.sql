-- Multi-supplier-invoice order control — Mini-build 2 regression v1
-- Run after 20260719d_multi_supplier_invoice_payment_bundle_v1.sql.
-- Catalog/read-only checks. No business data is changed.

BEGIN;

DO $$
DECLARE
  v_definition text;
  v_view_definition text;
BEGIN
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: atomic multi-invoice supplier-payment bundle RPC is missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)'::regprocedure
  ) INTO v_definition;

  IF position('jsonb_to_recordset' in v_definition) = 0
     OR position('same order' in lower(v_definition)) = 0
     OR position('full amount' in lower(v_definition)) = 0
     OR position('already has an active allocation' in lower(v_definition)) = 0
     OR position('approved_current' in v_definition) = 0
     OR position('ref_corrected_approved' in v_definition) = 0
     OR position('atomic multi-invoice supplier-payment bundle' in lower(v_definition)) = 0
  THEN
    RAISE EXCEPTION 'FAIL: bundle RPC is missing identity, approval, balance, reuse or atomic controls';
  END IF;

  IF position('INSERT INTO public.dva_statement_line_allocations' in v_definition) = 0
     OR position('FROM pg_temp.supplier_payment_bundle_input' in v_definition) = 0
     OR position('source_bank_account_mapping_code' in v_definition) = 0
     OR position('source_wallet_code' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: bundle RPC does not write exact child allocations with shared source provenance';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated execute grant is missing on bundle RPC';
  END IF;

  IF to_regclass('public.supplier_payment_candidate_status_vw') IS NULL THEN
    RAISE EXCEPTION 'FAIL: supplier payment candidate view is missing';
  END IF;

  SELECT pg_get_viewdef('public.supplier_payment_candidate_status_vw'::regclass, true)
    INTO v_view_definition;

  IF position('approved_current' in v_view_definition) = 0
     OR position('ref_corrected_approved' in v_view_definition) = 0
     OR position('remaining_unmatched_gbp' in v_view_definition) = 0
     OR position('selectable_yn' in v_view_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: supplier payment candidate view is not multi-invoice/corrected-reference compatible';
  END IF;

  IF to_regclass('public.order_supplier_invoice_bundle_lines_v1') IS NULL
     OR to_regclass('public.order_supplier_invoice_bundle_summary_v1') IS NULL
     OR to_regclass('public.order_tracking_allocation_completeness_vw') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: Mini-build 1 bundle or existing tracking compatibility views are missing';
  END IF;
END $$;

SELECT 'PASS: Mini-build 2 importer/supervisor integration, tracking compatibility, and atomic one-OUT multi-invoice allocation are installed' AS regression_result;

ROLLBACK;
