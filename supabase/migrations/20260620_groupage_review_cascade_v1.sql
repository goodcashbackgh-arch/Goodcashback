BEGIN;

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
    AND v_doc.document_kind = 'completed_cos'
    AND v_doc.document_ref = gm.groupage_movement_ref
  ORDER BY gm.created_at DESC
  LIMIT 1;

  IF v_groupage_movement_id IS NOT NULL THEN
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

  RETURN v_doc.shipment_batch_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_review_final_export_evidence_document_v1(uuid,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
