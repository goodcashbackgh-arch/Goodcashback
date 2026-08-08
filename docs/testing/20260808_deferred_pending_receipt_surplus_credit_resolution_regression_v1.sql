BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_order_id uuid := 'd2acf50b-5b8e-476d-b5ad-2578289f4cce'::uuid;
  v_pending_id uuid := '0a97a5ef-c691-4a09-b41b-f1de8d8bb5da'::uuid;
  v_supplier_fx_id uuid := 'e51c5ea9-f15e-4df5-8d43-32afd1d3e929'::uuid;
  v_auth_uid uuid;
  v_before_evidence record;
  v_before_settlement record;
  v_after_pending record;
  v_after_settlement record;
  v_after_fx record;
  v_result jsonb;
  v_repeat jsonb;
  v_credit_id uuid;
  v_provenance_id uuid;
  v_count integer;
  v_credit_amount numeric;
  v_fx_amount numeric;
  v_fx_allocated numeric;
  v_fx_status text;
  v_fx_line_id uuid;
  v_before_fx_amount numeric;
  v_before_fx_allocated numeric;
  v_before_fx_status text;
  v_before_fx_line_id uuid;
  v_definition text;
BEGIN
  IF to_regprocedure('public.staff_confirm_pending_receipt_surplus_credit_v1(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: new pending receipt surplus credit wrapper is missing.';
  END IF;

  IF to_regclass('public.order_pending_surplus_credit_resolution_provenance_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: new pending-credit provenance table is missing.';
  END IF;

  -- No legacy/backfilled provenance is permitted before this transactional test.
  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.order_pending_surplus_credit_resolution_provenance_v1;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: provenance table contains % pre-existing rows; migration must not backfill legacy credits.', v_count;
  END IF;

  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin','supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.created_at
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active admin/supervisor auth user is available for regression.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);

  -- -------------------------------------------------------------------------
  -- 1. Corrected evidence is exactly the locked calculation.
  -- -------------------------------------------------------------------------
  SELECT *
  INTO v_before_evidence
  FROM public.order_surplus_evidence_position_v3 e
  WHERE e.order_id = v_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: controlled order evidence position is missing.';
  END IF;

  IF round(v_before_evidence.funding_total_gbp, 2) <> 600.00
     OR round(v_before_evidence.pending_surplus_gbp, 2) <> 0.79
     OR round(v_before_evidence.effective_receipt_gbp, 2) <> 620.79
     OR round(v_before_evidence.evidence_value_gbp, 2) <> 620.00
     OR round(v_before_evidence.evidence_surplus_gbp, 2) <> 0.79
     OR v_before_evidence.evidence_status <> 'ready_posted_invoice_surplus'
  THEN
    RAISE EXCEPTION
      'FAIL: corrected pending evidence mismatch. funding %, pending %, effective %, evidence %, surplus %, status %',
      v_before_evidence.funding_total_gbp,
      v_before_evidence.pending_surplus_gbp,
      v_before_evidence.effective_receipt_gbp,
      v_before_evidence.evidence_value_gbp,
      v_before_evidence.evidence_surplus_gbp,
      v_before_evidence.evidence_status;
  END IF;

  IF (
    SELECT round(COALESCE(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    FROM public.dva_statement_line_allocations a
    WHERE a.order_id = v_order_id
      AND a.allocation_type = 'final_balance_payment'
      AND a.allocation_status = 'confirmed'
  ) <> 20.00 THEN
    RAISE EXCEPTION 'FAIL: controlled confirmed final-balance payment is not exactly GBP 20.00.';
  END IF;

  -- Non-pending v3 behaviour must still pass through v2 values.
  IF EXISTS (
    SELECT 1
    FROM public.order_surplus_evidence_position_v3 v3
    JOIN public.order_surplus_evidence_position_v2 v2 ON v2.order_id = v3.order_id
    WHERE v3.pending_position_count = 0
      AND (
        round(v3.evidence_surplus_gbp, 2) IS DISTINCT FROM round(v2.evidence_surplus_gbp, 2)
        OR v3.evidence_status IS DISTINCT FROM v2.evidence_status
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: non-pending v3 evidence behaviour changed from v2.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Capture immutable supplier FX and canonical settlement before action.
  -- -------------------------------------------------------------------------
  SELECT
    round(abs(COALESCE(NULLIF(a.fx_or_card_diff_gbp, 0), a.allocated_gbp_amount, 0))::numeric, 2),
    round(a.allocated_gbp_amount::numeric, 2),
    a.allocation_status,
    a.dva_statement_line_id
  INTO
    v_before_fx_amount,
    v_before_fx_allocated,
    v_before_fx_status,
    v_before_fx_line_id
  FROM public.dva_statement_line_allocations a
  WHERE a.id = v_supplier_fx_id
    AND a.allocation_type = 'fx_card_difference';

  IF NOT FOUND
     OR v_before_fx_amount <> 0.79
     OR v_before_fx_status <> 'confirmed' THEN
    RAISE EXCEPTION 'FAIL: controlled supplier FX fingerprint is missing or changed.';
  END IF;

  SELECT *
  INTO v_before_settlement
  FROM public.order_settlement_resolution_position_v1 s
  WHERE s.order_id = v_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: controlled settlement position is missing.';
  END IF;

  IF round(v_before_settlement.gross_positive_difference_gbp, 2) <> 0.79
     OR round(v_before_settlement.confirmed_customer_credit_gbp, 2) <> 0.00
     OR round(v_before_settlement.settlement_fx_card_difference_gbp, 2) <> 0.79
     OR round(v_before_settlement.total_classified_gbp, 2) <> 0.79
     OR round(v_before_settlement.remaining_unresolved_gbp, 2) <> 0.00
  THEN
    RAISE EXCEPTION 'FAIL: pre-confirmation settlement fingerprint is not the controlled 79p state: %', to_jsonb(v_before_settlement);
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. New wrapper delegates to the established credit RPC and writes provenance.
  -- -------------------------------------------------------------------------
  v_result := public.staff_confirm_pending_receipt_surplus_credit_v1(
    v_order_id,
    'Regression pending surplus confirmation',
    'Rollback-only governed regression.'
  );

  v_credit_id := NULLIF(v_result->>'credit_ledger_id', '')::uuid;
  v_provenance_id := NULLIF(v_result->>'provenance_id', '')::uuid;

  IF v_credit_id IS NULL OR v_provenance_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: wrapper did not return credit/provenance ids: %', v_result;
  END IF;

  SELECT p.*
  INTO v_after_pending
  FROM public.order_pending_funding_surplus p
  WHERE p.id = v_pending_id;

  IF NOT FOUND
     OR v_after_pending.status <> 'credit_confirmed'
     OR v_after_pending.confirmed_credit_ledger_id IS DISTINCT FROM v_credit_id
  THEN
    RAISE EXCEPTION 'FAIL: pending row did not transition through established confirmation logic.';
  END IF;

  SELECT round(abs(c.amount_gbp)::numeric, 2)
  INTO v_credit_amount
  FROM public.importer_credit_ledger c
  WHERE c.id = v_credit_id
    AND c.direction = 'credit'
    AND c.source_entity_type = 'order'
    AND c.source_entity_id = v_order_id;

  IF v_credit_amount <> 0.79 THEN
    RAISE EXCEPTION 'FAIL: established credit RPC created %, expected GBP 0.79.', v_credit_amount;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.order_pending_surplus_credit_resolution_provenance_v1 pr
  WHERE pr.id = v_provenance_id
    AND pr.order_id = v_order_id
    AND pr.pending_surplus_id = v_pending_id
    AND pr.confirmed_credit_ledger_id = v_credit_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: exact pending-to-credit provenance row was not created.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Only supplier-FX settlement participation is displaced by provenance.
  --    Downstream settlement arithmetic must resolve to GBP 0.79 exactly once.
  -- -------------------------------------------------------------------------
  SELECT *
  INTO v_after_settlement
  FROM public.order_settlement_resolution_position_v1 s
  WHERE s.order_id = v_order_id;

  IF round(v_after_settlement.gross_positive_difference_gbp, 2) <> 0.79
     OR round(v_after_settlement.confirmed_customer_credit_gbp, 2) <> 0.79
     OR round(v_after_settlement.settlement_fx_card_difference_gbp, 2) <> 0.00
     OR round(v_after_settlement.total_classified_gbp, 2) <> 0.79
     OR round(v_after_settlement.remaining_unresolved_gbp, 2) <> 0.00
     OR round(v_after_settlement.over_resolved_gbp, 2) <> 0.00
     OR v_after_settlement.resolution_status <> 'fully_resolved'
  THEN
    RAISE EXCEPTION 'FAIL: post-confirmation settlement result is not the locked 79p result: %', to_jsonb(v_after_settlement);
  END IF;

  -- Physical supplier FX row is byte/value-identical in the protected fields.
  SELECT
    round(abs(COALESCE(NULLIF(a.fx_or_card_diff_gbp, 0), a.allocated_gbp_amount, 0))::numeric, 2),
    round(a.allocated_gbp_amount::numeric, 2),
    a.allocation_status,
    a.dva_statement_line_id
  INTO
    v_fx_amount,
    v_fx_allocated,
    v_fx_status,
    v_fx_line_id
  FROM public.dva_statement_line_allocations a
  WHERE a.id = v_supplier_fx_id
    AND a.allocation_type = 'fx_card_difference';

  IF v_fx_amount IS DISTINCT FROM v_before_fx_amount
     OR v_fx_allocated IS DISTINCT FROM v_before_fx_allocated
     OR v_fx_status IS DISTINCT FROM v_before_fx_status
     OR v_fx_line_id IS DISTINCT FROM v_before_fx_line_id
  THEN
    RAISE EXCEPTION 'FAIL: physical supplier FX evidence was mutated.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 5. Wrapper is idempotent and does not create a second credit/provenance row.
  -- -------------------------------------------------------------------------
  v_repeat := public.staff_confirm_pending_receipt_surplus_credit_v1(
    v_order_id,
    'Regression pending surplus confirmation',
    'Rollback-only governed regression repeat.'
  );

  IF COALESCE((v_repeat->>'already_confirmed')::boolean, false) IS DISTINCT FROM true
     OR NULLIF(v_repeat->>'credit_ledger_id', '')::uuid IS DISTINCT FROM v_credit_id
     OR NULLIF(v_repeat->>'provenance_id', '')::uuid IS DISTINCT FROM v_provenance_id
  THEN
    RAISE EXCEPTION 'FAIL: wrapper idempotent response mismatch: %', v_repeat;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.order_pending_surplus_credit_resolution_provenance_v1 pr
  WHERE pr.order_id = v_order_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: repeat wrapper call created duplicate provenance.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.importer_credit_ledger c
  WHERE c.importer_id = v_after_pending.importer_id
    AND c.source_entity_type = 'order'
    AND c.source_entity_id = v_order_id
    AND c.direction = 'credit'
    AND c.source_type IN ('overfunding','settlement_credit');

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: repeat wrapper call created duplicate order credit; count %.', v_count;
  END IF;

  -- -------------------------------------------------------------------------
  -- 6. Source-scope guards: existing accounting RPC and downstream formulas are
  --    still present; the new path is provenance-gated rather than legacy-wide.
  -- -------------------------------------------------------------------------
  SELECT lower(pg_get_viewdef('public.order_settlement_resolution_position_v1'::regclass, true))
  INTO v_definition;

  IF position('order_pending_surplus_credit_resolution_provenance_v1' IN v_definition) = 0
     OR position('supplier_needed_before_pending_credit_gbp' IN v_definition) = 0
     OR position('supplier_needed_after_pending_credit_gbp' IN v_definition) = 0
     OR position('gross_positive_difference_gbp' IN v_definition) = 0
     OR position('total_classified_gbp' IN v_definition) = 0
     OR position('remaining_unresolved_gbp' IN v_definition) = 0
     OR position('over_resolved_gbp' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: governed provenance-gated settlement input or locked output formulas are missing.';
  END IF;

  RAISE NOTICE 'PASS: deferred pending receipt surplus credit resolves exactly GBP 0.79, provenance is future-only/idempotent, supplier FX evidence is unchanged, and settlement counts the difference exactly once.';
END;
$regression$;

ROLLBACK;
