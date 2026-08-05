BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive authenticated shipper-facing exact candidate RPC.
-- The live v1 candidate and shipment-creation RPCs remain unchanged.

CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_candidates_v2()
RETURNS TABLE (
  shipper_user_id uuid,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  order_id uuid,
  order_ref text,
  retailer_name text,
  tracking_submission_id uuid,
  courier_name text,
  tracking_ref text,
  tracking_date text,
  allocated_qty numeric,
  allocated_net_value_gbp numeric,
  latest_receipt_status text,
  latest_receipt_recorded_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: exact shipment batch candidates require auth.uid()';
  END IF;

  SELECT shipper_user.id, shipper_user.shipper_id
  INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users shipper_user
  WHERE shipper_user.auth_user_id = v_auth_uid
    AND shipper_user.active = true
  ORDER BY shipper_user.created_at DESC, shipper_user.id DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    v_shipper_user_id,
    shipper.id,
    shipper.name::text,
    source.importer_id,
    COALESCE(NULLIF(importer.trading_name, ''), importer.company_name)::text,
    source.order_id,
    order_row.order_ref::text,
    retailer.name::text,
    source.tracking_submission_id,
    courier.name::text,
    tracking.tracking_ref::text,
    tracking.tracking_date::text,
    source.shipment_ready_qty AS allocated_qty,
    source.shipment_ready_net_value_gbp AS allocated_net_value_gbp,
    source.latest_receipt_status,
    source.latest_receipt_recorded_at
  FROM public.internal_shipper_shipment_batch_candidates_v2(
    v_shipper_id,
    NULL,
    NULL
  ) source
  JOIN public.shippers shipper
    ON shipper.id = source.shipper_id
  JOIN public.orders order_row
    ON order_row.id = source.order_id
  JOIN public.order_tracking_submissions tracking
    ON tracking.id = source.tracking_submission_id
   AND tracking.order_id = source.order_id
   AND tracking.superseded_at IS NULL
  LEFT JOIN public.importers importer
    ON importer.id = source.importer_id
  LEFT JOIN public.retailers retailer
    ON retailer.id = order_row.retailer_id
  LEFT JOIN public.couriers courier
    ON courier.id = tracking.courier_id
  ORDER BY importer.company_name NULLS LAST,
           order_row.created_at DESC,
           tracking.tracking_date DESC NULLS LAST,
           tracking.id;
END;
$function$;

ALTER FUNCTION public.shipper_shipment_batch_candidates_v2()
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_candidates_v2()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_candidates_v2()
  TO authenticated;

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
    RAISE EXCEPTION 'Protected authority changed during additive shipper candidate v2 installation.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
