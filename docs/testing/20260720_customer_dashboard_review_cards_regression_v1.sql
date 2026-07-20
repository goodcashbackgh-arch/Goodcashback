BEGIN;

DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.customer_dashboard_review_cards_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: customer_dashboard_review_cards_v1() missing';
  END IF;

  SELECT pg_get_functiondef('public.customer_dashboard_review_cards_v1()'::regprocedure)
    INTO v_def;

  IF position('customer_active_order_review_link_v1' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: dashboard wrapper does not reuse the existing active review-link RPC';
  END IF;

  IF position('customer_order_has_review_ready_lines_v1' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: dashboard wrapper does not reuse existing review readiness';
  END IF;

  IF position('customer_order_review_links' in v_def) = 0
     OR position('expires_at' in v_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: dashboard wrapper does not return the existing review-link expiry';
  END IF;

  IF position('shipper_package_receipts' in v_def) > 0
     OR position('24 hours' in v_def) > 0
     OR position('customer_pre_shipment_hold_requests' in v_def) > 0
  THEN
    RAISE EXCEPTION 'FAIL: dashboard wrapper duplicates receipt, timer, or hold rules instead of delegating';
  END IF;
END $$;

SELECT 'PASS: customer order cards reuse the existing review path and existing expires_at deadline without duplicating receipt, hold, or shipment controls' AS regression_result;

ROLLBACK;
