BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite table missing: shipper_shipment_batch_line_memberships';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_effective_lines_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  shipment_batch_package_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  order_id uuid,
  supplier_invoice_line_id uuid,
  qty_in_shipment numeric,
  adjusted_net_value_gbp numeric,
  source_mode text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH valid_batch AS (
    SELECT b.id
    FROM public.shipper_shipment_batches b
    WHERE b.id = p_shipment_batch_id
      AND b.status <> 'voided'
  ), snapshot_exists AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_line_memberships m
      JOIN public.shipper_shipment_batch_packages p
        ON p.id = m.shipment_batch_package_id
       AND p.shipment_batch_id = m.shipment_batch_id
      JOIN valid_batch vb ON vb.id = m.shipment_batch_id
      WHERE m.shipment_batch_id = p_shipment_batch_id
        AND p.active = true
    ) AS yes
  ), snapshot_lines AS (
    SELECT
      m.shipment_batch_id,
      m.shipment_batch_package_id,
      m.tracking_submission_id,
      m.tracking_line_allocation_id,
      m.order_id,
      m.supplier_invoice_line_id,
      m.qty_in_shipment,
      m.adjusted_net_value_gbp,
      'immutable_snapshot'::text AS source_mode
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.shipper_shipment_batch_packages p
      ON p.id = m.shipment_batch_package_id
     AND p.shipment_batch_id = m.shipment_batch_id
     AND p.tracking_submission_id = m.tracking_submission_id
     AND p.order_id = m.order_id
    JOIN valid_batch vb ON vb.id = m.shipment_batch_id
    WHERE m.shipment_batch_id = p_shipment_batch_id
      AND m.active = true
      AND p.active = true
  ), legacy_lines AS (
    SELECT
      p.shipment_batch_id,
      p.id AS shipment_batch_package_id,
      p.tracking_submission_id,
      a.id AS tracking_line_allocation_id,
      a.order_id,
      a.supplier_invoice_line_id,
      COALESCE(a.qty_allocated, 0)::numeric AS qty_in_shipment,
      COALESCE(a.adjusted_net_value_gbp, 0)::numeric AS adjusted_net_value_gbp,
      'legacy_package_fallback'::text AS source_mode
    FROM public.shipper_shipment_batch_packages p
    JOIN valid_batch vb ON vb.id = p.shipment_batch_id
    JOIN public.order_tracking_line_allocations a
      ON a.tracking_submission_id = p.tracking_submission_id
     AND a.order_id = p.order_id
    CROSS JOIN snapshot_exists se
    WHERE p.shipment_batch_id = p_shipment_batch_id
      AND p.active = true
      AND se.yes = false
      AND COALESCE(a.qty_allocated, 0) > 0
  )
  SELECT * FROM snapshot_lines
  UNION ALL
  SELECT * FROM legacy_lines;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_effective_lines_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_effective_lines_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
