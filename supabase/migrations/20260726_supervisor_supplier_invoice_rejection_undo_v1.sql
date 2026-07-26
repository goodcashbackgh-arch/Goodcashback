BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Surgical, audit-preserving undo for an accidentally selected
-- "reject and require resubmission" decision.
--
-- Design:
--   * The existing rejection RPC remains untouched.
--   * A BEFORE UPDATE trigger snapshots only the rows that the existing RPC
--     changes, immediately before the rejection is applied.
--   * Undo is allowed only while the rejected invoice is still the same
--     untouched version, no replacement/resubmission exists, and no downstream
--     operational/accounting use has occurred.
--   * Undo restores the exact pre-rejection values rather than manufacturing a
--     new state.

CREATE TABLE IF NOT EXISTS public.supplier_invoice_rejection_undo_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  rejected_at timestamptz NOT NULL DEFAULT now(),
  rejected_by_staff_id uuid NULL REFERENCES public.staff(id),
  invoice_before jsonb NOT NULL,
  lines_before jsonb NOT NULL DEFAULT '[]'::jsonb,
  resolutions_before jsonb NOT NULL DEFAULT '[]'::jsonb,
  adjustments_before jsonb NOT NULL DEFAULT '[]'::jsonb,
  review_flags_before jsonb NOT NULL DEFAULT '[]'::jsonb,
  undone_at timestamptz NULL,
  undone_by_staff_id uuid NULL REFERENCES public.staff(id),
  undo_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_invoice_rejection_undo_reason_chk
    CHECK (undone_at IS NULL OR NULLIF(btrim(COALESCE(undo_reason, '')), '') IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS supplier_invoice_rejection_undo_one_open_idx
  ON public.supplier_invoice_rejection_undo_snapshots (supplier_invoice_id)
  WHERE undone_at IS NULL;

CREATE INDEX IF NOT EXISTS supplier_invoice_rejection_undo_order_idx
  ON public.supplier_invoice_rejection_undo_snapshots (order_id, rejected_at DESC);

ALTER TABLE public.supplier_invoice_rejection_undo_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supplier_invoice_rejection_undo_snapshots FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.capture_supplier_invoice_rejection_undo_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF COALESCE(OLD.review_status::text, 'pending_review') <> 'rejected_resubmit_required'
     AND NEW.review_status::text = 'rejected_resubmit_required' THEN

    IF EXISTS (
      SELECT 1
      FROM public.supplier_invoice_rejection_undo_snapshots s
      WHERE s.supplier_invoice_id = OLD.id
        AND s.undone_at IS NULL
    ) THEN
      RAISE EXCEPTION 'An open rejection-undo snapshot already exists for supplier invoice %.', OLD.id;
    END IF;

    INSERT INTO public.supplier_invoice_rejection_undo_snapshots (
      supplier_invoice_id,
      order_id,
      rejected_at,
      rejected_by_staff_id,
      invoice_before,
      lines_before,
      resolutions_before,
      adjustments_before,
      review_flags_before
    )
    VALUES (
      OLD.id,
      OLD.order_id,
      now(),
      NEW.reviewed_by_staff_id,
      to_jsonb(OLD),
      COALESCE((
        SELECT jsonb_agg(to_jsonb(sil) ORDER BY sil.id)
        FROM public.supplier_invoice_lines sil
        WHERE sil.supplier_invoice_id = OLD.id
      ), '[]'::jsonb),
      COALESCE((
        SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id)
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_id = OLD.id
      ), '[]'::jsonb),
      COALESCE((
        SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.order_value_adjustments a
        WHERE a.supplier_invoice_id = OLD.id
      ), '[]'::jsonb),
      COALESCE((
        SELECT jsonb_agg(to_jsonb(f) ORDER BY f.id)
        FROM public.supplier_invoice_review_flags f
        WHERE f.supplier_invoice_id = OLD.id
      ), '[]'::jsonb)
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_capture_supplier_invoice_rejection_undo_v1
  ON public.supplier_invoices;

CREATE TRIGGER trg_capture_supplier_invoice_rejection_undo_v1
BEFORE UPDATE OF review_status ON public.supplier_invoices
FOR EACH ROW
EXECUTE FUNCTION public.capture_supplier_invoice_rejection_undo_v1();

REVOKE ALL ON FUNCTION public.capture_supplier_invoice_rejection_undo_v1() FROM PUBLIC;

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
  v_staff_id uuid;
  v_role_type text;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_snapshot public.supplier_invoice_rejection_undo_snapshots%ROWTYPE;
  v_invoice_before public.supplier_invoices%ROWTYPE;
  v_blocker text;
  v_reason text := NULLIF(btrim(COALESCE(p_undo_reason, '')), '');
  v_now timestamptz := now();
BEGIN
  SELECT s.id, s.role_type::text
    INTO v_staff_id, v_role_type
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL OR v_role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can undo an invoice rejection.';
  END IF;

  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'An undo reason is required.';
  END IF;

  SELECT si.*
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF COALESCE(v_invoice.review_status::text, '') <> 'rejected_resubmit_required' THEN
    RAISE EXCEPTION 'Only an invoice currently rejected for resubmission can be undone.';
  END IF;

  SELECT s.*
    INTO v_snapshot
  FROM public.supplier_invoice_rejection_undo_snapshots s
  WHERE s.supplier_invoice_id = p_supplier_invoice_id
    AND s.undone_at IS NULL
  ORDER BY s.rejected_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_snapshot.id IS NULL THEN
    RAISE EXCEPTION 'No exact pre-rejection snapshot exists for this invoice. A blind status update is blocked.';
  END IF;

  SELECT *
    INTO v_invoice_before
  FROM jsonb_populate_record(NULL::public.supplier_invoices, v_snapshot.invoice_before);

  -- "No resubmission has occurred" is enforced against the exact order,
  -- retailer and normalised invoice-reference family captured before rejection.
  IF v_invoice.superseded_by_supplier_invoice_id IS NOT NULL
     OR EXISTS (
       SELECT 1
       FROM public.supplier_invoices sibling
       WHERE sibling.id <> v_invoice.id
         AND sibling.order_id = v_invoice_before.order_id
         AND sibling.retailer_id = v_invoice_before.retailer_id
         AND lower(regexp_replace(btrim(sibling.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) =
             lower(regexp_replace(btrim(v_invoice_before.invoice_ref), '[^a-zA-Z0-9]+', '', 'g'))
         AND COALESCE(sibling.uploaded_at, sibling.created_at) > v_snapshot.rejected_at
     ) THEN
    RAISE EXCEPTION 'Undo blocked: replacement or resubmitted evidence already exists.';
  END IF;

  -- Reuse the same downstream safety boundary as rejection, plus lanes that can
  -- consume invoice lines after rejection. Nothing is deleted or reversed here.
  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice.id
      AND COALESCE(a.qty_allocated, 0) > 0
  ) THEN v_blocker := 'tracking allocation';
  ELSIF EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.supplier_invoice_lines sil ON sil.id = m.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice.id
  ) THEN v_blocker := 'shipment membership';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines r
    WHERE r.supplier_invoice_id = v_invoice.id
  ) THEN v_blocker := 'customer-sales release membership';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_order_review_links l
    WHERE l.order_id = v_invoice.order_id
      AND l.is_active = true
      AND (l.expires_at IS NULL OR l.expires_at > now())
  ) THEN v_blocker := 'active customer review';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = v_invoice.order_id
      AND h.resolved_at IS NULL
      AND h.status IN ('requested', 'supervisor_approved', 'converted_to_exception')
  ) THEN v_blocker := 'active customer hold';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
    JOIN public.disputes d ON d.id = dl.dispute_id
    WHERE sil.supplier_invoice_id = v_invoice.id
      AND dl.resolved_at IS NULL
      AND d.resolved_at IS NULL
  ) THEN v_blocker := 'unresolved exception';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sales_invoices sales
    WHERE sales.order_id = v_invoice.order_id
      AND COALESCE(sales.invoice_type::text, '') IN ('main', 'supplementary')
      AND COALESCE(sales.sage_status::text, '') <> 'void'
  ) THEN v_blocker := 'non-void customer sales document';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.supplier_invoice_id = v_invoice.id
      AND a.allocation_type::text = 'supplier_invoice'
      AND a.allocation_status::text IN ('confirmed', 'held')
  ) THEN v_blocker := 'supplier-payment allocation';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_refund_evidence_submissions e
    WHERE e.original_supplier_invoice_id = v_invoice.id
  ) THEN v_blocker := 'supplier refund or credit evidence';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    WHERE s.source_table = 'supplier_invoices'
      AND s.source_id = v_invoice.id
      AND COALESCE(s.active, true) = true
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  ) OR EXISTS (
    SELECT 1
    FROM public.sage_postings p
    WHERE p.source_table = 'supplier_invoices'
      AND p.source_id = v_invoice.id
  ) THEN v_blocker := 'frozen or posted supplier accounting artefact';
  END IF;

  IF v_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Undo blocked by downstream use (%). No rows were changed.', v_blocker;
  END IF;

  -- Restore the exact pre-rejection invoice fields changed by the rejection RPC.
  UPDATE public.supplier_invoices si
  SET
    review_status = v_invoice_before.review_status,
    blocked_from_sage_yn = v_invoice_before.blocked_from_sage_yn,
    is_current_for_order = v_invoice_before.is_current_for_order,
    reviewed_by_staff_id = v_invoice_before.reviewed_by_staff_id,
    reviewed_at = v_invoice_before.reviewed_at,
    review_notes = v_invoice_before.review_notes,
    superseded_by_supplier_invoice_id = v_invoice_before.superseded_by_supplier_invoice_id
  WHERE si.id = v_invoice.id;

  WITH restored AS (
    SELECT (jsonb_populate_record(NULL::public.supplier_invoice_lines, x.value)).*
    FROM jsonb_array_elements(v_snapshot.lines_before) x
  )
  UPDATE public.supplier_invoice_lines target
  SET
    eligible_for_invoice_yn = restored.eligible_for_invoice_yn,
    qty_confirmed = restored.qty_confirmed,
    amount_confirmed = restored.amount_confirmed
  FROM restored
  WHERE target.id = restored.id
    AND target.supplier_invoice_id = v_invoice.id;

  WITH restored AS (
    SELECT (jsonb_populate_record(NULL::public.supplier_invoice_line_resolutions, x.value)).*
    FROM jsonb_array_elements(v_snapshot.resolutions_before) x
  )
  UPDATE public.supplier_invoice_line_resolutions target
  SET
    active = restored.active,
    updated_at = restored.updated_at,
    notes = restored.notes
  FROM restored
  WHERE target.id = restored.id
    AND target.supplier_invoice_id = v_invoice.id;

  WITH restored AS (
    SELECT (jsonb_populate_record(NULL::public.order_value_adjustments, x.value)).*
    FROM jsonb_array_elements(v_snapshot.adjustments_before) x
  )
  UPDATE public.order_value_adjustments target
  SET
    approval_status = restored.approval_status,
    approved_by_staff_id = restored.approved_by_staff_id,
    approved_at = restored.approved_at,
    notes = restored.notes,
    updated_at = restored.updated_at
  FROM restored
  WHERE target.id = restored.id
    AND target.supplier_invoice_id = v_invoice.id;

  WITH restored AS (
    SELECT (jsonb_populate_record(NULL::public.supplier_invoice_review_flags, x.value)).*
    FROM jsonb_array_elements(v_snapshot.review_flags_before) x
  )
  UPDATE public.supplier_invoice_review_flags target
  SET
    status = restored.status,
    resolved_by_staff_id = restored.resolved_by_staff_id,
    resolved_at = restored.resolved_at,
    resolution_notes = restored.resolution_notes,
    updated_at = restored.updated_at
  FROM restored
  WHERE target.id = restored.id
    AND target.supplier_invoice_id = v_invoice.id;

  UPDATE public.supplier_invoice_rejection_undo_snapshots s
  SET
    undone_at = v_now,
    undone_by_staff_id = v_staff_id,
    undo_reason = v_reason
  WHERE s.id = v_snapshot.id;

  RETURN QUERY SELECT v_invoice.order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_undo_supplier_invoice_rejection_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_undo_supplier_invoice_rejection_v1(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.staff_undo_supplier_invoice_rejection_v1(uuid, text) IS
  'Restores the exact pre-rejection supplier-invoice review state only when no replacement evidence or downstream use exists.';

NOTIFY pgrst, 'reload schema';
COMMIT;
