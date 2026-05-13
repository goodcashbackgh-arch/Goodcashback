BEGIN;

-- Staff-safe wrapper around the service-level shipping Mindee OCR save function.
-- This lets admin/supervisor staff save an already-fetched Mindee result from the internal fallback checker
-- without exposing the lower-level save function directly to every authenticated user.
CREATE OR REPLACE FUNCTION public.internal_staff_save_shipping_mindee_ocr_result_v1(
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
  v_auth_uid uuid := auth.uid();
  v_staff_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff shipping OCR result save requires auth.uid()';
  END IF;

  SELECT st.id INTO v_staff_id
  FROM public.staff st
  WHERE st.auth_user_id = v_auth_uid
    AND st.active = true
    AND st.role_type IN ('admin','supervisor')
  ORDER BY st.created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin or supervisor staff account required for shipping OCR result save.';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.internal_save_shipping_mindee_ocr_result_v1(
    p_shipping_document_id,
    p_model_id,
    p_http_status,
    p_mindee_job_id,
    p_mindee_inference_id,
    p_raw_json,
    p_ocr_shipper_name,
    p_ocr_reference_text,
    p_ocr_document_ref,
    p_ocr_document_date,
    p_ocr_total_amount,
    p_pages_consumed,
    p_lines
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_staff_save_shipping_mindee_ocr_result_v1(uuid,text,integer,text,text,jsonb,text,text,text,date,numeric,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_staff_save_shipping_mindee_ocr_result_v1(uuid,text,integer,text,text,jsonb,text,text,text,date,numeric,integer,jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
