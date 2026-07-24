BEGIN;

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.order_settlement_resolution_actions') IS NULL THEN
    v_missing := array_append(v_missing, 'order_settlement_resolution_actions');
  END IF;
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    v_missing := array_append(v_missing, 'order_settlement_resolution_position_v1');
  END IF;
  IF to_regprocedure('public.internal_order_settlement_resolution_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'internal_order_settlement_resolution_v1(uuid)');
  END IF;
  IF to_regprocedure('public.order_settlement_audience_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'order_settlement_audience_v1(uuid)');
  END IF;
  IF to_regprocedure('public.staff_resolve_order_settlement_v1(uuid,numeric,numeric,text,text,uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'staff_resolve_order_settlement_v1(uuid,numeric,numeric,text,text,uuid)');
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'Missing canonical settlement objects: %', array_to_string(v_missing, ', ');
  END IF;
END $$;

DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*)
  INTO v_count
  FROM public.order_settlement_resolution_position_v1 p
  WHERE ABS(
    p.gross_positive_difference_gbp
      - (
          p.confirmed_customer_credit_gbp
          + p.inbound_fx_receipt_residual_gbp
          + p.settlement_fx_card_difference_gbp
          + p.remaining_unresolved_gbp
          - p.over_resolved_gbp
        )
  ) > 0.01;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'Canonical settlement equation failed for % order(s).', v_count;
  END IF;
END $$;

DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*)
  INTO v_count
  FROM public.order_settlement_resolution_position_v1 p
  WHERE (p.operational_blocked_yn AND (p.credit_action_allowed_yn OR p.fx_action_allowed_yn))
     OR (p.remaining_unresolved_gbp <= 0.01 AND (p.credit_action_allowed_yn OR p.fx_action_allowed_yn))
     OR (p.over_resolved_gbp > 0.01 AND p.resolution_status <> 'over_resolved_review')
     OR (p.remaining_unresolved_gbp > 0.01 AND p.total_classified_gbp > 0.01 AND p.over_resolved_gbp <= 0.01 AND p.resolution_status NOT IN ('partially_resolved','not_ready_no_final_sale'))
     OR (p.remaining_unresolved_gbp <= 0.01 AND p.gross_positive_difference_gbp > 0.01 AND p.over_resolved_gbp <= 0.01 AND p.resolution_status <> 'fully_resolved');

  IF v_count > 0 THEN
    RAISE EXCEPTION 'Settlement status/action invariant failed for % order(s).', v_count;
  END IF;
END $$;

DO $$
DECLARE
  v_row record;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.orders WHERE order_ref = 'ORD-1784498556959'
  ) THEN
    SELECT *
    INTO v_row
    FROM public.order_settlement_resolution_position_v1
    WHERE order_ref = 'ORD-1784498556959';

    IF v_row.order_id IS NULL THEN
      RAISE EXCEPTION 'Target order settlement position missing.';
    END IF;

    IF ABS(v_row.order_attributed_receipt_gbp - 900.00) > 0.01
       OR ABS(v_row.payment_applied_to_order_gbp - 884.96) > 0.01
       OR ABS(v_row.final_order_value_gbp - 819.97) > 0.01
       OR ABS(v_row.gross_positive_difference_gbp - 80.03) > 0.01
       OR ABS(v_row.confirmed_customer_credit_gbp - 15.04) > 0.01
       OR ABS((v_row.inbound_fx_receipt_residual_gbp + v_row.settlement_fx_card_difference_gbp) - 0.00) > 0.01
       OR ABS(v_row.remaining_unresolved_gbp - 64.99) > 0.01
       OR v_row.resolution_status <> 'partially_resolved'
       OR v_row.open_dispute_count <> 0
       OR v_row.active_hold_count <> 0
       OR v_row.credit_action_allowed_yn IS DISTINCT FROM true
       OR v_row.fx_action_allowed_yn IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'Target order canonical settlement mismatch: %', to_jsonb(v_row);
    END IF;
  END IF;
END $$;

SELECT
  'PASS: canonical settlement resolution objects, equations, action gates and target-order partial-credit position are consistent.' AS regression_result;

ROLLBACK;
