-- =============================================================================
-- operator_supplier_invoice_line_reconciliation_wrappers_v1.sql
-- Multi Tenant Platform Build — operator-safe supplier invoice line reconciliation RPCs
--
-- Purpose:
--   Add narrow SECURITY DEFINER wrappers used by importer reconciliation actions so
--   the app no longer performs direct supplier_invoice_lines table writes.
--
-- Notes:
--   - Additive only. No baseline schema edits.
--   - No RLS policy changes.
--   - No OCR/dispute/funding/accounting/order-status side effects are introduced.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.operator_importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_importers';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_add_manual_supplier_invoice_line(
  p_order_id uuid,
  p_supplier_invoice_id uuid,
  p_description text,
  p_qty int,
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
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_importer_id uuid;
  v_invoice_order_id uuid;
  v_next_line_order int;
  v_line_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: operator reconciliation requires auth.uid()';
  END IF;

  SELECT o.id
    INTO v_operator_id
  FROM operators o
  WHERE o.auth_user_id = v_auth_uid
    AND COALESCE(o.active, true) = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found for auth user %', v_auth_uid;
  END IF;

  SELECT o.importer_id
    INTO v_importer_id
  FROM orders o
  WHERE o.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % does not have access to order %', v_operator_id, p_order_id;
  END IF;

  SELECT si.order_id
    INTO v_invoice_order_id
  FROM supplier_invoices si
  WHERE si.id = p_supplier_invoice_id;

  IF v_invoice_order_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found: %', p_supplier_invoice_id;
  END IF;

  IF v_invoice_order_id IS DISTINCT FROM p_order_id THEN
    RAISE EXCEPTION 'Supplier invoice % does not belong to order %', p_supplier_invoice_id, p_order_id;
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Description cannot be blank';
  END IF;

  IF p_qty IS NULL OR p_qty < 0 THEN
    RAISE EXCEPTION 'Quantity must be a valid non-negative integer';
  END IF;

  IF p_amount_inc_vat_gbp IS NULL OR p_amount_inc_vat_gbp < 0 THEN
    RAISE EXCEPTION 'Amount must be a valid non-negative number';
  END IF;

  SELECT COALESCE(MAX(sil.line_order), 0) + 1
    INTO v_next_line_order
  FROM supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id;

  INSERT INTO supplier_invoice_lines (
    supplier_invoice_id,
    line_order,
    retailer_sku,
    description,
    qty,
    size,
    amount_inc_vat_gbp,
    line_source
  )
  VALUES (
    p_supplier_invoice_id,
    v_next_line_order,
    NULLIF(BTRIM(COALESCE(p_retailer_sku, '')), ''),
    BTRIM(p_description),
    p_qty,
    NULLIF(BTRIM(COALESCE(p_size, '')), ''),
    ROUND(p_amount_inc_vat_gbp::numeric, 2),
    'manually_added'
  )
  RETURNING id INTO v_line_id;

  RETURN v_line_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.operator_update_supplier_invoice_line_fields(
  p_order_id uuid,
  p_line_id uuid,
  p_description text,
  p_qty int,
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
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_importer_id uuid;
  v_line_supplier_invoice_id uuid;
  v_invoice_order_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: operator reconciliation requires auth.uid()';
  END IF;

  SELECT o.id
    INTO v_operator_id
  FROM operators o
  WHERE o.auth_user_id = v_auth_uid
    AND COALESCE(o.active, true) = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found for auth user %', v_auth_uid;
  END IF;

  SELECT o.importer_id
    INTO v_importer_id
  FROM orders o
  WHERE o.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % does not have access to order %', v_operator_id, p_order_id;
  END IF;

  SELECT sil.supplier_invoice_id
    INTO v_line_supplier_invoice_id
  FROM supplier_invoice_lines sil
  WHERE sil.id = p_line_id;

  IF v_line_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line not found: %', p_line_id;
  END IF;

  SELECT si.order_id
    INTO v_invoice_order_id
  FROM supplier_invoices si
  WHERE si.id = v_line_supplier_invoice_id;

  IF v_invoice_order_id IS NULL OR v_invoice_order_id IS DISTINCT FROM p_order_id THEN
    RAISE EXCEPTION 'Line % is not part of order %', p_line_id, p_order_id;
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Description cannot be blank';
  END IF;

  IF p_qty IS NULL OR p_qty < 0 THEN
    RAISE EXCEPTION 'Quantity must be a valid non-negative integer';
  END IF;

  IF p_amount_inc_vat_gbp IS NULL OR p_amount_inc_vat_gbp < 0 THEN
    RAISE EXCEPTION 'Amount must be a valid non-negative number';
  END IF;

  UPDATE supplier_invoice_lines sil
  SET description = BTRIM(p_description),
      qty = p_qty,
      amount_inc_vat_gbp = ROUND(p_amount_inc_vat_gbp::numeric, 2),
      size = NULLIF(BTRIM(COALESCE(p_size, '')), ''),
      retailer_sku = NULLIF(BTRIM(COALESCE(p_retailer_sku, '')), '')
  WHERE sil.id = p_line_id
    AND sil.supplier_invoice_id = v_line_supplier_invoice_id;
END;
$$;

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
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_importer_id uuid;
  v_line_source text;
  v_line_supplier_invoice_id uuid;
  v_invoice_order_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: operator reconciliation requires auth.uid()';
  END IF;

  SELECT o.id
    INTO v_operator_id
  FROM operators o
  WHERE o.auth_user_id = v_auth_uid
    AND COALESCE(o.active, true) = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found for auth user %', v_auth_uid;
  END IF;

  SELECT o.importer_id
    INTO v_importer_id
  FROM orders o
  WHERE o.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % does not have access to order %', v_operator_id, p_order_id;
  END IF;

  SELECT sil.line_source, sil.supplier_invoice_id
    INTO v_line_source, v_line_supplier_invoice_id
  FROM supplier_invoice_lines sil
  WHERE sil.id = p_line_id;

  IF v_line_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line not found: %', p_line_id;
  END IF;

  SELECT si.order_id
    INTO v_invoice_order_id
  FROM supplier_invoices si
  WHERE si.id = v_line_supplier_invoice_id;

  IF v_invoice_order_id IS NULL OR v_invoice_order_id IS DISTINCT FROM p_order_id THEN
    RAISE EXCEPTION 'Line % is not part of order %', p_line_id, p_order_id;
  END IF;

  IF v_line_source <> 'manually_added' THEN
    RAISE EXCEPTION 'Only manually added lines can be deleted';
  END IF;

  DELETE FROM supplier_invoice_lines sil
  WHERE sil.id = p_line_id
    AND sil.supplier_invoice_id = v_line_supplier_invoice_id
    AND sil.line_source = 'manually_added';
END;
$$;

COMMENT ON FUNCTION public.operator_add_manual_supplier_invoice_line(uuid, uuid, text, int, numeric, text, text) IS
'Operator-safe SECURITY DEFINER wrapper to add a manual supplier invoice line during importer reconciliation.';

COMMENT ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, int, numeric, text, text) IS
'Operator-safe SECURITY DEFINER wrapper to update editable supplier invoice line reconciliation fields.';

COMMENT ON FUNCTION public.operator_delete_manual_supplier_invoice_line(uuid, uuid) IS
'Operator-safe SECURITY DEFINER wrapper to delete only manually-added supplier invoice lines during importer reconciliation.';

REVOKE ALL ON FUNCTION public.operator_add_manual_supplier_invoice_line(uuid, uuid, text, int, numeric, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, int, numeric, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.operator_delete_manual_supplier_invoice_line(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.operator_add_manual_supplier_invoice_line(uuid, uuid, text, int, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.operator_update_supplier_invoice_line_fields(uuid, uuid, text, int, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.operator_delete_manual_supplier_invoice_line(uuid, uuid) TO authenticated;

COMMIT;
