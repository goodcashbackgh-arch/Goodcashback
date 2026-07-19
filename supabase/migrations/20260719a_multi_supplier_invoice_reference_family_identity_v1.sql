BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.order_value_adjustments') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.customer_order_review_links') IS NULL
     OR to_regclass('public.customer_pre_shipment_hold_requests') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.sage_postings') IS NULL
     OR to_regclass('public.dispute_refund_evidence_submissions') IS NULL
  THEN
    RAISE EXCEPTION 'Mini-build 1 prerequisite relation is missing.';
  END IF;

  IF to_regprocedure('public.operator_submit_supplier_invoice(uuid,text,text)') IS NULL
     OR to_regprocedure('public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)') IS NULL
     OR to_regprocedure('public.staff_reject_supplier_invoice_resubmission(uuid,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Mini-build 1 prerequisite RPC is missing.';
  END IF;
END $$;

DROP INDEX IF EXISTS public.uq_supplier_invoices_one_current_per_order;

ALTER TABLE public.supplier_invoices
  DROP CONSTRAINT IF EXISTS supplier_invoices_retailer_id_invoice_ref_order_id_key;

DO $$
DECLARE
  v_collision record;
BEGIN
  SELECT
    si.order_id,
    si.retailer_id,
    lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) AS normalised_ref,
    COUNT(*)::integer AS live_count
  INTO v_collision
  FROM public.supplier_invoices si
  WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  )
  GROUP BY
    si.order_id,
    si.retailer_id,
    lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g'))
  HAVING COUNT(*) > 1
  ORDER BY live_count DESC
  LIMIT 1;

  IF v_collision.order_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Cannot install Mini-build 1: order %, retailer %, reference family % has % live versions.',
      v_collision.order_id,
      v_collision.retailer_id,
      v_collision.normalised_ref,
      v_collision.live_count;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_supplier_invoices_current_reference_family
  ON public.supplier_invoices (
    order_id,
    retailer_id,
    (lower(regexp_replace(btrim(invoice_ref), '[^a-zA-Z0-9]+', '', 'g')))
  )
  WHERE COALESCE(review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    );

CREATE INDEX IF NOT EXISTS idx_supplier_invoices_order_active_versions
  ON public.supplier_invoices (order_id, uploaded_at DESC, id)
  WHERE COALESCE(review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  );

COMMENT ON COLUMN public.supplier_invoices.is_current_for_order IS
'Legacy compatibility marker. Mini-build 1 defines active reference-family truth by non-retired review_status so existing live rows are not rewritten solely to change this flag.';

COMMENT ON INDEX public.uq_supplier_invoices_current_reference_family IS
'Allows several genuine supplier invoice references on one order while permitting only one live current version of each normalised reference family.';

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
  v_normalised_ref text;
  v_latest_family record;
  v_live_family record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: invoice submission requires auth.uid()';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id is required';
  END IF;

  v_invoice_ref := btrim(COALESCE(p_invoice_ref, ''));
  v_normalised_ref := lower(regexp_replace(v_invoice_ref, '[^a-zA-Z0-9]+', '', 'g'));

  IF length(v_invoice_ref) = 0 THEN
    RAISE EXCEPTION 'invoice_ref must not be blank';
  END IF;

  IF length(v_normalised_ref) = 0 THEN
    RAISE EXCEPTION 'invoice_ref must contain at least one letter or number';
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

  SELECT o.id, o.importer_id, o.retailer_id, o.shipper_id
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

  PERFORM pg_advisory_xact_lock(
    hashtext(v_order.id::text || ':' || v_order.retailer_id::text || ':' || v_normalised_ref)
  );

  SELECT si.id, si.review_status, si.invoice_ref, si.is_current_for_order
    INTO v_live_family
  FROM public.supplier_invoices si
  WHERE si.order_id = v_order.id
    AND si.retailer_id = v_order.retailer_id
    AND lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) = v_normalised_ref
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  ORDER BY si.uploaded_at DESC NULLS LAST, si.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_live_family.id IS NOT NULL THEN
    RAISE EXCEPTION
      'A live supplier invoice with reference % already exists for this order. Correct or retire that reference family before resubmitting it.',
      v_invoice_ref;
  END IF;

  SELECT si.id, si.review_status, si.invoice_ref, si.is_current_for_order
    INTO v_latest_family
  FROM public.supplier_invoices si
  WHERE si.order_id = v_order.id
    AND si.retailer_id = v_order.retailer_id
    AND lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) = v_normalised_ref
  ORDER BY si.uploaded_at DESC NULLS LAST, si.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_latest_family.id IS NOT NULL
     AND COALESCE(v_latest_family.review_status, '') NOT IN (
       'rejected_resubmit_required',
       'superseded'
     )
  THEN
    RAISE EXCEPTION
      'Invoice reference % already exists for this order and is not rejected for corrected resubmission.',
      v_invoice_ref;
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
    true
  )
  RETURNING id INTO v_supplier_invoice_id;

  RETURN jsonb_build_object(
    'supplier_invoice_id', v_supplier_invoice_id,
    'order_id', v_order.id,
    'invoice_ref', v_invoice_ref,
    'reference_family_current_yn', true
  );
END;
$$;

COMMENT ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) IS
'SECURITY DEFINER operator upload RPC. Allows different supplier invoice references to coexist on one order, blocks a duplicate live normalised reference, and preserves the genuine reference on corrected rejected-family resubmission.';

REVOKE ALL ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_submit_supplier_invoice(uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
