BEGIN;

-- Narrow shipper-facing sequencing fix only.
-- Do not change supervisor/AP readiness logic.
-- The shipper should not be blocked from uploading final evidence/POD just because
-- supervisor shipping apportionment is still pending. Apportionment remains visible as
-- supervisor-owned waiting only after shipper upload tasks are exhausted.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
      bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'accepted_current') AS has_final_accepted_current,
      bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') AS has_final_submitted_for_review,
      bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') AS has_final_rejected_resubmit_required,
      bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'accepted_current') AS has_pod_accepted_current,
      bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') AS has_pod_submitted_for_review,
      bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') AS has_pod_rejected_resubmit_required,
      count(*) FILTER (WHERE d.document_kind <> 'pod_delivery_evidence') AS final_document_count,
      count(*) FILTER (WHERE d.document_kind = 'pod_delivery_evidence') AS pod_document_count
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
      WHEN COALESCE(fee.has_final_accepted_current, false) THEN 'accepted_current'
      WHEN COALESCE(fee.has_final_submitted_for_review, false) THEN 'submitted_for_review'
      WHEN COALESCE(fee.has_final_rejected_resubmit_required, false) OR COALESCE(fee.has_pod_rejected_resubmit_required, false) THEN 'rejected_resubmit_required'
      WHEN COALESCE(fee.final_document_count, 0) + COALESCE(fee.pod_document_count, 0) > 0 THEN 'uploaded_pending_review'
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
      WHEN NOT COALESCE(fee.has_final_accepted_current, false)
           AND NOT COALESCE(fee.has_final_submitted_for_review, false)
        THEN 'upload_final_export_evidence'
      WHEN NOT COALESCE(fee.has_pod_accepted_current, false)
           AND NOT COALESCE(fee.has_pod_submitted_for_review, false)
        THEN 'upload_pod_or_delivery_evidence'
      WHEN NOT COALESCE(fee.has_final_accepted_current, false)
        THEN 'awaiting_supervisor_final_export_evidence_review'
      WHEN NOT COALESCE(fee.has_pod_accepted_current, false)
        THEN 'awaiting_supervisor_pod_review'
      WHEN aa.allocation_status IS DISTINCT FROM 'approved' THEN 'awaiting_supervisor_shipping_apportionment'
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
