BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_order_id uuid := '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid;
  v_tracking_id uuid := 'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid;
  v_receipt_count integer;
BEGIN
  IF to_regprocedure('public.internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Exact customer-review bridge is not installed.';
  END IF;

  IF to_regprocedure('public.internal_shipper_shipment_batch_candidates_v2(uuid,uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Exact shipment candidate source v2 is not installed.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_receipt_count
  FROM public.shipper_package_receipts receipt
  WHERE receipt.tracking_submission_id = v_tracking_id
    AND receipt.receipt_model_version = 2
    AND receipt.receipt_state = 'finalised'
    AND receipt.finalised_at IS NOT NULL;

  IF v_receipt_count = 0 THEN
    RAISE EXCEPTION 'The grouped fixture does not have a finalised v2 package receipt.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_packages package_link
    WHERE package_link.tracking_submission_id = v_tracking_id
      AND package_link.active = true
  ) THEN
    RAISE EXCEPTION 'The grouped fixture is already linked to an active shipment batch.';
  END IF;

  PERFORM public.internal_bridge_exact_customer_review_candidates_v1(
    v_order_id,
    NULL
  );
END $$;

COMMIT;

SELECT jsonb_build_object(
  'probe', 'activate_existing_grouped_fixture_exact_shipment_v1',
  'order_id', source.order_id,
  'tracking_submission_id', source.tracking_submission_id,
  'shipment_ready_qty', source.shipment_ready_qty,
  'shipment_ready_net_value_gbp', source.shipment_ready_net_value_gbp,
  'latest_receipt_status', source.latest_receipt_status,
  'activated', source.shipment_ready_qty = 1
) AS result
FROM public.internal_shipper_shipment_batch_candidates_v2(
  NULL,
  '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
  'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid
) source;
