BEGIN;

-- Narrow status correction:
-- 1. Keep AP/Sage readiness separate from final export/POD evidence.
-- 2. Once shipper invoice and apportionment are approved, do not keep saying
--    "ready for Sage/AP readiness review" if POD/final delivery evidence is still outstanding.
-- 3. Expose shipper-facing progress statuses without exposing amounts/coding/margins.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.shipper_final_export_evidence_documents'::regclass
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%document_kind%'
  LOOP
    EXECUTE format('ALTER TABLE public.shipper_final_export_evidence_documents DROP CONSTRAINT IF EXISTS %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE public.shipper_final_export_evidence_documents
  ADD CONSTRAINT shipper_final_export_evidence_documents_document_kind_check
  CHECK (document_kind IN (
    'completed_cos',
    'final_eep_packing_list',
    'mbl_bol_sea_waybill',
    'container_seal_evidence',
    'export_date_departure_evidence',
    'pod_delivery_evidence',
    'other_final_export_evidence'
  ));

CREATE OR REPLACE FUNCTION public.internal_shipping_control_v1()
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
  next_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipping control requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal shipping control.';
  END IF;

  RETURN QUERY
  WITH package_scope AS (
    SELECT
      b.id AS shipment_batch_id,
      p.id AS package_link_id,
      p.tracking_submission_id,
      p.order_id,
      o.order_ref::text AS order_ref,
      ots.tracking_ref::text AS tracking_ref,
      COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
      latest_receipt.receipt_status::text AS latest_receipt_status
    FROM public.shipper_shipment_batches b
    LEFT JOIN public.shipper_shipment_batch_packages p
      ON p.shipment_batch_id = b.id
     AND p.active = true
    LEFT JOIN public.orders o
      ON o.id = p.order_id
    LEFT JOIN public.order_tracking_submissions ots
      ON ots.id = p.tracking_submission_id
    LEFT JOIN LATERAL (
      SELECT SUM(otla.qty_allocated) AS allocated_qty
      FROM public.order_tracking_line_allocations otla
      WHERE otla.tracking_submission_id = p.tracking_submission_id
    ) alloc ON p.tracking_submission_id IS NOT NULL
    LEFT JOIN LATERAL (
      SELECT spr.receipt_status
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = p.tracking_submission_id
      ORDER BY spr.created_at DESC
      LIMIT 1
    ) latest_receipt ON p.tracking_submission_id IS NOT NULL
  ), latest_docs AS (
    SELECT DISTINCT ON (sd.shipment_batch_id)
      sd.id AS shipping_document_id,
      sd.shipment_batch_id,
      sd.review_status,
      sd.ocr_status
    FROM public.shipping_documents sd
    WHERE sd.active = true
    ORDER BY sd.shipment_batch_id, sd.created_at DESC
  ), final_export_evidence AS (
    SELECT
      d.shipment_batch_id,
      bool_or(d.review_status = 'accepted_current') AS has_accepted_current,
      bool_or(d.review_status = 'submitted_for_review') AS has_submitted_for_review,
      bool_or(d.review_status = 'rejected_resubmit_required') AS has_rejected_resubmit_required,
      bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'accepted_current') AS has_pod_accepted_current,
      bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') AS has_pod_submitted_for_review,
      count(*) AS document_count
    FROM public.shipper_final_export_evidence_documents d
    GROUP BY d.shipment_batch_id
  ), active_apportionment AS (
    SELECT
      sca.shipping_document_id,
      sca.shipment_batch_id,
      sca.allocation_status
    FROM public.shipping_cost_allocations sca
    WHERE sca.active = true
  )
  SELECT
    b.id AS shipment_batch_id,
    b.booking_ref::text,
    b.shipper_id,
    s.name::text AS shipper_name,
    b.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    b.status::text AS batch_status,
    b.shipment_cutoff_at,
    b.dispatched_at,
    b.box_count,
    b.created_at,
    COUNT(ps.package_link_id)::bigint AS package_count,
    COUNT(DISTINCT ps.order_id)::bigint AS order_count,
    COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) > 0)::bigint AS allocated_package_count,
    COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) = 0)::bigint AS unallocated_package_count,
    COALESCE(SUM(ps.allocated_qty), 0::numeric) AS item_qty,
    COUNT(ps.package_link_id) FILTER (WHERE ps.latest_receipt_status IN ('received_damaged','held_query','not_received'))::bigint AS receipt_issue_count,
    string_agg(DISTINCT ps.tracking_ref, ', ' ORDER BY ps.tracking_ref) FILTER (WHERE ps.tracking_ref IS NOT NULL)::text AS package_refs_preview,
    string_agg(DISTINCT ps.order_ref, ', ' ORDER BY ps.order_ref) FILTER (WHERE ps.order_ref IS NOT NULL)::text AS order_refs_preview,
    CASE
      WHEN COUNT(ps.package_link_id) = 0 THEN 'no_packages'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE ps.latest_receipt_status IN ('received_damaged','held_query','not_received')) > 0 THEN 'receipt_issue'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE ps.latest_receipt_status = 'received_clean') = COUNT(ps.package_link_id) THEN 'received_clean'
      ELSE 'mixed_or_missing_receipt'
    END::text AS receipt_status_summary,
    CASE
      WHEN COUNT(ps.package_link_id) = 0 THEN 'no_packages'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) = 0) > 0 THEN 'allocation_missing'
      ELSE 'contents_allocated'
    END::text AS allocation_status_summary,
    CASE
      WHEN ld.shipment_batch_id IS NULL THEN 'not_started'
      WHEN ld.review_status = 'accepted_current' THEN 'accepted_current'
      WHEN ld.review_status = 'uploaded_pending_ocr' THEN 'uploaded_pending_ocr'
      WHEN ld.ocr_status IN ('queued','processing') THEN ld.ocr_status
      WHEN ld.review_status IS NOT NULL THEN ld.review_status
      ELSE 'uploaded_pending_ocr'
    END::text AS shipper_invoice_status,
    CASE
      WHEN COALESCE(fee.has_pod_accepted_current, false) THEN 'pod_delivery_evidence_accepted'
      WHEN COALESCE(fee.has_pod_submitted_for_review, false) THEN 'pod_delivery_evidence_submitted_for_review'
      WHEN COALESCE(fee.has_accepted_current, false) THEN 'accepted_current'
      WHEN COALESCE(fee.has_submitted_for_review, false) THEN 'submitted_for_review'
      WHEN COALESCE(fee.has_rejected_resubmit_required, false) THEN 'rejected_resubmit_required'
      WHEN COALESCE(fee.document_count, 0) > 0 THEN 'uploaded_pending_review'
      ELSE 'not_started'
    END::text AS export_evidence_status,
    'not_applicable'::text AS master_shipment_status,
    CASE
      WHEN aa.allocation_status = 'approved' THEN 'shipping_apportionment_approved'
      WHEN ld.review_status = 'accepted_current' THEN 'shipping_apportionment_pending'
      ELSE 'not_ready'
    END::text AS sage_readiness_status,
    CASE
      WHEN b.status = 'voided' THEN 'voided_no_action'
      WHEN COUNT(ps.package_link_id) = 0 THEN 'check_empty_batch'
      WHEN COUNT(ps.package_link_id) FILTER (WHERE COALESCE(ps.allocated_qty, 0) = 0) > 0 THEN 'operator_supervisor_allocation_needed'
      WHEN ld.shipment_batch_id IS NULL THEN 'shipper_invoice_or_export_review_needed'
      WHEN ld.review_status <> 'accepted_current' THEN 'shipping_document_uploaded_needs_supervisor_processing'
      WHEN aa.allocation_status IS DISTINCT FROM 'approved' THEN 'shipping_apportionment_pending'
      WHEN NOT COALESCE(fee.has_accepted_current, false) THEN 'final_export_evidence_upload_or_review_needed'
      WHEN NOT COALESCE(fee.has_pod_accepted_current, false) THEN 'pod_or_delivery_evidence_pending'
      ELSE 'shipment_controls_complete'
    END::text AS next_action
  FROM public.shipper_shipment_batches b
  JOIN public.shippers s ON s.id = b.shipper_id
  LEFT JOIN public.importers i ON i.id = b.importer_id
  LEFT JOIN package_scope ps ON ps.shipment_batch_id = b.id
  LEFT JOIN latest_docs ld ON ld.shipment_batch_id = b.id
  LEFT JOIN final_export_evidence fee ON fee.shipment_batch_id = b.id
  LEFT JOIN active_apportionment aa ON aa.shipping_document_id = ld.shipping_document_id
  GROUP BY b.id, b.booking_ref, b.shipper_id, s.name, b.importer_id, i.trading_name, i.company_name,
           b.status, b.shipment_cutoff_at, b.dispatched_at, b.box_count, b.created_at,
           ld.shipment_batch_id, ld.review_status, ld.ocr_status, ld.shipping_document_id,
           fee.has_accepted_current, fee.has_submitted_for_review, fee.has_rejected_resubmit_required,
           fee.has_pod_accepted_current, fee.has_pod_submitted_for_review, fee.document_count,
           aa.allocation_status
  ORDER BY b.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_control_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_control_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_progress_v1()
RETURNS TABLE (
  shipment_batch_id uuid,
  shipper_invoice_status text,
  export_evidence_status text,
  sage_readiness_status text,
  next_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper shipment progress requires auth.uid()';
  END IF;

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  WITH latest_docs AS (
    SELECT DISTINCT ON (sd.shipment_batch_id)
      sd.id AS shipping_document_id,
      sd.shipment_batch_id,
      sd.review_status,
      sd.ocr_status
    FROM public.shipping_documents sd
    WHERE sd.active = true
      AND sd.shipper_id = v_shipper_id
    ORDER BY sd.shipment_batch_id, sd.created_at DESC
  ), final_export_evidence AS (
    SELECT
      d.shipment_batch_id,
      bool_or(d.review_status = 'accepted_current') AS has_accepted_current,
      bool_or(d.review_status = 'submitted_for_review') AS has_submitted_for_review,
      bool_or(d.review_status = 'rejected_resubmit_required') AS has_rejected_resubmit_required,
      bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'accepted_current') AS has_pod_accepted_current,
      bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') AS has_pod_submitted_for_review,
      count(*) AS document_count
    FROM public.shipper_final_export_evidence_documents d
    WHERE d.shipper_id = v_shipper_id
    GROUP BY d.shipment_batch_id
  ), active_apportionment AS (
    SELECT
      sca.shipping_document_id,
      sca.shipment_batch_id,
      sca.allocation_status
    FROM public.shipping_cost_allocations sca
    WHERE sca.active = true
  )
  SELECT
    b.id AS shipment_batch_id,
    CASE
      WHEN ld.shipment_batch_id IS NULL THEN 'not_started'
      WHEN ld.review_status = 'accepted_current' THEN 'accepted_current'
      WHEN ld.review_status = 'uploaded_pending_ocr' THEN 'uploaded_pending_ocr'
      WHEN ld.ocr_status IN ('queued','processing') THEN ld.ocr_status
      WHEN ld.review_status IS NOT NULL THEN ld.review_status
      ELSE 'uploaded_pending_ocr'
    END::text AS shipper_invoice_status,
    CASE
      WHEN COALESCE(fee.has_pod_accepted_current, false) THEN 'pod_delivery_evidence_accepted'
      WHEN COALESCE(fee.has_pod_submitted_for_review, false) THEN 'pod_delivery_evidence_submitted_for_review'
      WHEN COALESCE(fee.has_accepted_current, false) THEN 'accepted_current'
      WHEN COALESCE(fee.has_submitted_for_review, false) THEN 'submitted_for_review'
      WHEN COALESCE(fee.has_rejected_resubmit_required, false) THEN 'rejected_resubmit_required'
      WHEN COALESCE(fee.document_count, 0) > 0 THEN 'uploaded_pending_review'
      ELSE 'not_started'
    END::text AS export_evidence_status,
    CASE
      WHEN aa.allocation_status = 'approved' THEN 'shipping_apportionment_approved'
      WHEN ld.review_status = 'accepted_current' THEN 'shipping_apportionment_pending'
      ELSE 'not_ready'
    END::text AS sage_readiness_status,
    CASE
      WHEN b.status = 'voided' THEN 'voided_no_action'
      WHEN ld.shipment_batch_id IS NULL THEN 'upload_shipping_charge_document'
      WHEN ld.review_status <> 'accepted_current' THEN 'awaiting_supervisor_shipping_document_review'
      WHEN aa.allocation_status IS DISTINCT FROM 'approved' THEN 'awaiting_supervisor_shipping_apportionment'
      WHEN NOT COALESCE(fee.has_accepted_current, false) THEN 'upload_final_export_evidence'
      WHEN NOT COALESCE(fee.has_pod_accepted_current, false) THEN 'upload_pod_or_delivery_evidence'
      ELSE 'shipment_controls_complete'
    END::text AS next_action
  FROM public.shipper_shipment_batches b
  LEFT JOIN latest_docs ld ON ld.shipment_batch_id = b.id
  LEFT JOIN final_export_evidence fee ON fee.shipment_batch_id = b.id
  LEFT JOIN active_apportionment aa ON aa.shipping_document_id = ld.shipping_document_id
  WHERE b.shipper_id = v_shipper_id
    AND b.status <> 'voided'
  ORDER BY b.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_progress_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_progress_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
