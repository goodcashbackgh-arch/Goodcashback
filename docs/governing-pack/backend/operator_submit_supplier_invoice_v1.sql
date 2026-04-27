-- =============================================================================
-- operator_submit_supplier_invoice_v1.sql
-- Multi Tenant Platform Build — additive operator invoice submission RPC
--
-- Purpose:
--   Add a controlled operator-facing RPC that inserts a manual supplier invoice
--   record without OCR triggers, order status transitions, query auto-close,
--   or supplier_invoice_lines inserts.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. PREREQUISITE ASSERTIONS
-- =============================================================================

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

  IF to_regclass('public.retailer_accounts') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.retailer_accounts';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
END $$;

-- =============================================================================
-- 1. OPERATOR SUBMIT INVOICE RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION public.operator_submit_supplier_invoice(
  p_order_id uuid,
  p_invoice_ref text,
  p_invoice_pdf_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_order record;
  v_retailer_account_ids uuid[];
  v_retailer_account_id uuid;
  v_supplier_invoice_id uuid;
  v_order_status_before text;
  v_order_completed_at_before timestamptz;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: invoice submission requires auth.uid()';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order id is required';
  END IF;

  IF p_invoice_ref IS NULL OR length(btrim(p_invoice_ref)) = 0 THEN
    RAISE EXCEPTION 'invoice_ref must not be blank';
  END IF;

  IF p_invoice_pdf_url IS NULL OR length(btrim(p_invoice_pdf_url)) = 0 THEN
    RAISE EXCEPTION 'invoice_pdf_url must not be blank';
  END IF;

  SELECT op.id
    INTO v_operator_id
  FROM public.operators op
  WHERE op.auth_user_id = v_auth_uid
    AND COALESCE(op.active, true) = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator not found for auth user %', v_auth_uid;
  END IF;

  SELECT
    o.id,
    o.importer_id,
    o.retailer_id,
    o.shipper_id,
    o.status,
    o.completed_at
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF lower(COALESCE(v_order.status, '')) IN ('completed', 'cancelled', 'archived') THEN
    RAISE EXCEPTION 'Order % has terminal status %, invoice submission is blocked', p_order_id, v_order.status;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_order.importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % is not authorised for importer %', v_operator_id, v_order.importer_id;
  END IF;

  SELECT array_agg(ra.id ORDER BY ra.id)
    INTO v_retailer_account_ids
  FROM public.retailer_accounts ra
  WHERE ra.retailer_id = v_order.retailer_id
    AND ra.shipper_id = v_order.shipper_id
    AND ra.shipper_id IS NOT NULL
    AND ra.status = 'active';

  IF COALESCE(array_length(v_retailer_account_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'No active retailer_account found for retailer % and shipper %', v_order.retailer_id, v_order.shipper_id;
  END IF;

  IF array_length(v_retailer_account_ids, 1) > 1 THEN
    RAISE EXCEPTION 'Multiple active retailer_accounts found for retailer % and shipper %', v_order.retailer_id, v_order.shipper_id;
  END IF;

  v_retailer_account_id := v_retailer_account_ids[1];

  v_order_status_before := v_order.status;
  v_order_completed_at_before := v_order.completed_at;

  INSERT INTO public.supplier_invoices (
    order_id,
    retailer_id,
    retailer_account_id,
    invoice_ref,
    invoice_pdf_url,
    uploaded_by_operator_id,
    ocr_service_used
  )
  VALUES (
    v_order.id,
    v_order.retailer_id,
    v_retailer_account_id,
    btrim(p_invoice_ref),
    btrim(p_invoice_pdf_url),
    v_operator_id,
    'manual'
  )
  RETURNING id INTO v_supplier_invoice_id;

  -- Enforce no net order-status transition from this RPC, including any indirect
  -- trigger side-effects from supplier_invoices inserts.
  UPDATE public.orders o
  SET status = v_order_status_before,
      completed_at = v_order_completed_at_before
  WHERE o.id = v_order.id
    AND (
      o.status IS DISTINCT FROM v_order_status_before
      OR o.completed_at IS DISTINCT FROM v_order_completed_at_before
    );

  RETURN jsonb_build_object(
    'success', true,
    'supplier_invoice_id', v_supplier_invoice_id,
    'order_id', v_order.id,
    'invoice_ref', btrim(p_invoice_ref)
  );
END;
$$;

COMMENT ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) IS
'Operator-facing SECURITY DEFINER wrapper to submit a supplier invoice manually. Validates operator/importer access, resolves exactly one active retailer_account by (retailer_id, shipper_id), inserts supplier_invoices with ocr_service_used=manual, and preserves order status/completed_at.';

REVOKE ALL ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) TO authenticated;

COMMIT;
