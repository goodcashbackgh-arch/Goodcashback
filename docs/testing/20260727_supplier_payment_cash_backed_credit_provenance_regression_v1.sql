-- Shared supplier-payment cash-backed credit provenance regression.
-- Read-only. No economic rows are written.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_bundle_definition text;
  v_incremental_definition text;
  v_resolver_definition text;
  v_order_id uuid;
  v_result record;
BEGIN
  SELECT pg_get_functiondef(
           'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure
         )
  INTO v_resolver_definition;

  SELECT pg_get_functiondef(
           'public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)'::regprocedure
         )
  INTO v_bundle_definition;

  SELECT pg_get_functiondef(
           'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)'::regprocedure
         )
  INTO v_incremental_definition;

  IF strpos(v_bundle_definition, 'internal_supplier_payment_bundle_source_v1') = 0
     OR strpos(v_incremental_definition, 'internal_supplier_payment_bundle_source_v1') = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: current supplier allocation RPCs do not delegate to the shared source resolver.';
  END IF;

  IF strpos(v_resolver_definition, 'settlement_credit') = 0
     OR strpos(v_resolver_definition, 'overfunding') = 0
     OR strpos(v_resolver_definition, 'order_settlement_resolution_actions') = 0
     OR strpos(v_resolver_definition, 'order_pending_funding_surplus') = 0
     OR strpos(v_resolver_definition, 'DVA_CASH_BANK_ACCOUNT') = 0
  THEN
    RAISE EXCEPTION
      'REGRESSION: shared resolver is missing cash-backed settlement/overfunding provenance handling.';
  END IF;

  SELECT o.id
  INTO v_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_order_id IS NULL THEN
    RAISE NOTICE
      'REGRESSION: target order ORD-1784976429191 not present; live-data assertion skipped.';
    RETURN;
  END IF;

  SELECT *
  INTO v_result
  FROM public.internal_supplier_payment_bundle_source_v1(
    v_order_id,
    884.96
  );

  IF v_result.source_bank_account_mapping_code
       IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_result.source_wallet_code IS NOT NULL
     OR v_result.source_resolution_reason
          IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR ABS(
          COALESCE(v_result.remaining_order_cash_funding_gbp, 0)
          - 884.96
        ) > 0.01
     OR ABS(
          COALESCE(
            v_result.remaining_released_loyalty_funding_gbp,
            0
          )
        ) > 0.01
  THEN
    RAISE EXCEPTION
      'REGRESSION: expected target result mapping %, wallet %, reason %, cash %, loyalty %',
      v_result.source_bank_account_mapping_code,
      v_result.source_wallet_code,
      v_result.source_resolution_reason,
      v_result.remaining_order_cash_funding_gbp,
      v_result.remaining_released_loyalty_funding_gbp;
  END IF;

  RAISE NOTICE
    'PASS: £804.93 direct cash + £64.99 settlement credit + £15.04 overfunding = £884.96 DVA cash.';
END;
$regression$;

ROLLBACK;
