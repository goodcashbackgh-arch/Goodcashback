-- Read-only diagnostic for the authenticated J040826 draft creation.
-- Confirms whether J040826v1 was actually included in the created invoice or
-- merely changed to draft_exists because it shares the same commercial parent.

WITH target_batches AS (
  SELECT id, booking_ref
  FROM public.shipper_shipment_batches
  WHERE booking_ref IN ('J040826', 'J040826v1')
), target_order AS (
  SELECT DISTINCT e.order_id
  FROM target_batches b
  CROSS JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(b.id) e
), target_parent AS (
  SELECT DISTINCT
    CASE
      WHEN o.order_type = 'replacement_child' AND o.parent_order_id IS NOT NULL
        THEN o.parent_order_id
      ELSE o.id
    END AS commercial_parent_order_id
  FROM target_order t
  JOIN public.orders o ON o.id = t.order_id
), latest_draft AS (
  SELECT s.*
  FROM public.sales_invoices s
  JOIN target_parent p ON p.commercial_parent_order_id = s.order_id
  WHERE s.invoice_type IN ('main', 'supplementary')
    AND s.sage_status = 'draft'
  ORDER BY s.created_at DESC, s.id DESC
  LIMIT 1
), memberships AS (
  SELECT
    l.id AS release_line_id,
    l.sales_invoice_id,
    l.source_shipment_batch_id,
    b.booking_ref,
    l.tracking_line_allocation_id,
    l.released_qty,
    l.goods_amount_gbp,
    l.shipping_amount_gbp,
    l.customer_charge_amount_gbp,
    l.release_status,
    l.membership_fingerprint
  FROM public.customer_sales_release_lines l
  JOIN latest_draft d ON d.id = l.sales_invoice_id
  LEFT JOIN public.shipper_shipment_batches b ON b.id = l.source_shipment_batch_id
), payload_batches AS (
  SELECT DISTINCT value::uuid AS source_shipment_batch_id
  FROM latest_draft d
  CROSS JOIN LATERAL jsonb_array_elements_text(
    COALESCE(d.line_items_json #> '{draft_control,shipment_batch_ids}', '[]'::jsonb)
  )
)
SELECT jsonb_build_object(
  'diagnostic', 'j040826_created_draft_membership_v1',
  'latest_draft', (
    SELECT jsonb_build_object(
      'sales_invoice_id', d.id,
      'order_id', d.order_id,
      'invoice_type', d.invoice_type,
      'amount_gbp', d.amount_gbp,
      'sage_status', d.sage_status,
      'created_at', d.created_at,
      'payload_shipment_batch_ids', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'shipment_batch_id', p.source_shipment_batch_id,
          'booking_ref', b.booking_ref
        ) ORDER BY b.booking_ref)
        FROM payload_batches p
        LEFT JOIN public.shipper_shipment_batches b ON b.id = p.source_shipment_batch_id
      ), '[]'::jsonb)
    )
    FROM latest_draft d
  ),
  'active_membership_count', (
    SELECT COUNT(*) FROM memberships WHERE release_status = 'active'
  ),
  'active_membership_bookings', COALESCE((
    SELECT jsonb_agg(DISTINCT booking_ref ORDER BY booking_ref)
    FROM memberships
    WHERE release_status = 'active'
  ), '[]'::jsonb),
  'memberships', COALESCE((
    SELECT jsonb_agg(to_jsonb(m) ORDER BY booking_ref, release_line_id)
    FROM memberships m
  ), '[]'::jsonb),
  'interpretation', jsonb_build_object(
    'j040826_included', EXISTS (
      SELECT 1 FROM memberships
      WHERE release_status = 'active' AND booking_ref = 'J040826'
    ),
    'j040826v1_included', EXISTS (
      SELECT 1 FROM memberships
      WHERE release_status = 'active' AND booking_ref = 'J040826v1'
    ),
    'only_j040826_included', (
      EXISTS (
        SELECT 1 FROM memberships
        WHERE release_status = 'active' AND booking_ref = 'J040826'
      )
      AND NOT EXISTS (
        SELECT 1 FROM memberships
        WHERE release_status = 'active' AND booking_ref = 'J040826v1'
      )
    )
  )
) AS result;
