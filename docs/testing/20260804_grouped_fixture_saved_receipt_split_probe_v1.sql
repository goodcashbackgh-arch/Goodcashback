-- Read-only probe: show the saved clean-versus-diverted receipt truth for the
-- grouped five-line fixture. No auth-dependent RPCs and no writes.

WITH target_order AS (
  SELECT '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid AS order_id
), latest_receipt AS (
  SELECT r.*
  FROM public.shipper_package_receipts r
  JOIN target_order t ON t.order_id = r.order_id
  WHERE r.receipt_model_version = 2
    AND r.receipt_state = 'finalised'
    AND r.finalised_at IS NOT NULL
  ORDER BY r.created_at DESC, r.id DESC
  LIMIT 1
), saved_lines AS (
  SELECT
    d.receipt_id,
    d.tracking_line_allocation_id,
    d.supplier_invoice_line_id,
    sil.description AS item_description,
    a.qty_allocated,
    d.disposition_type,
    d.quantity,
    d.condition_note,
    d.id AS line_disposition_id
  FROM latest_receipt r
  JOIN public.shipper_package_receipt_line_dispositions d
    ON d.receipt_id = r.id
  JOIN public.order_tracking_line_allocations a
    ON a.id = d.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines sil
    ON sil.id = d.supplier_invoice_line_id
), per_allocation AS (
  SELECT
    tracking_line_allocation_id,
    supplier_invoice_line_id,
    item_description,
    MAX(qty_allocated)::numeric AS qty_allocated,
    COALESCE(SUM(quantity) FILTER (WHERE disposition_type = 'clean'), 0)::numeric AS clean_qty,
    COALESCE(SUM(quantity) FILTER (WHERE disposition_type <> 'clean'), 0)::numeric AS diverted_qty,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'disposition_type', disposition_type,
          'quantity', quantity,
          'condition_note', condition_note,
          'line_disposition_id', line_disposition_id
        ) ORDER BY disposition_type
      ) FILTER (WHERE disposition_type <> 'clean'),
      '[]'::jsonb
    ) AS diverted_segments
  FROM saved_lines
  GROUP BY tracking_line_allocation_id, supplier_invoice_line_id, item_description
), totals AS (
  SELECT
    COALESCE(SUM(clean_qty), 0)::numeric AS clean_qty,
    COALESCE(SUM(diverted_qty), 0)::numeric AS diverted_qty,
    COALESCE(SUM(qty_allocated), 0)::numeric AS allocated_qty
  FROM per_allocation
)
SELECT jsonb_build_object(
  'probe', 'grouped_fixture_saved_receipt_split_probe_v1',
  'latest_receipt', COALESCE((SELECT to_jsonb(r) FROM latest_receipt r), '{}'::jsonb),
  'totals', COALESCE((SELECT to_jsonb(t) FROM totals t), '{}'::jsonb),
  'per_allocation', COALESCE(
    (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.item_description, p.tracking_line_allocation_id) FROM per_allocation p),
    '[]'::jsonb
  ),
  'raw_saved_dispositions', COALESCE(
    (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.item_description, s.disposition_type) FROM saved_lines s),
    '[]'::jsonb
  )
) AS result;