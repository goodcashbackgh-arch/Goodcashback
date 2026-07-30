BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_normalized_definition text;
  v_result_signature text;
  v_count integer;
  v_order_id uuid;
  v_expected numeric;
  v_actual numeric;
  v_staff_uid uuid;
  v_candidate uuid;
  v_prosecdef boolean;
  v_proconfig text[];
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Required release audit exists and preserves its public contract.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.internal_order_status_drift_audit_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: release-blocking drift audit is missing.';
  END IF;

  SELECT
    lower(pg_get_functiondef(p.oid)),
    pg_get_function_result(p.oid),
    p.prosecdef,
    p.proconfig
  INTO
    v_definition,
    v_result_signature,
    v_prosecdef,
    v_proconfig
  FROM pg_proc p
  WHERE p.oid = 'public.internal_order_status_drift_audit_v1()'::regprocedure;

  v_normalized_definition := regexp_replace(v_definition, '\s+', ' ', 'g');

  IF v_result_signature IS DISTINCT FROM
    'TABLE(order_id uuid, order_ref text, importer_name text, retailer_name text, drift_result text, final_sale_value_gbp numeric, legacy_local_balance_due_gbp numeric, expected_canonical_balance_due_gbp numeric, canonical_status_balance_due_gbp numeric, audience_balance_due_gbp numeric, confirmed_final_balance_payment_gbp numeric, details jsonb)'
  THEN
    RAISE EXCEPTION 'FAIL: drift-audit return signature changed: %', v_result_signature;
  END IF;

  IF NOT COALESCE(v_prosecdef, false) THEN
    RAISE EXCEPTION 'FAIL: drift audit is no longer SECURITY DEFINER.';
  END IF;

  IF NOT COALESCE(v_proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'FAIL: drift-audit search_path execution boundary changed: %', v_proconfig;
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.internal_order_status_drift_audit_v1()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated role lost EXECUTE on drift audit.';
  END IF;

  IF has_function_privilege('anon', 'public.internal_order_status_drift_audit_v1()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon role unexpectedly has EXECUTE on drift audit.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Audience expectation is receipt-residual aware, while the canonical
  --    drift formula remains the established final-sale minus funding minus
  --    confirmed final-balance-payment formula.
  -- -------------------------------------------------------------------------
  IF position('expected_audience_balance_due_gbp' IN v_definition) = 0
     OR position('still_order_applied_residual_gbp' IN v_definition) = 0
     OR position('order_pending_funding_surplus' IN v_definition) = 0
     OR position('importer_credit_ledger' IN v_definition) = 0
     OR position('p.reversed_at is null' IN v_definition) = 0
     OR position('select distinct' IN v_definition) = 0
     OR position('c.source_type = ''overfunding''' IN v_definition) = 0
     OR position('c.source_table = ''orders''' IN v_definition) = 0
     OR position('c.source_id = l.order_id' IN v_definition) = 0
     OR position('c.linked_order_id = l.order_id' IN v_definition) = 0
     OR position('c.source_entity_type = ''order''' IN v_definition) = 0
     OR position('c.source_entity_id = l.order_id' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: drift audit is missing the locked receipt-residual audience expectation controls.';
  END IF;

  IF position(
       'greatest(coalesce(s.signed_final_sale_value_gbp, 0) - coalesce(f.accepted_estimate_amount_received_gbp, 0) - coalesce(fbp.confirmed_final_balance_payment_gbp, 0), 0)'
       IN v_normalized_definition
     ) = 0
     OR position(
       'abs(a.canonical_status_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01'
       IN v_normalized_definition
     ) = 0
  THEN
    RAISE EXCEPTION 'FAIL: established canonical-status drift formula changed.';
  END IF;

  IF position('order_attributed_receipt_gbp' IN v_definition) > 0
     OR position('fx_or_card_diff_gbp' IN v_definition) > 0
     OR position('settlement_fx_card_difference_gbp' IN v_definition) > 0
     OR position('inbound_fx_receipt_residual_gbp' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: drift audit incorrectly references attributed receipt or FX/card amounts.';
  END IF;

  IF position('insert into' IN v_definition) > 0
     OR position('update public.' IN v_definition) > 0
     OR position('delete from' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: drift audit contains a business-data write path.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Establish a real active-staff auth.uid() for protected RPC calls.
  --    Do not assume the shape of the staff table: test existing auth users
  --    through the platform's own is_active_staff() function and use the first
  --    one that passes. SET LOCAL semantics are rolled back with this script.
  -- -------------------------------------------------------------------------
  FOR v_candidate IN
    SELECT u.id
    FROM auth.users u
    ORDER BY u.created_at NULLS LAST, u.id
  LOOP
    PERFORM set_config('request.jwt.claim.sub', v_candidate::text, true);

    BEGIN
      IF public.is_active_staff() THEN
        v_staff_uid := v_candidate;
        EXIT;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  IF v_staff_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff auth user is available for protected regression calls.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_staff_uid::text, true);

  IF auth.uid() IS DISTINCT FROM v_staff_uid OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'FAIL: unable to establish active-staff auth context for regression.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Previous controlled order: £81.20 residual less exact £37.20 new
  --    overfunding credit leaves £44.00 against a £44.00 canonical balance.
  --    Expected and live audience balances are both £0.00; audit must be silent.
  -- -------------------------------------------------------------------------
  SELECT o.id INTO v_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled previous order is missing.';
  END IF;

  WITH active_pending AS (
    SELECT round(coalesce(sum(p.pending_surplus_gbp), 0)::numeric, 2) AS amount
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_order_id
      AND p.status IN ('pending_evidence', 'credit_confirmed')
      AND p.reversed_at IS NULL
  ), credit_links AS (
    SELECT DISTINCT p.importer_id, p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_order_id
      AND p.status = 'credit_confirmed'
      AND p.reversed_at IS NULL
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_credit AS (
    SELECT round(coalesce(sum(abs(c.amount_gbp)), 0)::numeric, 2) AS amount
    FROM credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.importer_id = l.importer_id
     AND c.direction = 'credit'
     AND c.entry_type = 'manual_credit'
     AND c.source_type = 'overfunding'
     AND c.source_table = 'orders'
     AND c.source_id = v_order_id
     AND c.linked_order_id = v_order_id
     AND c.source_entity_type = 'order'
     AND c.source_entity_id = v_order_id
  ), canonical AS (
    SELECT coalesce(s.final_balance_due_gbp, 0)::numeric AS balance
    FROM public.internal_platform_order_status_v1() s
    WHERE s.order_id = v_order_id
  ), audience AS (
    SELECT coalesce(a.canonical_balance_due_gbp, 0)::numeric AS balance
    FROM public.order_audience_status_v1(v_order_id) a
  )
  SELECT
    round(greatest(c.balance - greatest(ap.amount - lc.amount, 0), 0)::numeric, 2),
    round(a.balance::numeric, 2)
  INTO v_expected, v_actual
  FROM canonical c
  CROSS JOIN active_pending ap
  CROSS JOIN linked_credit lc
  CROSS JOIN audience a;

  IF v_expected <> 0.00 OR v_actual <> 0.00 THEN
    RAISE EXCEPTION 'FAIL: previous order expected audience balance %, actual %; expected both 0.00.', v_expected, v_actual;
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.internal_order_status_drift_audit_v1() d
  WHERE d.order_ref = 'ORD-1784976429191';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: corrected previous order is still reported by the release-blocking drift audit.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 5. Target order: canonical £47.60 less active physical residual £38.13
  --    gives £9.47. Live audience must be £9.47 and audit must be silent.
  -- -------------------------------------------------------------------------
  v_order_id := NULL;
  v_expected := NULL;
  v_actual := NULL;

  SELECT o.id INTO v_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: target order ORD-1785274708774 is missing.';
  END IF;

  WITH active_pending AS (
    SELECT round(coalesce(sum(p.pending_surplus_gbp), 0)::numeric, 2) AS amount
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_order_id
      AND p.status IN ('pending_evidence', 'credit_confirmed')
      AND p.reversed_at IS NULL
  ), credit_links AS (
    SELECT DISTINCT p.importer_id, p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_order_id
      AND p.status = 'credit_confirmed'
      AND p.reversed_at IS NULL
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_credit AS (
    SELECT round(coalesce(sum(abs(c.amount_gbp)), 0)::numeric, 2) AS amount
    FROM credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.importer_id = l.importer_id
     AND c.direction = 'credit'
     AND c.entry_type = 'manual_credit'
     AND c.source_type = 'overfunding'
     AND c.source_table = 'orders'
     AND c.source_id = v_order_id
     AND c.linked_order_id = v_order_id
     AND c.source_entity_type = 'order'
     AND c.source_entity_id = v_order_id
  ), canonical AS (
    SELECT coalesce(s.final_balance_due_gbp, 0)::numeric AS balance
    FROM public.internal_platform_order_status_v1() s
    WHERE s.order_id = v_order_id
  ), audience AS (
    SELECT coalesce(a.canonical_balance_due_gbp, 0)::numeric AS balance
    FROM public.order_audience_status_v1(v_order_id) a
  )
  SELECT
    round(greatest(c.balance - greatest(ap.amount - lc.amount, 0), 0)::numeric, 2),
    round(a.balance::numeric, 2)
  INTO v_expected, v_actual
  FROM canonical c
  CROSS JOIN active_pending ap
  CROSS JOIN linked_credit lc
  CROSS JOIN audience a;

  IF v_expected <> 9.47 OR v_actual <> 9.47 THEN
    RAISE EXCEPTION 'FAIL: target order expected audience balance %, actual %; expected both 9.47.', v_expected, v_actual;
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.internal_order_status_drift_audit_v1() d
  WHERE d.order_ref = 'ORD-1785274708774';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: corrected £9.47 target order is still reported by the release-blocking drift audit.';
  END IF;
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'drift-audit public contract and canonical formula remain locked; protected calls run under a real active-staff auth context; previous controlled order is £0.00 without false drift; target order is £9.47 without false drift; no FX/attributed-receipt or write path is introduced'
) AS regression_result;

ROLLBACK;
