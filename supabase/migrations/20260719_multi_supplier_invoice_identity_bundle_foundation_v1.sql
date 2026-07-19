-- =============================================================================
-- 20260719_multi_supplier_invoice_identity_bundle_foundation_v1.sql
-- Multi-supplier-invoice order control — Mini-build 1
--
-- Governing contract:
--   docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md
--
-- Purpose:
--   1. Replace the one-current-invoice-per-order assumption with one current
--      version per order, retailer, and normalised invoice-reference family.
--   2. Preserve same-reference duplicate protection and corrected resubmission.
--   3. Stop approval/rejection of one invoice from silently altering siblings.
--   4. Add read-only order bundle line and summary views.
--
-- Boundaries:
--   - No portal/UI changes (Mini-build 2).
--   - No supplier-payment allocation changes (Mini-build 2).
--   - No customer release ledger/review-cycle changes (Mini-builds 3/4).
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.order_value_adjustments') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.customer_order_review_links') IS NULL
     OR to_regclass('public.customer_pre_shipment_hold_requests') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.sage_postings') IS NULL
     OR to_regclass('public.dispute_refund_evidence_submissions') IS NULL
  THEN
    RAISE EXCEPTION 'Mini-build 1 prerequisite relation is missing.';
  END IF;

  IF to_regprocedure('public.operator_submit_supplier_invoice(uuid,text,text)') IS NULL
     OR to_regprocedure('public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)') IS NULL
     OR to_regprocedure('public.staff_reject_supplier_invoice_resubmission(uuid,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Mini-build 1 prerequisite RPC is missing.';
  END IF;
END $$;

-- Retire the order-wide current-invoice uniqueness rule and the all-history
-- same-reference constraint. The replacement partial index protects only live
-- current versions inside one normalised reference family.
DROP INDEX IF EXISTS public.uq_supplier_invoices_one_current_per_order;

ALTER TABLE public.supplier_invoices
  DROP CONSTRAINT IF EXISTS supplier_invoices_retailer_id_invoice_ref_order_id_key;

-- Under the retired upload route, active pending invoices were stored with
-- is_current_for_order=false. Prove there is at most one live row in each
-- normalised reference family, then retain that work as the current family row.
DO $$
DECLARE
  v_collision record;
BEGIN
  SELECT
    si.order_id,
    si.retailer_id,
    lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) AS normalised_ref,
    COUNT(*)::integer AS live_count
  INTO v_collision
  FROM public.supplier_invoices si
  WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  )
  GROUP BY
    si.order_id,
    si.retailer_id,
    lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g'))
  HAVING COUNT(*) > 1
  ORDER BY live_count DESC
  LIMIT 1;

  IF v_collision.order_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Cannot install Mini-build 1: order %, retailer %, reference family % has % live versions.',
      v_collision.order_id,
      v_collision.retailer_id,
      v_collision.normalised_ref,
      v_collision.live_count;
  END IF;
END $$;

UPDATE public.supplier_invoices si
SET is_current_for_order = true
WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  )
  AND si.is_current_for_order IS DISTINCT FROM true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_supplier_invoices_current_reference_family
  ON public.supplier_invoices (
    order_id,
    retailer_id,
    (lower(regexp_replace(btrim(invoice_ref), '[^a-zA-Z0-9]+', '', 'g')))
  )
  WHERE is_current_for_order = true
    AND COALESCE(review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    );

CREATE INDEX IF NOT EXISTS idx_supplier_invoices_order_active_versions
  ON public.supplier_invoices (order_id, uploaded_at DESC, id)
  WHERE COALESCE(review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  );

COMMENT ON COLUMN public.supplier_invoices.is_current_for_order IS
'Legacy column name retained for compatibility. True now means the current live version within this order/retailer/normalised invoice-reference family, not the only supplier invoice for the order.';

COMMENT ON INDEX public.uq_supplier_invoices_current_reference_family IS
'Allows several genuine supplier invoice references on one order while permitting only one live current version of each normalised reference family.';

-- ---------------------------------------------------------------------------
-- Operator submission: different references coexist; a same-reference live
-- version is blocked; a rejected same-reference version may be resubmitted
-- without mutating its genuine invoice reference.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.operator_submit_supplier_invoice(
  p_order_id uuid,
  p_invoice_ref text,
  p_invoice_pdf_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_operator_ids uuid[];
  v_operator_id uuid;
  v_order record;
  v_retailer_account_ids uuid[];
  v_supplier_invoice_id uuid;
  v_invoice_ref text;
  v_normalised_ref text;
  v_latest_family record;
  v_live_family record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: invoice submission requires auth.uid()';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id is required';
  END IF;

  v_invoice_ref := btrim(COALESCE(p_invoice_ref, ''));
  v_normalised_ref := lower(regexp_replace(v_invoice_ref, '[^a-zA-Z0-9]+', '', 'g'));

  IF length(v_invoice_ref) = 0 THEN
    RAISE EXCEPTION 'invoice_ref must not be blank';
  END IF;

  IF length(v_normalised_ref) = 0 THEN
    RAISE EXCEPTION 'invoice_ref must contain at least one letter or number';
  END IF;

  IF p_invoice_pdf_url IS NULL OR length(btrim(p_invoice_pdf_url)) = 0 THEN
    RAISE EXCEPTION 'invoice_pdf_url must not be blank';
  END IF;

  SELECT array_agg(op.id ORDER BY op.id)
    INTO v_operator_ids
  FROM public.operators op
  WHERE op.auth_user_id = v_auth_uid
    AND COALESCE(op.active, true) = true;

  IF COALESCE(array_length(v_operator_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'Active operator not found for auth user %', v_auth_uid;
  END IF;

  IF array_length(v_operator_ids, 1) > 1 THEN
    RAISE EXCEPTION 'Multiple active operators found for auth user %', v_auth_uid;
  END IF;

  v_operator_id := v_operator_ids[1];

  SELECT o.id, o.importer_id, o.retailer_id, o.shipper_id
    INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.shipper_id IS NULL THEN
    RAISE EXCEPTION 'Order % has NULL shipper_id; unsupported for MVP', p_order_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_order.importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % is not authorised for importer %', v_operator_id, v_order.importer_id;
  END IF;

  SELECT array_agg(ra.id ORDER BY ra.id)
    INTO v_retailer_account_ids
  FROM public.retailer_accounts ra
  WHERE ra.retailer_id = v_order.retailer_id
    AND ra.shipper_id = v_order.shipper_id
    AND ra.shipper_id IS NOT NULL
    AND ra.status = 'active';

  IF COALESCE(array_length(v_retailer_account_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'No active retailer_account found for retailer % and shipper %', v_order.retailer_id, v_order.shipper_id;
  END IF;

  IF array_length(v_retailer_account_ids, 1) > 1 THEN
    RAISE EXCEPTION 'Multiple active retailer_accounts found for retailer % and shipper %', v_order.retailer_id, v_order.shipper_id;
  END IF;

  -- Serialise only this order/reference family, not every invoice on the order.
  PERFORM pg_advisory_xact_lock(
    hashtext(v_order.id::text || ':' || v_order.retailer_id::text || ':' || v_normalised_ref)
  );

  SELECT si.id, si.review_status, si.invoice_ref, si.is_current_for_order
    INTO v_live_family
  FROM public.supplier_invoices si
  WHERE si.order_id = v_order.id
    AND si.retailer_id = v_order.retailer_id
    AND lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) = v_normalised_ref
    AND si.is_current_for_order = true
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  ORDER BY si.uploaded_at DESC NULLS LAST, si.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_live_family.id IS NOT NULL THEN
    RAISE EXCEPTION
      'A live supplier invoice with reference % already exists for this order. Correct or retire that reference family before resubmitting it.',
      v_invoice_ref;
  END IF;

  SELECT si.id, si.review_status, si.invoice_ref, si.is_current_for_order
    INTO v_latest_family
  FROM public.supplier_invoices si
  WHERE si.order_id = v_order.id
    AND si.retailer_id = v_order.retailer_id
    AND lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) = v_normalised_ref
  ORDER BY si.uploaded_at DESC NULLS LAST, si.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_latest_family.id IS NOT NULL
     AND COALESCE(v_latest_family.review_status, '') NOT IN (
       'rejected_resubmit_required',
       'superseded'
     )
  THEN
    RAISE EXCEPTION
      'Invoice reference % already exists for this order and is not rejected for corrected resubmission.',
      v_invoice_ref;
  END IF;

  INSERT INTO public.supplier_invoices (
    order_id,
    retailer_id,
    retailer_account_id,
    invoice_ref,
    invoice_pdf_url,
    uploaded_by_operator_id,
    ocr_service_used,
    review_status,
    blocked_from_sage_yn,
    is_current_for_order
  )
  VALUES (
    v_order.id,
    v_order.retailer_id,
    v_retailer_account_ids[1],
    v_invoice_ref,
    btrim(p_invoice_pdf_url),
    v_operator_id,
    'manual',
    'pending_review',
    true,
    true
  )
  RETURNING id INTO v_supplier_invoice_id;

  RETURN jsonb_build_object(
    'supplier_invoice_id', v_supplier_invoice_id,
    'order_id', v_order.id,
    'invoice_ref', v_invoice_ref,
    'reference_family_current_yn', true
  );
END;
$$;

COMMENT ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) IS
'SECURITY DEFINER operator upload RPC. Allows different supplier invoice references to coexist on one order, blocks a duplicate live normalised reference, and preserves the genuine reference on corrected rejected-family resubmission.';

REVOKE ALL ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Approval: approve only the selected document. Never supersede sibling
-- references; fail closed if the corrected reference collides with another
-- live current version in the same family.
-- ---------------------------------------------------------------------------
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
      AND sibling.is_current_for_order = true
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

-- ---------------------------------------------------------------------------
-- Rejection: retain the existing audit-preserving retirement, but fail closed
-- after irreversible downstream use. Until the durable customer-release ledger
-- exists, any non-void main/supplementary customer document on the order is a
-- conservative rejection blocker.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Read-only order bundle. Retired invoice versions never appear. All quantities
-- and values remain linked to the original supplier invoice and exact line.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.order_supplier_invoice_bundle_lines_v1
WITH (security_invoker = true)
AS
WITH active_invoices AS (
  SELECT si.*
  FROM public.supplier_invoices si
  WHERE si.is_current_for_order = true
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
),
tracking AS (
  SELECT
    otla.supplier_invoice_line_id,
    SUM(COALESCE(otla.qty_allocated, 0))::numeric AS allocated_tracking_qty,
    SUM(COALESCE(otla.adjusted_net_value_gbp, 0))::numeric AS allocated_tracking_value_gbp
  FROM public.order_tracking_line_allocations otla
  GROUP BY otla.supplier_invoice_line_id
),
line_state AS (
  SELECT
    sil.id AS supplier_invoice_line_id,
    EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_line_id = sil.id
        AND r.active = true
    ) AS non_physical_resolution_yn,
    EXISTS (
      SELECT 1
      FROM public.dispute_lines dl
      JOIN public.disputes d ON d.id = dl.dispute_id
      WHERE dl.supplier_invoice_line_id = sil.id
        AND dl.resolved_at IS NULL
        AND d.resolved_at IS NULL
    ) AS open_exception_yn
  FROM public.supplier_invoice_lines sil
),
hold_state AS (
  SELECT
    sil.id AS supplier_invoice_line_id,
    EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = si.order_id
        AND h.resolved_at IS NULL
        AND h.status IN ('requested', 'supervisor_approved', 'converted_to_exception')
        AND (
          h.requested_scope = 'order'
          OR (
            h.requested_scope = 'line'
            AND h.supplier_invoice_line_id = sil.id
          )
          OR (
            h.requested_scope = 'tracking'
            AND EXISTS (
              SELECT 1
              FROM public.order_tracking_line_allocations otla
              WHERE otla.supplier_invoice_line_id = sil.id
                AND otla.tracking_submission_id = h.tracking_submission_id
                AND COALESCE(otla.qty_allocated, 0) > 0
            )
          )
        )
    ) AS active_hold_yn
  FROM public.supplier_invoice_lines sil
  JOIN active_invoices si ON si.id = sil.supplier_invoice_id
)
SELECT
  ai.order_id,
  ai.id AS supplier_invoice_id,
  ai.invoice_ref::text AS supplier_invoice_ref,
  ai.review_status::text AS supplier_invoice_status,
  sil.id AS supplier_invoice_line_id,
  sil.line_order,
  sil.line_source::text AS line_source,
  sil.qty::numeric AS raw_qty,
  sil.amount_inc_vat_gbp::numeric AS raw_gross_gbp,
  COALESCE(sil.qty_confirmed, sil.qty)::numeric AS confirmed_qty,
  COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp)::numeric AS confirmed_gross_gbp,
  (
    lower(btrim(COALESCE(sil.eligible_for_invoice_yn::text, 'n')))
      IN ('y', 'yes', 'true', '1')
  ) AS progressed_yn,
  ls.non_physical_resolution_yn,
  ls.open_exception_yn,
  hs.active_hold_yn,
  COALESCE(t.allocated_tracking_qty, 0)::numeric AS allocated_tracking_qty,
  GREATEST(
    COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric
      - COALESCE(t.allocated_tracking_qty, 0)::numeric,
    0::numeric
  ) AS remaining_tracking_qty,
  COALESCE(t.allocated_tracking_value_gbp, 0)::numeric AS allocated_tracking_value_gbp
FROM active_invoices ai
JOIN public.supplier_invoice_lines sil
  ON sil.supplier_invoice_id = ai.id
JOIN line_state ls
  ON ls.supplier_invoice_line_id = sil.id
JOIN hold_state hs
  ON hs.supplier_invoice_line_id = sil.id
LEFT JOIN tracking t
  ON t.supplier_invoice_line_id = sil.id;

COMMENT ON VIEW public.order_supplier_invoice_bundle_lines_v1 IS
'Read-only exact-line bundle across every live current supplier invoice reference family for an order. Retired invoice versions are excluded.';

CREATE OR REPLACE VIEW public.order_supplier_invoice_bundle_summary_v1
WITH (security_invoker = true)
AS
WITH invoice_counts AS (
  SELECT
    si.order_id,
    COUNT(*)::integer AS active_invoice_count,
    COUNT(*) FILTER (
      WHERE si.review_status IN ('approved_current', 'ref_corrected_approved')
    )::integer AS approved_invoice_count,
    COUNT(*) FILTER (
      WHERE si.review_status NOT IN ('approved_current', 'ref_corrected_approved')
    )::integer AS review_invoice_count
  FROM public.supplier_invoices si
  WHERE si.is_current_for_order = true
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  GROUP BY si.order_id
),
line_counts AS (
  SELECT
    b.order_id,
    COUNT(*)::integer AS active_line_count,
    COALESCE(SUM(b.confirmed_qty) FILTER (
      WHERE b.progressed_yn = true
        AND b.non_physical_resolution_yn = false
        AND b.open_exception_yn = false
    ), 0)::numeric AS progressed_physical_qty,
    COALESCE(SUM(b.confirmed_gross_gbp) FILTER (
      WHERE b.progressed_yn = true
        AND b.non_physical_resolution_yn = false
        AND b.open_exception_yn = false
    ), 0)::numeric AS progressed_physical_value_gbp,
    COALESCE(SUM(b.confirmed_qty) FILTER (
      WHERE b.open_exception_yn = true
    ), 0)::numeric AS exception_qty,
    COALESCE(SUM(b.confirmed_gross_gbp) FILTER (
      WHERE b.open_exception_yn = true
    ), 0)::numeric AS exception_value_gbp,
    COALESCE(SUM(b.confirmed_gross_gbp) FILTER (
      WHERE b.non_physical_resolution_yn = true
    ), 0)::numeric AS non_physical_value_gbp,
    COALESCE(SUM(b.allocated_tracking_qty), 0)::numeric AS tracking_allocated_qty,
    COALESCE(SUM(b.allocated_tracking_value_gbp), 0)::numeric AS tracking_allocated_value_gbp,
    COUNT(*) FILTER (
      WHERE b.progressed_yn = false
        AND b.non_physical_resolution_yn = false
        AND b.open_exception_yn = false
    )::integer AS unresolved_line_count
  FROM public.order_supplier_invoice_bundle_lines_v1 b
  GROUP BY b.order_id
)
SELECT
  o.id AS order_id,
  COALESCE(ic.active_invoice_count, 0)::integer AS active_invoice_count,
  COALESCE(ic.approved_invoice_count, 0)::integer AS approved_invoice_count,
  COALESCE(ic.review_invoice_count, 0)::integer AS review_invoice_count,
  COALESCE(lc.active_line_count, 0)::integer AS active_line_count,
  COALESCE(lc.progressed_physical_qty, 0)::numeric AS progressed_physical_qty,
  COALESCE(lc.progressed_physical_value_gbp, 0)::numeric AS progressed_physical_value_gbp,
  COALESCE(lc.exception_qty, 0)::numeric AS exception_qty,
  COALESCE(lc.exception_value_gbp, 0)::numeric AS exception_value_gbp,
  COALESCE(lc.non_physical_value_gbp, 0)::numeric AS non_physical_value_gbp,
  COALESCE(lc.tracking_allocated_qty, 0)::numeric AS tracking_allocated_qty,
  COALESCE(lc.tracking_allocated_value_gbp, 0)::numeric AS tracking_allocated_value_gbp,
  COALESCE(o.total_qty_declared, 0)::numeric AS order_baseline_qty,
  COALESCE(o.order_total_gbp_declared, 0)::numeric AS order_baseline_value_gbp,
  GREATEST(
    COALESCE(o.total_qty_declared, 0)::numeric
      - COALESCE(lc.progressed_physical_qty, 0)::numeric
      - COALESCE(lc.exception_qty, 0)::numeric,
    0::numeric
  ) AS remaining_baseline_qty,
  GREATEST(
    COALESCE(o.order_total_gbp_declared, 0)::numeric
      - COALESCE(lc.progressed_physical_value_gbp, 0)::numeric
      - COALESCE(lc.exception_value_gbp, 0)::numeric
      - COALESCE(lc.non_physical_value_gbp, 0)::numeric,
    0::numeric
  ) AS remaining_baseline_value_gbp,
  (
    COALESCE(ic.active_invoice_count, 0) > 0
    AND COALESCE(lc.unresolved_line_count, 0) = 0
  ) AS all_documents_resolved_yn,
  (
    COALESCE(ic.active_invoice_count, 0) > 0
    AND COALESCE(lc.unresolved_line_count, 0) = 0
    AND COALESCE(lc.progressed_physical_qty, 0)
        + COALESCE(lc.exception_qty, 0)
        >= COALESCE(o.total_qty_declared, 0)
    AND COALESCE(lc.progressed_physical_value_gbp, 0)
        + COALESCE(lc.exception_value_gbp, 0)
        + COALESCE(lc.non_physical_value_gbp, 0)
        >= COALESCE(o.order_total_gbp_declared, 0) - 0.01
  ) AS baseline_accounted_for_yn
FROM public.orders o
LEFT JOIN invoice_counts ic ON ic.order_id = o.id
LEFT JOIN line_counts lc ON lc.order_id = o.id;

COMMENT ON VIEW public.order_supplier_invoice_bundle_summary_v1 IS
'Order-wide read model summarising all live supplier invoice reference families without merging their legal or accounting identities.';

REVOKE ALL ON public.order_supplier_invoice_bundle_lines_v1 FROM PUBLIC;
REVOKE ALL ON public.order_supplier_invoice_bundle_summary_v1 FROM PUBLIC;
GRANT SELECT ON public.order_supplier_invoice_bundle_lines_v1 TO authenticated, service_role;
GRANT SELECT ON public.order_supplier_invoice_bundle_summary_v1 TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
