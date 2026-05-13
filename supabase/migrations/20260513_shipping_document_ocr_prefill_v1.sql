BEGIN;

ALTER TABLE public.shipping_documents
  ADD COLUMN IF NOT EXISTS mindee_model_id text,
  ADD COLUMN IF NOT EXISTS mindee_job_id text,
  ADD COLUMN IF NOT EXISTS mindee_inference_id text,
  ADD COLUMN IF NOT EXISTS mindee_error_message text,
  ADD COLUMN IF NOT EXISTS ocr_raw_json jsonb,
  ADD COLUMN IF NOT EXISTS ocr_pages_consumed integer,
  ADD COLUMN IF NOT EXISTS ocr_shipper_name text,
  ADD COLUMN IF NOT EXISTS ocr_reference_text text,
  ADD COLUMN IF NOT EXISTS ocr_document_ref text,
  ADD COLUMN IF NOT EXISTS ocr_document_date date,
  ADD COLUMN IF NOT EXISTS ocr_total_amount numeric(14,2),
  ADD COLUMN IF NOT EXISTS ocr_match_status text,
  ADD COLUMN IF NOT EXISTS ocr_match_summary_json jsonb;

CREATE TABLE IF NOT EXISTS public.shipping_document_ocr_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipping_document_id uuid NOT NULL REFERENCES public.shipping_documents(id) ON DELETE CASCADE,
  line_order integer NOT NULL,
  description text NOT NULL,
  quantity numeric,
  amount_gbp numeric(14,2),
  raw_line_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shipping_document_id, line_order)
);

ALTER TABLE public.shipping_document_ocr_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shipping_document_ocr_lines_staff_select ON public.shipping_document_ocr_lines;
CREATE POLICY shipping_document_ocr_lines_staff_select
ON public.shipping_document_ocr_lines
FOR SELECT
TO authenticated
USING (public.is_active_staff());

CREATE INDEX IF NOT EXISTS idx_shipping_document_ocr_lines_document
  ON public.shipping_document_ocr_lines(shipping_document_id, line_order);

CREATE OR REPLACE FUNCTION public.internal_shipping_document_match_status_v1(
  p_expected_shipper text,
  p_expected_booking_ref text,
  p_expected_amount numeric,
  p_ocr_shipper_name text,
  p_ocr_reference_text text,
  p_ocr_document_ref text,
  p_ocr_document_date date,
  p_ocr_total_amount numeric,
  p_ocr_line_count integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_match boolean := false;
  v_booking_match boolean := false;
  v_amount_match boolean := false;
  v_ref_captured boolean := false;
  v_date_captured boolean := false;
  v_lines_captured boolean := false;
  v_status text := 'needs_review';
  v_combined_ref text;
  v_expected_shipper text;
  v_ocr_shipper text;
  v_expected_booking text;
BEGIN
  v_expected_shipper := lower(regexp_replace(COALESCE(p_expected_shipper, ''), '[^a-z0-9]+', '', 'g'));
  v_ocr_shipper := lower(regexp_replace(COALESCE(p_ocr_shipper_name, ''), '[^a-z0-9]+', '', 'g'));
  v_expected_booking := lower(regexp_replace(COALESCE(p_expected_booking_ref, ''), '[^a-z0-9]+', '', 'g'));
  v_combined_ref := lower(regexp_replace(COALESCE(p_ocr_reference_text, '') || ' ' || COALESCE(p_ocr_document_ref, ''), '[^a-z0-9]+', '', 'g'));

  IF v_expected_shipper <> '' AND v_ocr_shipper <> '' THEN
    v_shipper_match := position(v_expected_shipper in v_ocr_shipper) > 0 OR position(v_ocr_shipper in v_expected_shipper) > 0;
  END IF;

  IF v_expected_booking <> '' AND v_combined_ref <> '' THEN
    v_booking_match := position(v_expected_booking in v_combined_ref) > 0;
  END IF;

  IF p_expected_amount IS NOT NULL AND p_ocr_total_amount IS NOT NULL THEN
    v_amount_match := abs(p_expected_amount - p_ocr_total_amount) <= 0.01;
  END IF;

  v_ref_captured := NULLIF(btrim(COALESCE(p_ocr_document_ref, '')), '') IS NOT NULL;
  v_date_captured := p_ocr_document_date IS NOT NULL;
  v_lines_captured := COALESCE(p_ocr_line_count, 0) > 0;

  v_status := CASE
    WHEN v_shipper_match AND v_booking_match AND v_amount_match AND v_ref_captured AND v_date_captured THEN 'matched'
    WHEN v_shipper_match AND v_booking_match AND v_amount_match THEN 'needs_review'
    ELSE 'mismatch'
  END;

  RETURN jsonb_build_object(
    'status', v_status,
    'shipper_match', v_shipper_match,
    'booking_ref_match', v_booking_match,
    'amount_match', v_amount_match,
    'invoice_ref_captured', v_ref_captured,
    'invoice_date_captured', v_date_captured,
    'lines_captured', v_lines_captured,
    'line_count', COALESCE(p_ocr_line_count, 0)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_start_mindee_shipping_document_ocr_v1(
  p_shipping_document_id uuid,
  p_model_id text
)
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  file_url text,
  document_ref text,
  previous_mindee_job_id text,
  previous_mindee_inference_id text
)
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
    RAISE EXCEPTION 'Unauthenticated user: start shipping document OCR requires auth.uid()';
  END IF;

  SELECT st.id INTO v_staff_id
  FROM public.staff st
  WHERE st.auth_user_id = v_auth_uid
    AND st.active = true
    AND st.role_type IN ('admin','supervisor')
  ORDER BY st.created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin or supervisor staff account required for shipping document OCR.';
  END IF;

  SELECT * INTO v_doc
  FROM public.shipping_documents sd
  WHERE sd.id = p_shipping_document_id
    AND sd.active = true
  FOR UPDATE;

  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'Active shipping document not found.';
  END IF;

  IF v_doc.review_status IN ('accepted_current', 'superseded') THEN
    RAISE EXCEPTION 'Accepted/superseded shipping document is locked. OCR cannot be started.';
  END IF;

  IF v_doc.ocr_status IN ('queued', 'processing', 'completed') THEN
    RAISE EXCEPTION 'OCR is already queued, processing or completed for this document.';
  END IF;

  IF v_doc.ocr_status = 'failed' THEN
    RAISE EXCEPTION 'OCR previously failed for this document. Use supervisor correction/review instead of resending by default.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(v_doc.file_url, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Shipping document has no file URL for OCR.';
  END IF;

  UPDATE public.shipping_documents
     SET ocr_status = 'queued',
         review_status = 'ocr_pending',
         mindee_model_id = NULLIF(BTRIM(COALESCE(p_model_id, '')), ''),
         mindee_error_message = NULL,
         updated_at = now()
   WHERE id = v_doc.id;

  RETURN QUERY
  SELECT
    v_doc.id,
    v_doc.shipment_batch_id,
    v_doc.file_url::text,
    v_doc.document_ref::text,
    v_doc.mindee_job_id::text,
    v_doc.mindee_inference_id::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_record_shipping_mindee_enqueue_result_v1(
  p_shipping_document_id uuid,
  p_model_id text,
  p_http_status integer,
  p_success_yn boolean,
  p_mindee_job_id text DEFAULT NULL,
  p_mindee_inference_id text DEFAULT NULL,
  p_response_json jsonb DEFAULT NULL,
  p_error_message text DEFAULT NULL
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
    RAISE EXCEPTION 'Unauthenticated user: record shipping OCR enqueue requires auth.uid()';
  END IF;

  SELECT st.id INTO v_staff_id
  FROM public.staff st
  WHERE st.auth_user_id = v_auth_uid
    AND st.active = true
    AND st.role_type IN ('admin','supervisor')
  ORDER BY st.created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin or supervisor staff account required for shipping OCR enqueue recording.';
  END IF;

  SELECT * INTO v_doc
  FROM public.shipping_documents sd
  WHERE sd.id = p_shipping_document_id
    AND sd.active = true
  FOR UPDATE;

  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'Active shipping document not found.';
  END IF;

  UPDATE public.shipping_documents
     SET ocr_status = CASE WHEN p_success_yn THEN 'processing' ELSE 'failed' END,
         review_status = CASE WHEN p_success_yn THEN 'ocr_pending' ELSE 'needs_supervisor_review' END,
         mindee_model_id = COALESCE(NULLIF(BTRIM(COALESCE(p_model_id, '')), ''), mindee_model_id),
         mindee_job_id = COALESCE(NULLIF(BTRIM(COALESCE(p_mindee_job_id, '')), ''), mindee_job_id),
         mindee_inference_id = COALESCE(NULLIF(BTRIM(COALESCE(p_mindee_inference_id, '')), ''), mindee_inference_id),
         mindee_error_message = CASE WHEN p_success_yn THEN NULL ELSE NULLIF(BTRIM(COALESCE(p_error_message, '')), '') END,
         ocr_raw_json = COALESCE(p_response_json, ocr_raw_json),
         updated_at = now()
   WHERE id = v_doc.id;

  RETURN v_doc.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_save_shipping_mindee_ocr_result_v1(
  p_shipping_document_id uuid,
  p_model_id text,
  p_http_status integer,
  p_mindee_job_id text DEFAULT NULL,
  p_mindee_inference_id text DEFAULT NULL,
  p_raw_json jsonb DEFAULT NULL,
  p_ocr_shipper_name text DEFAULT NULL,
  p_ocr_reference_text text DEFAULT NULL,
  p_ocr_document_ref text DEFAULT NULL,
  p_ocr_document_date date DEFAULT NULL,
  p_ocr_total_amount numeric DEFAULT NULL,
  p_pages_consumed integer DEFAULT NULL,
  p_lines jsonb DEFAULT '[]'::jsonb
)
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  ocr_match_status text,
  inserted_line_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_doc public.shipping_documents%ROWTYPE;
  v_shipper_name text;
  v_booking_ref text;
  v_match jsonb;
  v_inserted_lines integer := 0;
BEGIN
  SELECT * INTO v_doc
  FROM public.shipping_documents sd
  WHERE sd.id = p_shipping_document_id
    AND sd.active = true
  FOR UPDATE;

  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'Active shipping document not found.';
  END IF;

  IF v_doc.review_status IN ('accepted_current', 'superseded') THEN
    RAISE EXCEPTION 'Accepted/superseded shipping document is locked. OCR result cannot be saved.';
  END IF;

  SELECT s.name::text, b.booking_ref::text
    INTO v_shipper_name, v_booking_ref
  FROM public.shipping_documents sd
  JOIN public.shippers s ON s.id = sd.shipper_id
  JOIN public.shipper_shipment_batches b ON b.id = sd.shipment_batch_id
  WHERE sd.id = v_doc.id;

  DELETE FROM public.shipping_document_ocr_lines WHERE shipping_document_id = v_doc.id;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    INSERT INTO public.shipping_document_ocr_lines (
      shipping_document_id,
      line_order,
      description,
      quantity,
      amount_gbp,
      raw_line_json
    )
    SELECT
      v_doc.id,
      arr.ord::int,
      COALESCE(NULLIF(BTRIM(COALESCE(arr.line_item->>'description', '')), ''), 'OCR line ' || arr.ord::text),
      NULLIF(arr.line_item->>'quantity', '')::numeric,
      NULLIF(arr.line_item->>'amount_gbp', '')::numeric,
      arr.line_item
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS arr(line_item, ord)
    WHERE COALESCE(NULLIF(BTRIM(COALESCE(arr.line_item->>'description', '')), ''), NULLIF(arr.line_item->>'amount_gbp', '')) IS NOT NULL;

    GET DIAGNOSTICS v_inserted_lines = ROW_COUNT;
  END IF;

  v_match := public.internal_shipping_document_match_status_v1(
    v_shipper_name,
    v_booking_ref,
    v_doc.total_amount,
    p_ocr_shipper_name,
    COALESCE(p_ocr_reference_text, '') || ' ' || COALESCE(p_ocr_document_ref, ''),
    p_ocr_document_ref,
    p_ocr_document_date,
    p_ocr_total_amount,
    v_inserted_lines
  );

  UPDATE public.shipping_documents
     SET ocr_status = 'completed',
         review_status = 'needs_supervisor_review',
         mindee_model_id = COALESCE(NULLIF(BTRIM(COALESCE(p_model_id, '')), ''), mindee_model_id),
         mindee_job_id = COALESCE(NULLIF(BTRIM(COALESCE(p_mindee_job_id, '')), ''), mindee_job_id),
         mindee_inference_id = COALESCE(NULLIF(BTRIM(COALESCE(p_mindee_inference_id, '')), ''), mindee_inference_id),
         mindee_error_message = NULL,
         ocr_raw_json = COALESCE(p_raw_json, ocr_raw_json),
         ocr_pages_consumed = p_pages_consumed,
         ocr_shipper_name = NULLIF(BTRIM(COALESCE(p_ocr_shipper_name, '')), ''),
         ocr_reference_text = NULLIF(BTRIM(COALESCE(p_ocr_reference_text, '')), ''),
         ocr_document_ref = NULLIF(BTRIM(COALESCE(p_ocr_document_ref, '')), ''),
         ocr_document_date = p_ocr_document_date,
         ocr_total_amount = p_ocr_total_amount,
         ocr_match_status = v_match->>'status',
         ocr_match_summary_json = v_match,
         extracted_document_ref = COALESCE(NULLIF(BTRIM(COALESCE(p_ocr_document_ref, '')), ''), extracted_document_ref, document_ref),
         extracted_document_date = COALESCE(p_ocr_document_date, extracted_document_date, document_date),
         extracted_total_amount = COALESCE(p_ocr_total_amount, extracted_total_amount, total_amount),
         extracted_currency_code = COALESCE(extracted_currency_code, currency_code, 'GBP'),
         updated_at = now()
   WHERE id = v_doc.id;

  RETURN QUERY
  SELECT v_doc.id, v_doc.shipment_batch_id, (v_match->>'status')::text, v_inserted_lines;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_shipping_document_ocr_lines_v1(
  p_shipping_document_id uuid
)
RETURNS TABLE (
  line_order integer,
  description text,
  quantity numeric,
  amount_gbp numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipping OCR lines require auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for shipping OCR lines.';
  END IF;

  RETURN QUERY
  SELECT l.line_order, l.description, l.quantity, l.amount_gbp
  FROM public.shipping_document_ocr_lines l
  JOIN public.shipping_documents sd ON sd.id = l.shipping_document_id
  WHERE l.shipping_document_id = p_shipping_document_id
    AND sd.active = true
  ORDER BY l.line_order;
END;
$$;

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
  next_action text,
  ocr_match_status text,
  ocr_match_summary_json jsonb,
  ocr_shipper_name text,
  ocr_reference_text text,
  ocr_document_ref text,
  ocr_document_date date,
  ocr_total_amount numeric,
  mindee_job_id text,
  mindee_inference_id text,
  mindee_error_message text
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
    SELECT p.shipment_batch_id,
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
    SELECT sdm.shipping_document_id,
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
      WHEN sd.ocr_status IN ('queued','processing') THEN 'ocr_processing'
      WHEN sd.ocr_status = 'completed' AND sd.ocr_match_status = 'matched' THEN 'ocr_ready_matched'
      WHEN sd.ocr_status = 'completed' THEN 'ocr_ready_needs_review'
      ELSE 'supervisor_review_needed'
    END::text AS next_action,
    sd.ocr_match_status::text,
    sd.ocr_match_summary_json,
    sd.ocr_shipper_name::text,
    sd.ocr_reference_text::text,
    sd.ocr_document_ref::text,
    sd.ocr_document_date,
    sd.ocr_total_amount,
    sd.mindee_job_id::text,
    sd.mindee_inference_id::text,
    sd.mindee_error_message::text
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
  item_qty numeric,
  ocr_match_status text,
  ocr_match_summary_json jsonb,
  ocr_shipper_name text,
  ocr_reference_text text,
  ocr_document_ref text,
  ocr_document_date date,
  ocr_total_amount numeric,
  mindee_job_id text,
  mindee_inference_id text,
  mindee_error_message text
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
    SELECT p.shipment_batch_id,
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
    COALESCE(pc.item_qty, 0::numeric) AS item_qty,
    sd.ocr_match_status::text,
    sd.ocr_match_summary_json,
    sd.ocr_shipper_name::text,
    sd.ocr_reference_text::text,
    sd.ocr_document_ref::text,
    sd.ocr_document_date,
    sd.ocr_total_amount,
    sd.mindee_job_id::text,
    sd.mindee_inference_id::text,
    sd.mindee_error_message::text
  FROM public.shipping_documents sd
  JOIN public.shipper_shipment_batches b ON b.id = sd.shipment_batch_id
  JOIN public.shippers s ON s.id = sd.shipper_id
  LEFT JOIN public.importers i ON i.id = sd.importer_id
  LEFT JOIN package_counts pc ON pc.shipment_batch_id = sd.shipment_batch_id
  WHERE sd.id = p_shipping_document_id
    AND sd.active = true;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_document_match_status_v1(text,text,numeric,text,text,text,date,numeric,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_start_mindee_shipping_document_ocr_v1(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_record_shipping_mindee_enqueue_result_v1(uuid,text,integer,boolean,text,text,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_save_shipping_mindee_ocr_result_v1(uuid,text,integer,text,text,jsonb,text,text,text,date,numeric,integer,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_shipping_document_ocr_lines_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_shipping_document_worklist_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_shipping_document_detail_v1(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.internal_shipping_document_match_status_v1(text,text,numeric,text,text,text,date,numeric,integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.internal_start_mindee_shipping_document_ocr_v1(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_record_shipping_mindee_enqueue_result_v1(uuid,text,integer,boolean,text,text,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_save_shipping_mindee_ocr_result_v1(uuid,text,integer,text,text,jsonb,text,text,text,date,numeric,integer,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_ocr_lines_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_worklist_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
