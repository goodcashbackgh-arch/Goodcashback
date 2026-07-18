-- Supplier payment readiness regression v1
-- Run after supabase/migrations/20260718_supplier_payment_readiness_v1.sql.
-- Read-only structural checks; no business data is changed.

BEGIN;

DO $$
DECLARE
  v_function_definition text;
  v_view_definition text;
  v_function_security_definer boolean;
  v_function_stable boolean;
  v_function_execute_granted boolean;
  v_view_select_granted boolean;
  v_required_columns integer;
BEGIN
  IF to_regprocedure('public.internal_supplier_payment_readiness_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_supplier_payment_readiness_v1(uuid)';
  END IF;

  IF to_regclass('public.supplier_payment_candidate_status_vw') IS NULL THEN
    RAISE EXCEPTION 'Missing supplier_payment_candidate_status_vw';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef, p.provolatile = 's'
    INTO v_function_definition, v_function_security_definer, v_function_stable
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_supplier_payment_readiness_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_order_id uuid';

  IF v_function_security_definer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Readiness function must remain SECURITY DEFINER';
  END IF;

  IF v_function_stable IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Readiness function must remain STABLE/read-only';
  END IF;

  IF position('order_not_fully_funded' in v_function_definition) = 0
     OR position('credit_application_source_lot_links_disagree' in v_function_definition) = 0
     OR position('cash_funding_dva_reconciliation_link_invalid' in v_function_definition) = 0
     OR position('source_funding_ambiguous_for_supplier_payment_bank_resolution' in v_function_definition) = 0 THEN
    RAISE EXCEPTION 'Readiness function is missing one or more required fail-closed blockers';
  END IF;

  IF position('INSERT INTO' in upper(v_function_definition)) > 0
     OR position('UPDATE ' in upper(v_function_definition)) > 0
     OR position('DELETE FROM' in upper(v_function_definition)) > 0 THEN
    RAISE EXCEPTION 'Readiness function must remain read-only';
  END IF;

  SELECT has_function_privilege('authenticated', 'public.internal_supplier_payment_readiness_v1(uuid)', 'EXECUTE')
    INTO v_function_execute_granted;
  IF v_function_execute_granted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'authenticated EXECUTE grant missing from readiness function';
  END IF;

  SELECT pg_get_viewdef('public.supplier_payment_candidate_status_vw'::regclass, true)
    INTO v_view_definition;

  IF position('approved_current' in v_view_definition) = 0
     OR position('remaining_unmatched_gbp' in v_view_definition) = 0
     OR position('supplier_payment_ready_yn' in v_view_definition) = 0 THEN
    RAISE EXCEPTION 'Candidate view is missing governed readiness or balance logic';
  END IF;

  SELECT has_table_privilege('authenticated', 'public.supplier_payment_candidate_status_vw', 'SELECT')
    INTO v_view_select_granted;
  IF v_view_select_granted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'authenticated SELECT grant missing from candidate view';
  END IF;

  SELECT COUNT(*)
    INTO v_required_columns
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'supplier_payment_candidate_status_vw'
    AND c.column_name IN (
      'supplier_invoice_id',
      'order_id',
      'invoice_total_gbp',
      'confirmed_matched_gbp',
      'remaining_unmatched_gbp',
      'funding_provenance_ready_yn',
      'supplier_payment_ready_yn',
      'blocker',
      'selectable_yn'
    );

  IF v_required_columns <> 9 THEN
    RAISE EXCEPTION 'Candidate view required column count mismatch: %', v_required_columns;
  END IF;
END $$;

ROLLBACK;
