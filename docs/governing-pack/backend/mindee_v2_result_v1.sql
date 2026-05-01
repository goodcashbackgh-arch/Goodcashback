-- =============================================================================
-- mindee_v2_result_v1.sql
-- Multi Tenant Platform Build — additive Mindee V2 result polling/save RPCs
--
-- Run after mindee_v2_tracking_v1.sql.
-- Purpose:
--   Save a completed Mindee V2 inference result into existing OCR receptacles:
--   supplier_invoices OCR header fields, supplier_invoice_lines OCR rows, and
--   supplier_invoice_review_flags. Fetching/polling results does not send a new
--   document to Mindee and should not consume extra page credits.
--
-- Schema discipline:
--   supplier_invoices.ocr_service_used currently allows 'mindee',
--   'google_docai', or 'manual'. Mindee V2 detail is tracked in the Mindee job,
--   inference, model id, and raw JSON fields. Do not use 'mindee_v2' here unless
--   the live check constraint is explicitly widened later.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regclass('public.mindee_api_calls') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.mindee_api_calls. Run mindee_v2_tracking_v1.sql first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_record_mindee_job_poll(
  p_supplier_invoice_id uuid,
  p_model_id varchar,
  p_http_status int,
  p_success_yn boolean,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar,
  p_job_status varchar,
  p_response_json jsonb,
  p_error_message text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_order_id uuid;
  v_next_status varchar;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can poll Mindee OCR results.';
  END IF;

  SELECT si.order_id
  INTO v_order_id
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  INSERT INTO public.mindee_api_calls (
    supplier_invoice_id,
    order_id,
    actor_staff_id,
    action_type,
    mindee_job_id,
    mindee_inference_id,
    mindee_model_id,
    http_status,
    request_completed_at,
    success_yn,
    error_message,
    response_json
  ) VALUES (
    p_supplier_invoice_id,
    v_order_id,
    v_staff_id,
    'get_job',
    NULLIF(btrim(COALESCE(p_mindee_job_id, '')), ''),
    NULLIF(btrim(COALESCE(p_mindee_inference_id, '')), ''),
    NULLIF(btrim(COALESCE(p_model_id, '')), ''),
    p_http_status,
    now(),
    COALESCE(p_success_yn, false),
    p_error_message,
    p_response_json
  );

  v_next_status := CASE
    WHEN NOT COALESCE(p_success_yn, false) THEN 'failed'
    WHEN lower(COALESCE(p_job_status, '')) IN ('failed','failure','error') THEN 'failed'
    WHEN lower(COALESCE(p_job_status, '')) IN ('completed','complete','processed','done','success','succeeded') THEN 'processing'
    ELSE 'processing'
  END;

  UPDATE public.supplier_invoices si
  SET
    mindee_ocr_status = v_next_status,
    mindee_job_id = COALESCE(NULLIF(btrim(COALESCE(p_mindee_job_id, '')), ''), si.mindee_job_id),
    mindee_inference_id = COALESCE(NULLIF(btrim(COALESCE(p_mindee_inference_id, '')), ''), si.mindee_inference_id),
    mindee_model_id = COALESCE(NULLIF(btrim(COALESCE(p_model_id, '')), ''), si.mindee_model_id),
    mindee_last_http_status = p_http_status,
    mindee_error_message = CASE WHEN v_next_status = 'failed' THEN p_error_message ELSE NULL END
  WHERE si.id = p_supplier_invoice_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_save_mindee_invoice_ocr_result(
  p_supplier_invoice_id uuid,
  p_model_id varchar,
  p_http_status int,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar,
  p_raw_json jsonb,
  p_ocr_invoice_ref varchar,
  p_ocr_retailer_name varchar,
  p_ocr_invoice_date date,
  p_ocr_invoice_total_gbp numeric,
  p_pages_consumed int,
  p_lines jsonb,
  p_flags jsonb DEFAULT '[]'::jsonb
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  order_id uuid,
  inserted_line_count int,
  inserted_flag_count int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_human_or_progressed_lines int;
  v_inserted_lines int := 0;
  v_inserted_flags int := 0;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can save Mindee OCR results.';
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF v_invoice.review_status IN ('rejected_resubmit_required','superseded','duplicate_blocked') THEN
    RAISE EXCEPTION 'Cannot save OCR result against a rejected, superseded, or duplicate-blocked supplier invoice.';
  END IF;

  IF v_invoice.ocr_raw_json IS NOT NULL THEN
    RAISE EXCEPTION 'OCR result already exists for this supplier invoice. Refusing to overwrite.';
  END IF;

  SELECT count(*)
  INTO v_human_or_progressed_lines
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND (
      sil.line_source <> 'ocr_extracted'
      OR sil.eligible_for_invoice_yn = 'Y'
    );

  IF COALESCE(v_human_or_progressed_lines, 0) > 0 THEN
    RAISE EXCEPTION 'Cannot save OCR result because manual/progressed invoice lines already exist. This protects human work.';
  END IF;

  DELETE FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND sil.line_source = 'ocr_extracted';

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    INSERT INTO public.supplier_invoice_lines (
      supplier_invoice_id,
      line_order,
      retailer_sku,
      description,
      qty,
      amount_inc_vat_gbp,
      line_source,
      eligible_for_invoice_yn
    )
    SELECT
      p_supplier_invoice_id,
      arr.ord::int,
      NULLIF(btrim(COALESCE(arr.line_item->>'retailer_sku', '')), ''),
      COALESCE(NULLIF(btrim(COALESCE(arr.line_item->>'description', '')), ''), 'OCR line ' || arr.ord::text),
      COALESCE(NULLIF(arr.line_item->>'qty', '')::numeric, 1),
      COALESCE(NULLIF(arr.line_item->>'amount_inc_vat_gbp', '')::numeric, 0),
      'ocr_extracted',
      'N'
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS arr(line_item, ord)
    WHERE COALESCE(NULLIF(arr.line_item->>'amount_inc_vat_gbp', '')::numeric, 0) >= 0;

    GET DIAGNOSTICS v_inserted_lines = ROW_COUNT;
  END IF;

  UPDATE public.supplier_invoices si
  SET
    ocr_service_used = 'mindee',
    ocr_raw_json = p_raw_json,
    ocr_extracted_at = now(),
    ocr_invoice_ref = NULLIF(btrim(COALESCE(p_ocr_invoice_ref, '')), ''),
    ocr_retailer_name = NULLIF(btrim(COALESCE(p_ocr_retailer_name, '')), ''),
    ocr_invoice_date = p_ocr_invoice_date,
    ocr_invoice_total_gbp = p_ocr_invoice_total_gbp,
    review_status = 'pending_review',
    blocked_from_sage_yn = true,
    mindee_ocr_status = 'completed',
    mindee_job_id = COALESCE(NULLIF(btrim(COALESCE(p_mindee_job_id, '')), ''), si.mindee_job_id),
    mindee_inference_id = COALESCE(NULLIF(btrim(COALESCE(p_mindee_inference_id, '')), ''), si.mindee_inference_id),
    mindee_model_id = COALESCE(NULLIF(btrim(COALESCE(p_model_id, '')), ''), si.mindee_model_id),
    mindee_completed_at = now(),
    mindee_result_saved_at = now(),
    mindee_last_http_status = p_http_status,
    mindee_pages_consumed = p_pages_consumed,
    mindee_error_message = NULL
  WHERE si.id = p_supplier_invoice_id;

  INSERT INTO public.mindee_api_calls (
    supplier_invoice_id,
    order_id,
    actor_staff_id,
    action_type,
    mindee_job_id,
    mindee_inference_id,
    mindee_model_id,
    http_status,
    request_completed_at,
    result_saved_at,
    pages_consumed,
    success_yn,
    response_json
  ) VALUES (
    p_supplier_invoice_id,
    v_invoice.order_id,
    v_staff_id,
    'save_result',
    NULLIF(btrim(COALESCE(p_mindee_job_id, '')), ''),
    NULLIF(btrim(COALESCE(p_mindee_inference_id, '')), ''),
    NULLIF(btrim(COALESCE(p_model_id, '')), ''),
    p_http_status,
    now(),
    now(),
    p_pages_consumed,
    true,
    p_raw_json
  );

  IF p_flags IS NOT NULL AND jsonb_typeof(p_flags) = 'array' THEN
    INSERT INTO public.supplier_invoice_review_flags (
      order_id,
      supplier_invoice_id,
      flag_type,
      message,
      status,
      raised_by_operator_id
    )
    SELECT
      v_invoice.order_id,
      p_supplier_invoice_id,
      flag_item.flag_type,
      flag_item.message,
      'open',
      v_invoice.uploaded_by_operator_id
    FROM jsonb_to_recordset(p_flags) AS flag_item(flag_type text, message text)
    WHERE flag_item.flag_type IS NOT NULL
      AND flag_item.message IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.supplier_invoice_review_flags existing
        WHERE existing.supplier_invoice_id = p_supplier_invoice_id
          AND existing.flag_type = flag_item.flag_type
          AND existing.status IN ('open','under_review')
      );

    GET DIAGNOSTICS v_inserted_flags = ROW_COUNT;
  END IF;

  RETURN QUERY
  SELECT p_supplier_invoice_id, v_invoice.order_id, v_inserted_lines, v_inserted_flags;
END;
$$;

COMMIT;
