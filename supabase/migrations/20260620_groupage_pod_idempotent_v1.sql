BEGIN;

CREATE OR REPLACE FUNCTION public.shipper_submit_groupage_pod_v1(
  p_groupage_movement_id uuid,
  p_shipment_batch_ids uuid[],
  p_file_url text,
  p_document_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_movement record;
  v_selected_count integer;
  v_valid_count integer;
  v_open_count integer;
  v_doc_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: submit groupage POD requires auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT * INTO v_movement
  FROM public.shipper_groupage_movements gm
  WHERE gm.id = p_groupage_movement_id
    AND gm.shipper_id = v_shipper_id
    AND gm.status <> 'voided';

  IF v_movement.id IS NULL THEN
    RAISE EXCEPTION 'Groupage Movement not found for this shipper.';
  END IF;

  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one booking reference covered by the POD.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_file_url, '')), '') IS NULL THEN
    RAISE EXCEPTION 'POD file URL is required.';
  END IF;

  SELECT COUNT(DISTINCT x)::integer INTO v_selected_count
  FROM unnest(p_shipment_batch_ids) AS x;

  SELECT COUNT(DISTINCT gmb.shipment_batch_id)::integer INTO v_valid_count
  FROM public.shipper_groupage_movement_batches gmb
  JOIN public.shipper_shipment_batches b ON b.id = gmb.shipment_batch_id
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true
    AND gmb.shipment_batch_id = ANY(p_shipment_batch_ids)
    AND gmb.shipper_id = v_shipper_id
    AND b.status <> 'voided';

  IF v_valid_count <> v_selected_count THEN
    RAISE EXCEPTION 'Selected POD booking references must belong to this active Groupage Movement.';
  END IF;

  SELECT COUNT(DISTINCT gmb.shipment_batch_id)::integer INTO v_open_count
  FROM public.shipper_groupage_movement_batches gmb
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true
    AND gmb.shipment_batch_id = ANY(p_shipment_batch_ids)
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_final_export_evidence_documents d
      WHERE d.shipment_batch_id = gmb.shipment_batch_id
        AND d.document_kind = 'pod_delivery_evidence'
        AND d.review_status IN ('submitted_for_review', 'accepted_current')
    );

  IF v_open_count = 0 THEN
    RAISE EXCEPTION 'Selected POD booking references already have POD submitted or accepted.';
  END IF;

  INSERT INTO public.shipper_groupage_movement_documents (
    groupage_movement_id, document_kind, document_ref, file_url, notes, created_by_shipper_user_id
  ) VALUES (
    p_groupage_movement_id,
    'pod_delivery_evidence',
    COALESCE(NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), v_movement.groupage_movement_ref),
    BTRIM(p_file_url),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    v_shipper_user_id
  ) RETURNING id INTO v_doc_id;

  INSERT INTO public.shipper_final_export_evidence_documents (
    shipment_batch_id, shipper_id, document_kind, document_ref, file_url, notes, review_status, created_by_shipper_user_id
  )
  SELECT
    gmb.shipment_batch_id,
    v_shipper_id,
    'pod_delivery_evidence',
    COALESCE(NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), v_movement.groupage_movement_ref),
    BTRIM(p_file_url),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    'submitted_for_review',
    v_shipper_user_id
  FROM public.shipper_groupage_movement_batches gmb
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true
    AND gmb.shipment_batch_id = ANY(p_shipment_batch_ids)
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_final_export_evidence_documents d
      WHERE d.shipment_batch_id = gmb.shipment_batch_id
        AND d.document_kind = 'pod_delivery_evidence'
        AND d.review_status IN ('submitted_for_review', 'accepted_current')
    );

  UPDATE public.shipper_groupage_movements
  SET status = CASE WHEN status = 'complete' THEN status ELSE 'pod_part_submitted' END,
      updated_by_shipper_user_id = v_shipper_user_id,
      updated_at = now()
  WHERE id = p_groupage_movement_id;

  RETURN v_doc_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_submit_groupage_pod_v1(uuid,uuid[],text,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
