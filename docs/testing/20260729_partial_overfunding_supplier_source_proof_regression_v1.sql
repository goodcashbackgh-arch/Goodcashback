-- Supabase SQL Editor regression.
-- READ ONLY. No business-row mutation, fixture creation, authenticated RPC,
-- allocator call, or protected settlement-row update is performed.

DO $regression$
DECLARE
  v_target_order_id uuid;
  v_source_order_id uuid;
  v_credit_id uuid;
  v_pending_id uuid;
  v_pending_surplus_gbp numeric(12,2);
  v_credit_gbp numeric(12,2);
  v_source_position record;
  v_result record;
  v_repeat record;
  v_resolver_definition text;
  v_bundle_core_definition text;
  v_incremental_definition text;
BEGIN
  -- Exact deployed resolver contract.
  SELECT pg_get_functiondef(
    'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure
  ) INTO v_resolver_definition;

  IF v_resolver_definition IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: supplier-payment source resolver is missing.';
  END IF;

  IF (SELECT p.provolatile
      FROM pg_proc p
      WHERE p.oid = 'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure) <> 's'
     OR (SELECT p.prosecdef
         FROM pg_proc p
         WHERE p.oid = 'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure) IS DISTINCT FROM true
     OR pg_get_function_result(
          'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure
        ) IS DISTINCT FROM
        'TABLE(source_bank_account_mapping_code text, source_wallet_code text, source_resolution_reason text, remaining_order_cash_funding_gbp numeric, remaining_released_loyalty_funding_gbp numeric)'
  THEN
    RAISE EXCEPTION 'REGRESSION: resolver contract changed.';
  END IF;

  -- Scope proof: original full-overfunding equality predicate is still present,
  -- and the new partial route is additional and canonically fail-closed.
  IF strpos(v_resolver_definition,
       'ABS(r.pending_surplus_gbp - r.credit_amount_gbp) <= 0.01') = 0
     OR strpos(v_resolver_definition,
       'r.pending_surplus_gbp > r.credit_amount_gbp + 0.01') = 0
     OR strpos(v_resolver_definition,
       'r.settlement_resolution_status = ''fully_resolved''') = 0
     OR strpos(v_resolver_definition,
       'r.settlement_remaining_unresolved_gbp') = 0
     OR strpos(v_resolver_definition,
       'r.settlement_over_resolved_gbp') = 0
     OR strpos(v_resolver_definition,
       'r.settlement_pending_evidence_count') = 0
     OR strpos(v_resolver_definition,
       'r.settlement_pending_credit_confirmed_count') = 0
     OR strpos(v_resolver_definition,
       'r.settlement_confirmed_customer_credit_gbp') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: scoped overfunding proof is missing or broadened.';
  END IF;

  -- Existing fail-closed provenance controls must still be present.
  IF strpos(v_resolver_definition, 'r.pending_status = ''credit_confirmed''') = 0
     OR strpos(v_resolver_definition, 'r.reversed_at IS NULL') = 0
     OR strpos(v_resolver_definition, 'r.confirmed_credit_ledger_id = r.credit_ledger_id') = 0
     OR strpos(v_resolver_definition, 'r.statement_direction = ''in''') = 0
     OR strpos(v_resolver_definition, 'r.mapped_wallet_code = ''dva_cash''') = 0
     OR strpos(v_resolver_definition, 'r.mapped_bank_code = ''DVA_CASH_BANK_ACCOUNT''') = 0
     OR strpos(v_resolver_definition, 'unsupported_applied_credit_source_type') = 0
     OR strpos(v_resolver_definition, 'cash_backed_credit_source_unresolved_or_ambiguous') = 0
     OR strpos(v_resolver_definition, 'source_funding_ambiguous_for_supplier_payment_bank_resolution') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: existing fail-closed provenance controls changed.';
  END IF;

  -- Existing direct-cash and completion-loyalty source routes remain present.
  IF strpos(v_resolver_definition, 'proven_remaining_order_cash_funding') = 0
     OR strpos(v_resolver_definition, 'completion_loyalty_reward') = 0
     OR strpos(v_resolver_definition, 'exact_remaining_released_loyalty_source') = 0
     OR strpos(v_resolver_definition, 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT') = 0
     OR strpos(v_resolver_definition, 'LOYALTY_DVA_GHS_BANK_ACCOUNT') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: existing cash or loyalty source route changed.';
  END IF;

  -- Active supplier allocation routes still delegate to the shared resolver.
  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_bundle_core_v(uuid,jsonb,text)'::regprocedure
  ) INTO v_bundle_core_definition;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_incremental_definition;

  IF strpos(v_bundle_core_definition, 'internal_supplier_payment_bundle_source_v1') = 0
     OR strpos(v_incremental_definition, 'internal_supplier_payment_bundle_source_v1') = 0
  THEN
    RAISE EXCEPTION 'REGRESSION: supplier allocation caller boundary changed.';
  END IF;

  -- Real partial-overfunding chain: target order consumes a smaller credit from
  -- a larger historical pending receipt residual.
  SELECT o.id
  INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'REGRESSION: target partial-overfunding order is missing.';
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
    v_pending_surplus_gbp,
    v_credit_gbp
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

  IF v_credit_id IS NULL
     OR v_source_order_id IS NULL
     OR v_pending_id IS NULL
     OR v_pending_surplus_gbp <= v_credit_gbp + 0.01
  THEN
    RAISE EXCEPTION 'REGRESSION: real partial-overfunding provenance chain is missing.';
  END IF;

  SELECT *
  INTO v_source_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_source_order_id;

  IF v_source_position.order_id IS NULL
     OR v_source_position.resolution_status IS DISTINCT FROM 'fully_resolved'
     OR COALESCE(v_source_position.remaining_unresolved_gbp, 999999999) > 0.01
     OR COALESCE(v_source_position.over_resolved_gbp, 999999999) > 0.01
     OR COALESCE(v_source_position.pending_evidence_count, -1) <> 0
     OR COALESCE(v_source_position.pending_credit_confirmed_count, 0) <= 0
     OR ABS(COALESCE(v_source_position.confirmed_customer_credit_gbp, -999999999) - v_credit_gbp) > 0.01
  THEN
    RAISE EXCEPTION 'REGRESSION: source order is not canonically fully resolved for the linked partial credit.';
  END IF;

  -- Behavioural proof of the new route. £1 is deliberately used only as the
  -- requested supplier-source amount: it exercises the complete provenance
  -- resolver without assuming the current bank OUT or remaining invoice amount.
  SELECT *
  INTO v_result
  FROM public.internal_supplier_payment_bundle_source_v1(v_target_order_id, 1.00::numeric);

  SELECT *
  INTO v_repeat
  FROM public.internal_supplier_payment_bundle_source_v1(v_target_order_id, 1.00::numeric);

  IF v_result.source_bank_account_mapping_code IS DISTINCT FROM 'DVA_CASH_BANK_ACCOUNT'
     OR v_result.source_wallet_code IS NOT NULL
     OR v_result.source_resolution_reason IS DISTINCT FROM 'proven_remaining_order_cash_funding'
     OR COALESCE(v_result.remaining_order_cash_funding_gbp, 0) < 1.00
  THEN
    RAISE EXCEPTION 'REGRESSION: valid partial overfunding did not resolve as DVA cash.';
  END IF;

  IF to_jsonb(v_result) IS DISTINCT FROM to_jsonb(v_repeat) THEN
    RAISE EXCEPTION 'REGRESSION: resolver is not deterministic.';
  END IF;

  -- Read-only integrity proof: the exact business facts remain unchanged.
  IF (SELECT ROUND(pending_surplus_gbp::numeric, 2)
      FROM public.order_pending_funding_surplus
      WHERE id = v_pending_id) IS DISTINCT FROM v_pending_surplus_gbp
     OR (SELECT ROUND(ABS(amount_gbp)::numeric, 2)
         FROM public.importer_credit_ledger
         WHERE id = v_credit_id) IS DISTINCT FROM v_credit_gbp
  THEN
    RAISE EXCEPTION 'REGRESSION: protected source facts changed during resolver execution.';
  END IF;

  RAISE NOTICE 'PASS: real partial fully-resolved overfunding resolves as DVA cash.';
  RAISE NOTICE 'PASS: original full-overfunding equality predicate remains unchanged.';
  RAISE NOTICE 'PASS: unresolved/reversed/ambiguous provenance controls remain fail-closed in the resolver definition.';
  RAISE NOTICE 'PASS: direct-cash, completion-loyalty and supplier-allocation caller boundaries remain unchanged.';
  RAISE NOTICE 'PASS: no business rows were mutated by this regression.';
END
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'read-only: real partial fully-resolved overfunding resolves as DVA cash; original full-overfunding equality predicate, fail-closed provenance controls, direct-cash, completion-loyalty and supplier allocation caller boundaries remain present unchanged; protected settlement facts are not mutated'
) AS regression_result;
