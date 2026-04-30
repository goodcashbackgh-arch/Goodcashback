-- =============================================================================
-- supplier_invoice_review_rpc_v2_reject_adjustments.sql
-- Multi Tenant Platform Build — reject invoice-linked adjustments on invoice rejection
--
-- Purpose:
--   When a supplier invoice is rejected for operator resubmission, any delivery
--   or discount adjustments attached to that rejected invoice must also be
--   retired so they do not affect readiness, dashboards, or final drafting.
--
-- Behaviour:
--   - Replaces staff_reject_supplier_invoice_resubmission(...).
--   - Keeps invoice audit row.
--   - Marks linked order_value_adjustments as rejected.
--   - Resolves invoice review flags.
--   - Includes a one-time cleanup for already-rejected invoices.
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

  IF to_regclass('public.order_value_adjustments') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_value_adjustments';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

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

  UPDATE public.order_value_adjustments ova
  SET
    approval_status = 'rejected',
    approved_by_staff_id = NULL,
    approved_at = NULL,
    notes = concat_ws(E'\n',
      NULLIF(ova.notes, ''),
      'Retired because supplier invoice was rejected for resubmission: ' || v_notes
    ),
    updated_at = v_now
  WHERE ova.supplier_invoice_id = p_supplier_invoice_id
    AND ova.approval_status <> 'rejected';

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

GRANT EXECUTE ON FUNCTION public.staff_reject_supplier_invoice_resubmission(uuid, text) TO authenticated;

-- One-time cleanup for invoices already rejected before this patch.
UPDATE public.order_value_adjustments ova
SET
  approval_status = 'rejected',
  approved_by_staff_id = NULL,
  approved_at = NULL,
  notes = concat_ws(E'\n',
    NULLIF(ova.notes, ''),
    'Retired by cleanup because linked supplier invoice is rejected_resubmit_required.'
  ),
  updated_at = now()
FROM public.supplier_invoices si
WHERE si.id = ova.supplier_invoice_id
  AND si.review_status = 'rejected_resubmit_required'
  AND ova.approval_status <> 'rejected';

COMMIT;

NOTIFY pgrst, 'reload schema';
