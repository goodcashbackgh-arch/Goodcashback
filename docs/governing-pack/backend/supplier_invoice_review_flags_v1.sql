-- =============================================================================
-- supplier_invoice_review_flags_v1.sql
-- Multi Tenant Platform Build — additive invoice review flag layer
--
-- Purpose:
--   Allow an operator to flag a whole supplier invoice for supervisor review
--   without changing OCR amounts or forcing the reconciliation to balance.
--
-- Principle:
--   Operator can identify mismatch. Supervisor resolves mismatch.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.supplier_invoice_review_flags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  flag_type varchar NOT NULL DEFAULT 'invoice_total_mismatch'
    CHECK (flag_type IN ('invoice_total_mismatch','ocr_unclear','wrong_invoice','delivery_discount_query','manual_line_needed','other')),
  message text NOT NULL,
  status varchar NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','under_review','resolved','rejected','cancelled')),
  raised_by_operator_id uuid NOT NULL REFERENCES public.operators(id),
  resolved_by_staff_id uuid REFERENCES public.staff(id),
  resolved_at timestamptz,
  resolution_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_invoice_review_flags_resolution_check CHECK (
    status NOT IN ('resolved','rejected','cancelled')
    OR resolved_at IS NOT NULL
  )
);

COMMENT ON TABLE public.supplier_invoice_review_flags IS
'Operator-raised invoice review flags. Operators identify invoice/OCR/adjustment mismatch; supervisors resolve before finalisation.';

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_review_flags_order
  ON public.supplier_invoice_review_flags(order_id);

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_review_flags_invoice
  ON public.supplier_invoice_review_flags(supplier_invoice_id);

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_review_flags_status
  ON public.supplier_invoice_review_flags(status);

CREATE UNIQUE INDEX IF NOT EXISTS uq_supplier_invoice_review_flags_open_type
  ON public.supplier_invoice_review_flags(supplier_invoice_id, flag_type)
  WHERE status IN ('open','under_review');

ALTER TABLE public.supplier_invoice_review_flags ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_review_flags'
      AND policyname = 'supplier_invoice_review_flags_operator_select'
  ) THEN
    CREATE POLICY supplier_invoice_review_flags_operator_select
    ON public.supplier_invoice_review_flags
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = supplier_invoice_review_flags.order_id
          AND oi.revoked_at IS NULL
          AND op.auth_user_id = auth.uid()
          AND COALESCE(op.active, true) = true
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_review_flags'
      AND policyname = 'supplier_invoice_review_flags_operator_insert'
  ) THEN
    CREATE POLICY supplier_invoice_review_flags_operator_insert
    ON public.supplier_invoice_review_flags
    FOR INSERT
    TO authenticated
    WITH CHECK (
      status = 'open'
      AND EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = supplier_invoice_review_flags.order_id
          AND oi.revoked_at IS NULL
          AND op.auth_user_id = auth.uid()
          AND COALESCE(op.active, true) = true
          AND supplier_invoice_review_flags.raised_by_operator_id = op.id
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_review_flags'
      AND policyname = 'supplier_invoice_review_flags_staff_all'
  ) THEN
    CREATE POLICY supplier_invoice_review_flags_staff_all
    ON public.supplier_invoice_review_flags
    FOR ALL
    TO authenticated
    USING (is_active_staff())
    WITH CHECK (is_active_staff());
  END IF;
END $$;

COMMIT;
