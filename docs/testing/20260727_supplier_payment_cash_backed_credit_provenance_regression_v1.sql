-- Supabase SQL Editor regression SQL.
-- Read-only: no business rows are inserted, updated or deleted.

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
  v_target_first record;
  v_target_second record;

  v_direct_order_id uuid;
  v_expected_direct_remaining numeric(12,2);
  v_direct_result record;

  v_loyalty_order_id uuid;
  v_loyalty_remaining numeric(12,2);
  v_loyalty_wallet text;
  v_loyalty_result record;

  v_ambiguous_order_id uuid;
  v_ambiguous_amount numeric(12,2);
  v_ambiguous_blocked boolean := false;

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
    RAISE EXCEPTION
      'REGRESSION: shared supplier-payment source resolver is missing.';
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
      'REGRESSION: resolver signature, return shape, volatility or security-definer contract changed.';
  END IF;

  IF strpos(v_resolver_definition, 'ORD-1784976429191') > 0
     OR strpos(
          v_resolver_definition,
          'abf15b7b-771f-482f-9751-2af0ee0bcbb1'
        ) > 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: proof-record identifier is embedded in the permanent resolver.';
  END IF;

  IF strpos(
       v_resolver_definition,
       'supported_cash_applied'
     ) = 0
     OR strpos(
          v_resolver_definition,
          'source_credit_type IN (''settlement_credit'', ''overfunding'')'
        ) = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: settlement/overfunding validation is not isolated from the loyalty path.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)'::regprocedure
  )
  INTO v_bundle_definition;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)'::regprocedure
  )
  INTO v_incremental_definition;

  IF strpos(
       v_bundle_definition,
       'internal_supplier_payment_bundle_source_v1'
     ) = 0
     OR strpos(
          v_incremental_definition,
          'internal_supplier_payment_bundle_source_v1'
        ) = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: active bundle or incremental route no longer delegates to the shared resolver.';
  END IF;

  SELECT COUNT(*) INTO v_event_count_before
  FROM public.order_funding_events;

  SELECT COUNT(*) INTO v_allocation_count_before
  FROM public.dva_statement_line_allocations;

  -- Defective real flow: proof only, never embedded in the migration/function.
  SELECT o.id
  INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION
      'REGRESSION: required defective-flow proof order is not present in this environment.';
  END IF;

  SELECT *
  INTO v_target_first
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_target_order_id,
    884.96
  );

  SELECT *
  INTO v_target_second
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_target_order_id,
    884.96
  );

  IF v_target_first.source_bank_account_mapping_code
       IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_target_first.source_wallet_code IS NOT NULL
     OR v_target_first.source_resolution_reason
          IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR ABS(
          COALESCE(
            v_target_first.remaining_order_cash_funding_gbp,
            0
          ) - 884.96
        ) > 0.01
     OR ABS(
          COALESCE(
            v_target_first.remaining_released_loyalty_funding_gbp,
            0
          )
        ) > 0.01
  THEN
    RAISE EXCEPTION
      'REGRESSION: defective flow did not resolve to £884.96 DVA cash. mapping %, wallet %, reason %, cash %, loyalty %',
      v_target_first.source_bank_account_mapping_code,
      v_target_first.source_wallet_code,
      v_target_first.source_resolution_reason,
      v_target_first.remaining_order_cash_funding_gbp,
      v_target_first.remaining_released_loyalty_funding_gbp;
  END IF;

  IF to_jsonb(v_target_first) IS DISTINCT FROM to_jsonb(v_target_second) THEN
    RAISE EXCEPTION
      'REGRESSION: repeated resolver execution is not deterministic.';
  END IF;

  -- Known-working behavioural baseline: direct DVA cash, no applied credit.
  WITH direct_candidates AS (
    SELECT
      o.id AS order_id,
      ROUND(
        COALESCE(SUM(ABS(ofe.amount_gbp)) FILTER (
          WHERE ofe.event_type = 'funding_contribution'
        ), 0)::numeric,
        2
      ) AS direct_funding_gbp,
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
      ), 0)::numeric, 2) AS confirmed_cash_allocated_gbp
    FROM public.orders o
    LEFT JOIN public.order_funding_events ofe
      ON ofe.order_id = o.id
    WHERE o.id <> v_target_order_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.order_funding_events credit_event
        WHERE credit_event.order_id = o.id
          AND credit_event.event_type = 'credit_applied'
          AND ROUND(
                ABS(COALESCE(credit_event.amount_gbp, 0))::numeric,
                2
              ) > 0
      )
    GROUP BY o.id
  )
  SELECT
    dc.order_id,
    ROUND(
      GREATEST(
        dc.direct_funding_gbp - dc.confirmed_cash_allocated_gbp,
        0
      )::numeric,
      2
    )
  INTO
    v_direct_order_id,
    v_expected_direct_remaining
  FROM direct_candidates dc
  JOIN LATERAL
    public.internal_supplier_payment_readiness_v1(dc.order_id) readiness
    ON readiness.supplier_payment_ready_yn IS TRUE
  WHERE dc.direct_funding_gbp
        - dc.confirmed_cash_allocated_gbp >= 1.00
  ORDER BY dc.order_id
  LIMIT 1;

  IF v_direct_order_id IS NULL THEN
    RAISE EXCEPTION
      'REGRESSION: no qualifying live direct-cash working comparison flow was found.';
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
          COALESCE(
            v_direct_result.remaining_order_cash_funding_gbp,
            0
          ) - v_expected_direct_remaining
        ) > 0.01
  THEN
    RAISE EXCEPTION
      'REGRESSION: direct-cash baseline changed. expected remaining %, mapping %, wallet %, reason %, actual remaining %',
      v_expected_direct_remaining,
      v_direct_result.source_bank_account_mapping_code,
      v_direct_result.source_wallet_code,
      v_direct_result.source_resolution_reason,
      v_direct_result.remaining_order_cash_funding_gbp;
  END IF;

  /*
    Known-working released-loyalty baseline. Select a current order whose exact
    remaining loyalty source exceeds its remaining DVA cash, so the established
    result must remain the exact loyalty source rather than ambiguity.
  */
  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.order_id,
      ofe.id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2)
        AS amount_gbp,
      resolver.resolved_wallet_code::text AS wallet_code
    FROM public.order_funding_events ofe
    JOIN public.importer_credit_ledger debit
      ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN debit.source_table = 'importer_credit_ledger'
          THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger'
          THEN debit.source_entity_id
        ELSE NULL::uuid
      END
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
    ORDER BY ofe.id, lm.id
  ),
  loyalty_by_wallet AS (
    SELECT
      la.order_id,
      la.wallet_code,
      ROUND(SUM(la.amount_gbp)::numeric, 2) AS applied_gbp
    FROM loyalty_applied la
    GROUP BY la.order_id, la.wallet_code
  ),
  allocated AS (
    SELECT
      si.order_id,
      NULLIF(TRIM(a.source_wallet_code), '') AS wallet_code,
      NULLIF(
        TRIM(a.source_bank_account_mapping_code),
        ''
      ) AS mapping_code,
      ROUND(SUM(a.allocated_gbp_amount)::numeric, 2)
        AS allocated_gbp
    FROM public.dva_statement_line_allocations a
    JOIN public.supplier_invoices si
      ON si.id = a.supplier_invoice_id
    WHERE a.allocation_type = 'supplier_invoice'
      AND a.allocation_status = 'confirmed'
    GROUP BY
      si.order_id,
      NULLIF(TRIM(a.source_wallet_code), ''),
      NULLIF(
        TRIM(a.source_bank_account_mapping_code),
        ''
      )
  ),
  cash AS (
    SELECT
      o.id AS order_id,
      ROUND(COALESCE(SUM(ABS(ofe.amount_gbp)) FILTER (
        WHERE ofe.event_type = 'funding_contribution'
      ), 0)::numeric, 2) AS funded_gbp,
      ROUND(COALESCE((
        SELECT SUM(a2.allocated_gbp)
        FROM allocated a2
        WHERE a2.order_id = o.id
          AND a2.mapping_code = 'DVA_CASH_BANK_ACCOUNT'
      ), 0)::numeric, 2) AS allocated_gbp
    FROM public.orders o
    LEFT JOIN public.order_funding_events ofe
      ON ofe.order_id = o.id
    GROUP BY o.id
  ),
  candidates AS (
    SELECT
      lbw.order_id,
      lbw.wallet_code,
      ROUND(
        GREATEST(
          lbw.applied_gbp - COALESCE(a.allocated_gbp, 0),
          0
        )::numeric,
        2
      ) AS loyalty_remaining_gbp,
      ROUND(
        GREATEST(c.funded_gbp - c.allocated_gbp, 0)::numeric,
        2
      ) AS cash_remaining_gbp
    FROM loyalty_by_wallet lbw
    LEFT JOIN allocated a
      ON a.order_id = lbw.order_id
     AND a.wallet_code = lbw.wallet_code
    JOIN cash c
      ON c.order_id = lbw.order_id
    JOIN LATERAL
      public.internal_supplier_payment_readiness_v1(lbw.order_id) readiness
      ON readiness.supplier_payment_ready_yn IS TRUE
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
  WHERE c.loyalty_remaining_gbp > 0
    AND c.cash_remaining_gbp + 0.01 < c.loyalty_remaining_gbp
  ORDER BY c.order_id
  LIMIT 1;

  IF v_loyalty_order_id IS NULL THEN
    RAISE EXCEPTION
      'REGRESSION: no qualifying live released-loyalty working comparison flow was found.';
  END IF;

  SELECT *
  INTO v_loyalty_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_loyalty_order_id,
    v_loyalty_remaining
  );

  IF v_loyalty_result.source_wallet_code
       IS DISTINCT FROM v_loyalty_wallet
     OR v_loyalty_result.source_bank_account_mapping_code
          IS DISTINCT FROM CASE v_loyalty_wallet
            WHEN 'virtual_gbp_wallet'
              THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
            WHEN 'dva_ghs_wallet'
              THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
            ELSE NULL
          END
     OR v_loyalty_result.source_resolution_reason
          IS DISTINCT FROM 'exact_remaining_released_loyalty_source'
  THEN
    RAISE EXCEPTION
      'REGRESSION: released-loyalty baseline changed. expected wallet %, mapping %, actual wallet %, mapping %, reason %',
      v_loyalty_wallet,
      CASE v_loyalty_wallet
        WHEN 'virtual_gbp_wallet'
          THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
        WHEN 'dva_ghs_wallet'
          THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
        ELSE NULL
      END,
      v_loyalty_result.source_wallet_code,
      v_loyalty_result.source_bank_account_mapping_code,
      v_loyalty_result.source_resolution_reason;
  END IF;

  /*
    Exercise a live ambiguity record when one exists. Otherwise require the
    unchanged ambiguity predicate and blocker to remain in the function body.
  */
  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.order_id,
      ofe.id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2)
        AS amount_gbp,
      resolver.resolved_wallet_code::text AS wallet_code
    FROM public.order_funding_events ofe
    JOIN public.importer_credit_ledger debit
      ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN debit.source_table = 'importer_credit_ledger'
          THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger'
          THEN debit.source_entity_id
        ELSE NULL::uuid
      END
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
    ORDER BY ofe.id, lm.id
  ),
  loyalty_by_order AS (
    SELECT
      la.order_id,
      ROUND(SUM(la.amount_gbp)::numeric, 2) AS loyalty_gbp
    FROM loyalty_applied la
    GROUP BY la.order_id
  ),
  cash_by_order AS (
    SELECT
      o.id AS order_id,
      ROUND(COALESCE(SUM(ABS(ofe.amount_gbp)) FILTER (
        WHERE ofe.event_type = 'funding_contribution'
      ), 0)::numeric, 2) AS cash_gbp
    FROM public.orders o
    LEFT JOIN public.order_funding_events ofe
      ON ofe.order_id = o.id
    GROUP BY o.id
  )
  SELECT
    l.order_id,
    l.loyalty_gbp
  INTO
    v_ambiguous_order_id,
    v_ambiguous_amount
  FROM loyalty_by_order l
  JOIN cash_by_order c
    ON c.order_id = l.order_id
  JOIN LATERAL
    public.internal_supplier_payment_readiness_v1(l.order_id) readiness
    ON readiness.supplier_payment_ready_yn IS TRUE
  WHERE l.loyalty_gbp > 0
    AND c.cash_gbp + 0.01 >= l.loyalty_gbp
  ORDER BY l.order_id
  LIMIT 1;

  IF v_ambiguous_order_id IS NOT NULL THEN
    BEGIN
      PERFORM *
      FROM public.internal_supplier_payment_bundle_source_v1(
        v_ambiguous_order_id,
        v_ambiguous_amount
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE
             'source_funding_ambiguous_for_supplier_payment_bank_resolution:%'
        THEN
          v_ambiguous_blocked := true;
        ELSE
          RAISE;
        END IF;
    END;

    IF v_ambiguous_blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION
        'REGRESSION: exact loyalty plus sufficient cash did not block as ambiguous.';
    END IF;
  ELSE
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
        'REGRESSION: established loyalty/cash ambiguity control is missing.';
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_event_count_after
  FROM public.order_funding_events;

  SELECT COUNT(*) INTO v_allocation_count_after
  FROM public.dva_statement_line_allocations;

  IF v_event_count_after <> v_event_count_before
     OR v_allocation_count_after <> v_allocation_count_before
  THEN
    RAISE EXCEPTION
      'REGRESSION: resolver execution mutated funding events or supplier allocations.';
  END IF;

  RAISE NOTICE
    'PASS: defective flow resolves £884.96 as DVA cash.';
  RAISE NOTICE
    'PASS: direct-cash and released-loyalty working flows remain unchanged.';
  RAISE NOTICE
    'PASS: loyalty/cash ambiguity, active callers, function contract, determinism and read-only behaviour are preserved.';
END;
$regression$;

ROLLBACK;
