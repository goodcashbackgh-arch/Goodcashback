-- =============================================================================
-- mindee_v2_cached_result_recovery_v1.sql
-- Multi Tenant Platform Build — cached Mindee result recovery RPC
--
-- Purpose:
--   If Mindee already returned a completed result in mindee_api_calls.response_json,
--   save that cached result into supplier_invoices and supplier_invoice_lines
--   without calling Mindee again.
--
-- Why:
--   Mindee V2 job polling may return the completed inference/result once. Later
--   job/inference fetches can 404. The platform must use the cached successful
--   result instead of resending the invoice or treating it as lost.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_save_cached_mindee_invoice_ocr_result(
  p_supplier_invoice_id uuid
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  order_id uuid,
  inserted_line_count int,
  saved_from_cache_yn boolean,
  pages_consumed int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_call public.mindee_api_calls%ROWTYPE;
  v_human_or_progressed_lines int;
  v_inserted_lines int := 0;
  v_pages int;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can save cached Mindee OCR results.';
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
    RETURN QUERY SELECT p_supplier_invoice_id, v_invoice.order_id, 0, false, v_invoice.mindee_pages_consumed;
    RETURN;
  END IF;

  SELECT *
  INTO v_call
  FROM public.mindee_api_calls mac
  WHERE mac.supplier_invoice_id = p_supplier_invoice_id
    AND mac.success_yn = true
    AND mac.http_status = 200
    AND mac.response_json #> '{inference,result,fields}' IS NOT NULL
  ORDER BY mac.request_completed_at DESC NULLS LAST, mac.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT p_supplier_invoice_id, v_invoice.order_id, 0, false, NULL::int;
    RETURN;
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
    RAISE EXCEPTION 'Cannot save cached OCR result because manual/progressed invoice lines already exist. This protects human work.';
  END IF;

  DELETE FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND sil.line_source = 'ocr_extracted';

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
    item.ord::int,
    NULLIF(item.line_item #>> '{fields,product_code,value}', ''),
    COALESCE(
      NULLIF(item.line_item #>> '{fields,description,value}', ''),
      'OCR line ' || item.ord::text
    ),
    COALESCE(NULLIF(item.line_item #>> '{fields,quantity,value}', '')::numeric, 1),
    COALESCE(
      NULLIF(item.line_item #>> '{fields,total_price,value}', '')::numeric,
      NULLIF(item.line_item #>> '{fields,total_amount,value}', '')::numeric,
      NULLIF(item.line_item #>> '{fields,unit_price,value}', '')::numeric,
      0
    ),
    'ocr_extracted',
    'N'
  FROM jsonb_array_elements(
    COALESCE(v_call.response_json #> '{inference,result,fields,line_items,items}', '[]'::jsonb)
  ) WITH ORDINALITY AS item(line_item, ord)
  WHERE COALESCE(
      NULLIF(item.line_item #>> '{fields,total_price,value}', '')::numeric,
      NULLIF(item.line_item #>> '{fields,total_amount,value}', '')::numeric,
      NULLIF(item.line_item #>> '{fields,unit_price,value}', '')::numeric,
      0
    ) >= 0;

  GET DIAGNOSTICS v_inserted_lines = ROW_COUNT;

  v_pages := NULLIF(v_call.response_json #>> '{inference,file,page_count}', '')::int;

  UPDATE public.supplier_invoices si
  SET
    ocr_service_used = 'mindee',
    ocr_raw_json = v_call.response_json,
    ocr_extracted_at = now(),
    ocr_invoice_ref = NULLIF(v_call.response_json #>> '{inference,result,fields,invoice_number,value}', ''),
    ocr_retailer_name = NULLIF(v_call.response_json #>> '{inference,result,fields,supplier_name,value}', ''),
    ocr_invoice_date = NULLIF(v_call.response_json #>> '{inference,result,fields,date,value}', '')::date,
    ocr_invoice_total_gbp = NULLIF(v_call.response_json #>> '{inference,result,fields,total_amount,value}', '')::numeric,
    review_status = 'pending_review',
    blocked_from_sage_yn = true,
    mindee_ocr_status = 'completed',
    mindee_job_id = COALESCE(v_call.mindee_job_id, si.mindee_job_id),
    mindee_inference_id = COALESCE(v_call.response_json #>> '{inference,id}', v_call.mindee_inference_id, si.mindee_inference_id),
    mindee_model_id = COALESCE(v_call.mindee_model_id, v_call.response_json #>> '{inference,model,id}', si.mindee_model_id),
    mindee_completed_at = now(),
    mindee_result_saved_at = now(),
    mindee_last_http_status = 200,
    mindee_pages_consumed = v_pages,
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
    COALESCE(v_call.mindee_job_id, v_invoice.mindee_job_id),
    COALESCE(v_call.response_json #>> '{inference,id}', v_call.mindee_inference_id, v_invoice.mindee_inference_id),
    COALESCE(v_call.mindee_model_id, v_call.response_json #>> '{inference,model,id}', v_invoice.mindee_model_id),
    200,
    now(),
    now(),
    v_pages,
    true,
    v_call.response_json
  );

  RETURN QUERY SELECT p_supplier_invoice_id, v_invoice.order_id, v_inserted_lines, true, v_pages;
END;
$$;

COMMIT;
