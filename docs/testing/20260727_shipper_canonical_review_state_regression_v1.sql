-- Transactional fixture guard for the shipper canonical review-state regression.
-- The supplier-invoice trigger must exercise the real order transition guard.

BEGIN;

DO $$
DECLARE
  v_source_order public.orders%ROWTYPE;
  v_fixture_order public.orders%ROWTYPE;
  v_source_invoice public.supplier_invoices%ROWTYPE;
  v_fixture_invoice public.supplier_invoices%ROWTYPE;
  v_fixture_order_id uuid := gen_random_uuid();
  v_fixture_invoice_id uuid := gen_random_uuid();
  v_fixture_ref text := 'SHIPPER-CANONICAL-' || replace(v_fixture_order_id::text, '-', '');
  v_status text;
BEGIN
  SELECT order_row.*
  INTO STRICT v_source_order
  FROM public.orders order_row
  WHERE order_row.order_ref = 'ORD-1784976429191';

  SELECT invoice_row.*
  INTO STRICT v_source_invoice
  FROM public.supplier_invoices invoice_row
  WHERE invoice_row.order_id = v_source_order.id
  ORDER BY invoice_row.uploaded_at, invoice_row.id
  LIMIT 1;

  -- Do not copy the source order's live lifecycle state into the isolated fixture.
  -- evidence_collecting -> reconciling is the canonical guarded transition made
  -- by recompute_order_status() when the first supplier invoice is inserted.
  v_fixture_order := jsonb_populate_record(
    NULL::public.orders,
    to_jsonb(v_source_order) || jsonb_build_object(
      'id', v_fixture_order_id,
      'order_ref', v_fixture_ref,
      'status', 'evidence_collecting',
      'content_locked_at', NULL,
      'tracking_locked_at', NULL,
      'completed_at', NULL,
      'created_at', now(),
      'updated_at', now()
    )
  );

  INSERT INTO public.orders
  SELECT v_fixture_order.*;

  v_fixture_invoice := jsonb_populate_record(
    NULL::public.supplier_invoices,
    to_jsonb(v_source_invoice) || jsonb_build_object(
      'id', v_fixture_invoice_id,
      'order_id', v_fixture_order_id,
      'invoice_ref', v_fixture_ref || '-INV',
      'uploaded_at', now()
    )
  );

  INSERT INTO public.supplier_invoices
  SELECT v_fixture_invoice.*;

  SELECT order_row.status
  INTO STRICT v_status
  FROM public.orders order_row
  WHERE order_row.id = v_fixture_order_id;

  IF v_status <> 'reconciling' THEN
    RAISE EXCEPTION
      'FAIL: fixture order status is %, expected reconciling after supplier-invoice insert',
      v_status;
  END IF;

  RAISE NOTICE 'PASS: fixture transitioned evidence_collecting -> reconciling';
END $$;

ROLLBACK;
