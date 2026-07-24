-- Read-only regression for customer release effective shipment membership alignment.

BEGIN;

DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_sales_release_guard_v1()') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: effective-membership alignment function missing';
  END IF;

  SELECT pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)
  INTO v_definition;

  IF position('shipper_shipment_batch_effective_lines_v1' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer release source resolver does not use effective shipment membership';
  END IF;
  IF position('terminal_refund_line_excluded' in v_definition) = 0
     OR position('terminal_dispute.status = ''refunded''' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: terminal refunded lines are not permanently excluded';
  END IF;
  IF position('JOIN public.shipper_shipment_batch_packages package_row' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: customer release source resolver still reconstructs package allocations';
  END IF;

  SELECT pg_get_functiondef('public.customer_sales_release_guard_v1()'::regprocedure)
  INTO v_definition;

  IF position('shipper_shipment_batch_effective_lines_v1' in v_definition) = 0
     OR position('Release source is not an effective line of the stated shipment batch' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: release insert guard does not enforce exact effective shipment membership';
  END IF;
  IF position('Terminal refunded line cannot be attached to a customer sales release' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: release insert guard does not block terminal refunded lines';
  END IF;

  SELECT pg_get_functiondef('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure)
  INTO v_definition;

  IF position('customer_sales_release_lines' in v_definition) = 0
     OR position('internal_shipping_customer_invoice_remaining_preview_v1' in v_definition) = 0
     OR position('already_bundled_in_main_sales_invoice' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: post-draft readiness does not switch from remaining preview to durable release truth';
  END IF;

  SELECT pg_get_functiondef('public.internal_resolved_customer_sales_sage_payload_v1(uuid)'::regprocedure)
  INTO v_definition;

  IF position('base_row.sage_status = ''void''' in v_definition) = 0
     OR position('shaped_row.sage_status <> ''void''' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: void customer documents are still subjected to active-membership blocking';
  END IF;
END $$;

DO $$
DECLARE
  v_batch_id uuid;
  v_effective_count integer;
  v_refunded_count integer;
  v_invalid_active_release_count integer;
  v_bad_active_draft_count integer;
BEGIN
  SELECT batch_row.id
  INTO v_batch_id
  FROM public.shipper_shipment_batches batch_row
  WHERE batch_row.booking_ref = 'J0210726'
  ORDER BY batch_row.created_at DESC, batch_row.id DESC
  LIMIT 1;

  IF v_batch_id IS NOT NULL THEN
    SELECT COUNT(*)::integer
    INTO v_effective_count
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);

    SELECT COUNT(*)::integer
    INTO v_refunded_count
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) effective_line
    WHERE effective_line.supplier_invoice_line_id = 'd7d42758-4a8d-4632-910e-353c06d2f621'::uuid;

    IF v_effective_count < 1 THEN
      RAISE EXCEPTION 'FAIL: J0210726 has no effective shipment line';
    END IF;
    IF v_refunded_count <> 0 THEN
      RAISE EXCEPTION 'FAIL: refunded Ninja line remains in J0210726 effective shipment membership';
    END IF;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_invalid_active_release_count
  FROM public.customer_sales_release_lines release_line
  JOIN public.orders order_row
    ON order_row.id = release_line.commercial_parent_order_id
  JOIN public.sales_invoices sales_invoice
    ON sales_invoice.id = release_line.sales_invoice_id
  WHERE order_row.order_ref = 'ORD-1784498556959'
    AND release_line.release_status = 'active'
    AND sales_invoice.sage_status <> 'void'
    AND release_line.source_shipment_batch_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(release_line.source_shipment_batch_id) effective_line
      WHERE effective_line.tracking_line_allocation_id = release_line.tracking_line_allocation_id
        AND effective_line.order_id = release_line.order_id
        AND effective_line.tracking_submission_id = release_line.tracking_submission_id
        AND effective_line.supplier_invoice_line_id = release_line.supplier_invoice_line_id
    );

  IF v_invalid_active_release_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: golden order retains % active release line(s) outside effective shipment membership', v_invalid_active_release_count;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad_active_draft_count
  FROM public.sales_invoices sales_invoice
  JOIN public.orders order_row
    ON order_row.id = sales_invoice.order_id
  WHERE order_row.order_ref = 'ORD-1784498556959'
    AND sales_invoice.sage_status = 'draft'
    AND ABS(COALESCE(sales_invoice.amount_gbp, 0) - 1004.96) <= 0.02
    AND EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.sales_invoice_id = sales_invoice.id
        AND release_line.release_status = 'active'
        AND release_line.supplier_invoice_line_id = 'd7d42758-4a8d-4632-910e-353c06d2f621'::uuid
    );

  IF v_bad_active_draft_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: invalid £1004.96 draft remains active';
  END IF;
END $$;

DO $$
BEGIN
  RAISE NOTICE 'PASS: exact effective shipment membership governs customer release; terminal refunded lines, post-draft readiness and void Sage documents are aligned without changing Mini-build 1-4 routes.';
END $$;

ROLLBACK;
