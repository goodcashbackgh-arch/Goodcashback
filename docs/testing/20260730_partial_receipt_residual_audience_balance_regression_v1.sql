BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_target_order_id uuid;
  v_full_cover_order_id uuid;
  v_old_balance numeric;
  v_new_balance numeric;
  v_expected_balance numeric;
  v_pending numeric;
  v_payment_applied numeric;
  v_attributed numeric;
  v_final numeric;
  v_count integer;
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_partial_receipt_residual_balance_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: partial receipt residual audience wrapper or predecessor is missing.';
  END IF;

  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical settlement position is missing.';
  END IF;

  SELECT o.id INTO v_target_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1785274708774';

  IF v_target_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled partial-residual order ORD-1785274708774 is missing.';
  END IF;

  SELECT
    p.pending_receipt_residual_gbp,
    p.payment_applied_to_order_gbp,
    p.order_attributed_receipt_gbp,
    p.final_order_value_gbp,
    ROUND(GREATEST(p.final_order_value_gbp - p.order_attributed_receipt_gbp, 0)::numeric, 2)
  INTO
    v_pending,
    v_payment_applied,
    v_attributed,
    v_final,
    v_expected_balance
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_target_order_id;

  SELECT canonical_balance_due_gbp
  INTO v_old_balance
  FROM public.order_audience_status_pre_partial_receipt_residual_balance_v1(v_target_order_id)
  LIMIT 1;

  SELECT canonical_balance_due_gbp
  INTO v_new_balance
  FROM public.order_audience_status_v1(v_target_order_id)
  LIMIT 1;

  IF ROUND(v_pending, 2) <> 38.13
     OR ROUND(v_payment_applied, 2) <> 701.83
     OR ROUND(v_attributed, 2) <> 739.96
     OR ROUND(v_final, 2) <> 749.43
     OR ROUND(v_old_balance, 2) <> 47.60
     OR ROUND(v_expected_balance, 2) <> 9.47
     OR ROUND(v_new_balance, 2) <> 9.47
  THEN
    RAISE EXCEPTION
      'FAIL: partial residual balance proof changed. pending %, applied %, attributed %, final %, old %, expected %, new %',
      v_pending,
      v_payment_applied,
      v_attributed,
      v_final,
      v_old_balance,
      v_expected_balance,
      v_new_balance;
  END IF;

  -- Previously proven fully-covered receipt-residual case must remain at zero.
  SELECT o.id INTO v_full_cover_order_id
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191';

  IF v_full_cover_order_id IS NOT NULL THEN
    SELECT canonical_balance_due_gbp
    INTO v_new_balance
    FROM public.order_audience_status_v1(v_full_cover_order_id)
    LIMIT 1;

    IF ROUND(COALESCE(v_new_balance, 0), 2) <> 0.00 THEN
      RAISE EXCEPTION 'FAIL: fully-covered receipt residual regressed; balance is %.', v_new_balance;
    END IF;
  END IF;

  -- Orders with no pending receipt residual must pass through unchanged.
  SELECT COUNT(*)::integer
  INTO v_count
  FROM (
    SELECT b.order_id
    FROM public.order_audience_status_pre_partial_receipt_residual_balance_v1(NULL) b
    JOIN public.order_audience_status_v1(NULL) n ON n.order_id = b.order_id
    LEFT JOIN public.order_settlement_resolution_position_v1 p ON p.order_id = b.order_id
    WHERE COALESCE(p.pending_receipt_residual_gbp, 0) <= 0.01
      AND ABS(COALESCE(b.canonical_balance_due_gbp, 0) - COALESCE(n.canonical_balance_due_gbp, 0)) > 0.01
  ) drift;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % no-pending-residual order(s) changed balance.', v_count;
  END IF;
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'ORD-1785274708774 partial receipt residual reduces collectible balance from £47.60 to £9.47 using £739.96 attributed receipt against £749.43 final sale; prior fully-covered case remains £0.00; no-pending-residual orders remain unchanged'
) AS regression_result;

ROLLBACK;
