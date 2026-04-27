-- =============================================================================
-- Goodcashback — Operator Invoice Line Progression RPCs
-- =============================================================================
-- Scope:
--   * Stage 9 clean-subset release for importer/operator OCR reconciliation.
--   * Marks a clean supplier_invoice_lines row as progressed/invoiceable by
--     setting qty_confirmed, amount_confirmed, and eligible_for_invoice_yn = 'Y'.
--   * Uses existing schema only.
--   * No child exception creation in this file.
--   * No funding, DVA, shipping, POD, accounting, VAT, Sage, order status, or
--     evidence-query side effects.
--
-- Governing basis:
--   * importer_role_stage_matrix_v7: correct lines may progress while unresolved
--     lines stay separate; parent cannot fully clear until progressed lines plus
--     resolved child outcomes reconcile to original qty/value.
--   * INVOICE_LINE_RECONCILIATION_ACTION_CONTRACT.md: progressed lines are
--     represented by confirmed commercial values and eligible_for_invoice_yn.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regprocedure('public.assert_current_operator_can_reconcile_order(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.assert_current_operator_can_reconcile_order(uuid). Apply operator_invoice_line_reconciliation_rpcs.sql first.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'supplier_invoice_lines'
      AND column_name IN ('qty', 'amount_inc_vat_gbp', 'qty_confirmed', 'amount_confirmed', 'eligible_for_invoice_yn')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 5
  ) THEN
    RAISE EXCEPTION 'Prerequisite mismatch: supplier_invoice_lines progression columns are missing. Do not add columns here; apply the locked baseline first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_mark_supplier_invoice_line_progressed(
  p_order_id uuid,
  p_line_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator_id uuid;
  v_line record;
BEGIN
  v_operator_id := public.assert_current_operator_can_reconcile_order(p_order_id);

  IF p_line_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line is required';
  END IF;

  SELECT
    sil.id,
    sil.supplier_invoice_id,
    sil.qty,
    sil.amount_inc_vat_gbp,
    sil.eligible_for_invoice_yn,
    si.order_id
  INTO v_line
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si
    ON si.id = sil.supplier_invoice_id
  WHERE sil.id = p_line_id
    AND si.order_id = p_order_id;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line does not belong to this order';
  END IF;

  IF v_line.qty IS NULL OR v_line.qty < 0 THEN
    RAISE EXCEPTION 'Line quantity must be non-negative before progression';
  END IF;

  IF v_line.amount_inc_vat_gbp IS NULL OR v_line.amount_inc_vat_gbp < 0 THEN
    RAISE EXCEPTION 'Line amount must be non-negative before progression';
  END IF;

  UPDATE public.supplier_invoice_lines sil
  SET qty_confirmed = v_line.qty,
      amount_confirmed = v_line.amount_inc_vat_gbp,
      eligible_for_invoice_yn = 'Y',
      updated_at = now()
  WHERE sil.id = p_line_id;
END;
$$;

COMMENT ON FUNCTION public.operator_mark_supplier_invoice_line_progressed(uuid, uuid) IS
'Marks one operator-owned supplier invoice line as progressed/invoiceable by setting confirmed qty/value from the current line and eligible_for_invoice_yn=Y. No child exception, funding, shipping, accounting, VAT, Sage, order status, or evidence-query side effects.';

REVOKE ALL ON FUNCTION public.operator_mark_supplier_invoice_line_progressed(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_mark_supplier_invoice_line_progressed(uuid, uuid) TO authenticated;

COMMIT;
