BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive exact shipment-eligible contents reader.
-- Before batching it reads exact routing positions; after batching it reads the
-- immutable July shipment membership snapshot. It does not alter v1.

CREATE OR REPLACE FUNCTION public.shipper_package_contents_preview_v2(
  p_tracking_submission_id uuid DEFAULT NULL
)
RETURNS TABLE (
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  allocation_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: exact package contents preview requires auth.uid()';
  END IF;

  SELECT shipper_user.shipper_id
  INTO v_shipper_id
  FROM public.shipper_users shipper_user
  WHERE shipper_user.auth_user_id = v_auth_uid
    AND shipper_user.active = true
  ORDER BY shipper_user.created_at DESC, shipper_user.id DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  WITH active_package AS (
    SELECT DISTINCT ON (package_link.tracking_submission_id)
      package_link.id AS package_id,
      package_link.shipment_batch_id,
      package_link.tracking_submission_id,
      package_link.order_id
    FROM public.shipper_shipment_batch_packages package_link
    JOIN public.shipper_shipment_batches batch
      ON batch.id = package_link.shipment_batch_id
    WHERE package_link.active = true
      AND batch.status <> 'voided'
      AND (p_tracking_submission_id IS NULL
        OR package_link.tracking_submission_id = p_tracking_submission_id)
    ORDER BY package_link.tracking_submission_id,
             package_link.created_at DESC,
             package_link.id DESC
  ),
  exact_pre_batch AS (
    SELECT
      position.tracking_submission_id,
      position.order_id,
      position.tracking_line_allocation_id,
      position.supplier_invoice_line_id,
      position.shipment_ready_qty::numeric AS qty_allocated,
      allocation.allocation_status::text AS allocation_status
    FROM public.internal_tracking_allocation_fulfilment_routing_position_v2(
      NULL,
      p_tracking_submission_id,
      NULL
    ) position
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = position.tracking_line_allocation_id
    LEFT JOIN active_package package_link
      ON package_link.tracking_submission_id = position.tracking_submission_id
    WHERE package_link.package_id IS NULL
      AND position.position_valid_yn
      AND position.shipment_ready_qty > 0
  ),
  exact_batched AS (
    SELECT
      membership.tracking_submission_id,
      membership.order_id,
      membership.tracking_line_allocation_id,
      membership.supplier_invoice_line_id,
      membership.qty_in_shipment::numeric AS qty_allocated,
      allocation.allocation_status::text AS allocation_status
    FROM active_package package_link
    JOIN public.shipper_shipment_batch_line_memberships membership
      ON membership.shipment_batch_package_id = package_link.package_id
     AND membership.active = true
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = membership.tracking_line_allocation_id
  ),
  exact_scope AS (
    SELECT * FROM exact_pre_batch
    UNION ALL
    SELECT * FROM exact_batched
  )
  SELECT
    tracking.id,
    order_row.id,
    order_row.order_ref::text,
    retailer.name::text,
    courier.name::text,
    tracking.tracking_ref::text,
    invoice_line.id,
    COALESCE(NULLIF(btrim(invoice_line.description), ''), 'Unlabelled item')::text,
    exact_scope.qty_allocated,
    exact_scope.allocation_status
  FROM exact_scope
  JOIN public.order_tracking_submissions tracking
    ON tracking.id = exact_scope.tracking_submission_id
   AND tracking.order_id = exact_scope.order_id
   AND tracking.superseded_at IS NULL
  JOIN public.orders order_row
    ON order_row.id = exact_scope.order_id
   AND order_row.shipper_id = v_shipper_id
  LEFT JOIN public.retailers retailer
    ON retailer.id = order_row.retailer_id
  LEFT JOIN public.couriers courier
    ON courier.id = tracking.courier_id
  JOIN public.supplier_invoice_lines invoice_line
    ON invoice_line.id = exact_scope.supplier_invoice_line_id
  ORDER BY order_row.order_ref NULLS LAST,
           tracking.tracking_date NULLS LAST,
           invoice_line.line_order NULLS LAST,
           invoice_line.description,
           exact_scope.tracking_line_allocation_id;
END;
$function$;

ALTER FUNCTION public.shipper_package_contents_preview_v2(uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.shipper_package_contents_preview_v2(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.shipper_package_contents_preview_v2(uuid)
  TO authenticated;

DO $postflight$
DECLARE
  v_preview_v1_md5 text;
  v_candidate_v1_md5 text;
  v_create_v1_md5 text;
  v_position_v1_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.shipper_package_contents_preview_v1(uuid)'::regprocedure))
  INTO v_preview_v1_md5;
  SELECT md5(pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure))
  INTO v_candidate_v1_md5;
  SELECT md5(pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure))
  INTO v_create_v1_md5;
  SELECT md5(pg_get_functiondef('public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::regprocedure))
  INTO v_position_v1_md5;

  IF v_preview_v1_md5 IS DISTINCT FROM 'a312af874648f50547270c2fcb7f7c6d'
     OR v_candidate_v1_md5 IS DISTINCT FROM '952f24084fed0dffcdebbfae988e7400'
     OR v_create_v1_md5 IS DISTINCT FROM '4e4b86b0121a85523fe95c1530a41658'
     OR v_position_v1_md5 IS DISTINCT FROM 'ae13557433f5e8500985b00266347807'
  THEN
    RAISE EXCEPTION 'Protected shipment authority changed during exact package preview installation.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
