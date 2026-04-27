-- =============================================================================
-- Goodcashback — Operator Invoice Line Bulk Progression RPC
-- =============================================================================
-- Scope:
--   * Stage 9 bulk clean-subset release for importer/operator OCR reconciliation.
--   * Bulk marks selected supplier_invoice_lines rows as progressed/invoiceable.
--   * Uses existing schema only.
--   * No child exception creation in this file.
--   * No funding, DVA, shipping, POD, accounting, VAT, Sage, order status, or
--     evidence-query side effects.
--
-- Governing basis:
--   * importer_role_stage_matrix_v7: importer can bulk progress correct lines.
--   * INVOICE_LINE_RECONCILIATION_ACTION_CONTRACT.md: progressed lines are
--     represented by confirmed commercial values and eligible_for_invoice_yn.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.operator_mark_supplier_invoice_line_progressed(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_mark_supplier_invoice_line_progressed(uuid, uuid). Apply operator_invoice_line_progression_rpcs.sql first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(
  p_order_id uuid,
  p_line_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_line_id uuid;
  v_count integer := 0;
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required';
  END IF;

  IF p_line_ids IS NULL OR cardinality(p_line_ids) = 0 THEN
    RAISE EXCEPTION 'Select at least one invoice line to progress';
  END IF;

  FOREACH v_line_id IN ARRAY p_line_ids LOOP
    PERFORM public.operator_mark_supplier_invoice_line_progressed(p_order_id, v_line_id);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) IS
'Bulk marks selected operator-owned supplier invoice lines as progressed/invoiceable. No child exception, funding, shipping, accounting, VAT, Sage, order status, or evidence-query side effects.';

REVOKE ALL ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) TO authenticated;

COMMIT;
