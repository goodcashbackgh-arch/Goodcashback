BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.internal_shipping_control_v2()') IS NOT NULL
     AND to_regprocedure('public.internal_shipping_control_v2_base_20260620()') IS NULL THEN
    ALTER FUNCTION public.internal_shipping_control_v2()
      RENAME TO internal_shipping_control_v2_base_20260620;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_shipping_control_v2()
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  batch_status text,
  shipment_cutoff_at timestamptz,
  dispatched_at timestamptz,
  box_count integer,
  created_at timestamptz,
  package_count bigint,
  order_count bigint,
  allocated_package_count bigint,
  unallocated_package_count bigint,
  item_qty numeric,
  receipt_issue_count bigint,
  package_refs_preview text,
  order_refs_preview text,
  receipt_status_summary text,
  allocation_status_summary text,
  shipper_invoice_status text,
  export_evidence_status text,
  master_shipment_status text,
  sage_readiness_status text,
  next_action text,
  groupage_movement_id uuid,
  groupage_movement_ref text,
  groupage_status text,
  groupage_export_pack_status text,
  groupage_pod_status text,
  grouped_yn boolean,
  groupage_batch_count bigint,
  groupage_completed_batch_count bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    b.shipment_batch_id,
    b.booking_ref,
    b.shipper_id,
    b.shipper_name,
    b.importer_id,
    b.importer_name,
    b.batch_status,
    b.shipment_cutoff_at,
    b.dispatched_at,
    b.box_count,
    b.created_at,
    b.package_count,
    b.order_count,
    b.allocated_package_count,
    b.unallocated_package_count,
    b.item_qty,
    b.receipt_issue_count,
    b.package_refs_preview,
    b.order_refs_preview,
    b.receipt_status_summary,
    b.allocation_status_summary,
    b.shipper_invoice_status,
    b.export_evidence_status,
    b.master_shipment_status,
    b.sage_readiness_status,
    CASE
      WHEN b.grouped_yn = true AND b.groupage_export_pack_status = 'submitted_for_review'
        THEN 'signed_export_pack_submitted'
      WHEN b.grouped_yn = true AND b.groupage_export_pack_status = 'accepted_current' AND COALESCE(b.groupage_pod_status, 'not_started') <> 'accepted_current'
        THEN 'pod_or_delivery_evidence_pending'
      WHEN b.grouped_yn = true AND b.groupage_export_pack_status = 'accepted_current' AND b.groupage_pod_status = 'accepted_current'
        THEN 'shipment_controls_complete'
      ELSE b.next_action
    END AS next_action,
    b.groupage_movement_id,
    b.groupage_movement_ref,
    b.groupage_status,
    b.groupage_export_pack_status,
    b.groupage_pod_status,
    b.grouped_yn,
    b.groupage_batch_count,
    b.groupage_completed_batch_count
  FROM public.internal_shipping_control_v2_base_20260620() b;
$$;

GRANT EXECUTE ON FUNCTION public.internal_shipping_control_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
