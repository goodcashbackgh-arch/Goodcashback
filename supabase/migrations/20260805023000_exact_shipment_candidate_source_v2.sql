BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive exact shipment-candidate source only.
-- Does not replace the live shipper candidate RPC or shipment creation RPC.
-- Preserves upstream receipt/review and downstream shipment membership authorities.

CREATE OR REPLACE FUNCTION public.internal_shipper_shipment_batch_candidates_v2(
  p_shipper_id uuid DEFAULT NULL,
  p_order_id uuid DEFAULT NULL,
  p_tracking_submission_id uuid DEFAULT NULL
)
RETURNS TABLE (
  shipper_id uuid,
  importer_id uuid,
  order_id uuid,
  tracking_submission_id uuid,
  shipment_ready_qty numeric,
  shipment_ready_net_value_gbp numeric,
  ready_allocation_count integer,
  latest_receipt_status text,
  latest_receipt_recorded_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH positions AS (
    SELECT position.*
    FROM public.internal_tracking_allocation_fulfilment_routing_position_v2(
      p_order_id,
      p_tracking_submission_id,
      NULL
    ) position
    WHERE position.position_valid_yn
      AND position.shipment_ready_qty > 0
  ),
  ready AS (
    SELECT
      position.order_id,
      position.tracking_submission_id,
      SUM(position.shipment_ready_qty)::numeric AS shipment_ready_qty,
      SUM(
        ROUND(
          COALESCE(allocation.adjusted_net_value_gbp, 0)::numeric
          * position.shipment_ready_qty
          / NULLIF(allocation.qty_allocated, 0),
          2
        )
      )::numeric AS shipment_ready_net_value_gbp,
      COUNT(*)::integer AS ready_allocation_count
    FROM positions position
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = position.tracking_line_allocation_id
     AND allocation.order_id = position.order_id
     AND allocation.tracking_submission_id = position.tracking_submission_id
    GROUP BY position.order_id, position.tracking_submission_id
  )
  SELECT
    order_row.shipper_id,
    order_row.importer_id,
    ready.order_id,
    ready.tracking_submission_id,
    ready.shipment_ready_qty,
    ready.shipment_ready_net_value_gbp,
    ready.ready_allocation_count,
    latest_receipt.receipt_status::text,
    latest_receipt.recorded_at
  FROM ready
  JOIN public.orders order_row
    ON order_row.id = ready.order_id
  JOIN public.order_tracking_submissions tracking
    ON tracking.id = ready.tracking_submission_id
   AND tracking.order_id = ready.order_id
   AND tracking.superseded_at IS NULL
  JOIN LATERAL (
    SELECT receipt.receipt_status, receipt.recorded_at
    FROM public.shipper_package_receipts receipt
    WHERE receipt.tracking_submission_id = ready.tracking_submission_id
    ORDER BY receipt.created_at DESC, receipt.id DESC
    LIMIT 1
  ) latest_receipt ON true
  WHERE (p_shipper_id IS NULL OR order_row.shipper_id = p_shipper_id)
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_packages package_link
      WHERE package_link.tracking_submission_id = ready.tracking_submission_id
        AND package_link.active = true
    )
  ORDER BY ready.order_id, ready.tracking_submission_id;
$function$;

ALTER FUNCTION public.internal_shipper_shipment_batch_candidates_v2(uuid,uuid,uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.internal_shipper_shipment_batch_candidates_v2(uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.internal_shipper_shipment_batch_candidates_v2(uuid,uuid,uuid)
  TO service_role;

DO $postflight$
DECLARE
  v_live_candidate_md5 text;
  v_live_create_md5 text;
  v_review_candidate_md5 text;
  v_materialiser_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure))
  INTO v_live_candidate_md5;

  SELECT md5(pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure))
  INTO v_live_create_md5;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_candidates_v1(uuid)'::regprocedure))
  INTO v_review_candidate_md5;

  SELECT md5(pg_get_functiondef('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure))
  INTO v_materialiser_md5;

  IF v_live_candidate_md5 IS DISTINCT FROM '952f24084fed0dffcdebbfae988e7400'
     OR v_live_create_md5 IS DISTINCT FROM '4e4b86b0121a85523fe95c1530a41658'
     OR v_review_candidate_md5 IS DISTINCT FROM '80c5ca83374ed2ddaedeadd3b88dd95d'
     OR v_materialiser_md5 IS DISTINCT FROM '0293a94d4eb17daf9c7e48131cd75ca1'
  THEN
    RAISE EXCEPTION 'Protected live authority changed during additive exact shipment candidate source installation.';
  END IF;
END
$postflight$;

COMMIT;
