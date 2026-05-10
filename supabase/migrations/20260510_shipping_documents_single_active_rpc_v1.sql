BEGIN;

CREATE OR REPLACE FUNCTION public.shipper_submit_shipping_document_v1(
  p_shipment_batch_id uuid,
  p_document_kind text,
  p_document_ref text,
  p_document_date date,
  p_currency_code text,
  p_total_amount numeric,
  p_file_url text,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_importer_id uuid;
  v_existing public.shipping_documents%ROWTYPE;
  v_document_id uuid;
  v_next_version integer;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: submit shipping document requires auth.uid()';
  END IF;

  IF p_document_kind NOT IN ('shipper_invoice','shipper_receipt','supporting_charge_document') THEN
    RAISE EXCEPTION 'Choose a valid shipping document type.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_file_url, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Shipping document file is required.';
  END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.importer_id INTO v_importer_id
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
    AND b.shipper_id = v_shipper_id
    AND b.status <> 'voided';

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found for this shipper, or batch is voided.';
  END IF;

  SELECT * INTO v_existing
  FROM public.shipping_documents sd
  WHERE sd.shipment_batch_id = p_shipment_batch_id
    AND sd.active = true
  ORDER BY sd.created_at DESC LIMIT 1;

  IF v_existing.id IS NOT NULL AND v_existing.review_status = 'accepted_current' THEN
    RAISE EXCEPTION 'Supervisor has accepted the current shipping charge document for this batch. Request resubmission instead of replacing it.';
  END IF;

  SELECT COALESCE(MAX(sd.version_no), 0) + 1 INTO v_next_version
  FROM public.shipping_documents sd
  WHERE sd.shipment_batch_id = p_shipment_batch_id;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.shipping_documents
       SET active = false,
           review_status = 'superseded',
           superseded_at = now(),
           updated_at = now()
     WHERE shipment_batch_id = p_shipment_batch_id
       AND active = true;
  END IF;

  INSERT INTO public.shipping_documents (
    shipment_batch_id, shipper_id, importer_id, uploaded_by_shipper_user_id,
    document_kind, document_ref, document_date, currency_code, total_amount,
    file_url, ocr_status, review_status, notes, version_no, active
  ) VALUES (
    p_shipment_batch_id, v_shipper_id, v_importer_id, v_shipper_user_id,
    p_document_kind, NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), p_document_date,
    UPPER(NULLIF(BTRIM(COALESCE(p_currency_code, '')), '')), p_total_amount,
    BTRIM(p_file_url), 'not_started', 'uploaded_pending_ocr',
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''), v_next_version, true
  ) RETURNING id INTO v_document_id;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.shipping_documents
       SET replaced_by_document_id = v_document_id,
           updated_at = now()
     WHERE id = v_existing.id;
  END IF;

  RETURN v_document_id;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
