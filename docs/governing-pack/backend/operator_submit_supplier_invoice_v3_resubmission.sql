-- =============================================================================
-- operator_submit_supplier_invoice_v3_resubmission.sql
-- Multi Tenant Platform Build — supplier invoice resubmission handling
--
-- Purpose:
--   Preserve rejected invoice audit rows while allowing an operator to upload the
--   corrected invoice using the same real supplier invoice reference.
--
-- Behaviour:
--   - Validates active operator/importer access as before.
--   - If a same order/retailer/invoice_ref invoice exists and is rejected, it is
--     archived by suffixing the rejected row invoice_ref internally.
--   - The corrected upload then inserts a fresh supplier_invoices row with the
--     real invoice_ref.
--   - Non-rejected duplicates remain blocked by the unique constraint.
--
-- Does not:
--   - Run OCR.
--   - Change reconciliation/progressed line logic.
--   - Post to Sage.
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

  IF to_regclass('public.retailer_accounts') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.retailer_accounts';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
END
$$;

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
  v_operator_ids uuid[];
  v_operator_id uuid;
  v_order record;
  v_retailer_account_ids uuid[];
  v_supplier_invoice_id uuid;
  v_invoice_ref text;
  v_existing_invoice record;
  v_archived_ref text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: invoice submission requires auth.uid()';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id is required';
  END IF;

  v_invoice_ref := btrim(COALESCE(p_invoice_ref, ''));

  IF length(v_invoice_ref) = 0 THEN
    RAISE EXCEPTION 'invoice_ref must not be blank';
  END IF;

  IF p_invoice_pdf_url IS NULL OR length(btrim(p_invoice_pdf_url)) = 0 THEN
    RAISE EXCEPTION 'invoice_pdf_url must not be blank';
  END IF;

  SELECT array_agg(op.id ORDER BY op.id)
    INTO v_operator_ids
  FROM public.operators op
  WHERE op.auth_user_id = v_auth_uid
    AND COALESCE(op.active, true) = true;

  IF COALESCE(array_length(v_operator_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'Active operator not found for auth user %', v_auth_uid;
  END IF;

  IF array_length(v_operator_ids, 1) > 1 THEN
    RAISE EXCEPTION 'Multiple active operators found for auth user %', v_auth_uid;
  END IF;

  v_operator_id := v_operator_ids[1];

  SELECT
    o.id,
    o.importer_id,
    o.retailer_id,
    o.shipper_id
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.shipper_id IS NULL THEN
    RAISE EXCEPTION 'Order % has NULL shipper_id; unsupported for MVP', p_order_id;
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

  SELECT si.id, si.review_status, si.invoice_ref, si.review_notes
    INTO v_existing_invoice
  FROM public.supplier_invoices si
  WHERE si.order_id = v_order.id
    AND si.retailer_id = v_order.retailer_id
    AND si.invoice_ref = v_invoice_ref
  ORDER BY si.uploaded_at DESC NULLS LAST, si.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_invoice.id IS NOT NULL THEN
    IF v_existing_invoice.review_status = 'rejected_resubmit_required' THEN
      v_archived_ref := v_invoice_ref || ' [rejected ' || left(v_existing_invoice.id::text, 8) || ']';

      UPDATE public.supplier_invoices si
      SET
        invoice_ref = v_archived_ref,
        review_notes = concat_ws(E'\n',
          NULLIF(si.review_notes, ''),
          'Original invoice_ref archived for corrected resubmission: ' || v_invoice_ref
        )
      WHERE si.id = v_existing_invoice.id;
    ELSE
      RAISE EXCEPTION 'An invoice with reference % already exists for this order and is not rejected for resubmission.', v_invoice_ref;
    END IF;
  END IF;

  INSERT INTO public.supplier_invoices (
    order_id,
    retailer_id,
    retailer_account_id,
    invoice_ref,
    invoice_pdf_url,
    uploaded_by_operator_id,
    ocr_service_used,
    review_status,
    blocked_from_sage_yn,
    is_current_for_order
  )
  VALUES (
    v_order.id,
    v_order.retailer_id,
    v_retailer_account_ids[1],
    v_invoice_ref,
    btrim(p_invoice_pdf_url),
    v_operator_id,
    'manual',
    'pending_review',
    true,
    false
  )
  RETURNING id INTO v_supplier_invoice_id;

  RETURN jsonb_build_object(
    'supplier_invoice_id', v_supplier_invoice_id
  );
END;
$$;

COMMENT ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) IS
'SECURITY DEFINER operator RPC for supplier invoice upload. Validates active operator mapping/access. If a same-ref invoice for the same order/retailer was rejected for resubmission, archives that rejected row invoice_ref and inserts a fresh corrected supplier invoice row with the real invoice_ref.';

REVOKE ALL ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
