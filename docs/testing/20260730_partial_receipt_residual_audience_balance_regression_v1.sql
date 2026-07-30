BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_target_order_id uuid;
  v_full_cover_order_id uuid;
  v_definition text;
  v_pending numeric;
  v_payment_applied numeric;
  v_funding_total numeric;
  v_applied_credit numeric;
  v_final numeric;
  v_expected_balance numeric;
  v_full_cover_expected numeric;
  v_count integer;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Required objects and source-level scope guard.
  --    The audience wrapper may use the physical pending receipt residual.
  --    It must not use attributed receipt or any FX residual as a customer
  --    balance reducer.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_partial_receipt_residual_balance_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: partial receipt residual audience wrapper or predecessor is missing.';
  END IF;

  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical settlement position is missing.';
  END IF;

  SELECT lower(pg_get_functiondef('public.order_audience_status_v1(uuid)'::regprocedure))
  INTO v_definition;

  IF position('pending_receipt_residual_gbp' IN v_definition) = 0
     OR position('payment_applied_to_order_gbp' IN v_definition) = 0
     OR position('safe_collectible_balance_due_gbp' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: wrapper is missing the locked physical-receipt balance formula.';
  END IF;

  IF position('order_attributed_receipt_gbp' IN v_definition) > 0
     OR position('inbound_fx_receipt_residual_gbp' IN v_definition) > 0
     OR position('settlement_fx_card_difference_gbp' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: wrapper references attributed-receipt or FX fields; customer balance must exclude FX.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Controlled partial-residual order.
  --    £701.83 already applied includes the £37.20 account credit.
  --    Only the £38.13 pending physical receipt residual additionally reduces
  --    the £47.60 final shortfall, leaving £9.47.
  -- -------------------------------------------------------------------------
  SELECT o.id INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled partial-residual order ORD-1785274708774 is missing.';
  END IF;

  SELECT
    p.pending_receipt_residual_gbp,
    p.payment_applied_to_order_gbp,
    p.funding_total_gbp,
    p.applied_account_credit_gbp,
    p.final_order_value_gbp,
    ROUND(
      GREATEST(
        p.final_order_value_gbp
          - p.payment_applied_to_order_gbp
          - p.pending_receipt_residual_gbp,
        0
      )::numeric,
      2
    )
  INTO
    v_pending,
    v_payment_applied,
    v_funding_total,
    v_applied_credit,
    v_final,
    v_expected_balance
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_target_order_id;

  IF ROUND(v_pending, 2) <> 38.13
     OR ROUND(v_payment_applied, 2) <> 701.83
     OR ROUND(v_funding_total, 2) <> 701.83
     OR ROUND(v_applied_credit, 2) <> 37.20
     OR ROUND(v_final, 2) <> 749.43
     OR ROUND(v_expected_balance, 2) <> 9.47
  THEN
    RAISE EXCEPTION
      'FAIL: controlled partial residual proof changed. pending %, payment applied %, funding %, applied credit %, final %, expected balance %',
      v_pending,
      v_payment_applied,
      v_funding_total,
      v_applied_credit,
      v_final,
      v_expected_balance;
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Previously proven fully-covered case remains £0.00 using the same
  --    FX-excluding formula.
  -- -------------------------------------------------------------------------
  SELECT o.id INTO v_full_cover_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_full_cover_order_id IS NOT NULL THEN
    SELECT ROUND(
      GREATEST(
        p.final_order_value_gbp
          - p.payment_applied_to_order_gbp
          - p.pending_receipt_residual_gbp,
        0
      )::numeric,
      2
    )
    INTO v_full_cover_expected
    FROM public.order_settlement_resolution_position_v1 p
    WHERE p.order_id = v_full_cover_order_id;

    IF ROUND(COALESCE(v_full_cover_expected, 0), 2) <> 0.00 THEN
      RAISE EXCEPTION 'FAIL: fully-covered receipt residual formula regressed; expected balance is %.', v_full_cover_expected;
    END IF;
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. No-pending-residual branch is explicit pass-through in source.
  -- -------------------------------------------------------------------------
  IF position('else coalesce(b.canonical_balance_due_gbp, 0)' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: no-pending-residual balance pass-through is missing.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 5. Wrapper is read-only: reject any financial or operational write verb.
  -- -------------------------------------------------------------------------
  IF position('insert into' IN v_definition) > 0
     OR position('update public.' IN v_definition) > 0
     OR position('delete from' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: audience wrapper contains a write path.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 6. No accidental creation/reclassification of the controlled £37.20 credit.
  --    The existing settlement position must still show one applied-credit
  --    component inside the already-applied funding total, not an extra amount.
  -- -------------------------------------------------------------------------
  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.order_funding_events e
  WHERE e.order_id = v_target_order_id
    AND e.event_type = 'credit_applied'
    AND ROUND(ABS(COALESCE(e.amount_gbp, 0))::numeric, 2) = 37.20;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one £37.20 applied-credit funding event on controlled order; found %.', v_count;
  END IF;
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'partial physical receipt residual only: £701.83 already applied (including £37.20 account credit) + £38.13 pending physical receipt residual against £749.43 final value leaves £9.47; FX/attributed-receipt fields are absent from the wrapper; prior fully-covered case remains £0.00; no-pending branch passes through; wrapper is read-only'
) AS regression_result;

ROLLBACK;
