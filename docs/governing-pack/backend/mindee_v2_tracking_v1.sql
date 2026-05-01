-- =============================================================================
-- mindee_v2_tracking_v1.sql
-- Multi Tenant Platform Build — additive Mindee V2 OCR tracking/idempotency
--
-- Purpose:
--   Add safe OCR enqueue/result tracking before any real invoice document is
--   sent to Mindee V2.
--
-- Principles:
--   - Additive only: no existing columns/tables/functions are dropped.
--   - Manual first: supports staff-controlled enqueue and result fetch.
--   - Idempotent: blocks repeat OCR sends once OCR exists or an active job exists.
--   - Audit: records each Mindee API attempt without exposing API keys.
--   - Human work is protected: re-OCR is blocked if non-OCR/progressed lines exist.
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

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

ALTER TABLE public.supplier_invoices
  ADD COLUMN IF NOT EXISTS mindee_job_id varchar,
  ADD COLUMN IF NOT EXISTS mindee_inference_id varchar,
  ADD COLUMN IF NOT EXISTS mindee_model_id varchar,
  ADD COLUMN IF NOT EXISTS mindee_ocr_status varchar NOT NULL DEFAULT 'not_started',
  ADD COLUMN IF NOT EXISTS mindee_enqueued_at timestamptz,
  ADD COLUMN IF NOT EXISTS mindee_completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS mindee_result_saved_at timestamptz,
  ADD COLUMN IF NOT EXISTS mindee_last_http_status int,
  ADD COLUMN IF NOT EXISTS mindee_pages_consumed int,
  ADD COLUMN IF NOT EXISTS mindee_error_message text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoices_mindee_ocr_status_check'
  ) THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT supplier_invoices_mindee_ocr_status_check
      CHECK (mindee_ocr_status IN ('not_started','enqueueing','queued','processing','completed','failed','cancelled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoices_mindee_pages_consumed_check'
  ) THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT supplier_invoices_mindee_pages_consumed_check
      CHECK (mindee_pages_consumed IS NULL OR mindee_pages_consumed >= 0);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_supplier_invoices_mindee_inference_id
  ON public.supplier_invoices(mindee_inference_id)
  WHERE mindee_inference_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_supplier_invoices_mindee_ocr_status
  ON public.supplier_invoices(mindee_ocr_status);

CREATE TABLE IF NOT EXISTS public.mindee_api_calls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  order_id uuid REFERENCES public.orders(id),
  actor_staff_id uuid REFERENCES public.staff(id),
  action_type varchar NOT NULL CHECK (action_type IN ('auth_check','enqueue','get_job','get_inference','save_result')),
  mindee_job_id varchar,
  mindee_inference_id varchar,
  mindee_model_id varchar,
  http_status int,
  request_started_at timestamptz NOT NULL DEFAULT now(),
  request_completed_at timestamptz,
  result_saved_at timestamptz,
  pages_consumed int CHECK (pages_consumed IS NULL OR pages_consumed >= 0),
  success_yn boolean NOT NULL DEFAULT false,
  error_message text,
  response_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mindee_api_calls_supplier_invoice
  ON public.mindee_api_calls(supplier_invoice_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_mindee_api_calls_inference
  ON public.mindee_api_calls(mindee_inference_id)
  WHERE mindee_inference_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_mindee_api_calls_job
  ON public.mindee_api_calls(mindee_job_id)
  WHERE mindee_job_id IS NOT NULL;

ALTER TABLE public.mindee_api_calls ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mindee_api_calls_staff_select ON public.mindee_api_calls;
CREATE POLICY mindee_api_calls_staff_select
ON public.mindee_api_calls
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
      AND s.role_type IN ('admin','supervisor')
  )
);

-- Inserts/updates are intentionally done through SECURITY DEFINER RPCs only.

CREATE OR REPLACE FUNCTION public.staff_start_mindee_invoice_ocr(
  p_supplier_invoice_id uuid,
  p_model_id varchar
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

CREATE OR REPLACE FUNCTION public.staff_record_mindee_enqueue_result(
  p_supplier_invoice_id uuid,
  p_model_id varchar,
  p_http_status int,
  p_success_yn boolean,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar,
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
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can record Mindee OCR.';
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
    'enqueue',
    NULLIF(btrim(COALESCE(p_mindee_job_id, '')), ''),
    NULLIF(btrim(COALESCE(p_mindee_inference_id, '')), ''),
    NULLIF(btrim(COALESCE(p_model_id, '')), ''),
    p_http_status,
    now(),
    COALESCE(p_success_yn, false),
    p_error_message,
    p_response_json
  );

  UPDATE public.supplier_invoices si
  SET
    mindee_ocr_status = CASE WHEN COALESCE(p_success_yn, false) THEN 'queued' ELSE 'failed' END,
    mindee_job_id = NULLIF(btrim(COALESCE(p_mindee_job_id, '')), ''),
    mindee_inference_id = NULLIF(btrim(COALESCE(p_mindee_inference_id, '')), ''),
    mindee_model_id = NULLIF(btrim(COALESCE(p_model_id, '')), ''),
    mindee_last_http_status = p_http_status,
    mindee_enqueued_at = CASE WHEN COALESCE(p_success_yn, false) THEN now() ELSE si.mindee_enqueued_at END,
    mindee_error_message = CASE WHEN COALESCE(p_success_yn, false) THEN NULL ELSE p_error_message END
  WHERE si.id = p_supplier_invoice_id;
END;
$$;

COMMENT ON COLUMN public.supplier_invoices.mindee_ocr_status IS
'Mindee V2 OCR lifecycle: not_started/enqueueing/queued/processing/completed/failed/cancelled. Used to prevent double sends.';

COMMENT ON COLUMN public.supplier_invoices.mindee_inference_id IS
'Mindee V2 inference id for result re-fetching/audit. Unique when present.';

COMMENT ON TABLE public.mindee_api_calls IS
'Audit table for Mindee API calls. Stores status/response metadata only; never stores API keys.';

COMMIT;
