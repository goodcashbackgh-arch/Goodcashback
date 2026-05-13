BEGIN;

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

  DELETE FROM public.shipping_document_ocr_lines ocl
  WHERE ocl.shipping_document_id = v_doc.id;

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

  UPDATE public.shipping_documents upd
     SET ocr_status = 'completed',
         review_status = 'needs_supervisor_review',
         mindee_model_id = COALESCE(NULLIF(BTRIM(COALESCE(p_model_id, '')), ''), upd.mindee_model_id),
         mindee_job_id = COALESCE(NULLIF(BTRIM(COALESCE(p_mindee_job_id, '')), ''), upd.mindee_job_id),
         mindee_inference_id = COALESCE(NULLIF(BTRIM(COALESCE(p_mindee_inference_id, '')), ''), upd.mindee_inference_id),
         mindee_error_message = NULL,
         ocr_raw_json = COALESCE(p_raw_json, upd.ocr_raw_json),
         ocr_pages_consumed = p_pages_consumed,
         ocr_shipper_name = NULLIF(BTRIM(COALESCE(p_ocr_shipper_name, '')), ''),
         ocr_reference_text = NULLIF(BTRIM(COALESCE(p_ocr_reference_text, '')), ''),
         ocr_document_ref = NULLIF(BTRIM(COALESCE(p_ocr_document_ref, '')), ''),
         ocr_document_date = p_ocr_document_date,
         ocr_total_amount = p_ocr_total_amount,
         ocr_match_status = v_match->>'status',
         ocr_match_summary_json = v_match,
         extracted_document_ref = COALESCE(NULLIF(BTRIM(COALESCE(p_ocr_document_ref, '')), ''), upd.extracted_document_ref, upd.document_ref),
         extracted_document_date = COALESCE(p_ocr_document_date, upd.extracted_document_date, upd.document_date),
         extracted_total_amount = COALESCE(p_ocr_total_amount, upd.extracted_total_amount, upd.total_amount),
         extracted_currency_code = COALESCE(upd.extracted_currency_code, upd.currency_code, 'GBP'),
         updated_at = now()
   WHERE upd.id = v_doc.id;

  RETURN QUERY
  SELECT
    v_doc.id AS shipping_document_id,
    v_doc.shipment_batch_id AS shipment_batch_id,
    (v_match->>'status')::text AS ocr_match_status,
    v_inserted_lines AS inserted_line_count;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_save_shipping_mindee_ocr_result_v1(uuid,text,integer,text,text,jsonb,text,text,text,date,numeric,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_save_shipping_mindee_ocr_result_v1(uuid,text,integer,text,text,jsonb,text,text,text,date,numeric,integer,jsonb) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
