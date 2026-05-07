-- =============================================================================
-- refund_document_workbench_v1c_staff_rls.sql
-- Multi Tenant Platform Build — refund document staff read policies
--
-- Purpose:
--   Make refund document child rows visible to active staff/supervisors after
--   refund evidence is submitted into the structured workbench.
--
-- Context:
--   The parent table dispute_refund_evidence_submissions already had staff read
--   policy, but the child tables created by refund_document_workbench_v1.sql have
--   RLS enabled and also need staff SELECT policies.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines';
  END IF;

  IF to_regclass('public.dispute_refund_document_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_line_accounting_codes';
  END IF;

  IF to_regclass('public.dispute_refund_document_accounting_adjustment_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_accounting_adjustment_lines';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'dispute_refund_document_lines'
      AND policyname = 'staff can read refund document lines'
  ) THEN
    CREATE POLICY "staff can read refund document lines"
      ON public.dispute_refund_document_lines
      FOR SELECT
      USING (is_active_staff());
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'dispute_refund_document_line_accounting_codes'
      AND policyname = 'staff can read refund document line coding'
  ) THEN
    CREATE POLICY "staff can read refund document line coding"
      ON public.dispute_refund_document_line_accounting_codes
      FOR SELECT
      USING (is_active_staff());
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'dispute_refund_document_accounting_adjustment_lines'
      AND policyname = 'staff can read refund document adjustment lines'
  ) THEN
    CREATE POLICY "staff can read refund document adjustment lines"
      ON public.dispute_refund_document_accounting_adjustment_lines
      FOR SELECT
      USING (is_active_staff());
  END IF;
END $$;

COMMIT;
