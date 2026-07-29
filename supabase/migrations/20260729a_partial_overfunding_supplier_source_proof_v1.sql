BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Scope lock: patch only the existing overfunding proof inside the shared
-- supplier-payment source resolver. No business rows or other DB objects change.
DO $migration$
DECLARE
  v_oid oid;
  v_definition text;
  v_patched text;

  v_old_select text := $old$
      map.source_wallet_code AS mapped_wallet_code,
      map.source_bank_account_mapping_code AS mapped_bank_code
    FROM source_lots sl
$old$;

  v_new_select text := $new$
      map.source_wallet_code AS mapped_wallet_code,
      map.source_bank_account_mapping_code AS mapped_bank_code,
      settlement.resolution_status AS settlement_resolution_status,
      settlement.remaining_unresolved_gbp AS settlement_remaining_unresolved_gbp,
      settlement.over_resolved_gbp AS settlement_over_resolved_gbp,
      settlement.pending_evidence_count AS settlement_pending_evidence_count,
      settlement.pending_credit_confirmed_count AS settlement_pending_credit_confirmed_count,
      settlement.confirmed_customer_credit_gbp AS settlement_confirmed_customer_credit_gbp
    FROM source_lots sl
$new$;

  v_old_join text := $old$
    ) map ON true
    WHERE sl.source_type = 'overfunding'
$old$;

  v_new_join text := $new$
    ) map ON true
    LEFT JOIN public.order_settlement_resolution_position_v1 settlement
      ON settlement.order_id = sl.source_order_id
    WHERE sl.source_type = 'overfunding'
$new$;

  v_old_amount_proof text := $old$
        AND ABS(r.pending_surplus_gbp - r.credit_amount_gbp) <= 0.01
$old$;

  v_new_amount_proof text := $new$
        AND (
          -- Existing ordinary/full-overfunding proof remains unchanged.
          ABS(r.pending_surplus_gbp - r.credit_amount_gbp) <= 0.01
          OR (
            -- Additional fail-closed proof for a partial credit created from a
            -- larger original receipt residual after canonical settlement.
            r.pending_surplus_gbp > r.credit_amount_gbp + 0.01
            AND r.settlement_resolution_status = 'fully_resolved'
            AND COALESCE(r.settlement_remaining_unresolved_gbp, 999999999::numeric) <= 0.01
            AND COALESCE(r.settlement_over_resolved_gbp, 999999999::numeric) <= 0.01
            AND COALESCE(r.settlement_pending_evidence_count, -1) = 0
            AND COALESCE(r.settlement_pending_credit_confirmed_count, 0) > 0
            AND ABS(
              COALESCE(r.settlement_confirmed_customer_credit_gbp, -999999999::numeric)
              - r.credit_amount_gbp
            ) <= 0.01
          )
        )
$new$;
BEGIN
  SELECT p.oid
  INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_supplier_payment_bundle_source_v1(uuid,numeric).';
  END IF;

  -- Dependency required only as a read-only proof for the new partial path.
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_settlement_resolution_position_v1'
      AND column_name = 'resolution_status'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_settlement_resolution_position_v1'
      AND column_name = 'remaining_unresolved_gbp'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_settlement_resolution_position_v1'
      AND column_name = 'over_resolved_gbp'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_settlement_resolution_position_v1'
      AND column_name = 'pending_evidence_count'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_settlement_resolution_position_v1'
      AND column_name = 'pending_credit_confirmed_count'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_settlement_resolution_position_v1'
      AND column_name = 'confirmed_customer_credit_gbp'
  ) THEN
    RAISE EXCEPTION 'Canonical settlement proof columns are missing. Stop before patching.';
  END IF;

  SELECT pg_get_functiondef(v_oid)
  INTO v_definition;

  -- Guard against scope drift or re-running against an unexpected resolver.
  IF strpos(v_definition, v_old_select) = 0
     OR strpos(v_definition, v_old_join) = 0
     OR strpos(v_definition, v_old_amount_proof) = 0
  THEN
    RAISE EXCEPTION 'Expected supplier-source overfunding proof shape not found. Stop before patching.';
  END IF;

  IF strpos(v_definition, 'settlement_resolution_status') > 0
     OR strpos(v_definition, 'settlement_remaining_unresolved_gbp') > 0
  THEN
    RAISE EXCEPTION 'Partial-overfunding proof appears already installed. Stop before patching.';
  END IF;

  v_patched := replace(v_definition, v_old_select, v_new_select);
  v_patched := replace(v_patched, v_old_join, v_new_join);
  v_patched := replace(v_patched, v_old_amount_proof, v_new_amount_proof);

  IF v_patched = v_definition THEN
    RAISE EXCEPTION 'Resolver definition was not changed. Stop before patching.';
  END IF;

  EXECUTE v_patched;
END
$migration$;

-- Contract guards: signature/shape/security remain exactly the existing contract.
DO $guard$
DECLARE
  v_oid oid := 'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure;
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(v_oid)
  INTO v_definition;

  IF (SELECT p.provolatile FROM pg_proc p WHERE p.oid = v_oid) <> 's'
     OR (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = v_oid) IS DISTINCT FROM true
     OR pg_get_function_result(v_oid) IS DISTINCT FROM
        'TABLE(source_bank_account_mapping_code text, source_wallet_code text, source_resolution_reason text, remaining_order_cash_funding_gbp numeric, remaining_released_loyalty_funding_gbp numeric)'
  THEN
    RAISE EXCEPTION 'Supplier-source resolver contract changed unexpectedly.';
  END IF;

  IF strpos(v_definition, 'ABS(r.pending_surplus_gbp - r.credit_amount_gbp) <= 0.01') = 0
     OR strpos(v_definition, 'settlement_resolution_status = ''fully_resolved''') = 0
     OR strpos(v_definition, 'settlement_remaining_unresolved_gbp') = 0
     OR strpos(v_definition, 'settlement_confirmed_customer_credit_gbp') = 0
  THEN
    RAISE EXCEPTION 'Partial-overfunding proof was not installed as scoped.';
  END IF;
END
$guard$;

COMMIT;
