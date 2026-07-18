-- Supplier payment final allocation guard regression v1
-- Run after supabase/migrations/20260718_supplier_payment_final_allocation_guard_v1.sql.
-- Read-only structural checks: no business data is changed.

BEGIN;

DO $$
DECLARE
  v_function_oid oid;
  v_definition text;
  v_security_definer boolean;
  v_execute_granted boolean;
BEGIN
  v_function_oid := to_regprocedure(
    'public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)'
  );

  IF v_function_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL: final supplier-invoice allocation RPC is missing';
  END IF;

  SELECT p.prosecdef, pg_get_functiondef(p.oid)
    INTO v_security_definer, v_definition
  FROM pg_proc p
  WHERE p.oid = v_function_oid;

  IF v_security_definer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: allocation RPC must remain SECURITY DEFINER';
  END IF;

  IF v_definition !~* 'internal_supplier_payment_readiness_v1\s*\(' THEN
    RAISE EXCEPTION 'FAIL: final allocation does not repeat the readiness gate';
  END IF;

  IF position('approved_current' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: final allocation does not enforce approved_current';
  END IF;

  IF position('source_funding_required_for_supplier_payment_bank_resolution' in v_definition) = 0
     OR position('source_funding_ambiguous_for_supplier_payment_bank_resolution' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: required fail-closed source-resolution errors are missing';
  END IF;

  IF position('default_real_dva_cash_no_released_loyalty_source' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: retired unproven DVA-cash fallback remains in executable function';
  END IF;

  IF position('proven_remaining_order_cash_funding' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: proven DVA cash source lane is missing';
  END IF;

  IF position('funding_not_required_physical_out_without_applied_credit_provenance' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: funding-not-required/no-credit lane is missing';
  END IF;

  IF v_definition !~* 'event_type\s*=\s*''funding_contribution''' THEN
    RAISE EXCEPTION 'FAIL: proven cash calculation does not use funding_contribution';
  END IF;

  IF v_definition ~* 'event_type\s+IN\s*\([^)]*manual_adjustment' THEN
    RAISE EXCEPTION 'FAIL: manual_adjustment is still being treated as proven cash';
  END IF;

  IF position('One physical supplier-payment OUT must be matched once for its full GBP amount' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: one-full-physical-OUT control is missing';
  END IF;

  IF position('Physical statement OUT' in v_definition) = 0
     OR position('already matched by active allocation' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: repeat allocation of a physical OUT is not blocked';
  END IF;

  IF position('supplier_payment_ready_yn' in v_definition) = 0
     OR position('supplier_payment_blocker' in v_definition) = 0
     OR position('source_bank_account_mapping_code' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: response compatibility/readiness/source fields are incomplete';
  END IF;

  SELECT has_function_privilege(
    'authenticated',
    'public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)',
    'EXECUTE'
  ) INTO v_execute_granted;

  IF v_execute_granted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: authenticated EXECUTE grant is missing';
  END IF;
END $$;

SELECT 'PASS: supplier payment final allocation guard is installed' AS regression_result;

ROLLBACK;
