WITH target_batch AS (
  SELECT id, booking_ref
  FROM public.shipper_shipment_batches
  WHERE booking_ref = 'J040826'
  ORDER BY created_at DESC, id DESC
  LIMIT 1
), effective AS (
  SELECT e.*
  FROM target_batch b
  CROSS JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(b.id) e
), latest_receipt AS (
  SELECT DISTINCT ON (spr.tracking_submission_id)
    spr.tracking_submission_id,
    spr.receipt_status,
    spr.recorded_at,
    spr.created_at,
    spr.id AS receipt_id
  FROM public.shipper_package_receipts spr
  JOIN effective e ON e.tracking_submission_id = spr.tracking_submission_id
  ORDER BY spr.tracking_submission_id,
           spr.recorded_at DESC NULLS LAST,
           spr.created_at DESC,
           spr.id DESC
), release_source AS (
  SELECT src.*
  FROM target_batch b
  CROSS JOIN LATERAL public.internal_customer_sales_release_sources_v1(b.id) src
), release_ledger AS (
  SELECT
    csl.tracking_line_allocation_id,
    csl.sales_invoice_id,
    csl.release_status,
    csl.released_qty,
    csl.goods_amount_gbp,
    csl.shipping_amount_gbp,
    csl.customer_charge_amount_gbp,
    csl.source_shipment_batch_id
  FROM public.customer_sales_release_lines csl
  JOIN target_batch b ON b.id = csl.source_shipment_batch_id
), invoice_rows AS (
  SELECT
    si.id,
    si.order_id,
    si.invoice_type,
    si.sage_status,
    si.amount_gbp,
    si.created_at
  FROM public.sales_invoices si
  WHERE si.order_id IN (SELECT DISTINCT order_id FROM effective)
)
SELECT jsonb_build_object(
  'probe', 'j040826_sales_release_line_diagnostic_v1',
  'batch', (SELECT to_jsonb(target_batch) FROM target_batch),
  'effective_lines', COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'tracking_submission_id', e.tracking_submission_id,
        'tracking_line_allocation_id', e.tracking_line_allocation_id,
        'order_id', e.order_id,
        'supplier_invoice_line_id', e.supplier_invoice_line_id,
        'qty_in_shipment', e.qty_in_shipment,
        'adjusted_net_value_gbp', e.adjusted_net_value_gbp,
        'source_mode', e.source_mode,
        'package_receipt_status', lr.receipt_status,
        'package_receipt_recorded_at', lr.recorded_at
      ) ORDER BY e.tracking_line_allocation_id
    )
    FROM effective e
    LEFT JOIN latest_receipt lr
      ON lr.tracking_submission_id = e.tracking_submission_id
  ), '[]'::jsonb),
  'release_sources', COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'tracking_submission_id', rs.tracking_submission_id,
        'tracking_line_allocation_id', rs.tracking_line_allocation_id,
        'supplier_invoice_line_id', rs.supplier_invoice_line_id,
        'release_qty', rs.release_qty,
        'goods_amount_gbp', rs.goods_amount_gbp,
        'shipping_amount_gbp', rs.shipping_amount_gbp,
        'customer_charge_amount_gbp', rs.customer_charge_amount_gbp,
        'proposed_invoice_type', rs.proposed_invoice_type,
        'sales_invoice_state', rs.sales_invoice_state,
        'blocker', rs.blocker
      ) ORDER BY rs.tracking_line_allocation_id
    )
    FROM release_source rs
  ), '[]'::jsonb),
  'release_ledger', COALESCE((SELECT jsonb_agg(to_jsonb(release_ledger)) FROM release_ledger), '[]'::jsonb),
  'sales_invoices', COALESCE((SELECT jsonb_agg(to_jsonb(invoice_rows) ORDER BY created_at) FROM invoice_rows), '[]'::jsonb)
) AS result;