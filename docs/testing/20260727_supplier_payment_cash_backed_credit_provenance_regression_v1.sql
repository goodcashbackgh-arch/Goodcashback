-- Supabase SQL Editor regression SQL.
-- Rollback-only: fixture mutations are subtransaction-scoped and the outer
-- transaction always ends with ROLLBACK. No authenticated allocator RPC runs.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_resolver_oid oid;
  v_resolver_definition text;
  v_bundle_definition text;
  v_incremental_definition text;

  v_target_order_id uuid;
  v_target_importer_id uuid;
  v_target_result record;
  v_repeat_result record;

  v_settlement_event_id uuid;
  v_settlement_debit_id uuid;
  v_settlement_credit_id uuid;
  v_settlement_action_id uuid;

  v_overfunding_credit_id uuid;
  v_pending_surplus_id uuid;
  v_source_statement_line_id uuid;

  v_other_importer_id uuid;
  v_unsupported_type text;
  v_blocked boolean;

  v_direct_order_id uuid;
  v_expected_direct_remaining numeric(12,2);
  v_direct_result record;
  v_confirmed_cash_allocation_id uuid;
  v_confirmed_cash_allocation_gbp numeric(12,2);
  v_reversed_result record;

  v_loyalty_order_id uuid;
  v_loyalty_remaining numeric(12,2);
  v_loyalty_wallet text;
  v_loyalty_result record;

  v_event_count_before bigint;
  v_event_count_after bigint;
  v_allocation_count_before bigint;
  v_allocation_count_after bigint;
BEGIN
  SELECT p.oid
  INTO v_resolver_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid =
      'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure;

  IF v_resolver_oid IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: shared supplier-payment resolver is missing.';
  END IF;

  SELECT pg_get_functiondef(v_resolver_oid)
  INTO v_resolver_definition;

  IF (SELECT p.provolatile FROM pg_proc p WHERE p.oid = v_resolver_oid) <> 's'
     OR (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = v_resolver_oid)
          IS DISTINCT FROM true
     OR pg_get_function_result(v_resolver_oid) IS DISTINCT FROM
        'TABLE(source_bank_account_mapping_code text, source_wallet_code text, source_resolution_reason text, remaining_order_cash_funding_gbp numeric, remaining_released_loyalty_funding_gbp numeric)'
  THEN
    RAISE EXCEPTION
      'REGRESSION: resolver signature, return shape, volatility or security contract changed.';
  END IF;

  IF strpos(v_resolver_definition, 'ORD-1784976429191') > 0
     OR strpos(v_resolver_definition, 'abf15b7b-771f-482f-9751-2af0ee0bcbb1') > 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: proof-record identifier is embedded in the permanent resolver.';
  END IF;

  IF strpos(v_resolver_definition, 'supported_cash_applied') = 0
     OR strpos(
          v_resolver_definition,
          'source_credit_type IN (''settlement_credit'', ''overfunding'')'
        ) = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: settlement/overfunding proof is not isolated from loyalty.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)'::regprocedure
  ) INTO v_bundle_definition;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_incremental_definition;

  IF strpos(v_bundle_definition, 'internal_supplier_payment_bundle_source_v1') = 0
     OR strpos(v_incremental_definition, 'internal_supplier_payment_bundle_source_v1') = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: active bundle or incremental route no longer delegates to the resolver.';
  END IF;

  IF strpos(v_incremental_definition, 'source_bank_account_mapping_code') = 0
     OR strpos(v_incremental_definition, 'source_wallet_code') = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: incremental route no longer preserves locked source mapping.';
  END IF;

  RAISE NOTICE
    'LIMITATION: sequential source locking is definition-verified because authenticated allocator RPCs are intentionally not executed in SQL Editor regression.';

  SELECT COUNT(*) INTO v_event_count_before
  FROM public.order_funding_events;

  SELECT COUNT(*) INTO v_allocation_count_before
  FROM public.dva_statement_line_allocations;

  SELECT o.id, o.importer_id
  INTO v_target_order_id, v_target_importer_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: required defective-flow proof order is missing.';
  END IF;

  SELECT
    ofe.id,
    debit.id,
    credit.id,
    action.id
  INTO
    v_settlement_event_id,
    v_settlement_debit_id,
    v_settlement_credit_id,
    v_settlement_action_id
  FROM public.order_funding_events ofe
  JOIN public.importer_credit_ledger debit
    ON debit.id = ofe.source_entity_id
  JOIN public.importer_credit_ledger credit
    ON credit.id = CASE
      WHEN debit.source_table = 'importer_credit_ledger' THEN debit.source_id
      WHEN debit.source_entity_type = 'importer_credit_ledger'
        THEN debit.source_entity_id
      ELSE NULL::uuid
    END
  JOIN public.order_settlement_resolution_actions action
    ON action.credit_ledger_id = credit.id
  WHERE ofe.order_id = v_target_order_id
    AND ofe.event_type = 'credit_applied'
    AND credit.source_type = 'settlement_credit'
  LIMIT 1;

  SELECT
    credit.id,
    surplus.id,
    surplus.dva_statement_line_id
  INTO
    v_overfunding_credit_id,
    v_pending_surplus_id,
    v_source_statement_line_id
  FROM public.order_funding_events ofe
  JOIN public.importer_credit_ledger debit
    ON debit.id = ofe.source_entity_id
  JOIN public.importer_credit_ledger credit
    ON credit.id = CASE
      WHEN debit.source_table = 'importer_credit_ledger' THEN debit.source_id
      WHEN debit.source_entity_type = 'importer_credit_ledger'
        THEN debit.source_entity_id
      ELSE NULL::uuid
    END
  JOIN public.order_pending_funding_surplus surplus
    ON surplus.confirmed_credit_ledger_id = credit.id
  WHERE ofe.order_id = v_target_order_id
    AND ofe.event_type = 'credit_applied'
    AND credit.source_type = 'overfunding'
  LIMIT 1;

  IF v_settlement_action_id IS NULL
     OR v_pending_surplus_id IS NULL
     OR v_source_statement_line_id IS NULL
  THEN
    RAISE EXCEPTION
      'REGRESSION: target settlement or overfunding proof chain is incomplete.';
  END IF;

  SELECT *
  INTO v_target_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_target_order_id,
    884.96
  );

  SELECT *
  INTO v_repeat_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_target_order_id,
    884.96
  );

  IF v_target_result.source_bank_account_mapping_code
       IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_target_result.source_wallet_code IS NOT NULL
     OR v_target_result.source_resolution_reason
          IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR ABS(
          COALESCE(v_target_result.remaining_order_cash_funding_gbp, 0)
          - 884.96
        ) > 0.01
     OR ABS(
          COALESCE(
            v_target_result.remaining_released_loyalty_funding_gbp,
            0
          )
        ) > 0.01
  THEN
    RAISE EXCEPTION
      'REGRESSION: defective flow did not resolve to £884.96 DVA cash.';
  END IF;

  IF to_jsonb(v_target_result) IS DISTINCT FROM to_jsonb(v_repeat_result) THEN
    RAISE EXCEPTION 'REGRESSION: resolver is not deterministic.';
  END IF;

  -- Reversed settlement must fail closed.
  BEGIN
    UPDATE public.order_settlement_resolution_actions
    SET reversed_at = now()
    WHERE id = v_settlement_action_id;

    v_blocked := false;
    BEGIN
      PERFORM *
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_target_order_id,
        884.96
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE
           'source_funding_required_for_supplier_payment_bank_resolution:%'
      THEN
        v_blocked := true;
      ELSE
        RAISE;
      END IF;
    END;

    IF v_blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'REGRESSION: reversed settlement did not block.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    NULL;
  END;

  -- Reversed overfunding must fail closed.
  BEGIN
    UPDATE public.order_pending_funding_surplus
    SET reversed_at = now()
    WHERE id = v_pending_surplus_id;

    v_blocked := false;
    BEGIN
      PERFORM *
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_target_order_id,
        884.96
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE
           'source_funding_required_for_supplier_payment_bank_resolution:%'
      THEN
        v_blocked := true;
      ELSE
        RAISE;
      END IF;
    END;

    IF v_blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'REGRESSION: reversed overfunding did not block.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    NULL;
  END;

  -- Event/debit amount mismatch must fail closed.
  BEGIN
    UPDATE public.order_funding_events
    SET amount_gbp = amount_gbp + 1.00
    WHERE id = v_settlement_event_id;

    v_blocked := false;
    BEGIN
      PERFORM *
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_target_order_id,
        884.96
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE
           'source_funding_required_for_supplier_payment_bank_resolution:%'
      THEN
        v_blocked := true;
      ELSE
        RAISE;
      END IF;
    END;

    IF v_blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'REGRESSION: event/debit mismatch did not block.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    NULL;
  END;

  -- Conflicting source-lot links must fail closed.
  BEGIN
    UPDATE public.importer_credit_ledger
    SET source_entity_id = v_overfunding_credit_id
    WHERE id = v_settlement_debit_id;

    v_blocked := false;
    BEGIN
      PERFORM *
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_target_order_id,
        884.96
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE
           'source_funding_required_for_supplier_payment_bank_resolution:%'
      THEN
        v_blocked := true;
      ELSE
        RAISE;
      END IF;
    END;

    IF v_blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'REGRESSION: source-lot disagreement did not block.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    NULL;
  END;

  -- Importer mismatch must fail closed when a second importer exists.
  SELECT o.importer_id
  INTO v_other_importer_id
  FROM public.orders o
  WHERE o.importer_id IS DISTINCT FROM v_target_importer_id
  LIMIT 1;

  IF v_other_importer_id IS NOT NULL THEN
    BEGIN
      UPDATE public.importer_credit_ledger
      SET importer_id = v_other_importer_id
      WHERE id = v_settlement_debit_id;

      v_blocked := false;
      BEGIN
        PERFORM *
        FROM public.internal_supplier_payment_bundle_source_v1(
          v_target_order_id,
          884.96
        );
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE
             'source_funding_required_for_supplier_payment_bank_resolution:%'
        THEN
          v_blocked := true;
        ELSE
          RAISE;
        END IF;
      END;

      IF v_blocked IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'REGRESSION: importer mismatch did not block.';
      END IF;

      RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
    EXCEPTION WHEN SQLSTATE 'ZX001' THEN
      NULL;
    END;
  ELSE
    RAISE NOTICE
      'LIMITATION: importer mismatch fixture skipped because no second importer exists.';
  END IF;

  -- Unsupported applied-credit type must fail closed when assignable.
  SELECT l.source_type::text
  INTO v_unsupported_type
  FROM public.importer_credit_ledger l
  WHERE COALESCE(l.source_type::text, '') NOT IN (
    '',
    'completion_loyalty_reward',
    'settlement_credit',
    'overfunding',
    'credit_application'
  )
  LIMIT 1;

  IF v_unsupported_type IS NOT NULL THEN
    BEGIN
      UPDATE public.importer_credit_ledger
      SET source_type = v_unsupported_type
      WHERE id = v_settlement_credit_id;

      v_blocked := false;
      BEGIN
        PERFORM *
        FROM public.internal_supplier_payment_bundle_source_v1(
          v_target_order_id,
          884.96
        );
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE
             'source_funding_required_for_supplier_payment_bank_resolution:%'
        THEN
          v_blocked := true;
        ELSE
          RAISE;
        END IF;
      END;

      IF v_blocked IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'REGRESSION: unsupported credit type did not block.';
      END IF;

      RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
    EXCEPTION WHEN SQLSTATE 'ZX001' THEN
      NULL;
    END;
  ELSE
    IF strpos(v_resolver_definition, 'unsupported_applied_credit_source_type') = 0
    THEN
      RAISE EXCEPTION 'REGRESSION: unsupported credit blocker is missing.';
    END IF;

    RAISE NOTICE
      'LIMITATION: unsupported-type behaviour definition-verified because no assignable unsupported source_type exists.';
  END IF;

  -- Conflicting statement mapping must fail closed.
  BEGIN
    UPDATE public.dva_statement_line_import_links
    SET statement_source_wallet_code = 'virtual_gbp_wallet',
        statement_source_bank_account_mapping_code =
          'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
    WHERE dva_statement_line_id = v_source_statement_line_id
      AND active_yn = true;

    v_blocked := false;
    BEGIN
      PERFORM *
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_target_order_id,
        884.96
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE
           'source_funding_required_for_supplier_payment_bank_resolution:%'
      THEN
        v_blocked := true;
      ELSE
        RAISE;
      END IF;
    END;

    IF v_blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'REGRESSION: conflicting source mapping did not block.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    NULL;
  END;

  -- Duplicate receipt evidence must not increase proven funding.
  BEGIN
    INSERT INTO public.order_funding_events (
      id,
      order_id,
      event_type,
      amount_gbp,
      source_table,
      source_id,
      resulting_funded_total_gbp,
      threshold_met,
      created_by_staff_id,
      created_at,
      notes,
      source_ref,
      source_entity_type,
      source_entity_id,
      legacy_event_type
    )
    SELECT
      gen_random_uuid(),
      e.order_id,
      e.event_type,
      e.amount_gbp,
      e.source_table,
      e.source_id,
      e.resulting_funded_total_gbp,
      e.threshold_met,
      e.created_by_staff_id,
      now(),
      'rollback-only duplicate receipt regression fixture',
      e.source_ref,
      e.source_entity_type,
      e.source_entity_id,
      e.legacy_event_type
    FROM public.order_funding_events e
    JOIN public.dva_reconciliation r
      ON r.id = e.source_entity_id
    WHERE r.dva_statement_line_id = v_source_statement_line_id
      AND e.event_type = 'funding_contribution'
    LIMIT 1;

    SELECT *
    INTO v_repeat_result
    FROM public.internal_supplier_payment_bundle_source_v1(
      v_target_order_id,
      884.96
    );

    IF ABS(
         COALESCE(v_repeat_result.remaining_order_cash_funding_gbp, 0)
         - 884.96
       ) > 0.01
    THEN
      RAISE EXCEPTION
        'REGRESSION: duplicate receipt evidence increased proven funding.';
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    NULL;
  END;

  -- Direct-cash working baseline excludes every applied-credit order.
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
        JOIN public.supplier_invoices si
          ON si.id = a.supplier_invoice_id
        WHERE si.order_id = o.id
          AND a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND a.source_bank_account_mapping_code =
                'DVA_CASH_BANK_ACCOUNT'
      ), 0)::numeric, 2) AS allocated_gbp
    FROM public.orders o
    LEFT JOIN public.order_funding_events e
      ON e.order_id = o.id
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
  JOIN LATERAL
    public.internal_supplier_payment_readiness_v1(c.order_id) readiness
    ON readiness.supplier_payment_ready_yn IS TRUE
  WHERE c.direct_gbp - c.allocated_gbp >= 1.00
  ORDER BY c.order_id
  LIMIT 1;

  IF v_direct_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: no qualifying direct-cash comparison order exists.';
  END IF;

  SELECT *
  INTO v_direct_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_direct_order_id,
    1.00
  );

  IF v_direct_result.source_bank_account_mapping_code
       IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_direct_result.source_wallet_code IS NOT NULL
     OR v_direct_result.source_resolution_reason
          IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR ABS(
          COALESCE(v_direct_result.remaining_order_cash_funding_gbp, 0)
          - v_expected_direct_remaining
        ) > 0.01
  THEN
    RAISE EXCEPTION 'REGRESSION: direct-cash baseline changed.';
  END IF;

  -- Confirmed allocation deduction and reversed allocation exclusion.
  SELECT a.id, a.allocated_gbp_amount
  INTO v_confirmed_cash_allocation_id, v_confirmed_cash_allocation_gbp
  FROM public.dva_statement_line_allocations a
  JOIN public.supplier_invoices si
    ON si.id = a.supplier_invoice_id
  WHERE si.order_id = v_direct_order_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed'
    AND a.source_bank_account_mapping_code = 'DVA_CASH_BANK_ACCOUNT'
  ORDER BY a.created_at, a.id
  LIMIT 1;

  IF v_confirmed_cash_allocation_id IS NOT NULL THEN
    BEGIN
      UPDATE public.dva_statement_line_allocations
      SET allocation_status = 'reversed',
          reversed_at = now()
      WHERE id = v_confirmed_cash_allocation_id;

      SELECT *
      INTO v_reversed_result
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_direct_order_id,
        1.00
      );

      IF ABS(
           COALESCE(v_reversed_result.remaining_order_cash_funding_gbp, 0)
           - (
               v_expected_direct_remaining
               + v_confirmed_cash_allocation_gbp
             )
         ) > 0.01
      THEN
        RAISE EXCEPTION
          'REGRESSION: reversed allocation was still deducted.';
      END IF;

      RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'rollback fixture';
    EXCEPTION WHEN SQLSTATE 'ZX001' THEN
      NULL;
    END;
  ELSE
    IF strpos(v_resolver_definition, 'a.allocation_status = ''confirmed''') = 0
    THEN
      RAISE EXCEPTION
        'REGRESSION: confirmed-only allocation deduction predicate is missing.';
    END IF;

    RAISE NOTICE
      'LIMITATION: confirmed/reversed allocation behaviour definition-verified because the selected direct-cash order has no confirmed cash allocation.';
  END IF;

  -- Released-loyalty baseline:
  -- 1. match importer must equal order importer;
  -- 2. no positive non-loyalty applied credit may exist;
  -- 3. exactly one wallet may have a positive remaining balance.
  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.order_id,
      ofe.id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      resolver.resolved_wallet_code::text AS wallet_code
    FROM public.order_funding_events ofe
    JOIN public.orders o
      ON o.id = ofe.order_id
    JOIN public.importer_credit_ledger debit
      ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN debit.source_table = 'importer_credit_ledger' THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger'
          THEN debit.source_entity_id
        ELSE NULL::uuid
      END
     AND lm.importer_id = o.importer_id
     AND lm.match_status = 'released_available_dashboard_credit'
     AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
     AND lm.destination_in_statement_line_id IS NOT NULL
    JOIN LATERAL
      public.internal_completion_loyalty_statement_ledger_resolver_v1(
        lm.destination_in_statement_line_id
      ) resolver
      ON resolver.blocker IS NULL
    WHERE ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
      AND NOT EXISTS (
        SELECT 1
        FROM public.order_funding_events other_event
        JOIN public.importer_credit_ledger other_debit
          ON other_debit.id = other_event.source_entity_id
        LEFT JOIN public.importer_credit_ledger other_credit
          ON other_credit.id = CASE
            WHEN other_debit.source_table = 'importer_credit_ledger'
              THEN other_debit.source_id
            WHEN other_debit.source_entity_type = 'importer_credit_ledger'
              THEN other_debit.source_entity_id
            ELSE NULL::uuid
          END
        WHERE other_event.order_id = ofe.order_id
          AND other_event.event_type = 'credit_applied'
          AND ROUND(
                ABS(COALESCE(other_event.amount_gbp, 0))::numeric,
                2
              ) > 0
          AND COALESCE(other_credit.source_type::text, '')
                <> 'completion_loyalty_reward'
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
          JOIN public.supplier_invoices si
            ON si.id = a.supplier_invoice_id
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
          JOIN public.supplier_invoices si
            ON si.id = a.supplier_invoice_id
          WHERE si.order_id = wr.order_id
            AND a.allocation_type = 'supplier_invoice'
            AND a.allocation_status = 'confirmed'
            AND a.source_bank_account_mapping_code =
                  'DVA_CASH_BANK_ACCOUNT'
        ), 0),
        0
      )::numeric, 2) AS cash_remaining_gbp
    FROM wallet_remaining wr
    JOIN unique_wallet_orders uwo
      ON uwo.order_id = wr.order_id
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
  JOIN LATERAL
    public.internal_supplier_payment_readiness_v1(c.order_id) readiness
    ON readiness.supplier_payment_ready_yn IS TRUE
  WHERE c.cash_remaining_gbp + 0.01 < c.loyalty_remaining_gbp
  ORDER BY c.order_id
  LIMIT 1;

  IF v_loyalty_order_id IS NULL THEN
    RAISE EXCEPTION
      'REGRESSION: no qualifying single-wallet released-loyalty comparison order exists.';
  END IF;

  SELECT *
  INTO v_loyalty_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_loyalty_order_id,
    v_loyalty_remaining
  );

  IF v_loyalty_result.source_wallet_code IS DISTINCT FROM v_loyalty_wallet
     OR v_loyalty_result.source_bank_account_mapping_code IS DISTINCT FROM
          CASE v_loyalty_wallet
            WHEN 'virtual_gbp_wallet'
              THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
            WHEN 'dva_ghs_wallet'
              THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
            ELSE NULL
          END
     OR v_loyalty_result.source_resolution_reason IS DISTINCT FROM
          'exact_remaining_released_loyalty_source'
  THEN
    RAISE EXCEPTION 'REGRESSION: released-loyalty baseline changed.';
  END IF;

  IF strpos(
       v_resolver_definition,
       'v_exact_count = 1 AND v_cash_remaining + 0.01 >= v_amount'
     ) = 0
     OR strpos(
          v_resolver_definition,
          'source_funding_ambiguous_for_supplier_payment_bank_resolution'
        ) = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: exact loyalty versus sufficient cash ambiguity control is missing.';
  END IF;

  RAISE NOTICE
    'LIMITATION: loyalty/cash ambiguity is definition-verified because creating a safe live ambiguity fixture would require inserting a new funding receipt and invoking unrelated receipt controls.';

  SELECT COUNT(*) INTO v_event_count_after
  FROM public.order_funding_events;

  SELECT COUNT(*) INTO v_allocation_count_after
  FROM public.dva_statement_line_allocations;

  IF v_event_count_after <> v_event_count_before
     OR v_allocation_count_after <> v_allocation_count_before
  THEN
    RAISE EXCEPTION
      'REGRESSION: rollback-only fixtures left persistent events or allocations.';
  END IF;

  RAISE NOTICE 'PASS: £884.96 defective flow resolves as DVA cash.';
  RAISE NOTICE 'PASS: reversed settlement and overfunding block.';
  RAISE NOTICE 'PASS: amount, lot-link, importer, unsupported-type and mapping faults fail closed where fixtures were available.';
  RAISE NOTICE 'PASS: duplicate receipt evidence does not increase funding.';
  RAISE NOTICE 'PASS: direct-cash and single-wallet released-loyalty baselines remain unchanged.';
  RAISE NOTICE 'PASS: allocation deduction, determinism, contract and caller boundaries are preserved.';
END;
$regression$;

ROLLBACK;
