BEGIN;

DO $$
DECLARE
  v_auth_uid uuid;
  v_mismatch_count integer;
  v_target record;
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing order_audience_status_v1(uuid)';
  END IF;
  IF to_regprocedure('public.order_settlement_audience_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing order_settlement_audience_v1(uuid)';
  END IF;
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing order_settlement_resolution_position_v1';
  END IF;

  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 WHEN s.role_type = 'supervisor' THEN 1 ELSE 2 END, s.created_at
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No active staff auth user available for cross-surface regression.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);

  WITH canonical AS (
    SELECT *
    FROM public.order_settlement_resolution_position_v1
    WHERE final_sale_document_count > 0
  ), audience AS (
    SELECT *
    FROM public.order_settlement_audience_v1(NULL)
  ), operational AS (
    SELECT *
    FROM public.order_audience_status_v1(NULL)
  )
  SELECT COUNT(*)::integer
  INTO v_mismatch_count
  FROM canonical c
  LEFT JOIN audience a ON a.order_id = c.order_id
  LEFT JOIN operational o ON o.order_id = c.order_id
  WHERE a.order_id IS NULL
     OR o.order_id IS NULL
     OR ABS(COALESCE(a.credit_added_to_account_gbp, 0) - COALESCE(c.confirmed_customer_credit_gbp, 0)) > 0.01
     OR ABS(
       COALESCE(a.other_settlement_adjustment_gbp, 0)
       - (COALESCE(c.inbound_fx_receipt_residual_gbp, 0) + COALESCE(c.settlement_fx_card_difference_gbp, 0))
     ) > 0.01
     OR ABS(COALESCE(a.potential_additional_credit_gbp, 0) - COALESCE(c.remaining_unresolved_gbp, 0)) > 0.01
     OR a.resolution_status IS DISTINCT FROM c.resolution_status
     OR ABS(COALESCE(o.potential_credit_pending_review_gbp, 0) - COALESCE(c.remaining_unresolved_gbp, 0)) > 0.01;

  IF v_mismatch_count > 0 THEN
    RAISE EXCEPTION 'Canonical settlement cross-surface mismatch for % order(s).', v_mismatch_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_settlement_audience_v1(NULL) a
    WHERE a.other_settlement_adjustment_gbp > 0.01
      AND a.credit_added_to_account_gbp <= 0.01
      AND a.potential_additional_credit_gbp <= 0.01
      AND a.resolution_status <> 'fully_resolved'
  ) THEN
    RAISE EXCEPTION 'FX-only fully classified settlement is not reported as fully resolved.';
  END IF;

  SELECT
    c.order_ref,
    c.order_attributed_receipt_gbp,
    c.final_order_value_gbp,
    c.gross_positive_difference_gbp,
    c.confirmed_customer_credit_gbp,
    c.inbound_fx_receipt_residual_gbp + c.settlement_fx_card_difference_gbp AS confirmed_fx_gbp,
    c.remaining_unresolved_gbp,
    c.resolution_status,
    a.credit_added_to_account_gbp,
    a.other_settlement_adjustment_gbp,
    a.potential_additional_credit_gbp,
    o.potential_credit_pending_review_gbp
  INTO v_target
  FROM public.order_settlement_resolution_position_v1 c
  JOIN public.order_settlement_audience_v1(NULL) a ON a.order_id = c.order_id
  JOIN public.order_audience_status_v1(NULL) o ON o.order_id = c.order_id
  WHERE c.order_ref = 'ORD-1784498556959';

  IF v_target.order_ref IS NOT NULL THEN
    IF ABS(v_target.order_attributed_receipt_gbp - 900.00) > 0.01
       OR ABS(v_target.final_order_value_gbp - 819.97) > 0.01
       OR ABS(v_target.gross_positive_difference_gbp - 80.03) > 0.01
       OR ABS(v_target.confirmed_customer_credit_gbp - 15.04) > 0.01
       OR ABS(v_target.confirmed_fx_gbp - 0.00) > 0.01
       OR ABS(v_target.remaining_unresolved_gbp - 64.99) > 0.01
       OR v_target.resolution_status <> 'partially_resolved'
       OR ABS(v_target.credit_added_to_account_gbp - 15.04) > 0.01
       OR ABS(v_target.other_settlement_adjustment_gbp - 0.00) > 0.01
       OR ABS(v_target.potential_additional_credit_gbp - 64.99) > 0.01
       OR ABS(v_target.potential_credit_pending_review_gbp - 64.99) > 0.01 THEN
      RAISE EXCEPTION 'Target order cross-surface values are inconsistent: %', to_jsonb(v_target);
    END IF;
  END IF;

  RAISE NOTICE 'PASS: canonical internal, customer-safe and importer-safe settlement projections agree.';
END $$;

ROLLBACK;
