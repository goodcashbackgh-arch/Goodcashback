-- Supabase SQL Editor regression.
-- Rollback-only. No authenticated allocator RPC is executed.
-- Scope: prove the new partial-overfunding source proof and protect the
-- existing full-overfunding, direct-cash, loyalty and fail-closed behaviours.

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
  v_events_before bigint;
  v_events_after bigint;

  v_direct_order_id uuid;
  v_expected_direct_remaining numeric(12,2);
  v_direct_result record;

  v_loyalty_order_id uuid;
  v_loyalty_remaining numeric(12,2);
  v_loyalty_wallet text;
  v_loyalty_result record;
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

  SELECT COUNT(*) INTO v_events_before
  FROM public.order_funding_events;

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

  -- 4. Existing direct-cash behaviour must still execute, not merely exist in text.
  WITH candidates AS (
    SELECT
      o.id AS order_id,
      ROUND(
        COALESCE(SUM(ABS(e.amount_gbp)) FILTER (
          WHERE e.event_type = 'funding_contribution'
        ), 0)::numeric,
        2
      ) AS direct_gbp,
      ROUND(COALESCE((
        SELECT SUM(a.allocated_gbp_amount)
        FROM public.dva_statement_line_allocations a
        JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
        WHERE si.order_id = o.id
          AND a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND a.source_bank_account_mapping_code = 'DVA_CASH_BANK_ACCOUNT'
      ), 0)::numeric, 2) AS allocated_gbp
    FROM public.orders o
    LEFT JOIN public.order_funding_events e ON e.order_id = o.id
    WHERE o.id <> v_target_order_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.order_funding_events ce
        WHERE ce.order_id = o.id
          AND ce.event_type = 'credit_applied'
          AND ROUND(ABS(COALESCE(ce.amount_gbp, 0))::numeric, 2) > 0
      )
    GROUP BY o.id
  )
  SELECT
    c.order_id,
    ROUND(GREATEST(c.direct_gbp - c.allocated_gbp, 0)::numeric, 2)
  INTO v_direct_order_id, v_expected_direct_remaining
  FROM candidates c
  JOIN LATERAL public.internal_supplier_payment_readiness_v1(c.order_id) readiness
    ON readiness.supplier_payment_ready_yn IS TRUE
  WHERE c.direct_gbp - c.allocated_gbp >= 1.00
  ORDER BY c.order_id
  LIMIT 1;

  IF v_direct_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: no qualifying direct-cash comparison order exists.';
  END IF;

  SELECT * INTO v_direct_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_direct_order_id,
    1.00
  );

  IF v_direct_result.source_bank_account_mapping_code IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_direct_result.source_wallet_code IS NOT NULL
     OR v_direct_result.source_resolution_reason IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR ABS(
          COALESCE(v_direct_result.remaining_order_cash_funding_gbp, 0)
          - v_expected_direct_remaining
        ) > 0.01
  THEN
    RAISE EXCEPTION 'REGRESSION: direct-cash baseline changed.';
  END IF;

  -- 5. Existing released-loyalty behaviour must still execute where a safe
  -- live single-wallet comparison order exists.
  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.order_id,
      ofe.id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      resolver.resolved_wallet_code::text AS wallet_code
    FROM public.order_funding_events ofe
    JOIN public.orders o ON o.id = ofe.order_id
    JOIN public.importer_credit_ledger debit ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN debit.source_table = 'importer_credit_ledger' THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger' THEN debit.source_entity_id
        ELSE NULL::uuid
      END
     AND lm.importer_id = o.importer_id
     AND lm.match_status = 'released_available_dashboard_credit'
     AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
     AND lm.destination_in_statement_line_id IS NOT NULL
    JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(
      lm.destination_in_statement_line_id
    ) resolver ON resolver.blocker IS NULL
    WHERE ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
      AND NOT EXISTS (
        SELECT 1
        FROM public.order_funding_events other_event
        JOIN public.importer_credit_ledger other_debit
          ON other_debit.id = other_event.source_entity_id
        LEFT JOIN public.importer_credit_ledger other_credit
          ON other_credit.id = CASE
            WHEN other_debit.source_table = 'importer_credit_ledger' THEN other_debit.source_id
            WHEN other_debit.source_entity_type = 'importer_credit_ledger' THEN other_debit.source_entity_id
            ELSE NULL::uuid
          END
        WHERE other_event.order_id = ofe.order_id
          AND other_event.event_type = 'credit_applied'
          AND ROUND(ABS(COALESCE(other_event.amount_gbp, 0))::numeric, 2) > 0
          AND COALESCE(other_credit.source_type::text, '') <> 'completion_loyalty_reward'
      )
    ORDER BY ofe.id, lm.id
  ),
  wallet_totals AS (
    SELECT
      la.order_id,
      la.wallet_code,
      ROUND(SUM(la.amount_gbp)::numeric, 2) AS applied_gbp
    FROM loyalty_applied la
    GROUP BY la.order_id, la.wallet_code
  ),
  wallet_remaining AS (
    SELECT
      wt.order_id,
      wt.wallet_code,
      ROUND(GREATEST(
        wt.applied_gbp - COALESCE((
          SELECT SUM(a.allocated_gbp_amount)
          FROM public.dva_statement_line_allocations a
          JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
          WHERE si.order_id = wt.order_id
            AND a.allocation_type = 'supplier_invoice'
            AND a.allocation_status = 'confirmed'
            AND a.source_wallet_code = wt.wallet_code
        ), 0),
        0
      )::numeric, 2) AS loyalty_remaining_gbp
    FROM wallet_totals wt
  ),
  unique_wallet_orders AS (
    SELECT wr.order_id
    FROM wallet_remaining wr
    WHERE wr.loyalty_remaining_gbp > 0
    GROUP BY wr.order_id
    HAVING COUNT(*) = 1
  ),
  candidates AS (
    SELECT
      wr.order_id,
      wr.wallet_code,
      wr.loyalty_remaining_gbp,
      ROUND(GREATEST(
        COALESCE((
          SELECT SUM(ABS(e.amount_gbp))
          FROM public.order_funding_events e
          WHERE e.order_id = wr.order_id
            AND e.event_type = 'funding_contribution'
        ), 0)
        - COALESCE((
          SELECT SUM(a.allocated_gbp_amount)
          FROM public.dva_statement_line_allocations a
          JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
          WHERE si.order_id = wr.order_id
            AND a.allocation_type = 'supplier_invoice'
            AND a.allocation_status = 'confirmed'
            AND a.source_bank_account_mapping_code = 'DVA_CASH_BANK_ACCOUNT'
        ), 0),
        0
      )::numeric, 2) AS cash_remaining_gbp
    FROM wallet_remaining wr
    JOIN unique_wallet_orders uwo ON uwo.order_id = wr.order_id
    WHERE wr.loyalty_remaining_gbp > 0
  )
  SELECT
    c.order_id,
    c.loyalty_remaining_gbp,
    c.wallet_code
  INTO
    v_loyalty_order_id,
    v_loyalty_remaining,
    v_loyalty_wallet
  FROM candidates c
  JOIN LATERAL public.internal_supplier_payment_readiness_v1(c.order_id) readiness
    ON readiness.supplier_payment_ready_yn IS TRUE
  WHERE c.cash_remaining_gbp + 0.01 < c.loyalty_remaining_gbp
  ORDER BY c.order_id
  LIMIT 1;

  IF v_loyalty_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: no qualifying single-wallet released-loyalty comparison order exists.';
  END IF;

  SELECT * INTO v_loyalty_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_loyalty_order_id,
    v_loyalty_remaining
  );

  IF v_loyalty_result.source_wallet_code IS DISTINCT FROM v_loyalty_wallet
     OR v_loyalty_result.source_bank_account_mapping_code IS DISTINCT FROM
          CASE v_loyalty_wallet
            WHEN 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
            WHEN 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
            ELSE NULL
          END
     OR v_loyalty_result.source_resolution_reason IS DISTINCT FROM
          'exact_remaining_released_loyalty_source'
  THEN
    RAISE EXCEPTION 'REGRESSION: released-loyalty baseline changed.';
  END IF;

  -- A safe live ambiguity fixture would require creating new receipt funding
  -- evidence and invoking unrelated controls. Under the governing regression
  -- contract this particular negative remains exact-definition verified.
  IF strpos(
       v_resolver_definition,
       'v_exact_count = 1 AND v_cash_remaining + 0.01 >= v_amount'
     ) = 0
     OR strpos(
          v_resolver_definition,
          'source_funding_ambiguous_for_supplier_payment_bank_resolution'
        ) = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: loyalty/cash ambiguity fail-closed control is missing.';
  END IF;

  RAISE NOTICE 'LIMITATION: loyalty/cash ambiguity is definition-verified because a safe behavioural fixture would require unrelated receipt controls.';

  -- Real facts must remain untouched after rollback-only fixtures and resolver calls.
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

  SELECT COUNT(*) INTO v_events_after
  FROM public.order_funding_events;

  IF v_rows_after IS DISTINCT FROM v_rows_before
     OR v_events_after IS DISTINCT FROM v_events_before
  THEN
    RAISE EXCEPTION 'REGRESSION: resolver/regression left persistent allocation or funding-event rows.';
  END IF;

  RAISE NOTICE 'PASS: partial fully-resolved overfunding resolves to DVA cash.';
  RAISE NOTICE 'PASS: ordinary full-overfunding equality remains valid.';
  RAISE NOTICE 'PASS: unresolved/over-resolved partial provenance still fails closed.';
  RAISE NOTICE 'PASS: direct-cash and released-loyalty baselines execute unchanged.';
  RAISE NOTICE 'PASS: settlement facts, funding events and supplier allocations remain unchanged.';
END
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'partial linked overfunding accepts only canonical fully-resolved source; ordinary full equality preserved; unresolved partial fails closed; direct-cash and released-loyalty behaviours execute unchanged; ambiguity control remains fail-closed; pending residual, confirmed credit, settlement position, funding events and supplier allocations remain unchanged'
) AS regression_result;

ROLLBACK;
