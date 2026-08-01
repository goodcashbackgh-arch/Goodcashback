-- Rollback-only catalog regression for terminal physical review/remedy immutability.
-- Run after 20260801131700_hybrid_physical_receipt_legacy_fail_closed_v1.sql.

BEGIN;

DO $regression$
DECLARE
  v_review_definition text;
  v_remedy_definition text;
BEGIN
  IF to_regprocedure(
       'public.physical_receipt_review_terminal_immutability_guard_v1()'
     ) IS NULL
     OR to_regprocedure(
       'public.physical_remedy_terminal_immutability_guard_v1()'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: terminal physical provenance guard is missing';
  END IF;

  IF to_regclass('public.uq_physical_remedy_dispute_line_v1') IS NULL THEN
    RAISE EXCEPTION
      'FAIL: one-to-one physical remedy dispute-line provenance index is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_index index_row
    WHERE index_row.indexrelid =
          'public.uq_physical_remedy_dispute_line_v1'::regclass
      AND index_row.indisunique = true
      AND index_row.indisvalid = true
  ) THEN
    RAISE EXCEPTION
      'FAIL: physical remedy dispute-line provenance index is not unique and valid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.physical_receipt_reviews'::regclass
      AND trigger_row.tgname =
          'trg_physical_receipt_review_00a_terminal_immutability_v1'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled <> 'D'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
          'public.physical_exception_remedy_allocations'::regclass
      AND trigger_row.tgname =
          'trg_physical_remedy_00a_terminal_immutability_v1'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION
      'FAIL: terminal physical provenance trigger is missing or disabled';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.physical_receipt_review_terminal_immutability_guard_v1()',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.physical_remedy_terminal_immutability_guard_v1()',
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION
      'FAIL: terminal physical provenance guard is executable by authenticated';
  END IF;

  SELECT pg_get_functiondef(
    'public.physical_receipt_review_terminal_immutability_guard_v1()'::regprocedure
  )
  INTO v_review_definition;

  IF position('approved_to_existing_exception' IN v_review_definition) = 0
     OR position('closed_no_action' IN v_review_definition) = 0
     OR position('superseded' IN v_review_definition) = 0
     OR position('to_jsonb(NEW)' IN v_review_definition) = 0
  THEN
    RAISE EXCEPTION
      'FAIL: terminal physical review identity/decision fields are not frozen';
  END IF;

  SELECT pg_get_functiondef(
    'public.physical_remedy_terminal_immutability_guard_v1()'::regprocedure
  )
  INTO v_remedy_definition;

  IF position('Importer remedy proposal cannot invent supplier claim' IN v_remedy_definition) = 0
     OR position('Terminal physical remedy provenance is immutable' IN v_remedy_definition) = 0
     OR position('dispute-line provenance is immutable once linked' IN v_remedy_definition) = 0
     OR position('replacement-child provenance is immutable once linked' IN v_remedy_definition) = 0
     OR position('replacement-child tracking provenance is immutable once linked' IN v_remedy_definition) = 0
     OR position('Final replacement supplier cost mode is immutable' IN v_remedy_definition) = 0
     OR position('supplier cost evidence remains pending' IN v_remedy_definition) = 0
  THEN
    RAISE EXCEPTION
      'FAIL: terminal remedy financial/source provenance is not fully frozen';
  END IF;

  RAISE NOTICE
    'PASS: one-to-one dispute linkage and terminal physical review/remedy identity, financial and replacement provenance guards are installed and private.';
END
$regression$;

ROLLBACK;