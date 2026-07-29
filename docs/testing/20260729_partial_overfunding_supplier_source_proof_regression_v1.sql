-- Supabase SQL Editor regression.
-- READ/ROLLBACK ONLY. No authenticated allocator RPC is executed.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_target_order_id uuid;
  v_source_order_id uuid;
  v_credit_id uuid;
  v_pending_id uuid;
  v_pending_before numeric(12,2);
  v_credit_before numeric(12,2);
  v_target_funding numeric(12,2);
  v_source_position_before jsonb;
  v_source_position_after jsonb;
  v_result record;
  v_repeat record;
  v_blocked boolean;
  v_resolver_definition text;
  v_bundle_core_definition text;
  v_incremental_definition text;
  v_settlement_definition text;
  v_rows_before bigint;
  v_rows_after bigint;
BEGIN
  SELECT o.id
  INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: target partial-overfunding proof order is missing.';
  END IF;

  SELECT
    credit.id,
    credit.source_entity_id,
    ops.id,
    ROUND(COALESCE(ops.pending_surplus_gbp, 0)::numeric, 2),
    ROUND(ABS(COALESCE(credit.amount_gbp, 0))::numeric, 2)
  INTO
    v_credit_id,
    v_source_order_id,
    v_pending_id,
    v_pending_before,
    v_credit_before
  FROM public.order_funding_events ofe
  JOIN public.importer_credit_ledger debit
    ON debit.id = ofe.source_entity_id
  JOIN public.importer_credit_ledger credit
    ON credit.id = CASE
      WHEN debit.source_table = 'importer_credit_ledger' THEN debit.source_id
      WHEN debit.source_entity_type = 'importer_credit_ledger' THEN debit.source_entity_id
      ELSE NULL::uuid
    END
  JOIN public.order_pending_funding_surplus ops
    ON ops.confirmed_credit_ledger_id = credit.id
  WHERE ofe.order_id = v_target_order_id
    AND ofe.event_type = 'credit_applied'
    AND credit.source_type = 'overfunding'
  LIMIT 1;

  IF v_credit_id IS NULL OR v_source_order_id IS NULL OR v_pending_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: exact applied overfunding provenance chain is missing.';
  END IF;

  IF v_pending_before <= v_credit_before + 0.01 THEN
    RAISE EXCEPTION 'REGRESSION: target is not a partial-overfunding case.';
  END IF;

  SELECT ROUND(COALESCE(SUM(
    CASE
      WHEN ofe.event_type IN ('funding_contribution','credit_applied','manual_adjustment')
        THEN ofe.amount_gbp
      WHEN ofe.event_type = 'funding_reversed'
        THEN -ABS(ofe.amount_gbp)
      ELSE 0
    END
  ),0)::numeric,2)
  INTO v_target_funding
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = v_target_order_id;

  IF v_target_funding <= 0 THEN
    RAISE EXCEPTION 'REGRESSION: target funding total is not positive.';
  END IF;

  SELECT to_jsonb(p)
  INTO v_source_position_before
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_source_order_id;

  IF v_source_position_before IS NULL
     OR v_source_position_before->>'resolution_status' IS DISTINCT FROM 'fully_resolved'
     OR COALESCE((v_source_position_before->>'remaining_unresolved_gbp')::numeric, 999999999) > 0.01
     OR COALESCE((v_source_position_before->>'over_resolved_gbp')::numeric, 999999999) > 0.01
     OR COALESCE((v_source_position_before->>'pending_evidence_count')::integer, -1) <> 0
     OR COALESCE((v_source_position_before->>'pending_credit_confirmed_count')::integer, 0) <= 0
     OR ABS(
          COALESCE((v_source_position_before->>'confirmed_customer_credit_gbp')::numeric, -999999999)
          - v_credit_before
        ) > 0.01
  THEN
    RAISE EXCEPTION 'REGRESSION: source order is not canonically fully resolved for the exact partial credit.';
  END IF;

  SELECT COUNT(*) INTO v_rows_before
  FROM public.dva_statement_line_allocations;

  SELECT pg_get_functiondef(
    'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure
  ) INTO v_resolver_definition;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_bundle_core_v(uuid,jsonb,text)'::regprocedure
  ) INTO v_bundle_core_definition;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_incremental_definition;

  SELECT definition
  INTO v_settlement_definition
  FROM pg_views
  WHERE schemaname = 'public'
    AND viewname = 'order_settlement_resolution_position_v1';

  IF strpos(v_resolver_definition, 'ABS(r.pending_surplus_gbp - r.credit_amount_gbp) <= 0.01') = 0
     OR strpos(v_resolver_definition, 'settlement_resolution_status = ''fully_resolved''') = 0
     OR strpos(v_resolver_definition, 'settlement_remaining_unresolved_gbp') = 0
     OR strpos(v_resolver_definition, 'settlement_confirmed_customer_credit_gbp') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: scoped partial-overfunding proof is missing.';
  END IF;

  IF strpos(v_resolver_definition, 'completion_loyalty_reward') = 0
     OR strpos(v_resolver_definition, 'exact_remaining_released_loyalty_source') = 0
     OR strpos(v_resolver_definition, 'source_funding_ambiguous_for_supplier_payment_bank_resolution') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: existing loyalty/ambiguity source logic changed or disappeared.';
  END IF;

  IF strpos(v_bundle_core_definition, 'internal_supplier_payment_bundle_source_v1') = 0
     OR strpos(v_incremental_definition, 'internal_supplier_payment_bundle_source_v1') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: active supplier allocation routes no longer delegate to the shared resolver.';
  END IF;

  IF v_settlement_definition IS NULL
     OR strpos(v_settlement_definition, 'pending_receipt_residual_gbp') = 0
     OR strpos(v_settlement_definition, 'remaining_unresolved_gbp') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: canonical settlement view contract changed.';
  END IF;

  -- 1. Real partial case must now resolve as DVA cash.
  SELECT * INTO v_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_target_order_id,
    v_target_funding
  );

  SELECT * INTO v_repeat
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_target_order_id,
    v_target_funding
  );

  IF v_result.source_bank_account_mapping_code IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_result.source_wallet_code IS NOT NULL
     OR v_result.source_resolution_reason IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR v_result.remaining_order_cash_funding_gbp + 0.01 < v_target_funding
  THEN
    RAISE EXCEPTION 'REGRESSION: valid partial overfunding did not resolve to sufficient DVA cash.';
  END IF;

  IF to_jsonb(v_result) IS DISTINCT FROM to_jsonb(v_repeat) THEN
    RAISE EXCEPTION 'REGRESSION: resolver is not deterministic.';
  END IF;

  -- 2. Ordinary full-overfunding equality route remains valid.
  -- Temporarily make the linked pending residual equal the exact linked credit;
  -- subtransaction rollback restores the real row immediately.
  BEGIN
    UPDATE public.order_pending_funding_surplus
    SET pending_surplus_gbp = v_credit_before
    WHERE id = v_pending_id;

    SELECT * INTO v_result
    FROM public.internal_supplier_payment_bundle_source_v1(
      v_target_order_id,
      v_target_funding
    );

    IF v_result.source_bank_account_mapping_code IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
       OR v_result.source_resolution_reason IS DISTINCT FROM 'proven_remaining_order_cash_funding'
    THEN
      RAISE EXCEPTION 'REGRESSION: ordinary full-overfunding equality path no longer resolves.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback full-overfunding fixture';
  EXCEPTION
    WHEN SQLSTATE 'ZX001' THEN NULL;
  END;

  -- 3. Partial but canonically unresolved/over-resolved must fail closed.
  -- Reduce the original receipt residual by £1 while leaving the linked credit
  -- untouched. This makes the canonical source settlement over-resolved.
  BEGIN
    UPDATE public.order_pending_funding_surplus
    SET pending_surplus_gbp = v_pending_before - 1.00
    WHERE id = v_pending_id;

    v_blocked := false;
    BEGIN
      PERFORM *
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_target_order_id,
        v_target_funding
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'source_funding_required_for_supplier_payment_bank_resolution:%'
         OR SQLERRM LIKE 'source_funding_ambiguous_for_supplier_payment_bank_resolution:%'
      THEN
        v_blocked := true;
      ELSE
        RAISE;
      END IF;
    END;

    IF v_blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'REGRESSION: unresolved/over-resolved partial provenance did not fail closed.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX002', MESSAGE = 'rollback unresolved fixture';
  EXCEPTION
    WHEN SQLSTATE 'ZX002' THEN NULL;
  END;

  -- Real facts must be untouched after both rollback-only fixtures.
  IF (SELECT ROUND(pending_surplus_gbp::numeric,2)
      FROM public.order_pending_funding_surplus
      WHERE id = v_pending_id) IS DISTINCT FROM v_pending_before
  THEN
    RAISE EXCEPTION 'REGRESSION: original pending residual was mutated.';
  END IF;

  IF (SELECT ROUND(ABS(amount_gbp)::numeric,2)
      FROM public.importer_credit_ledger
      WHERE id = v_credit_id) IS DISTINCT FROM v_credit_before
  THEN
    RAISE EXCEPTION 'REGRESSION: confirmed customer credit was mutated.';
  END IF;

  SELECT to_jsonb(p)
  INTO v_source_position_after
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_source_order_id;

  IF v_source_position_after IS DISTINCT FROM v_source_position_before THEN
    RAISE EXCEPTION 'REGRESSION: canonical source settlement position changed.';
  END IF;

  SELECT COUNT(*) INTO v_rows_after
  FROM public.dva_statement_line_allocations;

  IF v_rows_after IS DISTINCT FROM v_rows_before THEN
    RAISE EXCEPTION 'REGRESSION: resolver execution changed supplier allocation rows.';
  END IF;

  RAISE NOTICE 'PASS: partial overfunding resolves only when canonical source settlement is fully resolved; full-overfunding equality remains valid; unresolved partial provenance fails closed; settlement facts and allocations remain unchanged.';
END
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'partial linked overfunding accepts canonical fully-resolved source; ordinary full equality path preserved; unresolved/over-resolved partial path fails closed; original pending residual, confirmed credit, settlement position and supplier allocation rows remain unchanged'
) AS regression_result;

ROLLBACK;
