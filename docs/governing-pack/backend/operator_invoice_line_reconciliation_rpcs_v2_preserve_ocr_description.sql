-- =============================================================================
-- Goodcashback — Operator Invoice Line Reconciliation RPC v2 correction
-- =============================================================================
-- Purpose:
--   Tighten operator_update_supplier_invoice_line_fields so OCR-extracted line
--   descriptions are preserved for audit provenance.
--
-- Governing basis:
--   importer_role_stage_matrix_v7:
--   * importer edits OCR line size / quantity / value;
--   * OCR description/source provenance must remain preserved for audit;
--   * manual lines remain distinguishable from OCR lines.
--
-- Scope:
--   * Replaces one existing RPC only.
--   * No schema changes.
--   * No RLS changes.
--   * No OCR, disputes, funding, DVA, accounting, VAT, Sage, order-status, or
--     query-closing side effects.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.operator_update_supplier_invoice_line_fields(
  p_order_id uuid,
  p_line_id uuid,
  p_description text,
  p_qty integer,
  p_amount_inc_vat_gbp numeric,
  p_size text DEFAULT NULL,
  p_retailer_sku text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator_id uuid;
  v_supplier_invoice_id uuid;
  v_line_source text;
  v_existing_description text;
BEGIN
  v_operator_id := public.assert_current_operator_can_reconcile_order(p_order_id);

  IF p_line_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line is required';
  END IF;

  IF p_qty IS NULL OR p_qty < 0 THEN
    RAISE EXCEPTION 'Quantity must be a non-negative integer';
  END IF;

  IF p_amount_inc_vat_gbp IS NULL OR p_amount_inc_vat_gbp < 0 THEN
    RAISE EXCEPTION 'Amount must be a non-negative number';
  END IF;

  SELECT sil.supplier_invoice_id,
         sil.line_source,
         sil.description
    INTO v_supplier_invoice_id,
         v_line_source,
         v_existing_description
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si
    ON si.id = sil.supplier_invoice_id
  WHERE sil.id = p_line_id
    AND si.order_id = p_order_id;

  IF v_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line does not belong to this order';
  END IF;

  IF v_line_source = 'manually_added'
     AND NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Description cannot be blank for manually added lines';
  END IF;

  IF v_line_source = 'ocr_extracted'
     AND btrim(COALESCE(p_description, '')) IS DISTINCT FROM btrim(COALESCE(v_existing_description, '')) THEN
    RAISE EXCEPTION 'OCR line description is source evidence and cannot be changed';
  END IF;

  UPDATE public.supplier_invoice_lines sil
  SET description = CASE
        WHEN v_line_source = 'manually_added' THEN btrim(p_description)
        ELSE sil.description
      END,
      qty = p_qty,
      amount_inc_vat_gbp = p_amount_inc_vat_gbp,
      size = NULLIF(btrim(p_size), ''),
      retailer_sku = NULLIF(btrim(p_retailer_sku), ''),
      updated_at = now()
  WHERE sil.id = p_line_id;
END;
$$;

COMMENT ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, integer, numeric, text, text) IS
'Updates operator-editable reconciliation fields. Manually added line descriptions are editable; OCR-extracted line descriptions are preserved as source evidence. Does not mutate eligible_for_invoice_yn, confirmed values, order status, OCR, disputes, funding, accounting, VAT, or Sage state.';

REVOKE ALL ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, integer, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, integer, numeric, text, text) TO authenticated;

COMMIT;
