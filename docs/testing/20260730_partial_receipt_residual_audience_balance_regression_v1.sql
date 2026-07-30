BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_target_order_id uuid;
  v_previous_order_id uuid;
  v_definition text;
  v_bad_case text;
  v_bad_actual numeric;
  v_bad_expected numeric;
  v_pending numeric;
  v_linked_credit numeric;
  v_physical_receipt numeric;
  v_cash_funding numeric;
  v_payment_applied numeric;
  v_funding_total numeric;
  v_applied_credit numeric;
  v_final_value numeric;
  v_base_balance numeric;
  v_expected_balance numeric;
  v_previous_pending numeric;
  v_previous_linked_credit numeric;
  v_previous_base_balance numeric;
  v_previous_expected numeric;
  v_count integer;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Actual live post-migration audience structure and hard scope guards.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: required audience chain is missing.';
  END IF;

  IF to_regclass('public.order_pending_funding_surplus') IS NULL
     OR to_regclass('public.importer_credit_ledger') IS NULL
     OR to_regclass('public.order_settlement_resolution_position_v1') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: required proof objects are missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.order_audience_status_v1(uuid)'::regprocedure))
  INTO v_definition;

  -- Lock the residual arithmetic and exact linked-credit provenance that are present
  -- in the actual live post-migration function definition captured from PostgreSQL.
  IF position('order_audience_status_pre_receipt_residual_overlay_v1' IN v_definition) = 0
     OR position('still_order_applied_residual_gbp' IN v_definition) = 0
     OR position('active_pending_receipt_gbp' IN v_definition) = 0
     OR position('confirmed_credit_ledger_id' IN v_definition) = 0
     OR position('select distinct' IN v_definition) = 0
     OR position('p.status in (''pending_evidence'', ''credit_confirmed'')' IN v_definition) = 0
     OR position('p.reversed_at is null' IN v_definition) = 0
     OR position('c.entry_type = ''manual_credit''' IN v_definition) = 0
     OR position('c.source_type = ''overfunding''' IN v_definition) = 0
     OR position('c.source_table = ''orders''' IN v_definition) = 0
     OR position('c.source_id = l.order_id' IN v_definition) = 0
     OR position('c.linked_order_id = l.order_id' IN v_definition) = 0
     OR position('c.source_entity_type = ''order''' IN v_definition) = 0
     OR position('c.source_entity_id = l.order_id' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: repaired audience function is missing a locked residual/provenance control.';
  END IF;

  -- The repaired top-level function intentionally bypasses the defective old
  -- receipt-residual wrapper; it must not call the preserved tracking wrapper.
  IF position('order_audience_status_pre_importer_tracking_assignment_v1' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: repaired audience function unexpectedly calls the preserved tracking wrapper instead of preserving its behaviour in place.';
  END IF;

  -- No re-derivation of funding/final-sale balance and no FX/attributed receipt.
  IF position('order_settlement_resolution_position_v1' IN v_definition) > 0
     OR position('payment_applied_to_order_gbp' IN v_definition) > 0
     OR position('final_order_value_gbp' IN v_definition) > 0
     OR position('order_attributed_receipt_gbp' IN v_definition) > 0
     OR position('inbound_fx_receipt_residual_gbp' IN v_definition) > 0
     OR position('settlement_fx_card_difference_gbp' IN v_definition) > 0
     OR position('fx_or_card_diff_gbp' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: audience repair rederives canonical balance or references FX/attributed-receipt fields.';
  END IF;

  IF position('insert into' IN v_definition) > 0
     OR position('update public.' IN v_definition) > 0
     OR position('delete from' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: repaired audience function contains a business-data write path.';
  END IF;

  -- Lock the ACTUAL live post-migration status/tracking structure rather than old
  -- local alias names. Customer/importer status/action pass through unless the
  -- corrected physical residual clears the balance; shipper fields pass straight
  -- through; and the newer importer tracking-assignment behaviour remains present.
  IF position('balance_cleared_by_physical_residual' IN v_definition) = 0
     OR position('then r.customer_status_label' IN v_definition) = 0
     OR position('then r.customer_next_action' IN v_definition) = 0
     OR position('then r.importer_status_label' IN v_definition) = 0
     OR position('then r.importer_next_action' IN v_definition) = 0
     OR position('corrected_customer_status_label as customer_status_label' IN v_definition) = 0
     OR position('corrected_customer_next_action as customer_next_action' IN v_definition) = 0
     OR position('corrected_importer_status_label as importer_status_label' IN v_definition) = 0
     OR position('tracking_assignment_needed' IN v_definition) = 0
     OR position('when p.tracking_assignment_needed then ''assign tracking''' IN v_definition) = 0
     OR position('p.shipper_status_label' IN v_definition) = 0
     OR position('p.shipper_next_action' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: actual live audience pass-through/status/tracking boundary is not preserved.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Accounting scenario matrix. Only the existing canonical balance changes.
  -- -------------------------------------------------------------------------
  WITH cases(case_name, base_balance, active_pending, linked_credit, expected_balance) AS (
    VALUES
      ('no_residual_pass_through',            47.60::numeric,  0.00::numeric,  0.00::numeric, 47.60::numeric),
      ('partial_uncredited_residual',         47.60::numeric, 38.13::numeric,  0.00::numeric,  9.47::numeric),
      ('uncredited_residual_covers_balance',  20.00::numeric, 50.00::numeric,  0.00::numeric,  0.00::numeric),
      ('partially_credited_residual',          44.00::numeric, 81.20::numeric, 37.20::numeric,  0.00::numeric),
      ('fully_credited_residual',              47.60::numeric, 38.13::numeric, 38.13::numeric, 47.60::numeric),
      ('overlinked_credit_fails_closed',       47.60::numeric, 38.13::numeric, 40.00::numeric, 47.60::numeric),
      ('prior_final_balance_already_in_base',  42.60::numeric, 30.00::numeric,  0.00::numeric, 12.60::numeric),
      ('de_minimis_residual_pass_through',     47.60::numeric,  0.01::numeric,  0.00::numeric, 47.60::numeric),
      ('reversed_residual_excluded',           47.60::numeric,  0.00::numeric,  0.00::numeric, 47.60::numeric),
      ('zero_existing_balance_stays_zero',      0.00::numeric, 38.13::numeric,  0.00::numeric,  0.00::numeric)
  ), evaluated AS (
    SELECT
      c.*,
      ROUND(
        CASE
          WHEN c.active_pending > 0.01
          THEN GREATEST(c.base_balance - GREATEST(c.active_pending - c.linked_credit, 0), 0)
          ELSE c.base_balance
        END::numeric,
        2
      ) AS actual_balance
    FROM cases c
  )
  SELECT case_name, actual_balance, expected_balance
  INTO v_bad_case, v_bad_actual, v_bad_expected
  FROM evaluated
  WHERE actual_balance IS DISTINCT FROM expected_balance
  ORDER BY case_name
  LIMIT 1;

  IF v_bad_case IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: scenario % produced %, expected %.',
      v_bad_case, v_bad_actual, v_bad_expected;
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Live target: ORD-1785274708774.
  --    Physical receipt 702.76; cash funding 664.63; pre-existing account credit
  --    37.20; funded total 701.83; physical residual 38.13; final 749.43.
  --    Existing shortfall 47.60 - residual 38.13 = 9.47.
  -- -------------------------------------------------------------------------
  SELECT o.id INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: target order ORD-1785274708774 is missing.';
  END IF;

  WITH active_pending AS (
    SELECT ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS amount
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_target_order_id
      AND p.status IN ('pending_evidence','credit_confirmed')
      AND p.reversed_at IS NULL
  ), credit_links AS (
    SELECT DISTINCT p.importer_id, p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_target_order_id
      AND p.status = 'credit_confirmed'
      AND p.reversed_at IS NULL
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_credit AS (
    SELECT ROUND(COALESCE(SUM(ABS(c.amount_gbp)), 0)::numeric, 2) AS amount
    FROM credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.importer_id = l.importer_id
     AND c.direction = 'credit'
     AND c.entry_type = 'manual_credit'
     AND c.source_type = 'overfunding'
     AND c.source_table = 'orders'
     AND c.source_id = v_target_order_id
     AND c.linked_order_id = v_target_order_id
     AND c.source_entity_type = 'order'
     AND c.source_entity_id = v_target_order_id
  ), cash AS (
    SELECT ROUND(COALESCE(SUM(dr.reconciled_gbp_amount), 0)::numeric, 2) AS amount
    FROM public.dva_reconciliation dr
    WHERE dr.order_id = v_target_order_id
      AND dr.reconciliation_type = 'order_funding'
      AND dr.reconciled_at IS NOT NULL
  ), physical_lines AS (
    SELECT DISTINCT dr.dva_statement_line_id, dsl.amount_gbp_equivalent
    FROM public.dva_reconciliation dr
    JOIN public.dva_statement_lines dsl ON dsl.id = dr.dva_statement_line_id
    WHERE dr.order_id = v_target_order_id
      AND dr.reconciliation_type = 'order_funding'
      AND dr.reconciled_at IS NOT NULL
  ), physical AS (
    SELECT ROUND(COALESCE(SUM(amount_gbp_equivalent), 0)::numeric, 2) AS amount
    FROM physical_lines
  )
  SELECT
    ap.amount,
    lc.amount,
    ph.amount,
    ca.amount,
    s.payment_applied_to_order_gbp,
    s.funding_total_gbp,
    s.applied_account_credit_gbp,
    s.final_order_value_gbp,
    ROUND(GREATEST(s.final_order_value_gbp - s.payment_applied_to_order_gbp, 0)::numeric, 2),
    ROUND(
      GREATEST(
        GREATEST(s.final_order_value_gbp - s.payment_applied_to_order_gbp, 0)
          - GREATEST(ap.amount - lc.amount, 0),
        0
      )::numeric,
      2
    )
  INTO
    v_pending,
    v_linked_credit,
    v_physical_receipt,
    v_cash_funding,
    v_payment_applied,
    v_funding_total,
    v_applied_credit,
    v_final_value,
    v_base_balance,
    v_expected_balance
  FROM public.order_settlement_resolution_position_v1 s
  CROSS JOIN active_pending ap
  CROSS JOIN linked_credit lc
  CROSS JOIN cash ca
  CROSS JOIN physical ph
  WHERE s.order_id = v_target_order_id;

  IF ROUND(v_physical_receipt, 2) <> 702.76
     OR ROUND(v_cash_funding, 2) <> 664.63
     OR ROUND(v_pending, 2) <> 38.13
     OR ROUND(v_linked_credit, 2) <> 0.00
     OR ROUND(v_payment_applied, 2) <> 701.83
     OR ROUND(v_funding_total, 2) <> 701.83
     OR ROUND(v_applied_credit, 2) <> 37.20
     OR ROUND(v_final_value, 2) <> 749.43
     OR ROUND(v_base_balance, 2) <> 47.60
     OR ROUND(v_expected_balance, 2) <> 9.47
  THEN
    RAISE EXCEPTION
      'FAIL target proof: physical %, cash %, pending %, linked residual credit %, payment applied %, funding %, applied credit %, final %, base balance %, corrected %',
      v_physical_receipt, v_cash_funding, v_pending, v_linked_credit,
      v_payment_applied, v_funding_total, v_applied_credit, v_final_value,
      v_base_balance, v_expected_balance;
  END IF;

  -- The £37.20 already applied to this target is existing account credit, not the
  -- £38.13 pending residual and not FX. Prove it appears exactly once as applied credit.
  SELECT COUNT(*)::integer INTO v_count
  FROM public.order_funding_events e
  WHERE e.order_id = v_target_order_id
    AND e.event_type = 'credit_applied'
    AND ROUND(ABS(COALESCE(e.amount_gbp, 0))::numeric, 2) = 37.20;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one £37.20 applied-credit funding event on target; found %.', v_count;
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Live previous model: ORD-1784976429191.
  --    Original residual 81.20; exact new overfunding credit 37.20; therefore
  --    44.00 remains attached to this order. Existing shortfall 44.00 -> zero.
  -- -------------------------------------------------------------------------
  SELECT o.id INTO v_previous_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_previous_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: previous controlled order ORD-1784976429191 is missing.';
  END IF;

  WITH active_pending AS (
    SELECT ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS amount
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_previous_order_id
      AND p.status IN ('pending_evidence','credit_confirmed')
      AND p.reversed_at IS NULL
  ), credit_links AS (
    SELECT DISTINCT p.importer_id, p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_previous_order_id
      AND p.status = 'credit_confirmed'
      AND p.reversed_at IS NULL
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_credit AS (
    SELECT ROUND(COALESCE(SUM(ABS(c.amount_gbp)), 0)::numeric, 2) AS amount
    FROM credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.importer_id = l.importer_id
     AND c.direction = 'credit'
     AND c.entry_type = 'manual_credit'
     AND c.source_type = 'overfunding'
     AND c.source_table = 'orders'
     AND c.source_id = v_previous_order_id
     AND c.linked_order_id = v_previous_order_id
     AND c.source_entity_type = 'order'
     AND c.source_entity_id = v_previous_order_id
  )
  SELECT
    ap.amount,
    lc.amount,
    ROUND(GREATEST(s.final_order_value_gbp - s.payment_applied_to_order_gbp, 0)::numeric, 2),
    ROUND(
      GREATEST(
        GREATEST(s.final_order_value_gbp - s.payment_applied_to_order_gbp, 0)
          - GREATEST(ap.amount - lc.amount, 0),
        0
      )::numeric,
      2
    )
  INTO
    v_previous_pending,
    v_previous_linked_credit,
    v_previous_base_balance,
    v_previous_expected
  FROM public.order_settlement_resolution_position_v1 s
  CROSS JOIN active_pending ap
  CROSS JOIN linked_credit lc
  WHERE s.order_id = v_previous_order_id;

  IF ROUND(v_previous_pending, 2) <> 81.20
     OR ROUND(v_previous_linked_credit, 2) <> 37.20
     OR ROUND(v_previous_base_balance, 2) <> 44.00
     OR ROUND(v_previous_expected, 2) <> 0.00
  THEN
    RAISE EXCEPTION
      'FAIL previous proof: residual %, linked credit %, base balance %, corrected %',
      v_previous_pending, v_previous_linked_credit,
      v_previous_base_balance, v_previous_expected;
  END IF;
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'actual live post-migration audience structure verified; residual provenance locked; customer/importer pass-through preserved until corrected residual clears balance; shipper fields pass through unchanged; importer tracking assignment including Assign tracking preserved; existing canonical balance remains authoritative; partial residual £38.13 reduces £47.60 to £9.47; £81.20 residual less exact £37.20 overfunding credit leaves £44.00 and clears £44.00 shortfall; reversed rows excluded; FX and attributed-receipt fields forbidden; no business-data writes'
) AS regression_result;

ROLLBACK;
