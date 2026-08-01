-- Rollback-only regression for Build 2 receipt authority:
--   20260801139900_hybrid_physical_receipt_v2_terminal_correction_guard_v1.sql
--   20260801140000_hybrid_physical_receipt_v2_rpc_v1.sql
--
-- Run after the merged foundation and both ordered Build 2 migrations.
-- This script performs catalog, privilege and source-contract assertions and
-- leaves no data or schema change behind.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $catalog$
DECLARE
  v_receipt_v1_fingerprint text;
  v_rpc_definition text;
  v_guard_definition text;
  v_supersession_update text;
  v_rpc_oid oid;
  v_guard_oid oid;
  v_guard_trigger_oid oid;
  v_integrity_trigger_oid oid;
BEGIN
  IF to_regprocedure(
       'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: shipper_record_package_receipt_v2 is missing';
  END IF;

  IF to_regprocedure(
       'public.shipper_package_receipt_v2_terminal_correction_guard_v1()'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: terminal correction guard is missing';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_record_package_receipt_v1(uuid,text,text,text)'::regprocedure
  ))
  INTO v_receipt_v1_fingerprint;

  IF v_receipt_v1_fingerprint <> '27fb972b34258990cfa9d752cd2f927b' THEN
    RAISE EXCEPTION
      'FAIL: legacy receipt function fingerprint changed: %',
      v_receipt_v1_fingerprint;
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.shipper_record_package_receipt_v1(uuid,text,text,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: authenticated lost legacy v1 receipt execute';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: authenticated cannot execute v2 receipt RPC';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute v2 receipt RPC';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.shipper_package_receipt_v2_terminal_correction_guard_v1()',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute internal correction trigger function';
  END IF;

  SELECT procedure_row.oid,
         pg_get_functiondef(procedure_row.oid)
  INTO v_rpc_oid, v_rpc_definition
  FROM pg_proc procedure_row
  JOIN pg_namespace namespace_row
    ON namespace_row.oid = procedure_row.pronamespace
  WHERE namespace_row.nspname = 'public'
    AND procedure_row.oid =
      'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)'::regprocedure;

  SELECT procedure_row.oid,
         pg_get_functiondef(procedure_row.oid)
  INTO v_guard_oid, v_guard_definition
  FROM pg_proc procedure_row
  JOIN pg_namespace namespace_row
    ON namespace_row.oid = procedure_row.pronamespace
  WHERE namespace_row.nspname = 'public'
    AND procedure_row.oid =
      'public.shipper_package_receipt_v2_terminal_correction_guard_v1()'::regprocedure;

  IF v_rpc_definition NOT ILIKE '%SECURITY DEFINER%'
     OR REPLACE(v_rpc_definition, '''', '') NOT ILIKE
        '%SET search_path TO public, pg_temp%'
  THEN
    RAISE EXCEPTION 'FAIL: v2 receipt RPC security boundary is wrong';
  END IF;

  IF v_rpc_definition NOT LIKE '%pg_advisory_xact_lock(hashtext(p_tracking_submission_id::text))%'
     OR v_rpc_definition NOT LIKE '%FOR UPDATE OF ots%'
     OR v_rpc_definition NOT LIKE '%FOR UPDATE;%'
  THEN
    RAISE EXCEPTION 'FAIL: package/allocation serialization controls are missing';
  END IF;

  IF POSITION('PERFORM 1' IN v_rpc_definition) = 0
     OR POSITION('select count(*)::integer' IN LOWER(v_rpc_definition)) = 0
     OR POSITION('PERFORM 1' IN v_rpc_definition) >
        POSITION('select count(*)::integer' IN LOWER(v_rpc_definition))
  THEN
    RAISE EXCEPTION 'FAIL: allocation count is not derived after the locking read';
  END IF;

  IF v_rpc_definition NOT LIKE
       '%shipper-receipts/%|| v_shipper_id::text ||%p_tracking_submission_id::text%'
     OR v_rpc_definition NOT LIKE
       '%storage_object_path NOT LIKE v_evidence_prefix ||%'
     OR v_rpc_definition NOT LIKE
       '%POSITION(''..'' IN x.storage_object_path) > 0%'
  THEN
    RAISE EXCEPTION 'FAIL: private evidence path ownership/traversal controls are missing';
  END IF;

  IF v_rpc_definition NOT LIKE
       '%v_existing.receipt_model_version IS DISTINCT FROM 2%'
     OR v_rpc_definition NOT LIKE
       '%v_existing.receipt_state IS DISTINCT FROM ''finalised''%'
     OR v_rpc_definition NOT LIKE
       '%v_existing.finalised_at IS NULL%'
  THEN
    RAISE EXCEPTION 'FAIL: idempotent retry does not require a finalised v2 receipt';
  END IF;

  IF v_rpc_definition NOT LIKE
       '%Receipt submission identity was already used for another context or payload.%'
     OR v_rpc_definition NOT LIKE
       '%Every exact package allocation must balance to allocated quantity.%'
     OR v_rpc_definition NOT LIKE
       '%Affected quantity requires one or more evidence references.%'
  THEN
    RAISE EXCEPTION 'FAIL: required fail-closed receipt errors are missing';
  END IF;

  IF v_rpc_definition NOT LIKE
       '%v_prior_created_at + INTERVAL ''1 microsecond''%'
     OR v_rpc_definition NOT LIKE
       '%GREATEST(%clock_timestamp()%'
  THEN
    RAISE EXCEPTION 'FAIL: correction event ordering protection is missing';
  END IF;

  v_supersession_update := split_part(
    split_part(
      v_rpc_definition,
      'UPDATE public.physical_receipt_reviews pr',
      2
    ),
    'IF v_affected_qty > 0',
    1
  );

  IF NULLIF(BTRIM(v_supersession_update), '') IS NULL THEN
    RAISE EXCEPTION 'FAIL: RPC supersession update block could not be isolated';
  END IF;

  IF v_supersession_update LIKE '%''rejected''%'
     OR v_supersession_update LIKE '%''closed_no_action''%'
     OR v_supersession_update LIKE '%''approved_to_existing_exception''%'
     OR v_supersession_update LIKE '%''superseded''%'
  THEN
    RAISE EXCEPTION 'FAIL: terminal review states remain in RPC supersession update';
  END IF;

  IF v_supersession_update NOT LIKE '%''awaiting_importer_proposal''%'
     OR v_supersession_update NOT LIKE '%''awaiting_supervisor_review''%'
     OR v_supersession_update NOT LIKE '%''returned_for_information''%'
     OR v_supersession_update NOT LIKE '%''approved_for_investigation''%'
  THEN
    RAISE EXCEPTION 'FAIL: open-review correction supersession states are incomplete';
  END IF;

  IF v_guard_definition NOT LIKE '%approved_to_existing_exception%'
     OR v_guard_definition NOT LIKE '%rejected%'
     OR v_guard_definition NOT LIKE '%closed_no_action%'
     OR v_guard_definition NOT LIKE '%superseded%'
     OR v_guard_definition NOT LIKE '%Use controlled staff remediation.%'
  THEN
    RAISE EXCEPTION 'FAIL: terminal correction stop boundary is incomplete';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.shipper_package_receipts'::regclass
      AND trigger_row.tgname =
          'trg_shipper_package_receipt_v2_terminal_correction_guard_v1'
      AND trigger_row.tgenabled <> 'D'
      AND trigger_row.tgfoid = v_guard_oid
  ) THEN
    RAISE EXCEPTION 'FAIL: terminal correction trigger is absent or disabled';
  END IF;

  SELECT trigger_row.oid
  INTO v_guard_trigger_oid
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid = 'public.shipper_package_receipts'::regclass
    AND trigger_row.tgname =
        'trg_shipper_package_receipt_v2_terminal_correction_guard_v1';

  SELECT trigger_row.oid
  INTO v_integrity_trigger_oid
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid = 'public.shipper_package_receipts'::regclass
    AND trigger_row.tgname = 'trg_shipper_package_receipt_v2_integrity_guard_v1';

  IF v_guard_trigger_oid IS NULL OR v_integrity_trigger_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL: required receipt triggers are missing';
  END IF;

  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL
     OR to_regclass('public.shipper_package_receipt_evidence') IS NULL
     OR to_regclass('public.physical_receipt_reviews') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: foundation receipt/review tables are missing';
  END IF;

  RAISE NOTICE 'PASS: Build 2 receipt RPC catalog, privilege and source-contract checks passed.';
END
$catalog$;

DO $transaction_shape$
DECLARE
  v_pending_guard_count integer;
  v_direct_write_count integer;
BEGIN
  SELECT COUNT(*)::integer
  INTO v_pending_guard_count
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid = 'public.shipper_package_receipts'::regclass
    AND trigger_row.tgname =
        'trg_shipper_package_receipt_v2_pending_commit_guard_v1'
    AND trigger_row.tgdeferrable = true
    AND trigger_row.tginitdeferred = true
    AND trigger_row.tgenabled <> 'D';

  IF v_pending_guard_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: pending v2 commit guard is not active and deferred';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_direct_write_count
  FROM (
    SELECT has_table_privilege(
      'authenticated',
      'public.shipper_package_receipt_line_dispositions',
      privilege_name
    ) AS allowed
    FROM unnest(ARRAY['INSERT','UPDATE','DELETE']) privilege_name
    UNION ALL
    SELECT has_table_privilege(
      'authenticated',
      'public.shipper_package_receipt_evidence',
      privilege_name
    ) AS allowed
    FROM unnest(ARRAY['INSERT','UPDATE','DELETE']) privilege_name
    UNION ALL
    SELECT has_table_privilege(
      'authenticated',
      'public.physical_receipt_reviews',
      privilege_name
    ) AS allowed
    FROM unnest(ARRAY['INSERT','UPDATE','DELETE']) privilege_name
  ) privilege_row
  WHERE privilege_row.allowed;

  IF v_direct_write_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: authenticated direct-write boundary was weakened';
  END IF;

  RAISE NOTICE 'PASS: atomic pending guard and direct-write boundaries passed.';
END
$transaction_shape$;

ROLLBACK;