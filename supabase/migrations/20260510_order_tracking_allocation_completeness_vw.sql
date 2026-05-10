-- =============================================================================
-- 20260510_order_tracking_allocation_completeness_vw.sql
-- Multi Tenant Platform Build — delivery allocation equality/readiness control
--
-- Governing source:
--   docs/governing-pack/backend/Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md
--
-- Purpose:
--   Add a read/control view proving that item-to-package allocations reconcile
--   back to the original progressed supplier invoice line quantity before later
--   shipper shipment, draft COS, export evidence and Sage readiness gates.
--
-- Rule:
--   For each progressed supplier invoice line:
--     sum(qty_allocated across tracking refs/packages)
--     must equal
--     progressed/original line quantity
--   before downstream lock/readiness, unless supervisor has explicitly accepted
--   an uncertainty/estimate route.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_tracking_line_allocations';
  END IF;
END $$;

CREATE OR REPLACE VIEW public.order_tracking_allocation_completeness_vw AS
WITH line_base AS (
  SELECT
    si.order_id,
    sil.supplier_invoice_id,
    sil.id AS supplier_invoice_line_id,
    COALESCE(sil.line_order, 0)::integer AS line_order,
    COALESCE(sil.description, '')::text AS description,
    COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric(12,3) AS original_progressed_qty,
    COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)::numeric(12,2) AS original_line_value_gbp,
    COALESCE(sil.eligible_for_invoice_yn, 'N')::text AS eligible_for_invoice_yn
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
), allocation_summary AS (
  SELECT
    otla.supplier_invoice_line_id,
    COALESCE(SUM(otla.qty_allocated), 0)::numeric(12,3) AS allocated_qty,
    COALESCE(SUM(otla.adjusted_net_value_gbp), 0)::numeric(12,2) AS allocated_adjusted_net_value_gbp,
    COALESCE(BOOL_OR(otla.allocation_status IN ('unknown_contents','needs_operator_evidence')), false) AS has_uncertain_allocation,
    COALESCE(BOOL_OR(otla.allocation_status = 'supervisor_accepted_estimate'), false) AS has_supervisor_accepted_estimate,
    COUNT(*) FILTER (WHERE otla.locked_for_export_pack_at IS NOT NULL)::integer AS locked_export_allocation_count,
    COUNT(*)::integer AS allocation_row_count
  FROM public.order_tracking_line_allocations otla
  GROUP BY otla.supplier_invoice_line_id
)
SELECT
  lb.order_id,
  lb.supplier_invoice_id,
  lb.supplier_invoice_line_id,
  lb.line_order,
  lb.description,
  lb.original_progressed_qty,
  COALESCE(a.allocated_qty, 0)::numeric(12,3) AS allocated_qty,
  GREATEST(lb.original_progressed_qty - COALESCE(a.allocated_qty, 0), 0)::numeric(12,3) AS remaining_qty,
  lb.original_line_value_gbp,
  COALESCE(a.allocated_adjusted_net_value_gbp, 0)::numeric(12,2) AS allocated_adjusted_net_value_gbp,
  lb.eligible_for_invoice_yn,
  (LOWER(lb.eligible_for_invoice_yn) IN ('y','yes','true','1'))::boolean AS is_progressed,
  (COALESCE(a.allocated_qty, 0) > lb.original_progressed_qty + 0.0001)::boolean AS is_over_allocated,
  (ABS(COALESCE(a.allocated_qty, 0) - lb.original_progressed_qty) <= 0.0001 AND lb.original_progressed_qty > 0)::boolean AS is_qty_complete,
  COALESCE(a.has_uncertain_allocation, false)::boolean AS has_uncertain_allocation,
  COALESCE(a.has_supervisor_accepted_estimate, false)::boolean AS has_supervisor_accepted_estimate,
  COALESCE(a.locked_export_allocation_count, 0)::integer AS locked_export_allocation_count,
  COALESCE(a.allocation_row_count, 0)::integer AS allocation_row_count,
  CASE
    WHEN LOWER(lb.eligible_for_invoice_yn) NOT IN ('y','yes','true','1') THEN 'not_progressed'
    WHEN COALESCE(a.allocated_qty, 0) > lb.original_progressed_qty + 0.0001 THEN 'over_allocated_blocked'
    WHEN COALESCE(a.allocated_qty, 0) = 0 THEN 'not_allocated'
    WHEN COALESCE(a.allocated_qty, 0) < lb.original_progressed_qty - 0.0001 THEN 'partially_allocated_open'
    WHEN COALESCE(a.has_uncertain_allocation, false) THEN 'complete_but_uncertain_blocked'
    WHEN COALESCE(a.has_supervisor_accepted_estimate, false) THEN 'complete_supervisor_estimate'
    ELSE 'complete_ready'
  END::text AS allocation_readiness_status
FROM line_base lb
LEFT JOIN allocation_summary a ON a.supplier_invoice_line_id = lb.supplier_invoice_line_id;

COMMENT ON VIEW public.order_tracking_allocation_completeness_vw IS
'Control view showing whether package allocations reconcile to original progressed supplier invoice line quantities before shipment/COS/export/Sage readiness.';

GRANT SELECT ON public.order_tracking_allocation_completeness_vw TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
