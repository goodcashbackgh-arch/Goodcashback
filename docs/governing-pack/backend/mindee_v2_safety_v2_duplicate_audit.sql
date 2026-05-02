-- =============================================================================
-- mindee_v2_safety_v2_duplicate_audit.sql
-- Multi Tenant Platform Build — Mindee duplicate guard + audit compatibility
--
-- Run after:
--   docs/governing-pack/backend/mindee_v2_tracking_v1.sql
--   docs/governing-pack/backend/mindee_v2_result_v1.sql
--
-- Purpose:
--   1. Prevent staff from spending a Mindee OCR page on likely duplicate invoices.
--   2. Provide the expected mindee_v2_request_audit view name for debugging.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.mindee_api_calls') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.mindee_api_calls. Run mindee_v2_tracking_v1.sql first.';
  END IF;
END $$;

CREATE OR REPLACE VIEW public.mindee_v2_request_audit AS
SELECT
  mac.id,
  mac.supplier_invoice_id,
  mac.order_id,
  mac.action_type,
  mac.http_status,
  mac.success_yn,
  mac.mindee_job_id,
  mac.mindee_inference_id,
  mac.mindee_model_id,
  mac.request_started_at,
  mac.request_completed_at,
  mac.result_saved_at,
  mac.pages_consumed AS page_count,
  mac.error_message AS detail,
  mac.response_json,
  mac.created_at,
  CASE
    WHEN mac.action_type = 'get_job' THEN mac.response_json #>> '{job,status}'
    ELSE NULL
  END AS job_status,
  CASE
    WHEN mac.action_type = 'enqueue' THEN mac.response_json #>> '{job,polling_url}'
    ELSE NULL
  END AS polling_url,
  COALESCE(
    mac.response_json #>> '{inference,id}',
    mac.response_json #>> '{job,inference_id}',
    mac.response_json #>> '{inference_id}'
  ) AS inference_id_in_response
FROM public.mindee_api_calls mac;

CREATE OR REPLACE FUNCTION public.staff_find_supplier_invoice_ocr_duplicates(
  p_supplier_invoice_id uuid
)
RETURNS TABLE (
  duplicate_supplier_invoice_id uuid,
  duplicate_order_id uuid,
  duplicate_invoice_ref varchar,
  duplicate_review_status varchar,
  duplicate_mindee_ocr_status varchar,
  duplicate_ocr_invoice_ref varchar,
  duplicate_ocr_invoice_total_gbp numeric,
  duplicate_invoice_total_gbp numeric,
  duplicate_reason text,
  duplicate_severity varchar
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_total numeric;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can check Mindee OCR duplicates.';
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  SELECT sifs.invoice_total_gbp
  INTO v_total
  FROM public.supplier_invoice_financial_summary sifs
  WHERE sifs.supplier_invoice_id = p_supplier_invoice_id
  LIMIT 1;

  RETURN QUERY
  WITH current_invoice AS (
    SELECT
      v_invoice.id AS id,
      v_invoice.order_id AS order_id,
      v_invoice.retailer_id AS retailer_id,
      lower(regexp_replace(COALESCE(v_invoice.invoice_ref, ''), '[^a-zA-Z0-9]+', '', 'g')) AS invoice_ref_norm,
      round(COALESCE(v_total, v_invoice.ocr_invoice_total_gbp, 0)::numeric, 2) AS total_gbp,
      v_invoice.invoice_pdf_url AS invoice_pdf_url
  ), candidate_totals AS (
    SELECT
      si.id,
      si.order_id,
      si.invoice_ref,
      si.review_status,
      si.mindee_ocr_status,
      si.ocr_invoice_ref,
      si.ocr_invoice_total_gbp,
      sifs.invoice_total_gbp,
      si.invoice_pdf_url,
      si.retailer_id,
      lower(regexp_replace(COALESCE(si.invoice_ref, ''), '[^a-zA-Z0-9]+', '', 'g')) AS invoice_ref_norm,
      round(COALESCE(sifs.invoice_total_gbp, si.ocr_invoice_total_gbp, 0)::numeric, 2) AS total_gbp
    FROM public.supplier_invoices si
    LEFT JOIN public.supplier_invoice_financial_summary sifs
      ON sifs.supplier_invoice_id = si.id
    WHERE si.id <> p_supplier_invoice_id
      AND si.review_status NOT IN ('rejected_resubmit_required','superseded')
  ), matches AS (
    SELECT
      c.id,
      c.order_id,
      c.invoice_ref,
      c.review_status,
      c.mindee_ocr_status,
      c.ocr_invoice_ref,
      c.ocr_invoice_total_gbp,
      c.invoice_total_gbp,
      CASE
        WHEN c.order_id = ci.order_id AND c.invoice_ref_norm = ci.invoice_ref_norm THEN 'Same order and invoice reference already exists.'
        WHEN c.retailer_id = ci.retailer_id AND c.invoice_ref_norm = ci.invoice_ref_norm AND abs(c.total_gbp - ci.total_gbp) <= 0.01 THEN 'Same retailer, invoice reference and total already exists.'
        WHEN c.invoice_ref_norm = ci.invoice_ref_norm AND abs(c.total_gbp - ci.total_gbp) <= 0.01 AND c.mindee_ocr_status IN ('queued','processing','completed') THEN 'Same invoice reference and total already queued/processed for OCR.'
        WHEN c.invoice_pdf_url IS NOT NULL AND ci.invoice_pdf_url IS NOT NULL AND c.invoice_pdf_url = ci.invoice_pdf_url THEN 'Same invoice file URL already exists.'
        ELSE NULL
      END AS reason
    FROM candidate_totals c
    CROSS JOIN current_invoice ci
    WHERE
      ci.invoice_ref_norm <> ''
      AND (
        (c.order_id = ci.order_id AND c.invoice_ref_norm = ci.invoice_ref_norm)
        OR (c.retailer_id = ci.retailer_id AND c.invoice_ref_norm = ci.invoice_ref_norm AND abs(c.total_gbp - ci.total_gbp) <= 0.01)
        OR (c.invoice_ref_norm = ci.invoice_ref_norm AND abs(c.total_gbp - ci.total_gbp) <= 0.01 AND c.mindee_ocr_status IN ('queued','processing','completed'))
        OR (c.invoice_pdf_url IS NOT NULL AND ci.invoice_pdf_url IS NOT NULL AND c.invoice_pdf_url = ci.invoice_pdf_url)
      )
  )
  SELECT
    m.id,
    m.order_id,
    m.invoice_ref,
    m.review_status,
    m.mindee_ocr_status,
    m.ocr_invoice_ref,
    m.ocr_invoice_total_gbp,
    m.invoice_total_gbp,
    m.reason,
    CASE
      WHEN m.mindee_ocr_status IN ('queued','processing','completed') THEN 'block'
      ELSE 'warning'
    END::varchar AS duplicate_severity
  FROM matches m
  WHERE m.reason IS NOT NULL
  ORDER BY
    CASE WHEN m.mindee_ocr_status IN ('queued','processing','completed') THEN 0 ELSE 1 END,
    m.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_start_mindee_invoice_ocr(
  p_supplier_invoice_id uuid,
  p_model_id varchar,
  p_allow_duplicate_override boolean DEFAULT false
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  order_id uuid,
  invoice_pdf_url varchar,
  uploaded_by_operator_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_human_or_progressed_lines int;
  v_duplicate_count int;
  v_first_duplicate text;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can start Mindee OCR.';
  END IF;

  IF p_model_id IS NULL OR btrim(p_model_id) = '' THEN
    RAISE EXCEPTION 'Mindee model id is required.';
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
    RAISE EXCEPTION 'Cannot OCR a rejected, superseded, or duplicate-blocked supplier invoice.';
  END IF;

  IF v_invoice.invoice_pdf_url IS NULL OR btrim(v_invoice.invoice_pdf_url) = '' THEN
    RAISE EXCEPTION 'Supplier invoice PDF URL is missing.';
  END IF;

  IF v_invoice.ocr_raw_json IS NOT NULL THEN
    RAISE EXCEPTION 'Mindee OCR is blocked because OCR raw JSON already exists for this invoice.';
  END IF;

  IF v_invoice.mindee_ocr_status IN ('enqueueing','queued','processing','completed') THEN
    RAISE EXCEPTION 'Mindee OCR is already % for this invoice.', v_invoice.mindee_ocr_status;
  END IF;

  SELECT count(*), min(duplicate_reason)
  INTO v_duplicate_count, v_first_duplicate
  FROM public.staff_find_supplier_invoice_ocr_duplicates(p_supplier_invoice_id)
  WHERE duplicate_severity = 'block';

  IF COALESCE(v_duplicate_count, 0) > 0 AND NOT COALESCE(p_allow_duplicate_override, false) THEN
    RAISE EXCEPTION 'Possible duplicate invoice blocked before Mindee OCR spend: %', COALESCE(v_first_duplicate, 'duplicate found');
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
    RAISE EXCEPTION 'Mindee OCR is blocked because manual/progressed invoice lines already exist. This protects human work.';
  END IF;

  UPDATE public.supplier_invoices si
  SET
    mindee_ocr_status = 'enqueueing',
    mindee_model_id = btrim(p_model_id),
    mindee_error_message = NULL,
    mindee_last_http_status = NULL,
    mindee_job_id = NULL,
    mindee_inference_id = NULL,
    mindee_enqueued_at = NULL,
    mindee_completed_at = NULL,
    mindee_result_saved_at = NULL,
    mindee_pages_consumed = NULL
  WHERE si.id = p_supplier_invoice_id;

  INSERT INTO public.mindee_api_calls (
    supplier_invoice_id,
    order_id,
    actor_staff_id,
    action_type,
    mindee_model_id,
    success_yn
  ) VALUES (
    p_supplier_invoice_id,
    v_invoice.order_id,
    v_staff_id,
    'enqueue',
    btrim(p_model_id),
    false
  );

  RETURN QUERY
  SELECT
    v_invoice.id,
    v_invoice.order_id,
    v_invoice.invoice_pdf_url,
    v_invoice.uploaded_by_operator_id;
END;
$$;

COMMIT;
