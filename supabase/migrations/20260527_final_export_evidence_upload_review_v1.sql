BEGIN;

CREATE TABLE IF NOT EXISTS public.shipper_final_export_evidence_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id) ON DELETE CASCADE,
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  document_kind varchar NOT NULL CHECK (document_kind IN ('completed_cos','final_eep_packing_list','mbl_bol_sea_waybill','container_seal_evidence','export_date_departure_evidence','other_final_export_evidence')),
  document_ref text,
  file_url text NOT NULL,
  notes text,
  review_status varchar NOT NULL DEFAULT 'submitted_for_review' CHECK (review_status IN ('submitted_for_review','accepted_current','rejected_resubmit_required')),
  supervisor_review_notes text,
  reviewed_by_staff_id uuid REFERENCES public.staff(id),
  reviewed_at timestamptz,
  created_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shipper_final_export_evidence_documents_batch
  ON public.shipper_final_export_evidence_documents(shipment_batch_id, review_status, created_at DESC);

ALTER TABLE public.shipper_final_export_evidence_documents ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND tablename='shipper_final_export_evidence_documents'
      AND policyname='shipper_final_export_evidence_documents_select'
  ) THEN
    CREATE POLICY shipper_final_export_evidence_documents_select
    ON public.shipper_final_export_evidence_documents
    FOR SELECT TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = shipper_final_export_evidence_documents.shipper_id
      )
      OR public.is_active_staff()
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_submit_final_export_evidence_v1(
  p_shipment_batch_id uuid,
  p_document_kind text,
  p_document_ref text DEFAULT NULL,
  p_file_url text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch_shipper_id uuid;
  v_completion_status text;
  v_document_id uuid;
BEGIN
  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid() AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.shipper_id INTO v_batch_shipper_id
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id;

  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Shipment batch does not belong to this shipper.';
  END IF;

  SELECT f.completion_status INTO v_completion_status
  FROM public.shipper_export_evidence_completion_fields f
  WHERE f.shipment_batch_id = p_shipment_batch_id;

  IF COALESCE(v_completion_status,'completion_fields_draft') <> 'completion_fields_ready' THEN
    RAISE EXCEPTION 'Complete and save final shipment/COS fields before uploading final export evidence.';
  END IF;

  INSERT INTO public.shipper_final_export_evidence_documents (
    shipment_batch_id, shipper_id, document_kind, document_ref, file_url, notes, review_status, created_by_shipper_user_id
  ) VALUES (
    p_shipment_batch_id, v_shipper_id, p_document_kind, NULLIF(BTRIM(COALESCE(p_document_ref,'')),''), BTRIM(COALESCE(p_file_url,'')), NULLIF(BTRIM(COALESCE(p_notes,'')),''), 'submitted_for_review', v_shipper_user_id
  ) RETURNING id INTO v_document_id;

  RETURN v_document_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_submit_final_export_evidence_v1(uuid,text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_final_export_evidence_documents_v1(p_shipment_batch_id uuid)
RETURNS TABLE (
  document_id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  shipper_name text,
  document_kind text,
  document_ref text,
  file_url text,
  notes text,
  review_status text,
  supervisor_review_notes text,
  reviewed_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public, pg_temp
AS $$
BEGIN
  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required.';
  END IF;

  RETURN QUERY
  SELECT d.id, d.shipment_batch_id, b.booking_ref::text, s.name::text, d.document_kind::text,
         d.document_ref, d.file_url, d.notes, d.review_status::text,
         d.supervisor_review_notes, d.reviewed_at, d.created_at
  FROM public.shipper_final_export_evidence_documents d
  JOIN public.shipper_shipment_batches b ON b.id = d.shipment_batch_id
  JOIN public.shippers s ON s.id = d.shipper_id
  WHERE d.shipment_batch_id = p_shipment_batch_id
  ORDER BY d.created_at DESC, d.id DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_final_export_evidence_documents_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_review_final_export_evidence_document_v1(
  p_document_id uuid,
  p_review_status text,
  p_review_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_shipment_batch_id uuid;
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

  UPDATE public.shipper_final_export_evidence_documents d
     SET review_status = p_review_status,
         supervisor_review_notes = NULLIF(BTRIM(COALESCE(p_review_notes,'')),''),
         reviewed_by_staff_id = v_staff_id,
         reviewed_at = now(),
         updated_at = now()
   WHERE d.id = p_document_id
   RETURNING d.shipment_batch_id INTO v_shipment_batch_id;

  RETURN v_shipment_batch_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_review_final_export_evidence_document_v1(uuid,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
