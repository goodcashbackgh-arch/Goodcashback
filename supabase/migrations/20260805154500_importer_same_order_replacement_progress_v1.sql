BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.physical_replacement_same_order_routes') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.operators') IS NULL
     OR to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
  THEN
    RAISE EXCEPTION 'Importer replacement progress prerequisites are missing.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.importer_same_order_replacement_progress_v1(
  p_dispute_ids uuid[] DEFAULT NULL
)
RETURNS TABLE (
  dispute_id uuid,
  route_id uuid,
  route_status text,
  successor_tracking_submission_id uuid,
  successor_tracking_line_allocation_id uuid,
  latest_receipt_status text,
  active_shipment_booking_ref text,
  progress_status text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH caller AS (
    SELECT op.id AS operator_id
    FROM public.operators op
    WHERE op.auth_user_id = auth.uid()
      AND op.active = true
    ORDER BY op.created_at DESC, op.id DESC
    LIMIT 1
  )
  SELECT
    route.dispute_id,
    route.id AS route_id,
    route.route_status::text,
    route.successor_tracking_submission_id,
    route.successor_tracking_line_allocation_id,
    receipt.receipt_status::text AS latest_receipt_status,
    membership.booking_ref::text AS active_shipment_booking_ref,
    CASE
      WHEN route.route_status <> 'tracking_allocated'
        OR route.successor_tracking_submission_id IS NULL
        OR route.successor_tracking_line_allocation_id IS NULL
        THEN 'awaiting_successor_tracking'
      WHEN membership.booking_ref IS NOT NULL
        THEN 'added_to_shipment'
      WHEN receipt.receipt_status = 'received_clean'
        THEN 'shipment_eligible'
      ELSE 'awaiting_replacement_receipt'
    END::text AS progress_status
  FROM public.physical_replacement_same_order_routes route
  JOIN public.orders o ON o.id = route.order_id
  JOIN caller c ON c.operator_id = o.operator_id
  LEFT JOIN LATERAL (
    SELECT spr.receipt_status
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = route.successor_tracking_submission_id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1
  ) receipt ON true
  LEFT JOIN LATERAL (
    SELECT b.booking_ref
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.shipper_shipment_batches b ON b.id = m.shipment_batch_id
    WHERE m.tracking_line_allocation_id = route.successor_tracking_line_allocation_id
      AND m.active = true
    ORDER BY m.created_at DESC, m.id DESC
    LIMIT 1
  ) membership ON true
  WHERE p_dispute_ids IS NULL
     OR route.dispute_id = ANY(p_dispute_ids)
  ORDER BY route.created_at DESC, route.id DESC;
$function$;

REVOKE ALL ON FUNCTION public.importer_same_order_replacement_progress_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.importer_same_order_replacement_progress_v1(uuid[]) TO authenticated;

COMMENT ON FUNCTION public.importer_same_order_replacement_progress_v1(uuid[]) IS
'Read-only importer-scoped projection of same-order replacement tracking, latest package receipt and exact active shipment membership. Does not mutate route, receipt or shipment authorities.';

COMMIT;
