-- =============================================================================
-- supplier_invoice_financial_summary_v1.sql
-- Multi Tenant Platform Build — additive supplier invoice total/check layer
--
-- Purpose:
--   Store the supplier invoice total used to check whether goods item lines plus
--   retailer delivery minus retailer discount reconcile to the supplier invoice.
--
-- Principles:
--   - Do not make delivery/discount supplier invoice item lines.
--   - Do not alter supplier_invoice_lines progression.
--   - Do not overwrite orders.order_total_gbp_declared.
--   - This table supports financial matching/finalisation only.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
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

CREATE TABLE IF NOT EXISTS public.supplier_invoice_financial_summary (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_id uuid NOT NULL UNIQUE REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  invoice_total_gbp decimal(12,2) NOT NULL CHECK (invoice_total_gbp >= 0),
  source varchar NOT NULL DEFAULT 'operator_entered'
    CHECK (source IN ('operator_entered','ocr_detected','supervisor_entered','system_calculated')),
  confidence varchar
    CHECK (confidence IN ('high','medium','low')),
  entered_by_operator_id uuid REFERENCES public.operators(id),
  entered_by_staff_id uuid REFERENCES public.staff(id),
  ocr_raw_json jsonb,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_invoice_financial_summary_actor_check CHECK (
    entered_by_operator_id IS NOT NULL OR entered_by_staff_id IS NOT NULL OR source IN ('ocr_detected','system_calculated')
  )
);

COMMENT ON TABLE public.supplier_invoice_financial_summary IS
'Stores supplier invoice total/header amount for financial matching: goods item lines + approved/pending delivery - approved/pending discount should explain invoice_total_gbp.';

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_financial_summary_invoice
  ON public.supplier_invoice_financial_summary(supplier_invoice_id);

ALTER TABLE public.supplier_invoice_financial_summary ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_financial_summary'
      AND policyname = 'supplier_invoice_financial_summary_operator_select'
  ) THEN
    CREATE POLICY supplier_invoice_financial_summary_operator_select
    ON public.supplier_invoice_financial_summary
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM public.supplier_invoices si
        JOIN public.orders o ON o.id = si.order_id
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE si.id = supplier_invoice_financial_summary.supplier_invoice_id
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
      AND tablename = 'supplier_invoice_financial_summary'
      AND policyname = 'supplier_invoice_financial_summary_operator_insert'
  ) THEN
    CREATE POLICY supplier_invoice_financial_summary_operator_insert
    ON public.supplier_invoice_financial_summary
    FOR INSERT
    TO authenticated
    WITH CHECK (
      source = 'operator_entered'
      AND EXISTS (
        SELECT 1
        FROM public.supplier_invoices si
        JOIN public.orders o ON o.id = si.order_id
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE si.id = supplier_invoice_financial_summary.supplier_invoice_id
          AND oi.revoked_at IS NULL
          AND op.auth_user_id = auth.uid()
          AND COALESCE(op.active, true) = true
          AND supplier_invoice_financial_summary.entered_by_operator_id = op.id
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_financial_summary'
      AND policyname = 'supplier_invoice_financial_summary_staff_all'
  ) THEN
    CREATE POLICY supplier_invoice_financial_summary_staff_all
    ON public.supplier_invoice_financial_summary
    FOR ALL
    TO authenticated
    USING (is_active_staff())
    WITH CHECK (is_active_staff());
  END IF;
END $$;

COMMIT;
