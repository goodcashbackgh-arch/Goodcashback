BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: shipper_shipment_batch_effective_lines_v1(uuid)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_package_facts_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  shipment_batch_package_id uuid,
  tracking_submission_id uuid,
  order_id uuid,
  shipment_line_count bigint,
  shipment_qty numeric,
  shipment_net_value_gbp numeric,
  source_mode text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    p.shipment_batch_id,
    p.id AS shipment_batch_package_id,
    p.tracking_submission_id,
    p.order_id,
    COUNT(el.tracking_line_allocation_id)::bigint AS shipment_line_count,
    COALESCE(SUM(el.qty_in_shipment), 0::numeric) AS shipment_qty,
    COALES