BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Add one explicit classification without changing the established retired status.
ALTER TABLE public.supplier_invoices
  ADD COLUMN IF NOT EXISTS rejection_requires_resubmission_yn boolean NULL;

-- Every historical use of rejected_resubmit_required meant corrected evidence was required.
UPDATE public.supplier_invoices
SET rejection_requires_resubmission_yn = true
WHERE review_status::text = 'rejected_resubmit_required'
  AND rejection_requires_resubmission_yn IS NULL;

COMMENT ON COLUMN public.supplier_invoices.rejection_requires_resubmission_yn IS
  'For review_status rejected_resubmit_required only: true requires corrected evidence; false excludes the invoice from the order with no resubmission request.';

-- One shared retirement routine. It preserves the existing rejection boundary and
-- changes only the explicit supervisor classification and classification-aware notes.
CREATE OR REPLACE FUNCTION public.internal_classify_supplier_invoice_rejection_v1(
  p_supplier_invoice_id uuid,
  p_requires_resubmission boolean,
  p_review_notes text
)
RETURNS TABLE(order_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_role_type text;
  v_invoice record;
  v_now timestamptz := now();
  v_notes text := NULLIF(btrim(COALESCE(p_review_notes, '')), '');
  v_blocker text;
  v_retirement_note text;
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

  IF p_requires_resubmission IS NULL THEN
    RAISE EXCEPTION 'A rejection classification is required.';
  END IF;

  IF v_notes IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required.';
  END IF;

  SELECT si.id, si.order_id
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations otla
    JOIN public.supplier_invoice_lines sil
      ON sil.id = otla.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice.id
      AND COALESCE(otla.qty_allocated, 0) > 0
  ) THEN
    v_blocker := 'tracking allocation';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_order_review_links l
    WHERE l.order_id = v_invoice.order_id
      AND l.is_active = true
      AND (l.expires_at IS NULL OR l.expires_at > now())
  ) THEN
    v_blocker := 'active customer review';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = v_invoice.order_id
      AND h.resolved_at IS NULL
      AND h.status IN ('requested', 'supervisor_approved', 'converted_to_exception')
      AND (
        h.requested_scope = 'order'
        OR (
          h.requested_scope = 'line'
          AND EXISTS (
            SELECT 1
            FROM public.supplier_invoice_lines sil
            WHERE sil.id = h.supplier_invoice_line_id
              AND sil.supplier_invoice_id = v_invoice.id
          )
        )
        OR (
          h.requested_scope = 'tracking'
          AND EXISTS (
            SELECT 1
            FROM public.order_tracking_line_allocations otla
            JOIN public.supplier_invoice_lines sil
              ON sil.id = otla.supplier_invoice_line_id
            WHERE otla.tracking_submission_id = h.tracking_submission_id
              AND sil.supplier_invoice_id = v_invoice.id
              AND COALESCE(otla.qty_allocated, 0) > 0
          )
        )
      )
  ) THEN
    v_blocker := 'active customer hold';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.supplier_invoice_lines sil
      ON sil.id = dl.supplier_invoice_line_id
    JOIN public.disputes d
      ON d.id = dl.dispute_id
    WHERE sil.supplier_invoice_id = v_invoice.id
      AND dl.resolved_at IS NULL
      AND d.resolved_at IS NULL
  ) THEN
    v_blocker := 'unresolved exception';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sales_invoices sales
    WHERE sales.order_id = v_invoice.order_id
      AND COALESCE(sales.invoice_type::text, '') IN ('main', 'supplementary')
      AND COALESCE(sales.sage_status::text, '') <> 'void'
  ) THEN
    v_blocker := 'non-void customer sales document';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.supplier_invoice_id = v_invoice.id
      AND a.allocation_type::text = 'supplier_invoice'
      AND a.allocation_status::text IN ('confirmed', 'held')
  ) THEN
    v_blocker := 'supplier-payment allocation';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_refund_evidence_submissions e
    WHERE e.original_supplier_invoice_id = v_invoice.id
  ) THEN
    v_blocker := 'supplier refund or credit evidence';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    WHERE s.source_table = 'supplier_invoices'
      AND s.source_id = v_invoice.id
      AND COALESCE(s.active, true) = true
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  ) OR EXISTS (
    SELECT 1
    FROM public.sage_postings sp
    WHERE sp.source_table = 'supplier_invoices'
      AND sp.source_id = v_invoice.id
  ) THEN
    v_blocker := 'frozen or posted supplier accounting artefact';
  END IF;

  IF v_blocker IS NOT NULL THEN
    RAISE EXCEPTION
      'Supplier invoice % cannot be rejected after downstream use (%). Use the controlled correction route.',
      v_invoice.id,
      v_blocker;
  END IF;

  v_retirement_note := CASE
    WHEN p_requires_resubmission
      THEN 'Retired because the source supplier invoice was rejected and corrected evidence is required.'
    ELSE 'Retired because the source supplier invoice was excluded from this order with no resubmission required.'
  END;

  UPDATE public.supplier_invoices si
  SET
    review_status = 'rejected_resubmit_required',
    rejection_requires_resubmission_yn = p_requires_resubmission,
    blocked_from_sage_yn = true,
    is_current_for_order = false,
    reviewed_by_staff_id = v_staff_id,
    reviewed_at = v_now,
    review_notes = v_notes
  WHERE si.id = p_supplier_invoice_id;

  UPDATE public.supplier_invoice_lines sil
  SET
    eligible_for_invoice_yn = 'N',
    qty_confirmed = NULL,
    amount_confirmed = NULL
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id;

  UPDATE public.supplier_invoice_line_resolutions r
  SET
    active = false,
    updated_at = v_now,
    notes = concat_ws(E'\n', NULLIF(r.notes, ''), v_retirement_note)
  WHERE r.supplier_invoice_id = p_supplier_invoice_id
    AND r.active = true;

  UPDATE public.order_value_adjustments ova
  SET
    approval_status = 'rejected',
    approved_by_staff_id = NULL,
    approved_at = NULL,
    notes = concat_ws(E'\n', NULLIF(ova.notes, ''), v_retirement_note || ': ' || v_notes),
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

REVOKE ALL ON FUNCTION public.internal_classify_supplier_invoice_rejection_v1(uuid, boolean, text) FROM PUBLIC, anon, authenticated;

-- Preserve the exact existing public signature.
CREATE OR REPLACE FUNCTION public.staff_reject_supplier_invoice_resubmission(
  p_supplier_invoice_id uuid,
  p_review_notes text DEFAULT NULL
)
RETURNS TABLE(order_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT *
  FROM public.internal_classify_supplier_invoice_rejection_v1(
    p_supplier_invoice_id,
    true,
    p_review_notes
  );
$$;

REVOKE ALL ON FUNCTION public.staff_reject_supplier_invoice_resubmission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reject_supplier_invoice_resubmission(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_exclude_supplier_invoice_no_resubmission_v1(
  p_supplier_invoice_id uuid,
  p_review_notes text
)
RETURNS TABLE(order_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT *
  FROM public.internal_classify_supplier_invoice_rejection_v1(
    p_supplier_invoice_id,
    false,
    p_review_notes
  );
$$;

REVOKE ALL ON FUNCTION public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid, text) TO authenticated;

-- Preserve the existing guarded undo implementation and extend only its final
-- invoice restoration with the classification captured in invoice_before JSON.
DO $$
BEGIN
  IF to_regprocedure('public.staff_undo_supplier_invoice_rejection_pre_classification_v1(uuid,text)') IS NULL THEN
    ALTER FUNCTION public.staff_undo_supplier_invoice_rejection_v1(uuid, text)
      RENAME TO staff_undo_supplier_invoice_rejection_pre_classification_v1;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_undo_supplier_invoice_rejection_v1(
  p_supplier_invoice_id uuid,
  p_undo_reason text
)
RETURNS TABLE(order_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_classification_before boolean;
BEGIN
  SELECT restored.order_id
    INTO v_order_id
  FROM public.staff_undo_supplier_invoice_rejection_pre_classification_v1(
    p_supplier_invoice_id,
    p_undo_reason
  ) restored;

  SELECT (s.invoice_before ->> 'rejection_requires_resubmission_yn')::boolean
    INTO v_classification_before
  FROM public.supplier_invoice_rejection_undo_snapshots s
  WHERE s.supplier_invoice_id = p_supplier_invoice_id
    AND s.undone_at IS NOT NULL
  ORDER BY s.undone_at DESC
  LIMIT 1;

  UPDATE public.supplier_invoices
  SET rejection_requires_resubmission_yn = v_classification_before
  WHERE id = p_supplier_invoice_id;

  RETURN QUERY SELECT v_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_undo_supplier_invoice_rejection_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_undo_supplier_invoice_rejection_v1(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid, text) IS
  'Retires a supplier invoice from its order without requesting corrected evidence, using the same guarded rejection path.';

NOTIFY pgrst, 'reload schema';
COMMIT;
