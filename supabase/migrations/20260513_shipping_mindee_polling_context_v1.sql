BEGIN;

CREATE OR REPLACE FUNCTION public.internal_shipping_mindee_polling_context_v1(
  p_shipping_document_id uuid
)
RETURNS TABLE (
  shipping_document_id uuid,
  mindee_model_id text,
  mindee_job_id text,
  mindee_inference_id text,
  polling_url text,
  result_url text,
  ocr_status text,
  review_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipping Mindee polling context requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for shipping Mindee polling context.';
  END IF;

  RETURN QUERY
  SELECT
    sd.id,
    sd.mindee_model_id::text,
    sd.mindee_job_id::text,
    sd.mindee_inference_id::text,
    COALESCE(
      sd.ocr_raw_json #>> '{job,polling_url}',
      sd.ocr_raw_json #>> '{polling_url}'
    )::text AS polling_url,
    COALESCE(
      sd.ocr_raw_json #>> '{job,result_url}',
      sd.ocr_raw_json #>> '{result_url}'
    )::text AS result_url,
    sd.ocr_status::text,
    sd.review_status::text
  FROM public.shipping_documents sd
  WHERE sd.id = p_shipping_document_id
    AND sd.active = true;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_mindee_polling_context_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_mindee_polling_context_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
