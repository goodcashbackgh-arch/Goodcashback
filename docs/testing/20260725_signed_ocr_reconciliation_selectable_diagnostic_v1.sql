-- Read-only SQL Editor diagnostic for the missing bulk progression controls on
-- order abf15b7b-771f-482f-9751-2af0ee0bcbb1 / NIN-240726-A.
--
-- This reproduces the importer reconciliation page's current selectable maths.
-- It performs no INSERT, UPDATE, DELETE, RPC or auth.uid()-dependent call.

WITH active_invoices AS (
  SELECT si.id, si.order_id, si.invoice_ref
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND COALESCE(si.review_status, '') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
),
all_lines AS (
  SELECT
    sil.*,
    ai.invoice_ref,
    lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1') AS progressed
  FROM public.supplier_invoice_lines sil
  JOIN active_invoices ai
    ON ai.id = sil.supplier_invoice_id
),
active_resolutions AS (
  SELECT DISTINCT r.supplier_invoice_line_id
  FROM public.supplier_invoice_line_resolutions r
  JOIN all_lines l
    ON l.id = r.supplier_invoice_line_id
  WHERE r.active = true
),
open_disputes AS (
  SELECT DISTINCT dl.supplier_invoice_line_id
  FROM public.dispute_lines dl
  JOIN public.disputes d
    ON d.id = dl.dispute_id
  JOIN all_lines l
    ON l.id = dl.supplier_invoice_line_id
  WHERE dl.resolved_at IS NULL
    AND d.resolved_at IS NULL
),
order_position AS (
  SELECT
    o.id AS order_id,
    COALESCE(o.total_qty_declared, 0)::numeric AS declared_qty,
    COALESCE(o.order_total_gbp_declared, 0)::numeric AS declared_value,
    COALESCE(SUM(l.qty) FILTER (
      WHERE l.progressed
         OR od.supplier_invoice_line_id IS NOT NULL
    ), 0)::numeric AS accounted_qty,
    COALESCE(SUM(l.amount_inc_vat_gbp) FILTER (
      WHERE l.progressed
         OR od.supplier_invoice_line_id IS NOT NULL
         OR ar.supplier_invoice_line_id IS NOT NULL
    ), 0)::numeric AS accounted_value
  FROM public.orders o
  LEFT JOIN all_lines l
    ON true
  LEFT JOIN open_disputes od
    ON od.supplier_invoice_line_id = l.id
  LEFT JOIN active_resolutions ar
    ON ar.supplier_invoice_line_id = l.id
  WHERE o.id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
  GROUP BY o.id, o.total_qty_declared, o.order_total_gbp_declared
),
position AS (
  SELECT
    *,
    GREATEST(0, declared_qty - accounted_qty) AS remaining_qty,
    GREATEST(0, declared_value - accounted_value) AS remaining_value
  FROM order_position
),
target_lines AS (
  SELECT
    l.*,
    od.supplier_invoice_line_id IS NOT NULL AS has_open_dispute,
    ar.supplier_invoice_line_id IS NOT NULL AS has_active_resolution
  FROM all_lines l
  LEFT JOIN open_disputes od
    ON od.supplier_invoice_line_id = l.id
  LEFT JOIN active_resolutions ar
    ON ar.supplier_invoice_line_id = l.id
  WHERE l.invoice_ref = 'NIN-240726-A'
),
adjustments AS (
  SELECT
    ova.id,
    ova.adjustment_type::text AS adjustment_type,
    COALESCE(ova.amount_gbp, 0)::numeric AS amount_gbp,
    ova.approval_status::text AS approval_status
  FROM public.order_value_adjustments ova
  JOIN active_invoices ai
    ON ai.id = ova.supplier_invoice_id
  WHERE ai.invoice_ref = 'NIN-240726-A'
),
combined AS (
  SELECT
    1 AS sort_order,
    'SUMMARY'::text AS row_type,
    NULL::integer AS line_order,
    NULL::text AS description,
    jsonb_build_object(
      'declared_qty', p.declared_qty,
      'accounted_qty', p.accounted_qty,
      'remaining_qty', p.remaining_qty,
      'declared_value_gbp', p.declared_value,
      'accounted_value_gbp', p.accounted_value,
      'remaining_value_gbp', p.remaining_value,
      'target_signed_line_total_gbp', COALESCE((SELECT SUM(t.amount_inc_vat_gbp) FROM target_lines t), 0),
      'target_positive_line_total_gbp', COALESCE((SELECT SUM(t.amount_inc_vat_gbp) FROM target_lines t WHERE t.amount_inc_vat_gbp >= 0), 0),
      'target_negative_line_total_gbp', COALESCE((SELECT SUM(t.amount_inc_vat_gbp) FROM target_lines t WHERE t.amount_inc_vat_gbp < 0), 0)
    ) AS details
  FROM position p

  UNION ALL

  SELECT
    2 AS sort_order,
    'LINE'::text AS row_type,
    t.line_order,
    t.description,
    jsonb_build_object(
      'line_id', t.id,
      'qty', t.qty,
      'amount_inc_vat_gbp', t.amount_inc_vat_gbp,
      'progressed', t.progressed,
      'has_open_dispute', t.has_open_dispute,
      'has_active_resolution', t.has_active_resolution,
      'unresolved', NOT t.progressed AND NOT t.has_open_dispute AND NOT t.has_active_resolution,
      'nonnegative_gate', t.amount_inc_vat_gbp >= 0,
      'qty_gate', t.qty <= p.remaining_qty,
      'value_gate', t.amount_inc_vat_gbp <= p.remaining_value + 0.01,
      'current_page_selectable',
        NOT t.progressed
        AND NOT t.has_open_dispute
        AND NOT t.has_active_resolution
        AND t.amount_inc_vat_gbp >= 0
        AND t.qty <= p.remaining_qty
        AND t.amount_inc_vat_gbp <= p.remaining_value + 0.01
    ) AS details
  FROM target_lines t
  CROSS JOIN position p

  UNION ALL

  SELECT
    3 AS sort_order,
    'ADJUSTMENT'::text AS row_type,
    NULL::integer AS line_order,
    a.adjustment_type AS description,
    jsonb_build_object(
      'adjustment_id', a.id,
      'amount_gbp', a.amount_gbp,
      'approval_status', a.approval_status
    ) AS details
  FROM adjustments a
)
SELECT
  row_type,
  line_order,
  description,
  details
FROM combined
ORDER BY
  sort_order,
  line_order NULLS LAST,
  description NULLS LAST;
