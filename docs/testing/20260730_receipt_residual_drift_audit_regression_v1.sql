BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_count integer;
  v_order_id uuid;
  v_expected numeric;
  v_actual numeric;
BEGIN
  IF to_regprocedure('public.internal_order_status_drift_audit_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: release-blocking drift audit is missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_order_status_drift_audit_v1()'::regprocedure))
  INTO v_definition;

  IF position('expected_audience_balance_due_gbp' IN v_definition) = 0
     OR position('still_order_applied_residual_gbp' IN v_definition) = 0
     OR position('order_pending_funding_surplus' IN v_definition) = 0
     OR position('importer_credit_ledger' IN v_definition) = 0
     OR position('p.reversed_at is null' IN v_definition) = 0
     OR position('select distinct' IN v_definition) = 0
     OR position('c.source_type = ''overfunding''' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: drift audit is missing the locked receipt-residual audience expectation controls.';
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
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'release-blocking drift audit distinguishes canonical balance from receipt-residual-adjusted audience balance; previous controlled order is not false-positive drift; no FX/attributed-receipt or write path is introduced'
) AS regression_result;

ROLLBACK;
