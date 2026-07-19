BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';
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
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_role_type text;
  v_invoice record;
  v_now timestamptz := now();
  v_next_ref text;
  v_normalised_ref text;
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

  SELECT si.id, si.order_id, si.retailer_id, si.invoice_ref, si.review_status
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF COALESCE(v_invoice.review_status::text, '') IN (
    'rejected_resubmit_required',
    'superseded',
    'duplicate_blocked'
  ) THEN
    RAISE EXCEPTION 'Cannot approve a rejected, superseded, or duplicate-blocked supplier invoice.';
  END IF;

  v_next_ref := COALESCE(
    NULLIF(btrim(COALESCE(p_corrected_invoice_ref, '')), ''),
    v_invoice.invoice_ref
  );
  v_normalised_ref := lower(regexp_replace(btrim(v_next_ref), '[^a-zA-Z0-9]+', '', 'g'));
  v_status := CASE
    WHEN v_next_ref IS DISTINCT FROM v_invoice.invoice_ref
      THEN 'ref_corrected_approved'
    ELSE 'approved_current'
  END;

  PERFORM pg_advisory_xact_lock(
    hashtext(v_invoice.order_id::text || ':' || v_invoice.retailer_id::text || ':' || v_normalised_ref)
  );

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoices sibling
    WHERE sibling.id <> v_invoice.id
      AND sibling.order_id = v_invoice.order_id
      AND sibling.retailer_id = v_invoice.retailer_id
      AND lower(regexp_replace(btrim(sibling.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) = v_normalised_ref
      AND COALESCE(sibling.review_status, 'pending_review') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  ) THEN
    RAISE EXCEPTION
      'Cannot approve supplier invoice: corrected reference % collides with another live version on this order.',
      v_next_ref;
  END IF;

  UPDATE public.supplier_invoices si
  SET
    invoice_ref = v_next_ref,
    review_status = v_status,
    blocked_from_sage_yn = false,
    is_current_for_order = true,
    reviewed_by_staff_id = v_staff_id,
    reviewed_at = v_now,
    review_notes = COALESCE(
      NULLIF(btrim(COALESCE(p_review_notes, '')), ''),
      'Approved as current version of this supplier invoice reference.'
    ),
    ocr_invoice_ref = COALESCE(
      NULLIF(btrim(COALESCE(p_ocr_invoice_ref, '')), ''),
      NULLIF(btrim(COALESCE(p_corrected_invoice_ref, '')), ''),
      si.ocr_invoice_ref
    ),
    ocr_retailer_name = COALESCE(
      NULLIF(btrim(COALESCE(p_ocr_retailer_name, '')), ''),
      si.ocr_retailer_name
    ),
    ocr_invoice_date = COALESCE(p_ocr_invoice_date, si.ocr_invoice_date),
    ocr_invoice_total_gbp = COALESCE(p_ocr_invoice_total_gbp, si.ocr_invoice_total_gbp),
    superseded_by_supplier_invoice_id = NULL
  WHERE si.id = p_supplier_invoice_id;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff_id,
    resolved_at = v_now,
    resolution_notes = COALESCE(
      NULLIF(btrim(COALESCE(p_review_notes, '')), ''),
      'Invoice approved as current reference-family version.'
    ),
    updated_at = v_now
  WHERE f.supplier_invoice_id = p_supplier_invoice_id
    AND f.status IN ('open', 'under_review');

  RETURN QUERY SELECT v_invoice.order_id::uuid;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_approve_supplier_invoice_current(uuid, text, text, text, date, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_approve_supplier_invoice_current(uuid, text, text, text, date, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_reject_supplier_invoice_resubmission(
  p_supplier_invoice_id uuid,
  p_review_notes text DEFAULT NULL
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
  v_notes text;
  v_blocker text;
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
    FROM public.sales_invoices si
    WHERE si.order_id = v_invoice.order_id
      AND COALESCE(si.invoice_type::text, '') IN ('main', 'supplementary')
      AND COALESCE(si.sage_status::text, '') <> 'void'
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
      'Supplier invoice % cannot be rejected for resubmission after downstream use (%). Use the controlled correction route.',
      v_invoice.id,
      v_blocker;
  END IF;

  v_notes := COALESCE(
    NULLIF(trim(p_review_notes), ''),
    'Rejected. Operator must resubmit the correct invoice evidence.'
  );

  UPDATE public.supplier_invoices si
  SET
    review_status = 'rejected_resubmit_required',
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
    notes = concat_ws(
      E'\n',
      NULLIF(r.notes, ''),
      'Retired because the source supplier invoice was rejected for resubmission.'
    )
  WHERE r.supplier_invoice_id = p_supplier_invoice_id
    AND r.active = true;

  UPDATE public.order_value_adjustments ova
  SET
    approval_status = 'rejected',
    approved_by_staff_id = NULL,
    approved_at = NULL,
    notes = concat_ws(
      E'\n',
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

REVOKE ALL ON FUNCTION public.staff_reject_supplier_invoice_resubmission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reject_supplier_invoice_resubmission(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
