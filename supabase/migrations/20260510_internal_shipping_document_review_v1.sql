-- Internal shipping document review controls v1
-- Scope: supervisor review of shipper invoice/receipt/supporting charge docs only.
-- No COS/BOL/POD, no shipping apportionment, no Sage posting, no VAT clearance.

BEGIN;

ALTER TABLE public.shipping_documents
  ADD COLUMN IF NOT EXISTS reviewed_by_staff_id uuid REFERENCES public.staff(id),
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS review_note text,
  ADD COLUMN IF NOT EXISTS extracted_document_ref varchar,
  ADD COLUMN IF NOT EXISTS extracted_document_date date,
  ADD COLUMN IF NOT EXISTS extracted_currency_code varchar,
  ADD COLUMN IF NOT EXISTS extracted_total_amount numeric(14,2);

ALTER TABLE public.shipping_document_messages
  ADD COLUMN IF NOT EXISTS created_by_staff_id uuid REFERENCES public.staff(id),
  ADD COLUMN IF NOT EXISTS closed_at timestamptz,
  ADD COLUMN IF NOT EXISTS closed_by_staff_id uuid REFERENCES public.staff(id);

CREATE OR REPLACE FUNCTION public.internal_shipping_document_worklist_v1()
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  document_kind text,
  document_ref text,
  document_date date,
  currency_code text,
  total_amount numeric,
  file_url text,
  ocr_status text,
  review_status text,
  version_no integer,
  created_at timestamptz,
  accepted_at timestamptz,
  reviewed_at timestamptz,
  package_count bigint,
  item_qty numeric,
  open_message_count bigint,
  next_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipping document worklist requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal shipping document worklist.';
  END IF;

  RETURN QUERY
  WITH package_counts AS (
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
  ), message_counts AS (
    SELECT
      sdm.shipping_document_id,
      COUNT(*) FILTER (WHERE sdm.status = 'open')::bigint AS open_message_count
    FROM public.shipping_document_messages sdm
    GROUP BY sdm.shipping_document_id
  )
  SELECT
    sd.id AS shipping_document_id,
    sd.shipment_batch_id,
    b.booking_ref::text,
    sd.shipper_id,
    s.name::text AS shipper_name,
    sd.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    sd.document_kind::text,
    sd.document_ref::text,
    sd.document_date,
    sd.currency_code::text,
    sd.total_amount,
    sd.file_url::text,
    sd.ocr_status::text,
    sd.review_status::text,
    sd.version_no,
    sd.created_at,
    sd.accepted_at,
    sd.reviewed_at,
    COALESCE(pc.package_count, 0)::bigint AS package_count,
    COALESCE(pc.item_qty, 0::numeric) AS item_qty,
    COALESCE(mc.open_message_count, 0)::bigint AS open_message_count,
    CASE
      WHEN sd.review_status = 'accepted_current' THEN 'accepted_locked'
      WHEN sd.review_status = 'rejected_resubmit_required' THEN 'awaiting_shipper_resubmission'
      WHEN sd.ocr_status IN ('queued','processing') THEN 'ocr_in_progress'
      ELSE 'supervisor_review_needed'
    END::text AS next_action
  FROM public.shipping_documents sd
  JOIN public.shipper_shipment_batches b ON b.id = sd.shipment_batch_id
  JOIN public.shippers s ON s.id = sd.shipper_id
  LEFT JOIN public.importers i ON i.id = sd.importer_id
  LEFT JOIN package_counts pc ON pc.shipment_batch_id = sd.shipment_batch_id
  LEFT JOIN message_counts mc ON mc.shipping_document_id = sd.id
  WHERE sd.active = true
  ORDER BY sd.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_document_worklist_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_worklist_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_shipping_document_detail_v1(
  p_shipping_document_id uuid
)
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  shipper_name text,
  importer_name text,
  document_kind text,
  document_ref text,
  document_date date,
  currency_code text,
  total_amount numeric,
  file_url text,
  ocr_status text,
  review_status text,
  notes text,
  version_no integer,
  created_at timestamptz,
  accepted_at timestamptz,
  reviewed_at timestamptz,
  review_note text,
  extracted_document_ref text,
  extracted_document_date date,
  extracted_currency_code text,
  extracted_total_amount numeric,
  package_count bigint,
  item_qty numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipping document detail requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal shipping document detail.';
  END IF;

  RETURN QUERY
  WITH package_counts AS (
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
  )
  SELECT
    sd.id AS shipping_document_id,
    sd.shipment_batch_id,
    b.booking_ref::text,
    s.name::text AS shipper_name,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    sd.document_kind::text,
    sd.document_ref::text,
    sd.document_date,
    sd.currency_code::text,
    sd.total_amount,
    sd.file_url::text,
    sd.ocr_status::text,
    sd.review_status::text,
    sd.notes::text,
    sd.version_no,
    sd.created_at,
    sd.accepted_at,
    sd.reviewed_at,
    sd.review_note::text,
    sd.extracted_document_ref::text,
    sd.extracted_document_date,
    sd.extracted_currency_code::text,
    sd.extracted_total_amount,
    COALESCE(pc.package_count, 0)::bigint AS package_count,
    COALESCE(pc.item_qty, 0::numeric) AS item_qty
  FROM public.shipping_documents sd
  JOIN public.shipper_shipment_batches b ON b.id = sd.shipment_batch_id
  JOIN public.shippers s ON s.id = sd.shipper_id
  LEFT JOIN public.importers i ON i.id = sd.importer_id
  LEFT JOIN package_counts pc ON pc.shipment_batch_id = sd.shipment_batch_id
  WHERE sd.id = p_shipping_document_id
    AND sd.active = true;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_document_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_detail_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_review_shipping_document_v1(
  p_shipping_document_id uuid,
  p_decision text,
  p_review_note text DEFAULT NULL,
  p_extracted_document_ref text DEFAULT NULL,
  p_extracted_document_date date DEFAULT NULL,
  p_extracted_currency_code text DEFAULT NULL,
  p_extracted_total_amount numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff_id uuid;
  v_doc public.shipping_documents%ROWTYPE;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: review shipping document requires auth.uid()';
  END IF;

  SELECT st.id INTO v_staff_id
  FROM public.staff st
  WHERE st.auth_user_id = v_auth_uid
    AND st.active = true
  ORDER BY st.created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required for shipping document review.';
  END IF;

  SELECT * INTO v_doc
  FROM public.shipping_documents sd
  WHERE sd.id = p_shipping_document_id
    AND sd.active = true;

  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'Active shipping document not found.';
  END IF;

  IF v_doc.review_status = 'accepted_current' AND p_decision <> 'reject_resubmit_required' THEN
    RAISE EXCEPTION 'Accepted shipping document is locked. Use a controlled reject/resubmission path if correction is required.';
  END IF;

  IF p_decision = 'mark_ocr_queued' THEN
    UPDATE public.shipping_documents
       SET ocr_status = 'queued',
           review_status = 'ocr_pending',
           reviewed_by_staff_id = v_staff_id,
           reviewed_at = now(),
           review_note = NULLIF(BTRIM(COALESCE(p_review_note, '')), ''),
           updated_at = now()
     WHERE id = v_doc.id;
  ELSIF p_decision = 'mark_ocr_not_applicable' THEN
    UPDATE public.shipping_documents
       SET ocr_status = 'not_applicable',
           review_status = 'needs_supervisor_review',
           reviewed_by_staff_id = v_staff_id,
           reviewed_at = now(),
           review_note = NULLIF(BTRIM(COALESCE(p_review_note, '')), ''),
           updated_at = now()
     WHERE id = v_doc.id;
  ELSIF p_decision = 'accept_current' THEN
    UPDATE public.shipping_documents
       SET review_status = 'accepted_current',
           ocr_status = CASE WHEN ocr_status = 'not_started' THEN 'not_applicable' ELSE ocr_status END,
           reviewed_by_staff_id = v_staff_id,
           reviewed_at = now(),
           accepted_at = now(),
           review_note = NULLIF(BTRIM(COALESCE(p_review_note, '')), ''),
           extracted_document_ref = NULLIF(BTRIM(COALESCE(p_extracted_document_ref, '')), ''),
           extracted_document_date = p_extracted_document_date,
           extracted_currency_code = UPPER(NULLIF(BTRIM(COALESCE(p_extracted_currency_code, '')), '')),
           extracted_total_amount = p_extracted_total_amount,
           updated_at = now()
     WHERE id = v_doc.id;
  ELSIF p_decision = 'reject_resubmit_required' THEN
    UPDATE public.shipping_documents
       SET review_status = 'rejected_resubmit_required',
           reviewed_by_staff_id = v_staff_id,
           reviewed_at = now(),
           review_note = NULLIF(BTRIM(COALESCE(p_review_note, '')), ''),
           updated_at = now()
     WHERE id = v_doc.id;

    INSERT INTO public.shipping_document_messages (
      shipping_document_id,
      shipment_batch_id,
      shipper_id,
      importer_id,
      message_type,
      message_body,
      status,
      created_by_staff_id
    ) VALUES (
      v_doc.id,
      v_doc.shipment_batch_id,
      v_doc.shipper_id,
      v_doc.importer_id,
      'supervisor_note',
      COALESCE(NULLIF(BTRIM(COALESCE(p_review_note, '')), ''), 'Supervisor rejected shipping document and requested resubmission.'),
      'open',
      v_staff_id
    );
  ELSE
    RAISE EXCEPTION 'Invalid shipping document review decision: %', p_decision;
  END IF;

  RETURN v_doc.id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_review_shipping_document_v1(uuid,text,text,date,text,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_review_shipping_document_v1(uuid,text,text,text,date,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_review_shipping_document_v1(uuid,text,text,text,date,text,numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
