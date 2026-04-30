-- =============================================================================
-- supplier_invoice_review_rpc_v1.sql
-- Multi Tenant Platform Build — staff supplier invoice review wrappers
--
-- Purpose:
--   Move internal supplier invoice approval/rejection through SECURITY DEFINER
--   RPCs so staff review does not depend on ordinary portal RLS paths.
--
-- Scope:
--   - Approve one supplier invoice as current for an order.
--   - Reject one supplier invoice and require operator resubmission.
--   - Resolve open supplier_invoice_review_flags for the reviewed invoice.
--
-- Does not:
--   - Change reconciliation/progressed line logic.
--   - Change delivery/discount adjustment approval logic.
--   - Post to Sage.
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

CREATE OR REPLACE FUNCTION public.staff_approve_supplier_invoice_current(
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
  v_next_ref text;
  v_status text;
BEGIN
  SELECT s.id, s.role_type::text
    INTO v_staff_id, v_role_type
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL OR v_role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can review invoices.';
  END IF;

  SELECT si.id, si.order_id, si.invoice_ref
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  UPDATE public.supplier_invoices si
  SET
    review_status = 'superseded',
    blocked_from_sage_yn = true,
    is_current_for_order = false,
    reviewed_by_staff_id = v_staff_id,
    reviewed_at = v_now,
    review_notes = 'Superseded because another invoice was approved as current for this order.',
    superseded_by_supplier_invoice_id = p_supplier_invoice_id
  WHERE si.order_id = v_invoice.order_id
    AND si.id <> p_supplier_invoice_id
    AND si.is_current_for_order = true;

  v_next_ref := COALESCE(NULLIF(trim(p_corrected_invoice_ref), ''), v_invoice.invoice_ref);
  v_status := CASE
    WHEN NULLIF(trim(COALESCE(p_corrected_invoice_ref, '')), '') IS NOT NULL
      AND trim(COALESCE(p_corrected_invoice_ref, '')) <> v_invoice.invoice_ref
      THEN 'ref_corrected_approved'
    ELSE 'approved_current'
  END;

  UPDATE public.supplier_invoices si
  SET
    invoice_ref = v_next_ref,
    review_status = v_status,
    blocked_from_sage_yn = false,
    is_current_for_order = true,
    reviewed_by_staff_id = v_staff_id,
    reviewed_at = v_now,
    review_notes = COALESCE(NULLIF(trim(p_review_notes), ''), 'Approved as current supplier invoice for this order.'),
    ocr_invoice_ref = COALESCE(NULLIF(trim(p_ocr_invoice_ref), ''), NULLIF(trim(p_corrected_invoice_ref), ''), si.ocr_invoice_ref),
    ocr_retailer_name = COALESCE(NULLIF(trim(p_ocr_retailer_name), ''), si.ocr_retailer_name),
    ocr_invoice_date = COALESCE(p_ocr_invoice_date, si.ocr_invoice_date),
    ocr_invoice_total_gbp = COALESCE(p_ocr_invoice_total_gbp, si.ocr_invoice_total_gbp)
  WHERE si.id = p_supplier_invoice_id;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff_id,
    resolved_at = v_now,
    resolution_notes = COALESCE(NULLIF(trim(p_review_notes), ''), 'Invoice approved as current.'),
    updated_at = v_now
  WHERE f.supplier_invoice_id = p_supplier_invoice_id
    AND f.status IN ('open', 'under_review');

  RETURN QUERY SELECT v_invoice.order_id::uuid;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_reject_supplier_invoice_resubmission(
  p_supplier_invoice_id uuid,
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
  v_notes text;
BEGIN
  SELECT s.id, s.role_type::text
    INTO v_staff_id, v_role_type
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL OR v_role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can review invoices.';
  END IF;

  SELECT si.id, si.order_id
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  v_notes := COALESCE(NULLIF(trim(p_review_notes), ''), 'Rejected. Operator must resubmit the correct invoice evidence.');

  UPDATE public.supplier_invoices si
  SET
    review_status = 'rejected_resubmit_required',
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

GRANT EXECUTE ON FUNCTION public.staff_approve_supplier_invoice_current(uuid, text, text, text, date, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_reject_supplier_invoice_resubmission(uuid, text) TO authenticated;

COMMIT;
