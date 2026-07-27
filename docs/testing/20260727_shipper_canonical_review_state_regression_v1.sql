-- Transaction-based, read-only regression for the shipper canonical review gate.
BEGIN;

SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_helper text;
  v_candidates text;
  v_create text;
  v_dashboard text;
  v_controlled_count integer;
  v_controlled_active_count integer;
BEGIN
  SELECT pg_get_functiondef('public.shipper_tracking_review_state_v1(uuid,uuid)'::regprocedure) INTO v_helper;
  SELECT pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure) INTO v_candidates;
  SELECT pg_get_functiondef(
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  ) INTO v_create;
  SELECT pg_get_functiondef('public.shipper_package_receipt_dashboard_v1()'::regprocedure) INTO v_dashboard;

  IF v_helper NOT LIKE '%review_link.order_id = p_order_id%'
     OR v_helper NOT LIKE '%membership.tracking_submission_id = p_tracking_submission_id%'
     OR v_helper NOT LIKE '%membership.review_link_id = review_link.id%'
     OR v_helper NOT LIKE '%membership.membership_status = ''active''%'
     OR v_helper NOT LIKE '%review_link.is_active = true%'
     OR v_helper NOT LIKE '%review_link.expires_at IS NOT NULL%'
     OR v_helper NOT LIKE '%review_link.expires_at > now()%'
  THEN
    RAISE EXCEPTION 'FAIL: canonical helper does not prove the complete exact durable review state';
  END IF;

  IF v_helper ~* 'shipper_package_receipts|recorded_at[[:space:]]*\\+[[:space:]]*interval' THEN
    RAISE EXCEPTION 'FAIL: canonical helper contains receipt-derived review state';
  END IF;

  IF v_candidates NOT LIKE '%shipper_tracking_review_state_v1(o.id, ots.id)%'
     OR v_candidates NOT LIKE '%NOT review_state.active_review_yn%'
     OR v_create NOT LIKE '%shipper_tracking_review_state_v1(v_order_id, v_tracking_id)%'
  THEN
    RAISE EXCEPTION 'FAIL: candidate and direct-create routes do not share the canonical helper';
  END IF;

  IF v_candidates ~* 'recorded_at[[:space:]]*\\+[[:space:]]*interval[[:space:]]*''24 hours'''
     OR v_create ~* 'recorded_at[[:space:]]*\\+[[:space:]]*interval[[:space:]]*''24 hours'''
  THEN
    RAISE EXCEPTION 'FAIL: a shipper database gate still derives review state from receipt time';
  END IF;

  IF v_candidates NOT LIKE '%customer_line_has_active_hold_conflict_v1%'
     OR v_create NOT LIKE '%customer_line_has_active_hold_conflict_v1%'
     OR v_candidates NOT LIKE '%existing_link.active = true%'
     OR v_create NOT LIKE '%p.tracking_submission_id = v_tracking_id AND p.active = true%'
  THEN
    RAISE EXCEPTION 'FAIL: existing hold or active-shipment blockers were not preserved';
  END IF;

  IF v_dashboard LIKE '%customer_order_review_links%'
     OR v_dashboard LIKE '%customer_review_cycle_memberships%'
  THEN
    RAISE EXCEPTION 'FAIL: receipt dashboard was broadened instead of preserved';
  END IF;

  SELECT count(*), count(*) FILTER (WHERE canonical.active_review_yn)
  INTO v_controlled_count, v_controlled_active_count
  FROM (
    SELECT
      package.tracking_ref,
      EXISTS (
        SELECT 1
        FROM public.customer_order_review_links review_link
        JOIN public.customer_review_cycle_memberships membership
          ON membership.review_link_id = review_link.id
         AND membership.order_id = package.order_id
         AND membership.tracking_submission_id = package.tracking_submission_id
         AND membership.membership_status = 'active'
        WHERE review_link.order_id = package.order_id
          AND review_link.is_active = true
          AND review_link.expires_at IS NOT NULL
          AND review_link.expires_at > now()
      ) AS active_review_yn
    FROM public.orders order_row
    JOIN public.order_tracking_submissions package ON package.order_id = order_row.id
    WHERE order_row.order_ref = 'ORD-1784976429191'
      AND package.tracking_ref IN ('DPD240726', 'DHL240726A')
  ) canonical;

  IF v_controlled_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: controlled packages were not both found (found %)', v_controlled_count;
  END IF;
  IF v_controlled_active_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: controlled packages still have active canonical review state';
  END IF;
END $$;

-- Readers must not mutate review, receipt, shipment, or protected commercial state.
WITH protected_counts AS (
  SELECT jsonb_build_object(
    'receipts', (SELECT count(*) FROM public.shipper_package_receipts),
    'review_links', (SELECT count(*) FROM public.customer_order_review_links),
    'review_memberships', (SELECT count(*) FROM public.customer_review_cycle_memberships),
    'shipment_batches', (SELECT count(*) FROM public.shipper_shipment_batches),
    'shipment_memberships', (SELECT count(*) FROM public.shipper_shipment_batch_packages),
    'customer_sales_invoices', (SELECT count(*) FROM public.sales_invoices),
    'refund_disputes', (SELECT count(*) FROM public.disputes WHERE desired_outcome = 'refund')
  ) AS counts
)
SELECT 'PASS: canonical shipper review state and protected-route checks' AS regression_result, counts
FROM protected_counts;

ROLLBACK;
