BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.customer_review_ready_line_ids_v1(p_order_id uuid)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH package_scope AS (
    SELECT
      p.shipment_batch_id,
      p.tracking_submission_id,
      otla.order_id,
      otla.supplier_invoice_line_id,
      COALESCE(otla.qty_allocated, 0) AS qty_allocated,
      (
        SELECT spr.receipt_status
        FROM public.shipper_package_receipts spr
        WHERE spr.tracking_submission_id = p.tracking_submission_id
        ORDER BY spr.created_at DESC
        LIMIT 1
      ) AS latest_receipt_status
    FROM public.shipper_shipment_batch_packages p
    JOIN public.order_tracking_line_allocations otla
      ON otla.tracking_submission_id = p.tracking_submission_id
    WHERE p.active = true
      AND otla.order_id = p_order_id
      AND otla.supplier_invoice_line_id IS NOT NULL
  ), good_batches AS (
    SELECT DISTINCT ps.shipment_batch_id
    FROM package_scope ps
    WHERE ps.latest_receipt_status = 'received_clean'
      AND ps.qty_allocated > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages p2
        LEFT JOIN LATERAL (
          SELECT SUM(COALESCE(otla2.qty_allocated, 0)) AS allocated_qty
          FROM public.order_tracking_line_allocations otla2
          WHERE otla2.tracking_submission_id = p2.tracking_submission_id
        ) alloc2 ON true
        LEFT JOIN LATERAL (
          SELECT spr2.receipt_status
          FROM public.shipper_package_receipts spr2
          WHERE spr2.tracking_submission_id = p2.tracking_submission_id
          ORDER BY spr2.created_at DESC
          LIMIT 1
        ) r2 ON true
        WHERE p2.shipment_batch_id = ps.shipment_batch_id
          AND p2.active = true
          AND (
            COALESCE(alloc2.allocated_qty, 0) <= 0
            OR COALESCE(r2.receipt_status, '') <> 'received_clean'
          )
      )
  )
  SELECT DISTINCT
    ps.supplier_invoice_line_id,
    ps.tracking_submission_id
  FROM package_scope ps
  JOIN good_batches gb ON gb.shipment_batch_id = ps.shipment_batch_id
  JOIN public.supplier_invoice_lines sil ON sil.id = ps.supplier_invoice_line_id
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
    AND ps.latest_receipt_status = 'received_clean'
    AND ps.qty_allocated > 0;
$$;

REVOKE ALL ON FUNCTION public.customer_review_ready_line_ids_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_review_ready_line_ids_v1(uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.customer_order_has_review_ready_lines_v1(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.customer_review_ready_line_ids_v1(p_order_id));
$$;

REVOKE ALL ON FUNCTION public.customer_order_has_review_ready_lines_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_order_has_review_ready_lines_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_active_order_review_link_v1(p_order_id uuid)
RETURNS TABLE (order_id uuid, customer_review_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_importer_id uuid;
  v_token text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT o.importer_id INTO v_importer_id FROM public.orders o WHERE o.id = p_order_id;
  IF v_importer_id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id = op.id
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
      AND oi.revoked_at IS NULL
      AND oi.importer_id = v_importer_id
  ) THEN
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;

  SELECT l.secure_token INTO v_token
  FROM public.customer_order_review_links l
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  ORDER BY l.created_at DESC
  LIMIT 1;

  IF v_token IS NULL
     AND public.customer_order_has_review_ready_lines_v1(p_order_id)
     AND NOT EXISTS (
       SELECT 1 FROM public.sales_invoices si
       WHERE si.order_id = p_order_id
         AND COALESCE(si.invoice_type::text, '') IN ('main','supplementary')
         AND COALESCE(si.sage_status::text, '') IN ('draft','posted')
     )
  THEN
    INSERT INTO public.customer_order_review_links(order_id, is_active)
    VALUES (p_order_id, true)
    RETURNING secure_token INTO v_token;
  END IF;

  IF v_token IS NULL THEN RETURN; END IF;

  RETURN QUERY SELECT p_order_id, ('/customer/orders/' || v_token || '/review')::text;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_active_order_review_link_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_active_order_review_link_v1(uuid) TO authenticated;

COMMIT;
