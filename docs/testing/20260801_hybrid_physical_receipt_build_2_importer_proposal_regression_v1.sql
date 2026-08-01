BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $catalog$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: importer proposal RPC is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_receipt_reviews'
      AND column_name = 'importer_proposal_note'
  ) THEN
    RAISE EXCEPTION 'FAIL: importer proposal note column is missing';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: authenticated cannot execute importer proposal RPC';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute importer proposal RPC';
  END IF;

  SELECT pg_get_functiondef(
    'public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)'::regprocedure
  )
  INTO v_definition;

  IF v_definition NOT ILIKE '%SECURITY DEFINER%'
     OR REPLACE(v_definition, '''', '') NOT ILIKE
        '%SET search_path TO public, pg_temp%'
  THEN
    RAISE EXCEPTION 'FAIL: importer proposal RPC security boundary is wrong';
  END IF;

  IF v_definition NOT LIKE '%auth.uid()%'
     OR v_definition NOT LIKE '%operator_importers%'
     OR v_definition NOT LIKE '%revoked_at IS NULL%'
  THEN
    RAISE EXCEPTION 'FAIL: importer tenant access controls are missing';
  END IF;

  IF v_definition NOT LIKE '%pg_advisory_xact_lock%'
     OR v_definition NOT LIKE '%FOR UPDATE;%'
     OR v_definition NOT LIKE '%physical_exception_remedy_allocations%FOR UPDATE;%'
  THEN
    RAISE EXCEPTION 'FAIL: importer proposal serialization controls are missing';
  END IF;

  IF v_definition NOT LIKE '%awaiting_importer_proposal%'
     OR v_definition NOT LIKE '%returned_for_information%'
     OR v_definition NOT LIKE '%awaiting_supervisor_review%'
  THEN
    RAISE EXCEPTION 'FAIL: importer-owned state boundary is incomplete';
  END IF;

  IF v_definition NOT LIKE '%key_name NOT IN (%'
     OR v_definition NOT LIKE '%receipt_line_disposition_id%'
     OR v_definition NOT LIKE '%proposed_remedy_type%'
     OR v_definition NOT LIKE '%proposed_remedy_qty%'
  THEN
    RAISE EXCEPTION 'FAIL: strict importer payload-key boundary is missing';
  END IF;

  IF v_definition LIKE '%approved_remedy_type%'
     OR v_definition LIKE '%approved_remedy_qty%'
     OR v_definition LIKE '%approved_by_staff_id%'
     OR v_definition LIKE '%linked_dispute_id%'
     OR v_definition LIKE '%supplier_claim_amount_gbp%'
     OR v_definition LIKE '%customer_commercial_value_gbp%'
     OR v_definition LIKE '%supplier_cost_mode%'
     OR v_definition LIKE '%replacement_child_order_id%'
  THEN
    RAISE EXCEPTION 'FAIL: importer proposal RPC can write prohibited supervisor/dispute/commercial/child facts';
  END IF;

  IF v_definition NOT LIKE '%SET status = ''cancelled''%'
     OR v_definition LIKE '%DELETE FROM public.physical_exception_remedy_allocations%'
     OR v_definition LIKE '%SET status = ''superseded''%'
  THEN
    RAISE EXCEPTION 'FAIL: prior proposal provenance transition is wrong';
  END IF;

  IF v_definition NOT LIKE '%SUM(proposal_row.proposed_remedy_qty)%'
     OR v_definition NOT LIKE '%> disposition.quantity + 0.0005%'
  THEN
    RAISE EXCEPTION 'FAIL: per-disposition quantity ceiling is missing';
  END IF;

  IF v_definition NOT LIKE '%NULLIF(BTRIM(COALESCE(p_proposal_note, '''')), '''') IS NULL%'
     OR v_definition NOT LIKE '%importer_proposal_note = BTRIM(p_proposal_note)%'
  THEN
    RAISE EXCEPTION 'FAIL: importer factual note requirement/storage is missing';
  END IF;

  IF v_definition NOT LIKE '%status = ''awaiting_supervisor_review''%'
     OR v_definition NOT LIKE '%importer_proposed_by_operator_id = v_operator_id%'
     OR v_definition NOT LIKE '%importer_proposed_at = v_event_at%'
  THEN
    RAISE EXCEPTION 'FAIL: atomic review transition facts are incomplete';
  END IF;

  RAISE NOTICE 'PASS: importer proposal RPC catalog and source-contract checks passed.';
END
$catalog$;

ROLLBACK;
