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
    COALESCE(SUM(el.adjusted_net_value_gbp), 0::numeric) AS shipment_net_value_gbp,
    COALESCE(string_agg(DISTINCT el.source_mode, ', ' ORDER BY el.source_mode), 'no_effective_lines')::text AS source_mode
  FROM public.shipper_shipment_batch_packages p
  JOIN public.shipper_shipment_batches b
    ON b.id = p.shipment_batch_id
   AND b.status <> 'voided'
  LEFT JOIN public.shipper_shipment_batch_effective_lines_v1(p_shipment_batch_id) el
    ON el.shipment_batch_package_id = p.id
  WHERE p.shipment_batch_id = p_shipment_batch_id
    AND p.active = true
  GROUP BY p.shipment_batch_id, p.id, p.tracking_submission_id, p.order_id, p.created_at
  ORDER BY p.created_at, p.id;
$$;

COMMENT ON FUNCTION public.shipper_shipment_batch_package_facts_v1(uuid) IS
'Canonical read-only package facts for shipment-facing views. Quantity/value derive only from effective shipment lines; package identity remains active package membership.';

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_package_facts_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_package_facts_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_summary_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  active_package_count bigint,
  shipment_order_count bigint,
  shipment_line_count bigint,
  shipment_qty numeric,
  shipment_net_value_gbp numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    p_shipment_batch_id,
    COUNT(*)::bigint,
    COUNT(DISTINCT f.order_id) FILTER (WHERE f.shipment_qty > 0)::bigint,
    COALESCE(SUM(f.shipment_line_count), 0)::bigint,
    COALESCE(SUM(f.shipment_qty), 0::numeric),
    COALESCE(SUM(f.shipment_net_value_gbp), 0::numeric)
  FROM public.shipper_shipment_batch_package_facts_v1(p_shipment_batch_id) f;
$$;

COMMENT ON FUNCTION public.shipper_shipment_batch_summary_v1(uuid) IS
'Canonical read-only batch facts for shipment-facing views, documents and controls. Does not determine status, readiness, permissions or next action.';

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_summary_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_summary_v1(uuid) TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.internal_shipping_control_v2()') IS NOT NULL
     AND to_regprocedure('public.internal_shipping_control_v2_base_20260723k()') IS NULL THEN
    ALTER FUNCTION public.internal_shipping_control_v2()
      RENAME TO internal_shipping_control_v2_base_20260723k;
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
    COALESCE(s.shipment_qty, 0::numeric),
    b.receipt_issue_count,
    b.package_refs_preview,
    b.order_refs_preview,
    b.receipt_status_summary,
    b.allocation_status_summary,
    b.shipper_invoice_status,
    b.export_evidence_status,
    b.master_shipment_status,
    b.sage_readiness_status,
    b.next_action,
    b.groupage_movement_id,
    b.groupage_movement_ref,
    b.groupage_status,
    b.groupage_export_pack_status,
    b.groupage_pod_status,
    b.grouped_yn,
    b.groupage_batch_count,
    b.groupage_completed_batch_count
  FROM public.internal_shipping_control_v2_base_20260723k() b
  LEFT JOIN LATERAL public.shipper_shipment_batch_summary_v1(b.shipment_batch_id) s ON true;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_control_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_control_v2() TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.shipper_shipping_document_worklist_v1()') IS NOT NULL
     AND to_regprocedure('public.shipper_shipping_document_worklist_v1_base_20260723k()') IS NULL THEN
    ALTER FUNCTION public.shipper_shipping_document_worklist_v1()
      RENAME TO shipper_shipping_document_worklist_v1_base_20260723k;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_shipping_document_worklist_v1()
RETURNS TABLE (
  shipper_user_id uuid,
  shipper_id uuid,
  shipper_name text,
  shipment_batch_id uuid,
  booking_ref text,
  batch_status text,
  importer_id uuid,
  importer_name text,
  dispatched_at timestamptz,
  package_count bigint,
  item_qty numeric,
  latest_document_id uuid,
  latest_document_kind text,
  latest_document_ref text,
  latest_document_date date,
  latest_currency_code text,
  latest_total_amount numeric,
  latest_file_url text,
  latest_ocr_status text,
  latest_review_status text,
  latest_version_no integer,
  open_resubmission_request_count bigint,
  can_upload_or_replace boolean,
  requires_resubmission_request boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    w.shipper_user_id,
    w.shipper_id,
    w.shipper_name,
    w.shipment_batch_id,
    w.booking_ref,
    w.batch_status,
    w.importer_id,
    w.importer_name,
    w.dispatched_at,
    w.package_count,
    COALESCE(s.shipment_qty, 0::numeric),
    w.latest_document_id,
    w.latest_document_kind,
    w.latest_document_ref,
    w.latest_document_date,
    w.latest_currency_code,
    w.latest_total_amount,
    w.latest_file_url,
    w.latest_ocr_status,
    w.latest_review_status,
    w.latest_version_no,
    w.open_resubmission_request_count,
    w.can_upload_or_replace,
    w.requires_resubmission_request
  FROM public.shipper_shipping_document_worklist_v1_base_20260723k() w
  LEFT JOIN LATERAL public.shipper_shipment_batch_summary_v1(w.shipment_batch_id) s ON true;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipping_document_worklist_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipping_document_worklist_v1() TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.internal_shipping_batch_detail_v1(uuid)') IS NOT NULL
     AND to_regprocedure('public.internal_shipping_batch_detail_v1_base_20260723k(uuid)') IS NULL THEN
    ALTER FUNCTION public.internal_shipping_batch_detail_v1(uuid)
      RENAME TO internal_shipping_batch_detail_v1_base_20260723k;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_shipping_batch_detail_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  batch_status text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  shipment_cutoff_at timestamptz,
  dispatched_at timestamptz,
  box_count integer,
  batch_notes text,
  package_link_id uuid,
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  tracking_date date,
  tracking_evidence_url text,
  allocated_qty numeric,
  allocation_status_summary text,
  latest_receipt_status text,
  latest_receipt_note text,
  latest_receipt_evidence_url text,
  latest_receipt_recorded_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    d.shipment_batch_id,
    d.booking_ref,
    d.batch_status,
    d.shipper_id,
    d.shipper_name,
    d.importer_id,
    d.importer_name,
    d.shipment_cutoff_at,
    d.dispatched_at,
    d.box_count,
    d.batch_notes,
    d.package_link_id,
    d.tracking_submission_id,
    d.order_id,
    d.order_ref,
    d.retailer_name,
    d.courier_name,
    d.tracking_ref,
    d.tracking_date,
    d.tracking_evidence_url,
    COALESCE(f.shipment_qty, 0::numeric),
    d.allocation_status_summary,
    d.latest_receipt_status,
    d.latest_receipt_note,
    d.latest_receipt_evidence_url,
    d.latest_receipt_recorded_at
  FROM public.internal_shipping_batch_detail_v1_base_20260723k(p_shipment_batch_id) d
  LEFT JOIN public.shipper_shipment_batch_package_facts_v1(p_shipment_batch_id) f
    ON f.shipment_batch_package_id = d.package_link_id;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_batch_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_batch_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
