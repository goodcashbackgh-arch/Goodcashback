-- =============================================================================
-- supplier_invoice_review_gate_v1.sql
-- Multi Tenant Platform Build — additive invoice approval/Sage gate
--
-- Purpose:
--   Make supplier invoice posting/finalisation depend on an approved-current
--   invoice, not merely on supplier_invoices.order_id being populated.
--
-- Principles:
--   - Upload remains order-first for MVP.
--   - OCR/header values are stored separately from operator-entered values.
--   - Wrong/ref-mismatch invoices are blocked from Sage until staff resolves them.
--   - Only one supplier invoice can be approved_current/current for an order.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

ALTER TABLE public.supplier_invoices
  ADD COLUMN IF NOT EXISTS ocr_invoice_ref varchar,
  ADD COLUMN IF NOT EXISTS ocr_invoice_total_gbp decimal(12,2),
  ADD COLUMN IF NOT EXISTS ocr_retailer_name varchar,
  ADD COLUMN IF NOT EXISTS ocr_invoice_date date,
  ADD COLUMN IF NOT EXISTS review_status varchar NOT NULL DEFAULT 'pending_review',
  ADD COLUMN IF NOT EXISTS blocked_from_sage_yn boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS is_current_for_order boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS reviewed_by_staff_id uuid,
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS review_notes text,
  ADD COLUMN IF NOT EXISTS superseded_by_supplier_invoice_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoices_ocr_invoice_total_nonnegative_check'
  ) THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT supplier_invoices_ocr_invoice_total_nonnegative_check
      CHECK (ocr_invoice_total_gbp IS NULL OR ocr_invoice_total_gbp >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoices_review_status_check'
  ) THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT supplier_invoices_review_status_check
      CHECK (review_status IN ('pending_review','approved_current','rejected_resubmit_required','superseded','duplicate_blocked','ref_corrected_approved'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoices_reviewed_by_staff_id_fkey'
  ) THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT supplier_invoices_reviewed_by_staff_id_fkey
      FOREIGN KEY (reviewed_by_staff_id) REFERENCES public.staff(id);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoices_superseded_by_supplier_invoice_id_fkey'
  ) THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT supplier_invoices_superseded_by_supplier_invoice_id_fkey
      FOREIGN KEY (superseded_by_supplier_invoice_id) REFERENCES public.supplier_invoices(id);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoices_review_resolution_check'
  ) THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT supplier_invoices_review_resolution_check
      CHECK (
        review_status NOT IN ('approved_current','rejected_resubmit_required','superseded','duplicate_blocked','ref_corrected_approved')
        OR reviewed_at IS NOT NULL
      );
  END IF;
END $$;

-- Existing invoices are deliberately blocked until reviewed. This is safer than
-- silently treating historic/test uploads as Sage-ready.
UPDATE public.supplier_invoices
SET
  review_status = COALESCE(review_status, 'pending_review'),
  blocked_from_sage_yn = COALESCE(blocked_from_sage_yn, true),
  is_current_for_order = COALESCE(is_current_for_order, false)
WHERE review_status IS NULL
   OR blocked_from_sage_yn IS NULL
   OR is_current_for_order IS NULL;

CREATE INDEX IF NOT EXISTS idx_supplier_invoices_review_status
  ON public.supplier_invoices(review_status);

CREATE INDEX IF NOT EXISTS idx_supplier_invoices_blocked_from_sage
  ON public.supplier_invoices(blocked_from_sage_yn);

CREATE INDEX IF NOT EXISTS idx_supplier_invoices_ocr_invoice_ref
  ON public.supplier_invoices(retailer_id, ocr_invoice_ref)
  WHERE ocr_invoice_ref IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_supplier_invoices_one_current_per_order
  ON public.supplier_invoices(order_id)
  WHERE is_current_for_order = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_supplier_invoices_approved_ocr_ref_per_retailer
  ON public.supplier_invoices(retailer_id, ocr_invoice_ref)
  WHERE review_status IN ('approved_current','ref_corrected_approved')
    AND blocked_from_sage_yn = false
    AND ocr_invoice_ref IS NOT NULL;

COMMENT ON COLUMN public.supplier_invoices.ocr_invoice_ref IS
'OCR/header invoice reference extracted from supplier invoice evidence. Stored separately from operator-entered invoice_ref.';

COMMENT ON COLUMN public.supplier_invoices.ocr_invoice_total_gbp IS
'OCR/header invoice total extracted from supplier invoice evidence. Used to compare against operator-entered final invoice total.';

COMMENT ON COLUMN public.supplier_invoices.review_status IS
'Invoice approval gate for finalisation/Sage. order_id alone is not enough for posting.';

COMMENT ON COLUMN public.supplier_invoices.blocked_from_sage_yn IS
'True means this supplier invoice must not feed final invoice drafting or Sage posting.';

COMMENT ON COLUMN public.supplier_invoices.is_current_for_order IS
'True only for the currently approved invoice version for an order. Partial unique index allows max one current invoice per order.';

COMMIT;
