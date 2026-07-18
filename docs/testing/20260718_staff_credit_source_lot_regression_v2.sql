-- Staff credit source-lot provenance regression v2
-- Run after supabase/migrations/20260718_staff_credit_source_lot_provenance_v1.sql.
-- Read-only structural checks: no business data is changed.

BEGIN;

DO $$
DECLARE
  v_function_oid oid;
  v_definition text;
  v_trigger_enabled "char";
BEGIN
  v_function_oid := to_regprocedure(
    'public.staff_apply_importer_credit_to_order(uuid,uuid,numeric,uuid)'
  );

  IF v_function_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL: public.staff_apply_importer_credit_to_order(uuid,uuid,numeric,uuid) is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    WHERE p.oid = v_function_oid
      AND p.prosecdef = true
  ) THEN
    RAISE EXCEPTION 'FAIL: staff credit RPC is not SECURITY DEFINER';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.staff_apply_importer_credit_to_order(uuid,uuid,numeric,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated role does not have EXECUTE on staff credit RPC';
  END IF;

  SELECT pg_get_functiondef(v_function_oid)
    INTO v_definition;

  IF position('internal_importer_available_account_credit_lots_v1' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: staff credit RPC does not use the existing source-lot helper';
  END IF;

  IF position('ORDER BY priority, effective_at, created_at, credit_ledger_id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: deterministic source-lot ordering is missing';
  END IF;

  IF position("'importer_credit_ledger'" IN v_definition) = 0
     OR position('v_lot.credit_ledger_id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: exact source-lot provenance fields are not written';
  END IF;

  IF position('source_entity_type' IN v_definition) = 0
     OR position('source_entity_id' IN v_definition) = 0
     OR position('applied_to_order_id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: required provenance linkage fields are missing from staff credit RPC';
  END IF;

  IF position('order_funding_events' IN v_definition) > 0
     AND position('trg_sync_order_funding_event_from_importer_credit_ledger' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: staff credit RPC appears to write funding events directly';
  END IF;

  SELECT t.tgenabled
    INTO v_trigger_enabled
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'importer_credit_ledger'
    AND t.tgname = 'trg_sync_order_funding_event_from_importer_credit_ledger'
    AND NOT t.tgisinternal
  LIMIT 1;

  IF v_trigger_enabled IS NULL THEN
    RAISE EXCEPTION 'FAIL: importer-credit funding-event sync trigger is missing';
  END IF;

  IF v_trigger_enabled = 'D' THEN
    RAISE EXCEPTION 'FAIL: importer-credit funding-event sync trigger is disabled';
  END IF;
END
$$;

SELECT 'PASS: staff credit source-lot provenance structure is installed' AS regression_result;

ROLLBACK;
