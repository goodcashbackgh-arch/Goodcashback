-- =============================================================================
-- supplier_invoice_header_review_rpc_v1.sql
-- Multi Tenant Platform Build — supplier invoice header correction
--
-- Purpose:
--   Allows admin/supervisor staff to save accepted invoice header/OCR values
--   without approving the invoice as current. Clean approval remains in the
--   Supplier draft ready queue.
--
-- Behaviour:
--   - SECURITY DEFINER to avoid recursive RLS policy paths.
--   - Updates accepted invoice_ref and OCR/header values after PDF/OCR review.
--   - Resolves open invoice review flags with a staff note.
--   - Keeps review_status = pending_review and blocked_from_sage_yn = true.
--   - Does NOT mark is_current_for_order and does NOT post to Sage.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_review_flags') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_review_flags';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_save_supplier_invoice_header_review(
  p_supplier_invoice_id uuid,
  p_corrected_invoice_ref text DEFAULT NULL,
  p_ocr_invoice_ref text DEFAULT NULL,
  p_ocr_retailer_name text DEFAULT NULL,
  p_ocr_invoice_date date DEFAULT NULL,
  p_ocr_invoice_total_gbp numeric DEFAULT NULL,
  p_review_notes text DEFAULT NULL
)
RETURNS TABLE(order_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_role_type text;
  v_invoice record;
  v_now timestamptz := now();
  v_corrected_ref text;
  v_notes text;
BEGIN
  SELECT s.id, s.role_type::text
    INTO v_staff_id, v_role_type
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL OR v_role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can review invoice headers.';
  END IF;

  SELECT si.id, si.order_id, si.invoice_ref, si.review_status
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF v_invoice.review_status IN ('rejected_resubmit_required', 'superseded', 'duplicate_blocked') THEN
    RAISE EXCEPTION 'Cannot save header review for a rejected, superseded, or duplicate-blocked invoice.';
  END IF;

  v_corrected_ref := NULLIF(trim(COALESCE(p_corrected_invoice_ref, '')), '');
  v_notes := COALESCE(NULLIF(trim(p_review_notes), ''), 'Header/OCR values reviewed by supervisor.');

  UPDATE public.supplier_invoices si
  SET
    invoice_ref = COALESCE(v_corrected_ref, si.invoice_ref),
    ocr_invoice_ref = NULLIF(trim(COALESCE(p_ocr_invoice_ref, '')), ''),
    ocr_retailer_name = NULLIF(trim(COALESCE(p_ocr_retailer_name, '')), ''),
    ocr_invoice_date = p_ocr_invoice_date,
    ocr_invoice_total_gbp = p_ocr_invoice_total_gbp,
    review_status = 'pending_review',
    blocked_from_sage_yn = true,
    is_current_for_order = false,
    reviewed_by_staff_id = v_staff_id,
    reviewed_at = v_now,
    review_notes = v_notes
  WHERE si.id = p_supplier_invoice_id;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff_id,
    resolved_at = v_now,
    resolution_notes = v_notes,
    updated_at = v_now
  WHERE f.supplier_invoice_id = p_supplier_invoice_id
    AND f.status IN ('open', 'under_review');

  RETURN QUERY SELECT v_invoice.order_id::uuid;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_save_supplier_invoice_header_review(uuid, text, text, text, date, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_save_supplier_invoice_header_review(uuid, text, text, text, date, numeric, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
