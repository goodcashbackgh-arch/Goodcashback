BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';
CREATE OR REPLACE VIEW public.order_supplier_invoice_bundle_lines_v1
WITH (security_invoker = true)
AS
WITH active_invoices AS (
  SELECT si.*
  FROM public.supplier_invoices si
  WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
),
tracking AS (
  SELECT
    otla.supplier_invoice_line_id,
    SUM(COALESCE(otla.qty_allocated, 0))::numeric AS allocated_tracking_qty,
    SUM(COALESCE(otla.adjusted_net_value_gbp, 0))::numeric AS allocated_tracking_value_gbp
  FROM public.order_tracking_line_allocations otla
  GROUP BY otla.supplier_invoice_line_id
),
line_state AS (
  SELECT
    sil.id AS supplier_invoice_line_id,
    EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_line_id = sil.id
        AND r.active = true
    ) AS non_physical_resolution_yn,
    EXISTS (
      SELECT 1
      FROM public.dispute_lines dl
      JOIN public.disputes d ON d.id = dl.dispute_id
      WHERE dl.supplier_invoice_line_id = sil.id
        AND dl.resolved_at IS NULL
        AND d.resolved_at IS NULL
    ) AS open_exception_yn
  FROM public.supplier_invoice_lines sil
),
hold_state AS (
  SELECT
    sil.id AS supplier_invoice_line_id,
    EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = si.order_id
        AND h.resolved_at IS NULL
        AND h.status IN ('requested', 'supervisor_approved', 'converted_to_exception')
        AND (
          h.requested_scope = 'order'
          OR (
            h.requested_scope = 'line'
            AND h.supplier_invoice_line_id = sil.id
          )
          OR (
            h.requested_scope = 'tracking'
            AND EXISTS (
              SELECT 1
              FROM public.order_tracking_line_allocations otla
              WHERE otla.supplier_invoice_line_id = sil.id
                AND otla.tracking_submission_id = h.tracking_submission_id
                AND COALESCE(otla.qty_allocated, 0) > 0
            )
          )
        )
    ) AS active_hold_yn
  FROM public.supplier_invoice_lines sil
  JOIN active_invoices si ON si.id = sil.supplier_invoice_id
)
SELECT
  ai.order_id,
  ai.id AS supplier_invoice_id,
  ai.invoice_ref::text AS supplier_invoice_ref,
  ai.review_status::text AS supplier_invoice_status,
  sil.id AS supplier_invoice_line_id,
  sil.line_order,
  sil.line_source::text AS line_source,
  sil.qty::numeric AS raw_qty,
  sil.amount_inc_vat_gbp::numeric AS raw_gross_gbp,
  COALESCE(sil.qty_confirmed, sil.qty)::numeric AS confirmed_qty,
  COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp)::numeric AS confirmed_gross_gbp,
  (
    lower(btrim(COALESCE(sil.eligible_for_invoice_yn::text, 'n')))
      IN ('y', 'yes', 'true', '1')
  ) AS progressed_yn,
  ls.non_physical_resolution_yn,
  ls.open_exception_yn,
  hs.active_hold_yn,
  COALESCE(t.allocated_tracking_qty, 0)::numeric AS allocated_tracking_qty,
  GREATEST(
    COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric
      - COALESCE(t.allocated_tracking_qty, 0)::numeric,
    0::numeric
  ) AS remaining_tracking_qty,
  COALESCE(t.allocated_tracking_value_gbp, 0)::numeric AS allocated_tracking_value_gbp
FROM active_invoices ai
JOIN public.supplier_invoice_lines sil
  ON sil.supplier_invoice_id = ai.id
JOIN line_state ls
  ON ls.supplier_invoice_line_id = sil.id
JOIN hold_state hs
  ON hs.supplier_invoice_line_id = sil.id
LEFT JOIN tracking t
  ON t.supplier_invoice_line_id = sil.id;

COMMENT ON VIEW public.order_supplier_invoice_bundle_lines_v1 IS
'Read-only exact-line bundle across every live current supplier invoice reference family for an order. Retired invoice versions are excluded.';

CREATE OR REPLACE VIEW public.order_supplier_invoice_bundle_summary_v1
WITH (security_invoker = true)
AS
WITH invoice_counts AS (
  SELECT
    si.order_id,
    COUNT(*)::integer AS active_invoice_count,
    COUNT(*) FILTER (
      WHERE si.review_status IN ('approved_current', 'ref_corrected_approved')
    )::integer AS approved_invoice_count,
    COUNT(*) FILTER (
      WHERE si.review_status NOT IN ('approved_current', 'ref_corrected_approved')
    )::integer AS review_invoice_count
  FROM public.supplier_invoices si
  WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  GROUP BY si.order_id
),
line_counts AS (
  SELECT
    b.order_id,
    COUNT(*)::integer AS active_line_count,
    COALESCE(SUM(b.confirmed_qty) FILTER (
      WHERE b.progressed_yn = true
        AND b.non_physical_resolution_yn = false
        AND b.open_exception_yn = false
    ), 0)::numeric AS progressed_physical_qty,
    COALESCE(SUM(b.confirmed_gross_gbp) FILTER (
      WHERE b.progressed_yn = true
        AND b.non_physical_resolution_yn = false
        AND b.open_exception_yn = false
    ), 0)::numeric AS progressed_physical_value_gbp,
    COALESCE(SUM(b.confirmed_qty) FILTER (
      WHERE b.open_exception_yn = true
    ), 0)::numeric AS exception_qty,
    COALESCE(SUM(b.confirmed_gross_gbp) FILTER (
      WHERE b.open_exception_yn = true
    ), 0)::numeric AS exception_value_gbp,
    COALESCE(SUM(b.confirmed_gross_gbp) FILTER (
      WHERE b.non_physical_resolution_yn = true
    ), 0)::numeric AS non_physical_value_gbp,
    COALESCE(SUM(b.allocated_tracking_qty), 0)::numeric AS tracking_allocated_qty,
    COALESCE(SUM(b.allocated_tracking_value_gbp), 0)::numeric AS tracking_allocated_value_gbp,
    COUNT(*) FILTER (
      WHERE b.progressed_yn = false
        AND b.non_physical_resolution_yn = false
        AND b.open_exception_yn = false
    )::integer AS unresolved_line_count
  FROM public.order_supplier_invoice_bundle_lines_v1 b
  GROUP BY b.order_id
)
SELECT
  o.id AS order_id,
  COALESCE(ic.active_invoice_count, 0)::integer AS active_invoice_count,
  COALESCE(ic.approved_invoice_count, 0)::integer AS approved_invoice_count,
  COALESCE(ic.review_invoice_count, 0)::integer AS review_invoice_count,
  COALESCE(lc.active_line_count, 0)::integer AS active_line_count,
  COALESCE(lc.progressed_physical_qty, 0)::numeric AS progressed_physical_qty,
  COALESCE(lc.progressed_physical_value_gbp, 0)::numeric AS progressed_physical_value_gbp,
  COALESCE(lc.exception_qty, 0)::numeric AS exception_qty,
  COALESCE(lc.exception_value_gbp, 0)::numeric AS exception_value_gbp,
  COALESCE(lc.non_physical_value_gbp, 0)::numeric AS non_physical_value_gbp,
  COALESCE(lc.tracking_allocated_qty, 0)::numeric AS tracking_allocated_qty,
  COALESCE(lc.tracking_allocated_value_gbp, 0)::numeric AS tracking_allocated_value_gbp,
  COALESCE(o.total_qty_declared, 0)::numeric AS order_baseline_qty,
  COALESCE(o.order_total_gbp_declared, 0)::numeric AS order_baseline_value_gbp,
  GREATEST(
    COALESCE(o.total_qty_declared, 0)::numeric
      - COALESCE(lc.progressed_physical_qty, 0)::numeric
      - COALESCE(lc.exception_qty, 0)::numeric,
    0::numeric
  ) AS remaining_baseline_qty,
  GREATEST(
    COALESCE(o.order_total_gbp_declared, 0)::numeric
      - COALESCE(lc.progressed_physical_value_gbp, 0)::numeric
      - COALESCE(lc.exception_value_gbp, 0)::numeric
      - COALESCE(lc.non_physical_value_gbp, 0)::numeric,
    0::numeric
  ) AS remaining_baseline_value_gbp,
  (
    COALESCE(ic.active_invoice_count, 0) > 0
    AND COALESCE(lc.unresolved_line_count, 0) = 0
  ) AS all_documents_resolved_yn,
  (
    COALESCE(ic.active_invoice_count, 0) > 0
    AND COALESCE(lc.unresolved_line_count, 0) = 0
    AND COALESCE(lc.progressed_physical_qty, 0)
        + COALESCE(lc.exception_qty, 0)
        >= COALESCE(o.total_qty_declared, 0)
    AND COALESCE(lc.progressed_physical_value_gbp, 0)
        + COALESCE(lc.exception_value_gbp, 0)
        + COALESCE(lc.non_physical_value_gbp, 0)
        >= COALESCE(o.order_total_gbp_declared, 0) - 0.01
  ) AS baseline_accounted_for_yn
FROM public.orders o
LEFT JOIN invoice_counts ic ON ic.order_id = o.id
LEFT JOIN line_counts lc ON lc.order_id = o.id;

COMMENT ON VIEW public.order_supplier_invoice_bundle_summary_v1 IS
'Order-wide read model summarising all live supplier invoice reference families without merging their legal or accounting identities.';

REVOKE ALL ON public.order_supplier_invoice_bundle_lines_v1 FROM PUBLIC;
REVOKE ALL ON public.order_supplier_invoice_bundle_summary_v1 FROM PUBLIC;
GRANT SELECT ON public.order_supplier_invoice_bundle_lines_v1 TO authenticated, service_role;
GRANT SELECT ON public.order_supplier_invoice_bundle_summary_v1 TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
