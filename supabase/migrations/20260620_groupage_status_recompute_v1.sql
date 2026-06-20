BEGIN;

CREATE OR REPLACE FUNCTION public.groupage_recompute_movement_status_v1(p_groupage_movement_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_current_status text;
  v_next_status text;
  v_active_count integer;
  v_export_submitted_count integer;
  v_export_accepted_count integer;
  v_pod_submitted_count integer;
  v_pod_accepted_count integer;
BEGIN
  SELECT status INTO v_current_status
  FROM public.shipper_groupage_movements
  WHERE id = p_groupage_movement_id;

  IF v_current_status IS NULL THEN
    RAISE EXCEPTION 'Groupage Movement not found.';
  END IF;

  IF v_current_status = 'voided' THEN
    RETURN v_current_status;
  END IF;

  WITH active_batches AS (
    SELECT gmb.shipment_batch_id
    FROM public.shipper_groupage_movement_batches gmb
    WHERE gmb.groupage_movement_id = p_groupage_movement_id
      AND gmb.active = true
  ), movement AS (
    SELECT gm.groupage_movement_ref
    FROM public.shipper_groupage_movements gm
    WHERE gm.id = p_groupage_movement_id
  ), per_batch AS (
    SELECT
      ab.shipment_batch_id,
      EXISTS (
        SELECT 1
        FROM public.shipper_final_export_evidence_documents d
        CROSS JOIN movement m
        WHERE d.shipment_batch_id = ab.shipment_batch_id
          AND d.document_kind = 'completed_cos'
          AND d.document_ref = m.groupage_movement_ref
          AND d.review_status = 'submitted_for_review'
      ) AS export_submitted,
      EXISTS (
        SELECT 1
        FROM public.shipper_final_export_evidence_documents d
        CROSS JOIN movement m
        WHERE d.shipment_batch_id = ab.shipment_batch_id
          AND d.document_kind = 'completed_cos'
          AND d.document_ref = m.groupage_movement_ref
          AND d.review_status = 'accepted_current'
      ) AS export_accepted,
      EXISTS (
        SELECT 1
        FROM public.shipper_final_export_evidence_documents d
        WHERE d.shipment_batch_id = ab.shipment_batch_id
          AND d.document_kind = 'pod_delivery_evidence'
          AND d.review_status = 'submitted_for_review'
      ) AS pod_submitted,
      EXISTS (
        SELECT 1
        FROM public.shipper_final_export_evidence_documents d
        WHERE d.shipment_batch_id = ab.shipment_batch_id
          AND d.document_kind = 'pod_delivery_evidence'
          AND d.review_status = 'accepted_current'
      ) AS pod_accepted
    FROM active_batches ab
  )
  SELECT
    COUNT(*)::integer,
    COUNT(*) FILTER (WHERE export_submitted)::integer,
    COUNT(*) FILTER (WHERE export_accepted)::integer,
    COUNT(*) FILTER (WHERE pod_submitted)::integer,
    COUNT(*) FILTER (WHERE pod_accepted)::integer
  INTO
    v_active_count,
    v_export_submitted_count,
    v_export_accepted_count,
    v_pod_submitted_count,
    v_pod_accepted_count
  FROM per_batch;

  IF COALESCE(v_active_count, 0) = 0 THEN
    v_next_status := v_current_status;
  ELSIF v_active_count >= 2
    AND v_export_accepted_count = v_active_count
    AND v_pod_accepted_count = v_active_count THEN
    v_next_status := 'complete';
  ELSIF v_export_accepted_count = v_active_count
    AND v_pod_accepted_count > 0 THEN
    v_next_status := 'pod_part_accepted';
  ELSIF v_export_accepted_count = v_active_count
    AND v_pod_submitted_count > 0 THEN
    v_next_status := 'pod_part_submitted';
  ELSIF v_export_accepted_count = v_active_count THEN
    v_next_status := 'signed_export_pack_fully_accepted';
  ELSIF v_export_accepted_count > 0 THEN
    v_next_status := 'signed_export_pack_part_accepted';
  ELSIF v_export_submitted_count > 0 THEN
    v_next_status := 'signed_export_pack_submitted';
  ELSE
    v_next_status := v_current_status;
  END IF;

  UPDATE public.shipper_groupage_movements
  SET status = v_next_status,
      updated_at = now()
  WHERE id = p_groupage_movement_id
    AND status <> v_next_status;

  RETURN v_next_status;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_review_final_export_evidence_document_v1(
  p_document_id uuid,
  p_review_status text,
  p_review_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_doc record;
  v_groupage_movement_id uuid;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  ORDER BY s.created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active supervisor/admin staff account required.';
  END IF;

  SELECT d.* INTO v_doc
  FROM public.shipper_final_export_evidence_documents d
  WHERE d.id = p_document_id;

  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'Final export evidence document not found.';
  END IF;

  SELECT gm.id INTO v_groupage_movement_id
  FROM public.shipper_groupage_movement_batches gmb
  JOIN public.shipper_groupage_movements gm
    ON gm.id = gmb.groupage_movement_id
   AND gm.status <> 'voided'
  WHERE gmb.active = true
    AND gmb.shipment_batch_id = v_doc.shipment_batch_id
    AND (
      (v_doc.document_kind = 'completed_cos' AND v_doc.document_ref = gm.groupage_movement_ref)
      OR v_doc.document_kind = 'pod_delivery_evidence'
    )
  ORDER BY gm.created_at DESC
  LIMIT 1;

  IF v_groupage_movement_id IS NOT NULL AND v_doc.document_kind = 'completed_cos' THEN
    UPDATE public.shipper_final_export_evidence_documents d
       SET review_status = p_review_status,
           supervisor_review_notes = NULLIF(BTRIM(COALESCE(p_review_notes,'')),''),
           reviewed_by_staff_id = v_staff_id,
           reviewed_at = now(),
           updated_at = now()
     WHERE d.document_kind = 'completed_cos'
       AND d.document_ref = v_doc.document_ref
       AND d.file_url = v_doc.file_url
       AND d.shipper_id = v_doc.shipper_id
       AND d.shipment_batch_id IN (
         SELECT gmb2.shipment_batch_id
         FROM public.shipper_groupage_movement_batches gmb2
         WHERE gmb2.groupage_movement_id = v_groupage_movement_id
           AND gmb2.active = true
       );
  ELSE
    UPDATE public.shipper_final_export_evidence_documents d
       SET review_status = p_review_status,
           supervisor_review_notes = NULLIF(BTRIM(COALESCE(p_review_notes,'')),''),
           reviewed_by_staff_id = v_staff_id,
           reviewed_at = now(),
           updated_at = now()
     WHERE d.id = p_document_id;
  END IF;

  IF v_groupage_movement_id IS NOT NULL THEN
    PERFORM public.groupage_recompute_movement_status_v1(v_groupage_movement_id);
  END IF;

  RETURN v_doc.shipment_batch_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.groupage_recompute_movement_status_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_review_final_export_evidence_document_v1(uuid,text,text) TO authenticated;

-- Recompute existing active groupage movements after deploying the fixed aggregate status logic.
SELECT public.groupage_recompute_movement_status_v1(id)
FROM public.shipper_groupage_movements
WHERE status <> 'voided';

NOTIFY pgrst, 'reload schema';

COMMIT;
