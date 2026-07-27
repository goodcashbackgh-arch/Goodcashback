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
    AND p.oid = 'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure;

  IF v_resolver_oid IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: shared supplier-payment source resolver is missing.';
  END IF;

  SELECT pg_get_functiondef(v_resolver_oid)
  INTO v_resolver_definition;

  IF (SELECT p.provolatile FROM pg_proc p WHERE p.oid = v_resolver_oid) <> 's'
     OR (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = v_resolver_oid) IS DISTINCT FROM true
     OR pg_get_function_result(v_resolver_oid) IS DISTINCT FROM
        'TABLE(source_bank_account_mapping_code text, source_wallet_code text, source_resolution_reason text, remaining_order_cash_funding_gbp numeric, remaining_released_loyalty_funding_gbp numeric)'
  THEN
    RAISE EXCEPTION 'REGRESSION: resolver signature, return shape, volatility or security-definer contract changed.';
  END IF;

  IF strpos(v_resolver_definition, 'ORD-1784976429191') > 0
     OR strpos(v_resolver_definition, 'abf15b7b-771f-482f-9751-2af0ee0bcbb1') > 0
  THEN
    RAISE EXCEPTION 'REGRESSION: proof-record identifier is embedded in the permanent resolver.';
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
    RAISE EXCEPTION 'REGRESSION: active bundle or incremental route no longer delegates to the shared resolver.';
  END IF;

  SELECT COUNT(*) INTO v_event_count_before FROM public.order_funding_events;
  SELECT COUNT(*) INTO v_allocation_count_before FROM public.dva_statement_line_allocations;

  -- Defective real flow: proof only, never embedded in the migration/function.
  SELECT o.id
  INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: required defective-flow proof order is not present in this environment.';
  END IF;

  SELECT *
  INTO v_target_first
  FROM public.internal_supplier_payment_bundle_source_v1(v_target_order_id, 884.96);

  SELECT *
  INTO v_target_second
  FROM public.internal_supplier_payment_bundle_source_v1(v_target_order_id, 884.96);

  IF v_target_first.source_bank_account_mapping_code IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_target_first.source_wallet_code IS NOT NULL
     OR v_target_first.source_resolution_reason IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR ABS(COALESCE(v_target_first.remaining_order_cash_funding_gbp, 0) - 884.96) > 0.01
     OR ABS(COALESCE(v_target_first.remaining_released_loyalty_funding_gbp, 0)) > 0.01
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
    RAISE EXCEPTION 'REGRESSION: repeated resolver execution is not deterministic.';
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
        JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
        WHERE si.order_id = o.id
          AND a.allocation_type = 'supplier_invoice'
          AND a.allocation_status = 'confirmed'
          AND a.source_bank_account_mapping_code = 'DVA_CASH_BANK_ACCOUNT'
      ), 0)::numeric, 2) AS confirmed_cash_allocated_gbp
    FROM public.orders o
    LEFT JOIN public.order_funding_events ofe ON ofe.order_id = o.id
    WHERE o.id <> v_target_order_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.order_funding_events credit_event
        WHERE credit_event.order_id = o.id
          AND credit_event.event_type = 'credit_applied'
          AND ROUND(ABS(COALESCE(credit_event.amount_gbp, 0))::numeric, 2) > 0
      )
    GROUP BY o.id
  )
  SELECT
    dc.order_id,
    ROUND(GREATEST(dc.direct_funding_gbp - dc.confirmed_cash_allocated_gbp, 0)::numeric, 2)
  INTO v_direct_order_id, v_expected_direct_remaining
  FROM direct_candidates dc
  JOIN LATERAL public.internal_supplier_payment_readiness_v1(dc.order_id) readiness
    ON readiness.supplier_payment_ready_yn IS TRUE
  WHERE dc.direct_funding_gbp - dc.confirmed_cash_allocated_gbp >= 1.00
  ORDER BY dc.order_id
  LIMIT 1;

  IF v_direct_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: no qualifying live direct-cash working comparison flow was found.';
  END IF;

  SELECT *
  INTO v_direct_result
  FROM public.internal_supplier_payment_bundle_source_v1(v_direct_order_id, 1.00);

  IF v_direct_result.source_bank_account_mapping_code IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_direct_result.source_wallet_code IS NOT NULL
     OR v_direct_result.source_resolution_reason IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR ABS(COALESCE(v_direct_result.remaining_order_cash_funding_gbp, 0) - v_expected_direct_remaining) > 0.01
  THEN
    RAISE EXCEPTION
      'REGRESSION: direct-cash baseline changed. expected remaining %, mapping %, wallet %, reason %, actual remaining %',
      v_expected_direct_remaining,
      v_direct_result.source_bank_account_mapping_code,
      v_direct_result.source_wallet_code,
      v_direct_result.source_resolution_reason,
      v_direct_result.remaining_order_cash_funding_gbp;
  END IF;

  SELECT COUNT(*) INTO v_event_count_after FROM public.order_funding_events;
  SELECT COUNT(*) INTO v_allocation_count_after FROM public.dva_statement_line_allocations;

  IF v_event_count_after <> v_event_count_before
     OR v_allocation_count_after <> v_allocation_count_before
  THEN
    RAISE EXCEPTION 'REGRESSION: resolver execution mutated funding events or supplier allocations.';
  END IF;

  RAISE NOTICE 'PASS: defective flow resolves £884.96 as DVA cash.';
  RAISE NOTICE 'PASS: direct-cash working comparison remains unchanged.';
  RAISE NOTICE 'PASS: active routes, function contract, determinism and read-only behaviour are preserved.';
END;
$regression$;

ROLLBACK;
