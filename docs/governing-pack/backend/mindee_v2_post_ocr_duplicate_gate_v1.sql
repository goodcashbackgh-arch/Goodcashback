-- =============================================================================
-- mindee_v2_post_ocr_duplicate_gate_v1.sql
-- Multi Tenant Platform Build — post-OCR duplicate protection
--
-- Purpose:
--   Catch duplicates where the operator entered a different invoice ref/amount,
--   but Mindee OCR extracts the real invoice ref/total that has already been
--   processed on another supplier invoice.
--
-- Run after:
--   supplier_invoice_review_flags_v1.sql
--   mindee_v2_result_v1.sql
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_financial_summary') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_financial_summary';
  END IF;

  IF to_regclass('public.supplier_invoice_review_flags') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_review_flags. Run supplier_invoice_review_flags_v1.sql first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_find_supplier_invoice_post_ocr_duplicates(
  p_supplier_invoice_id uuid
)
RETURNS TABLE (
  duplicate_supplier_invoice_id uuid,
  duplicate_order_id uuid,
  duplicate_invoice_ref varchar,
  duplicate_ocr_invoice_ref varchar,
  duplicate_review_status varchar,
  duplicate_mindee_ocr_status varchar,
  duplicate_total_gbp numeric,
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
  v_current_ref_norm text;
  v_current_total numeric;
  v_current_ocr_retailer_norm text;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can check post-OCR duplicates.';
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  v_current_ref_norm := lower(regexp_replace(COALESCE(v_invoice.ocr_invoice_ref, ''), '[^a-zA-Z0-9]+', '', 'g'));
  v_current_total := round(COALESCE(v_invoice.ocr_invoice_total_gbp, 0)::numeric, 2);
  v_current_ocr_retailer_norm := lower(regexp_replace(COALESCE(v_invoice.ocr_retailer_name, ''), '[^a-zA-Z0-9]+', '', 'g'));

  IF v_current_ref_norm = '' OR v_current_total <= 0 THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH candidate AS (
    SELECT
      si.id,
      si.order_id,
      si.invoice_ref,
      si.ocr_invoice_ref,
      si.review_status,
      si.mindee_ocr_status,
      round(COALESCE(si.ocr_invoice_total_gbp, sifs.invoice_total_gbp, 0)::numeric, 2) AS candidate_total,
      lower(regexp_replace(COALESCE(si.ocr_invoice_ref, si.invoice_ref, ''), '[^a-zA-Z0-9]+', '', 'g')) AS candidate_ref_norm,
      lower(regexp_replace(COALESCE(si.ocr_retailer_name, ''), '[^a-zA-Z0-9]+', '', 'g')) AS candidate_ocr_retailer_norm,
      si.retailer_id,
      si.ocr_raw_json,
      si.is_current_for_order
    FROM public.supplier_invoices si
    LEFT JOIN public.supplier_invoice_financial_summary sifs
      ON sifs.supplier_invoice_id = si.id
    WHERE si.id <> p_supplier_invoice_id
      AND si.review_status NOT IN ('rejected_resubmit_required','superseded')
  )
  SELECT
    c.id,
    c.order_id,
    c.invoice_ref,
    c.ocr_invoice_ref,
    c.review_status,
    c.mindee_ocr_status,
    c.candidate_total,
    CASE
      WHEN c.retailer_id = v_invoice.retailer_id
        THEN 'OCR extracted an invoice ref/total already processed for the same retailer.'
      WHEN v_current_ocr_retailer_norm <> ''
        AND c.candidate_ocr_retailer_norm <> ''
        AND (v_current_ocr_retailer_norm = c.candidate_ocr_retailer_norm
          OR v_current_ocr_retailer_norm LIKE '%' || c.candidate_ocr_retailer_norm || '%'
          OR c.candidate_ocr_retailer_norm LIKE '%' || v_current_ocr_retailer_norm || '%')
        THEN 'OCR extracted an invoice ref/total already processed for a matching OCR retailer name.'
      ELSE 'OCR extracted an invoice ref/total already processed elsewhere.'
    END AS duplicate_reason,
    'block'::varchar AS duplicate_severity
  FROM candidate c
  WHERE c.candidate_ref_norm = v_current_ref_norm
    AND abs(c.candidate_total - v_current_total) <= 0.01
    AND (c.ocr_raw_json IS NOT NULL OR c.mindee_ocr_status IN ('queued','processing','completed') OR c.is_current_for_order = true)
    AND (
      c.retailer_id = v_invoice.retailer_id
      OR (
        v_current_ocr_retailer_norm <> ''
        AND c.candidate_ocr_retailer_norm <> ''
        AND (
          v_current_ocr_retailer_norm = c.candidate_ocr_retailer_norm
          OR v_current_ocr_retailer_norm LIKE '%' || c.candidate_ocr_retailer_norm || '%'
          OR c.candidate_ocr_retailer_norm LIKE '%' || v_current_ocr_retailer_norm || '%'
        )
      )
    )
  ORDER BY c.is_current_for_order DESC, c.review_status = 'duplicate_blocked', c.id
  LIMIT 10;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_apply_post_ocr_duplicate_gate(
  p_supplier_invoice_id uuid
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  duplicate_count int,
  first_duplicate_supplier_invoice_id uuid,
  duplicate_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_duplicate_count int := 0;
  v_first_duplicate_id uuid;
  v_first_reason text;
  v_message text;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can apply post-OCR duplicate gate.';
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  SELECT count(*), min(d.duplicate_supplier_invoice_id), min(d.duplicate_reason)
  INTO v_duplicate_count, v_first_duplicate_id, v_first_reason
  FROM public.staff_find_supplier_invoice_post_ocr_duplicates(p_supplier_invoice_id) d
  WHERE d.duplicate_severity = 'block';

  IF COALESCE(v_duplicate_count, 0) > 0 THEN
    v_message := 'Possible duplicate invoice blocked after OCR. OCR extracted invoice ref '
      || COALESCE(v_invoice.ocr_invoice_ref, '—')
      || ' and total '
      || COALESCE(v_invoice.ocr_invoice_total_gbp::text, '—')
      || ', matching existing supplier invoice '
      || COALESCE(v_first_duplicate_id::text, 'unknown')
      || '. ' || COALESCE(v_first_reason, 'Duplicate suspected.');

    UPDATE public.supplier_invoices si
    SET
      review_status = 'duplicate_blocked',
      blocked_from_sage_yn = true,
      review_notes = concat_ws(E'\n', NULLIF(si.review_notes, ''), v_message)
    WHERE si.id = p_supplier_invoice_id;

    IF v_invoice.uploaded_by_operator_id IS NOT NULL THEN
      INSERT INTO public.supplier_invoice_review_flags (
        order_id,
        supplier_invoice_id,
        flag_type,
        message,
        status,
        raised_by_operator_id
      )
      VALUES (
        v_invoice.order_id,
        p_supplier_invoice_id,
        'wrong_invoice',
        v_message,
        'open',
        v_invoice.uploaded_by_operator_id
      )
      ON CONFLICT ON CONSTRAINT uq_supplier_invoice_review_flags_open_type DO NOTHING;
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    p_supplier_invoice_id,
    COALESCE(v_duplicate_count, 0),
    v_first_duplicate_id,
    v_first_reason;
END;
$$;

COMMIT;
