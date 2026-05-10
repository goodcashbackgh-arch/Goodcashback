-- Shipping document shipper RPCs v1

BEGIN;

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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipping document worklist requires auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  WITH batch_packages AS (
    SELECT
      p.shipment_batch_id,
      COUNT(*)::bigint AS package_count,
      COALESCE(SUM(alloc.allocated_qty), 0::numeric) AS item_qty
    FROM public.shipper_shipment_batch_packages p
    LEFT JOIN LATERAL (
      SELECT SUM(otla.qty_allocated) AS allocated_qty
      FROM public.order_tracking_line_allocations otla
      WHERE otla.tracking_submission_id = p.tracking_submission_id
    ) alloc ON true
    WHERE p.active = true
    GROUP BY p.shipment_batch_id
  ), latest_doc AS (
    SELECT DISTINCT ON (sd.shipment_batch_id)
      sd.*
    FROM public.shipping_documents sd
    WHERE sd.active = true
      AND sd.shipper_id = v_shipper_id
    ORDER BY sd.shipment_batch_id, sd.created_at DESC
  ), open_requests AS (
    SELECT
      sdm.shipping_document_id,
      COUNT(*)::bigint AS open_count
    FROM public.shipping_document_messages sdm
    WHERE sdm.status = 'open'
      AND sdm.message_type = 'resubmission_request'
    GROUP BY sdm.shipping_document_id
  )
  SELECT
    v_shipper_user_id AS shipper_user_id,
    b.shipper_id,
    s.name::text AS shipper_name,
    b.id AS shipment_batch_id,
    b.booking_ref::text,
    b.status::text AS batch_status,
    b.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    b.dispatched_at,
    COALESCE(bp.package_count, 0)::bigint AS package_count,
    COALESCE(bp.item_qty, 0::numeric) AS item_qty,
    ld.id AS latest_document_id,
    ld.document_kind::text AS latest_document_kind,
    ld.document_ref::text AS latest_document_ref,
    ld.document_date AS latest_document_date,
    ld.currency_code::text AS latest_currency_code,
    ld.total_amount AS latest_total_amount,
    ld.file_url::text AS latest_file_url,
    ld.ocr_status::text AS latest_ocr_status,
    CASE
      WHEN ld.review_status = 'accepted_current' AND COALESCE(orq.open_count, 0) > 0 THEN 'resubmission_requested'
      ELSE COALESCE(ld.review_status, 'not_started')::text
    END AS latest_review_status,
    ld.version_no,
    COALESCE(orq.open_count, 0)::bigint AS open_resubmission_request_count,
    CASE
      WHEN b.status = 'voided' THEN false
      WHEN ld.id IS NULL THEN true
      WHEN ld.review_status = 'accepted_current' THEN false
      ELSE true
    END AS can_upload_or_replace,
    CASE WHEN ld.review_status = 'accepted_current' THEN true ELSE false END AS requires_resubmission_request
  FROM public.shipper_shipment_batches b
  JOIN public.shippers s ON s.id = b.shipper_id
  LEFT JOIN public.importers i ON i.id = b.importer_id
  LEFT JOIN batch_packages bp ON bp.shipment_batch_id = b.id
  LEFT JOIN latest_doc ld ON ld.shipment_batch_id = b.id
  LEFT JOIN open_requests orq ON orq.shipping_document_id = ld.id
  WHERE b.shipper_id = v_shipper_id
    AND b.status <> 'voided'
  ORDER BY b.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipping_document_worklist_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipping_document_worklist_v1() TO authenticated;

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
    AND sd.document_kind = p_document_kind
    AND sd.active = true
  ORDER BY sd.created_at DESC LIMIT 1;

  IF v_existing.id IS NOT NULL AND v_existing.review_status = 'accepted_current' THEN
    RAISE EXCEPTION 'Supervisor has accepted this shipping document. Request resubmission instead of replacing it.';
  END IF;

  SELECT COALESCE(MAX(sd.version_no), 0) + 1 INTO v_next_version
  FROM public.shipping_documents sd
  WHERE sd.shipment_batch_id = p_shipment_batch_id
    AND sd.document_kind = p_document_kind;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.shipping_documents
       SET active = false,
           review_status = 'superseded',
           superseded_at = now(),
           updated_at = now()
     WHERE id = v_existing.id;
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

REVOKE ALL ON FUNCTION public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_request_shipping_document_resubmission_v1(
  p_shipping_document_id uuid,
  p_message text
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
  v_doc public.shipping_documents%ROWTYPE;
  v_message_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: request resubmission requires auth.uid()';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_message, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Message is required.';
  END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT * INTO v_doc
  FROM public.shipping_documents sd
  WHERE sd.id = p_shipping_document_id
    AND sd.shipper_id = v_shipper_id
    AND sd.active = true;

  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'Active shipping document not found for this shipper.';
  END IF;

  IF v_doc.review_status <> 'accepted_current' THEN
    RAISE EXCEPTION 'This document has not been accepted yet. Upload a replacement instead of requesting resubmission.';
  END IF;

  INSERT INTO public.shipping_document_messages (
    shipping_document_id, shipment_batch_id, shipper_id, importer_id,
    message_type, message_body, status, created_by_shipper_user_id
  ) VALUES (
    v_doc.id, v_doc.shipment_batch_id, v_doc.shipper_id, v_doc.importer_id,
    'resubmission_request', BTRIM(p_message), 'open', v_shipper_user_id
  ) RETURNING id INTO v_message_id;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_request_shipping_document_resubmission_v1(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_request_shipping_document_resubmission_v1(uuid,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
