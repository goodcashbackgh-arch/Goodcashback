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
), facts AS (
  SELECT
    e.*,
    ots.tracking_ref,
    sil.description AS item_description,
    si.review_status AS supplier_invoice_review_status,
    COALESCE(si.blocked_from_sage_yn, false) AS supplier_invoice_blocked_from_sage,
    sil.eligible_for_invoice_yn,
    receipt.receipt_status AS package_receipt_status,
    EXISTS (
      SELECT 1
      FROM public.dispute_lines dl
      JOIN public.disputes d ON d.id = dl.dispute_id
      WHERE dl.supplier_invoice_line_id = e.supplier_invoice_line_id
        AND dl.resolved_at IS NULL
        AND d.resolved_at IS NULL
    ) AS has_unresolved_exception,
    COALESCE(released.released_qty, 0) AS already_released_qty,
    COALESCE(released.released_goods, 0) AS already_released_goods,
    EXISTS (
      SELECT 1
      FROM public.sales_invoices s
      WHERE s.order_id = e.order_id
        AND s.invoice_type IN ('main', 'supplementary')
        AND s.sage_status = 'draft'
    ) AS has_active_sales_draft
  FROM effective e
  JOIN public.order_tracking_submissions ots ON ots.id = e.tracking_submission_id
  JOIN public.supplier_invoice_lines sil ON sil.id = e.supplier_invoice_line_id
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  LEFT JOIN LATERAL (
    SELECT spr.receipt_status
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = e.tracking_submission_id
    ORDER BY spr.recorded_at DESC NULLS LAST, spr.created_at DESC, spr.id DESC
    LIMIT 1
  ) receipt ON true
  LEFT JOIN LATERAL (
    SELECT
      SUM(csl.released_qty)::numeric AS released_qty,
      SUM(csl.goods_amount_gbp)::numeric AS released_goods
    FROM public.customer_sales_release_lines csl
    WHERE csl.tracking_line_allocation_id = e.tracking_line_allocation_id
      AND csl.release_status = 'active'
  ) released ON true
)
SELECT jsonb_build_object(
  'probe', 'j040826_sales_release_line_diagnostic_v2',
  'batch', (SELECT to_jsonb(target_batch) FROM target_batch),
  'lines', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'tracking_ref', f.tracking_ref,
      'tracking_line_allocation_id', f.tracking_line_allocation_id,
      'supplier_invoice_line_id', f.supplier_invoice_line_id,
      'item_description', f.item_description,
      'qty_in_shipment', f.qty_in_shipment,
      'adjusted_net_value_gbp', f.adjusted_net_value_gbp,
      'source_mode', f.source_mode,
      'package_receipt_status', f.package_receipt_status,
      'supplier_invoice_review_status', f.supplier_invoice_review_status,
      'supplier_invoice_blocked_from_sage', f.supplier_invoice_blocked_from_sage,
      'eligible_for_invoice_yn', f.eligible_for_invoice_yn,
      'has_unresolved_exception', f.has_unresolved_exception,
      'has_active_sales_draft', f.has_active_sales_draft,
      'already_released_qty', f.already_released_qty,
      'already_released_goods', f.already_released_goods,
      'inferred_release_blocker', CASE
        WHEN f.has_active_sales_draft THEN 'customer_sales_release_draft_already_exists'
        WHEN f.supplier_invoice_review_status NOT IN ('approved_current', 'ref_corrected_approved')
          OR f.supplier_invoice_blocked_from_sage THEN 'supplier_invoice_not_approved_current'
        WHEN lower(COALESCE(f.eligible_for_invoice_yn::text, '')) NOT IN ('y','yes','true','1') THEN 'supplier_line_not_progressed'
        WHEN f.package_receipt_status IS DISTINCT FROM 'received_clean' THEN 'package_not_received_clean'
        WHEN f.has_unresolved_exception THEN 'unresolved_exception'
        WHEN f.already_released_qty >= f.qty_in_shipment
          AND f.already_released_goods >= f.adjusted_net_value_gbp THEN 'source_fully_released'
        ELSE NULL
      END
    ) ORDER BY f.tracking_line_allocation_id)
    FROM facts f
  ), '[]'::jsonb)
) AS result;