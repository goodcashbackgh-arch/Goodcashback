BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Platform-wide canonical importer projection.
--
-- Importer-facing status follows actual importer-owned work across every active
-- order. Internal supplier review remains visible to staff, but it is not
-- presented as an importer evidence defect unless current replacement evidence
-- is genuinely required. Open evidence queries remain a separate importer action
-- lane and outrank reconciliation/tracking progression.
--
-- Read-model only. No order, invoice, line, query, tracking, allocation,
-- shipment, funding, settlement, Sage, VAT, customer or shipper data is mutated.

DO $$
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid) prerequisite';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_supplier_rejection_final_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_pre_supplier_rejection_final_v1(uuid) prerequisite';
  END IF;

  IF to_regclass('public.order_evidence_queries') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_evidence_queries prerequisite';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.order_audience_status_v1(
  p_order_id uuid DEFAULT NULL
)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  raw_order_status text,
  lifecycle_status text,
  importer_id uuid,
  importer_name text,
  retailer_id uuid,
  retailer_name text,
  accepted_estimate_gbp numeric,
  final_sale_value_gbp numeric,
  canonical_amount_received_gbp numeric,
  canonical_balance_due_gbp numeric,
  potential_credit_pending_review_gbp numeric,
  internal_current_stage text,
  internal_current_stage_label text,
  internal_next_owner text,
  internal_next_action text,
  internal_next_href text,
  internal_status_tone text,
  gate_complete_count integer,
  gate_total integer,
  funding_state text,
  dva_state text,
  supplier_state text,
  reconciliation_state text,
  tracking_state text,
  shipment_state text,
  export_evidence_state text,
  pod_delivery_state text,
  customer_sales_state text,
  shipper_ap_state text,
  accounting_sage_state text,
  vat_compliance_state text,
  internal_complete_yn boolean,
  customer_complete_yn boolean,
  importer_complete_yn boolean,
  shipper_complete_yn boolean,
  customer_status_label text,
  customer_next_action text,
  importer_status_label text,
  importer_next_action text,
  shipper_status_label text,
  shipper_next_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: order audience status requires auth.uid()';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT *
    FROM public.order_audience_status_pre_supplier_rejection_final_v1(p_order_id)
  ), rejection_scope AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND si.review_status = 'rejected_resubmit_required'
          AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
      )::integer AS genuine_resubmission_required_count
    FROM public.supplier_invoices si
    JOIN base b ON b.order_id = si.order_id
    GROUP BY si.order_id
  ), query_scope AS (
    SELECT
      q.order_id,
      COUNT(*) FILTER (WHERE q.status = 'open')::integer AS open_query_count
    FROM public.order_evidence_queries q
    JOIN base b ON b.order_id = q.order_id
    GROUP BY q.order_id
  ), projected AS (
    SELECT
      b.*,
      COALESCE(rs.genuine_resubmission_required_count, 0) AS genuine_resubmission_required_count,
      COALESCE(qs.open_query_count, 0) AS open_query_count,
      CASE
        WHEN COALESCE(b.canonical_balance_due_gbp, 0) > 0.01
          THEN b.importer_status_label
        WHEN COALESCE(b.internal_current_stage, '') = 'exception_or_hold_open'
          THEN b.importer_status_label
        WHEN COALESCE(rs.genuine_resubmission_required_count, 0) > 0
          THEN b.importer_status_label
        WHEN COALESCE(qs.open_query_count, 0) > 0
          THEN 'Evidence query open'
        WHEN b.reconciliation_state = 'incomplete'
          THEN 'Invoice reconciliation open'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'missing'
          THEN 'Invoice reconciled; tracking open'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'allocation_incomplete'
          THEN 'Tracking submitted'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'submitted'
          AND b.pod_delivery_state = 'accepted_current'
          THEN 'Order complete'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'submitted'
          THEN 'No importer action required'
        ELSE b.importer_status_label
      END::text AS projected_importer_status_label,
      CASE
        WHEN COALESCE(b.canonical_balance_due_gbp, 0) > 0.01
          THEN b.importer_next_action
        WHEN COALESCE(b.internal_current_stage, '') = 'exception_or_hold_open'
          THEN b.importer_next_action
        WHEN COALESCE(rs.genuine_resubmission_required_count, 0) > 0
          THEN b.importer_next_action
        WHEN COALESCE(qs.open_query_count, 0) > 0
          THEN 'Answer query'
        WHEN b.reconciliation_state = 'incomplete'
          THEN 'Continue invoice reconciliation'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'missing'
          THEN 'Add tracking'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'allocation_incomplete'
          THEN 'Assign tracking'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'submitted'
          AND b.pod_delivery_state = 'accepted_current'
          THEN 'Order complete'
        WHEN b.reconciliation_state = 'complete'
          AND b.tracking_state = 'submitted'
          THEN 'No importer action required'
        ELSE b.importer_next_action
      END::text AS projected_importer_next_action
    FROM base b
    LEFT JOIN rejection_scope rs ON rs.order_id = b.order_id
    LEFT JOIN query_scope qs ON qs.order_id = b.order_id
  )
  SELECT
    p.order_id,
    p.order_ref,
    p.raw_order_status,
    p.lifecycle_status,
    p.importer_id,
    p.importer_name,
    p.retailer_id,
    p.retailer_name,
    p.accepted_estimate_gbp,
    p.final_sale_value_gbp,
    p.canonical_amount_received_gbp,
    p.canonical_balance_due_gbp,
    p.potential_credit_pending_review_gbp,
    p.internal_current_stage,
    p.internal_current_stage_label,
    p.internal_next_owner,
    p.internal_next_action,
    p.internal_next_href,
    p.internal_status_tone,
    p.gate_complete_count,
    p.gate_total,
    p.funding_state,
    p.dva_state,
    p.supplier_state,
    p.reconciliation_state,
    p.tracking_state,
    p.shipment_state,
    p.export_evidence_state,
    p.pod_delivery_state,
    p.customer_sales_state,
    p.shipper_ap_state,
    p.accounting_sage_state,
    p.vat_compliance_state,
    p.internal_complete_yn,
    p.customer_complete_yn,
    p.projected_importer_next_action IN ('No importer action required', 'Order complete') AS importer_complete_yn,
    p.shipper_complete_yn,
    p.customer_status_label,
    p.customer_next_action,
    p.projected_importer_status_label,
    p.projected_importer_next_action,
    p.shipper_status_label,
    p.shipper_next_action
  FROM projected p
  ORDER BY p.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'Platform-wide canonical audience status. Importer action precedence covers balances, exceptions/holds, genuine replacement evidence, open evidence queries, active reconciliation and tracking allocation. Importer completion is derived from the projected importer action. Customer and shipper projections pass through unchanged.';

NOTIFY pgrst, 'reload schema';

COMMIT;
