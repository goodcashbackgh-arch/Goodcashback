-- =============================================================================
-- Goodcashback — Operator Invoice Line Reconciliation RPCs
-- =============================================================================
-- Scope:
--   * Add/update/delete supplier_invoice_lines from the importer/operator lane.
--   * SECURITY DEFINER wrappers avoid direct browser writes to supplier_invoice_lines.
--   * No schema changes.
--   * No OCR, disputes, funding, DVA, accounting, VAT, Sage, order-status, or query-closing side effects.
--
-- Governing boundary:
--   * Normal invoice-line reconciliation is owned by importer/operator.
--   * Staff supervises/reviews/escalates separately.
--   * eligible_for_invoice_yn/progression is intentionally not mutated here.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. PREREQUISITE ASSERTIONS — verify existing schema only, do not add columns
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.operator_importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_importers';
  END IF;

  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'supplier_invoice_lines'
      AND column_name IN (
        'id',
        'supplier_invoice_id',
        'line_order',
        'retailer_sku',
        'description',
        'qty',
        'size',
        'amount_inc_vat_gbp',
        'line_source',
        'qty_confirmed',
        'amount_confirmed',
        'eligible_for_invoice_yn',
        'created_at',
        'updated_at'
      )
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 14
  ) THEN
    RAISE EXCEPTION 'Prerequisite mismatch: supplier_invoice_lines expected reconciliation columns are missing. Do not add columns here; apply the locked baseline first.';
  END IF;
END $$;

-- =============================================================================
-- 1. PRIVATE GUARD — current active operator must own/access the order importer
-- =============================================================================

CREATE OR REPLACE FUNCTION public.assert_current_operator_can_reconcile_order(
  p_order_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator_id uuid;
  v_importer_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT op.id
    INTO v_operator_id
  FROM public.operators op
  WHERE op.auth_user_id = auth.uid()
    AND op.active = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found';
  END IF;

  SELECT o.importer_id
    INTO v_importer_id
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised for this order importer';
  END IF;

  RETURN v_operator_id;
END;
$$;

COMMENT ON FUNCTION public.assert_current_operator_can_reconcile_order(uuid) IS
'Private guard for importer/operator invoice-line reconciliation. Verifies auth.uid() maps to an active operator with active operator_importers access to the order importer.';

REVOKE ALL ON FUNCTION public.assert_current_operator_can_reconcile_order(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_current_operator_can_reconcile_order(uuid) TO authenticated;

-- =============================================================================
-- 2. ADD MANUAL LINE — operator lane only, no progression/status side effects
-- =============================================================================

CREATE OR REPLACE FUNCTION public.operator_add_manual_supplier_invoice_line(
  p_order_id uuid,
  p_supplier_invoice_id uuid,
  p_description text,
  p_qty integer,
  p_amount_inc_vat_gbp numeric,
  p_size text DEFAULT NULL,
  p_retailer_sku text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator_id uuid;
  v_line_id uuid;
  v_next_line_order integer;
BEGIN
  v_operator_id := public.assert_current_operator_can_reconcile_order(p_order_id);

  IF p_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice is required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Description cannot be blank';
  END IF;

  IF p_qty IS NULL OR p_qty < 0 THEN
    RAISE EXCEPTION 'Quantity must be a non-negative integer';
  END IF;

  IF p_amount_inc_vat_gbp IS NULL OR p_amount_inc_vat_gbp < 0 THEN
    RAISE EXCEPTION 'Amount must be a non-negative number';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.id = p_supplier_invoice_id
      AND si.order_id = p_order_id
  ) THEN
    RAISE EXCEPTION 'Supplier invoice does not belong to this order';
  END IF;

  SELECT COALESCE(MAX(sil.line_order), 0) + 1
    INTO v_next_line_order
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id;

  INSERT INTO public.supplier_invoice_lines (
    supplier_invoice_id,
    line_order,
    retailer_sku,
    description,
    qty,
    size,
    amount_inc_vat_gbp,
    line_source,
    eligible_for_invoice_yn
  )
  VALUES (
    p_supplier_invoice_id,
    v_next_line_order,
    NULLIF(btrim(p_retailer_sku), ''),
    btrim(p_description),
    p_qty,
    NULLIF(btrim(p_size), ''),
    p_amount_inc_vat_gbp,
    'manually_added',
    'N'
  )
  RETURNING id INTO v_line_id;

  RETURN v_line_id;
END;
$$;

COMMENT ON FUNCTION public.operator_add_manual_supplier_invoice_line(uuid, uuid, text, integer, numeric, text, text) IS
'Adds a manually_added supplier invoice line for an operator-owned order invoice. Does not mutate progression, status, OCR, disputes, funding, accounting, VAT, or Sage state.';

REVOKE ALL ON FUNCTION public.operator_add_manual_supplier_invoice_line(uuid, uuid, text, integer, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_add_manual_supplier_invoice_line(uuid, uuid, text, integer, numeric, text, text) TO authenticated;

-- =============================================================================
-- 3. UPDATE LINE COMMERCIAL FIELDS — no eligible_for_invoice_yn mutation
-- =============================================================================

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
BEGIN
  v_operator_id := public.assert_current_operator_can_reconcile_order(p_order_id);

  IF p_line_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line is required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Description cannot be blank';
  END IF;

  IF p_qty IS NULL OR p_qty < 0 THEN
    RAISE EXCEPTION 'Quantity must be a non-negative integer';
  END IF;

  IF p_amount_inc_vat_gbp IS NULL OR p_amount_inc_vat_gbp < 0 THEN
    RAISE EXCEPTION 'Amount must be a non-negative number';
  END IF;

  SELECT sil.supplier_invoice_id
    INTO v_supplier_invoice_id
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si
    ON si.id = sil.supplier_invoice_id
  WHERE sil.id = p_line_id
    AND si.order_id = p_order_id;

  IF v_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line does not belong to this order';
  END IF;

  UPDATE public.supplier_invoice_lines sil
  SET description = btrim(p_description),
      qty = p_qty,
      amount_inc_vat_gbp = p_amount_inc_vat_gbp,
      size = NULLIF(btrim(p_size), ''),
      retailer_sku = NULLIF(btrim(p_retailer_sku), ''),
      updated_at = now()
  WHERE sil.id = p_line_id;
END;
$$;

COMMENT ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, integer, numeric, text, text) IS
'Updates operator-editable commercial reconciliation fields only. Does not mutate eligible_for_invoice_yn, confirmed values, order status, OCR, disputes, funding, accounting, VAT, or Sage state.';

REVOKE ALL ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, integer, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, integer, numeric, text, text) TO authenticated;

-- =============================================================================
-- 4. DELETE MANUAL LINE ONLY — OCR lines remain source-audit evidence
-- =============================================================================

CREATE OR REPLACE FUNCTION public.operator_delete_manual_supplier_invoice_line(
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
  v_line_source text;
BEGIN
  v_operator_id := public.assert_current_operator_can_reconcile_order(p_order_id);

  IF p_line_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line is required';
  END IF;

  SELECT sil.line_source
    INTO v_line_source
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si
    ON si.id = sil.supplier_invoice_id
  WHERE sil.id = p_line_id
    AND si.order_id = p_order_id;

  IF v_line_source IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line does not belong to this order';
  END IF;

  IF v_line_source <> 'manually_added' THEN
    RAISE EXCEPTION 'Only manually_added supplier invoice lines can be deleted';
  END IF;

  DELETE FROM public.supplier_invoice_lines sil
  WHERE sil.id = p_line_id
    AND sil.line_source = 'manually_added';
END;
$$;

COMMENT ON FUNCTION public.operator_delete_manual_supplier_invoice_line(uuid, uuid) IS
'Deletes only manually_added supplier invoice lines for an operator-owned order. OCR-extracted lines remain non-deletable source evidence.';

REVOKE ALL ON FUNCTION public.operator_delete_manual_supplier_invoice_line(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_delete_manual_supplier_invoice_line(uuid, uuid) TO authenticated;

COMMIT;
