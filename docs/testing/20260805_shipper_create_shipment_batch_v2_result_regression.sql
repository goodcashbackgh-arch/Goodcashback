BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE exact_shipment_v2_regression_result (
  result jsonb NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
  v_order_id uuid := '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid;
  v_tracking_id uuid := 'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid;
  v_clean_allocation_id uuid := '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid;
  v_importer_id uuid;
  v_auth_user_id uuid;
  v_batch_id uuid;
  v_package_id uuid;
  v_ready_qty numeric;
  v_membership_qty numeric;
  v_membership_count integer;
  v_clean_membership_count integer;
  v_nonclean_membership_count integer;
  v_candidate_present_after boolean;
BEGIN
  SELECT o.importer_id, su.auth_user_id
  INTO STRICT v_importer_id, v_auth_user_id
  FROM public.orders o
  JOIN public.shipper_users su
    ON su.shipper_id = o.shipper_id
   AND su.active = true
  WHERE o.id = v_order_id
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::text, true);

  PERFORM public.internal_bridge_exact_customer_review_candidates_v1(v_order_id, NULL);

  SELECT c.shipment_ready_qty
  INTO STRICT v_ready_qty
  FROM public.internal_shipper_shipment_batch_candidates_v2(NULL, v_order_id, v_tracking_id) c;

  IF v_ready_qty <> 1 THEN
    RAISE EXCEPTION 'FAIL pre-create: expected exact shipment-ready qty 1, got %', v_ready_qty;
  END IF;

  v_batch_id := public.shipper_create_shipment_batch_v2(
    v_importer_id,
    ARRAY[v_tracking_id],
    'REG-EXACT-SHIPMENT-V2-RESULT'
  );

  SELECT p.id
  INTO STRICT v_package_id
  FROM public.shipper_shipment_batch_packages p
  WHERE p.shipment_batch_id = v_batch_id
    AND p.tracking_submission_id = v_tracking_id
    AND p.active = true;

  SELECT
    COUNT(*)::integer,
    COALESCE(SUM(m.qty_in_shipment), 0),
    COUNT(*) FILTER (
      WHERE m.tracking_line_allocation_id = v_clean_allocation_id
    )::integer,
    COUNT(*) FILTER (
      WHERE m.tracking_line_allocation_id <> v_clean_allocation_id
    )::integer
  INTO
    v_membership_count,
    v_membership_qty,
    v_clean_membership_count,
    v_nonclean_membership_count
  FROM public.shipper_shipment_batch_line_memberships m
  WHERE m.shipment_batch_package_id = v_package_id;

  IF v_membership_count <> 1
     OR v_membership_qty <> 1
     OR v_clean_membership_count <> 1
     OR v_nonclean_membership_count <> 0
  THEN
    RAISE EXCEPTION
      'FAIL memberships: count %, qty %, clean %, nonclean %',
      v_membership_count,
      v_membership_qty,
      v_clean_membership_count,
      v_nonclean_membership_count;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.internal_shipper_shipment_batch_candidates_v2(NULL, v_order_id, v_tracking_id)
  )
  INTO v_candidate_present_after;

  IF v_candidate_present_after THEN
    RAISE EXCEPTION 'FAIL post-create: package still appears as shipment candidate';
  END IF;

  INSERT INTO exact_shipment_v2_regression_result(result)
  VALUES (
    jsonb_build_object(
      'probe', 'shipper_create_shipment_batch_v2_result_regression',
      'passed', true,
      'pre_create_shipment_ready_qty', v_ready_qty,
      'membership_count', v_membership_count,
      'membership_qty', v_membership_qty,
      'clean_membership_count', v_clean_membership_count,
      'diverted_membership_count', v_nonclean_membership_count,
      'candidate_present_after_create', v_candidate_present_after,
      'writes_rolled_back_after_result', true
    )
  );
END $$;

SELECT result
FROM exact_shipment_v2_regression_result;

ROLLBACK;
