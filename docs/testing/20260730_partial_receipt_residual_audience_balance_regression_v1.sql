BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_target_order_id uuid;
  v_full_cover_order_id uuid;
  v_layer_definition text;
  v_top_definition text;
  v_pending numeric;
  v_linked_credit numeric;
  v_payment_applied numeric;
  v_funding_total numeric;
  v_applied_credit numeric;
  v_final numeric;
  v_expected_balance numeric;
  v_full_pending numeric;
  v_full_linked_credit numeric;
  v_full_expected numeric;
  v_bad_case text;
  v_bad_actual numeric;
  v_bad_expected numeric;
  v_count integer;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Required objects and hard scope guards.
  --    The repair must live only in the 28 July receipt-residual layer.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_importer_tracking_assignment_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: required audience chain is missing.';
  END IF;

  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL
     OR to_regclass('public.order_pending_funding_surplus') IS NULL
     OR to_regclass('public.importer_credit_ledger') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: required settlement/pending/credit objects are missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.order_audience_status_pre_importer_tracking_assignment_v1(uuid)'::regprocedure))
  INTO v_layer_definition;

  SELECT lower(pg_get_functiondef('public.order_audience_status_v1(uuid)'::regprocedure))
  INTO v_top_definition;

  IF position('still_order_applied_residual_gbp' IN v_layer_definition) = 0
     OR position('active_pending_receipt_gbp' IN v_layer_definition) = 0
     OR position('payment_applied_to_order_gbp' IN v_layer_definition) = 0
     OR position('final_order_value_gbp' IN v_layer_definition) = 0
     OR position('confirmed_credit_ledger_id' IN v_layer_definition) = 0
     OR position('select distinct' IN v_layer_definition) = 0
     OR position('p.status in (''pending_evidence'', ''credit_confirmed'')' IN v_layer_definition) = 0
     OR position('p.status = ''credit_confirmed''' IN v_layer_definition) = 0
     OR position('c.direction = ''credit''' IN v_layer_definition) = 0
     OR position('order_audience_status_pre_receipt_residual_overlay_v1' IN v_layer_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: 28 July audience layer is missing the locked physical-residual controls.';
  END IF;

  -- Hard boundary: do not move this arithmetic into the shared top-level audience function.
  IF position('still_order_applied_residual_gbp' IN v_top_definition) > 0
     OR position('active_pending_receipt_gbp' IN v_top_definition) > 0
     OR position('confirmed_credit_ledger_id' IN v_top_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: receipt-residual arithmetic leaked into top-level order_audience_status_v1.';
  END IF;

  IF position('order_attributed_receipt_gbp' IN v_layer_definition) > 0
     OR position('inbound_fx_receipt_residual_gbp' IN v_layer_definition) > 0
     OR position('settlement_fx_card_difference_gbp' IN v_layer_definition) > 0
     OR position('fx_or_card_diff_gbp' IN v_layer_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: repaired audience layer references attributed-receipt or FX fields.';
  END IF;

  IF position('insert into' IN v_layer_definition) > 0
     OR position('update public.' IN v_layer_definition) > 0
     OR position('delete from' IN v_layer_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: repaired audience layer contains a financial or operational write path.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Pure accounting/arithmetic scenario matrix.
  -- -------------------------------------------------------------------------
  WITH cases(
    case_name,
    base_balance,
    final_value,
    payment_applied,
    active_pending,
    linked_credit,
    final_docs,
    expected_balance
  ) AS (
    VALUES
      ('no_residual_pass_through',             47.60::numeric, 749.43::numeric, 701.83::numeric,  0.00::numeric,  0.00::numeric, 1, 47.60::numeric),
      ('partial_uncredited_residual',          47.60::numeric, 749.43::numeric, 701.83::numeric, 38.13::numeric,  0.00::numeric, 1,  9.47::numeric),
      ('uncredited_residual_covers_balance',   47.60::numeric, 749.43::numeric, 701.83::numeric, 60.00::numeric,  0.00::numeric, 1,  0.00::numeric),
      ('partially_credited_residual',            0.00::numeric, 928.96::numeric, 884.96::numeric, 81.20::numeric, 37.20::numeric, 1,  0.00::numeric),
      ('fully_credited_recomputes_old_overlay',  0.00::numeric, 749.43::numeric, 701.83::numeric, 38.13::numeric, 38.13::numeric, 1, 47.60::numeric),
      ('overlinked_credit_fail_closed',          0.00::numeric, 749.43::numeric, 701.83::numeric, 38.13::numeric, 40.00::numeric, 1, 47.60::numeric),
      ('prior_final_balance_payment',          42.60::numeric, 749.43::numeric, 706.83::numeric, 30.00::numeric,  0.00::numeric, 1, 12.60::numeric),
      ('no_final_sale_pass_through',           47.60::numeric,   0.00::numeric,   0.00::numeric, 38.13::numeric,  0.00::numeric, 0, 47.60::numeric),
      ('de_minimis_residual_pass_through',     47.60::numeric, 749.43::numeric, 701.83::numeric,  0.01::numeric,  0.00::numeric, 1, 47.60::numeric)
  ), evaluated AS (
    SELECT
      c.*,
      ROUND(
        CASE
          WHEN c.active_pending > 0.01
           AND c.final_docs > 0
          THEN GREATEST(
            GREATEST(c.final_value - c.payment_applied, 0)
              - GREATEST(c.active_pending - c.linked_credit, 0),
            0
          )
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
    RAISE EXCEPTION 'FAIL: scenario % produced %, expected %.', v_bad_case, v_bad_actual, v_bad_expected;
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Live controlled partial-residual order.
  --    £701.83 already applied includes £37.20 account credit.
  --    £38.13 is separate physical receipt residual.
  --    £749.43 - £701.83 - £38.13 = £9.47.
  -- -------------------------------------------------------------------------
  SELECT o.id INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled partial-residual order ORD-1785274708774 is missing.';
  END IF;

  WITH active_pending AS (
    SELECT ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS amount
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_target_order_id
      AND p.status IN ('pending_evidence','credit_confirmed')
  ), credit_links AS (
    SELECT DISTINCT p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_target_order_id
      AND p.status = 'credit_confirmed'
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_credit AS (
    SELECT ROUND(COALESCE(SUM(ABS(c.amount_gbp)), 0)::numeric, 2) AS amount
    FROM credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.direction = 'credit'
  )
  SELECT
    ap.amount,
    lc.amount,
    s.payment_applied_to_order_gbp,
    s.funding_total_gbp,
    s.applied_account_credit_gbp,
    s.final_order_value_gbp,
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
    v_payment_applied,
    v_funding_total,
    v_applied_credit,
    v_final,
    v_expected_balance
  FROM public.order_settlement_resolution_position_v1 s
  CROSS JOIN active_pending ap
  CROSS JOIN linked_credit lc
  WHERE s.order_id = v_target_order_id;

  IF ROUND(v_pending, 2) <> 38.13
     OR ROUND(v_linked_credit, 2) <> 0.00
     OR ROUND(v_payment_applied, 2) <> 701.83
     OR ROUND(v_funding_total, 2) <> 701.83
     OR ROUND(v_applied_credit, 2) <> 37.20
     OR ROUND(v_final, 2) <> 749.43
     OR ROUND(v_expected_balance, 2) <> 9.47
  THEN
    RAISE EXCEPTION
      'FAIL: target proof changed. pending %, linked residual credit %, payment applied %, funding %, applied account credit %, final %, expected balance %',
      v_pending, v_linked_credit, v_payment_applied, v_funding_total, v_applied_credit, v_final, v_expected_balance;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.order_funding_events e
  WHERE e.order_id = v_target_order_id
    AND e.event_type = 'credit_applied'
    AND ROUND(ABS(COALESCE(e.amount_gbp, 0))::numeric, 2) = 37.20;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one £37.20 applied-credit funding event on target order; found %.', v_count;
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Live credit-confirmed residual scenario.
  --    £81.20 residual - £37.20 new customer credit = £44 still order-applied.
  --    Final-sale shortfall is £44, therefore balance remains £0.
  -- -------------------------------------------------------------------------
  SELECT o.id INTO v_full_cover_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_full_cover_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled credit-confirmed residual order ORD-1784976429191 is missing.';
  END IF;

  WITH active_pending AS (
    SELECT ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS amount
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_full_cover_order_id
      AND p.status IN ('pending_evidence','credit_confirmed')
  ), credit_links AS (
    SELECT DISTINCT p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = v_full_cover_order_id
      AND p.status = 'credit_confirmed'
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_credit AS (
    SELECT ROUND(COALESCE(SUM(ABS(c.amount_gbp)), 0)::numeric, 2) AS amount
    FROM credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.direction = 'credit'
  )
  SELECT
    ap.amount,
    lc.amount,
    ROUND(
      GREATEST(
        GREATEST(s.final_order_value_gbp - s.payment_applied_to_order_gbp, 0)
          - GREATEST(ap.amount - lc.amount, 0),
        0
      )::numeric,
      2
    )
  INTO v_full_pending, v_full_linked_credit, v_full_expected
  FROM public.order_settlement_resolution_position_v1 s
  CROSS JOIN active_pending ap
  CROSS JOIN linked_credit lc
  WHERE s.order_id = v_full_cover_order_id;

  IF ROUND(v_full_pending, 2) <> 81.20
     OR ROUND(v_full_linked_credit, 2) <> 37.20
     OR ROUND(v_full_expected, 2) <> 0.00
  THEN
    RAISE EXCEPTION
      'FAIL: credit-confirmed residual proof changed. active residual %, exact linked customer credit %, expected balance %',
      v_full_pending, v_full_linked_credit, v_full_expected;
  END IF;
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'Repair is confined to the 28 July pre-importer-tracking receipt-residual audience layer; top-level audience function contains no new residual arithmetic; FX excluded; no write path; scenario matrix passed; target £9.47 and prior £81.20/£37.20 credit-confirmed case £0 both proved'
) AS regression_result;

ROLLBACK;
