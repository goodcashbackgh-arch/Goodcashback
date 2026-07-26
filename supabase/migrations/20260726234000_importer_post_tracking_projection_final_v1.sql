BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Platform-wide supplier and importer status correction.
--
-- 1. Corrects active supplier state so a genuine current replacement-evidence
--    rejection outranks approved or review invoices, and approval is returned
--    only when every active invoice is explicitly approved.
-- 2. Projects actual importer-owned work across every active order, including
--    open evidence queries and tracking allocation.
--
-- Read-model only. No order, invoice, line, query, tracking, allocation,
-- shipment, funding, settlement, Sage, VAT, customer or shipper data is mutated.

DO $$
BEGIN
  IF to_regprocedure('public.internal_platform_order_status_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_platform_order_status_v1() prerequisite';
  END IF;

  IF to_regprocedure('public.internal_platform_order_status_pre_supplier_rejection_final_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_platform_order_status_pre_supplier_rejection_final_v1() prerequisite';
  END IF;

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

CREATE OR REPLACE FUNCTION public.internal_platform_order_status_v1()
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  raw_order_status text,
  lifecycle_status text,
  order_type text,
  importer_id uuid,
  importer_name text,
  retailer_id uuid,
  retailer_name text,
  created_at timestamptz,
  accepted_estimate_gbp numeric,
  amount_received_gbp numeric,
  signed_final_sale_value_gbp numeric,
  final_balance_due_gbp numeric,
  potential_credit_pending_review_gbp numeric,
  funding_state text,
  supplier_state text,
  reconciliation_state text,
  exception_state text,
  hold_state text,
  tracking_state text,
  shipment_state text,
  export_evidence_state text,
  pod_delivery_state text,
  customer_sales_state text,
  shipper_ap_state text,
  current_stage text,
  current_stage_label text,
  next_owner text,
  next_action text,
  next_href text,
  status_tone text,
  status_priority integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: platform order status requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for platform order status.';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT *
    FROM public.internal_platform_order_status_pre_supplier_rejection_final_v1()
  ), active_invoice_counts AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
          AND NOT (
            si.review_status = 'rejected_resubmit_required'
            AND si.rejection_requires_resubmission_yn = false
          )
      )::integer AS active_invoice_count,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
          AND NOT (
            si.review_status = 'rejected_resubmit_required'
            AND si.rejection_requires_resubmission_yn = false
          )
          AND si.review_status IN ('approved_current', 'ref_corrected_approved')
          AND COALESCE(si.blocked_from_sage_yn, false) = false
      )::integer AS approved_invoice_count,
      COUNT(*) FILTER (
        WHERE COALESCE(si.is_current_for_order, true) = true
          AND si.review_status = 'rejected_resubmit_required'
          AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
      )::integer AS genuine_rejected_count
    FROM public.supplier_invoices si
    GROUP BY si.order_id
  ), active_line_counts AS (
    SELECT
      si.order_id,
      COUNT(sil.id)::integer AS active_line_count,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y', 'yes', 'true', '1')
          AND NOT EXISTS (
            SELECT 1
            FROM public.supplier_invoice_line_resolutions r
            WHERE r.supplier_invoice_line_id = sil.id
              AND r.supplier_invoice_id = si.id
              AND r.resolution_type = 'non_physical_financial'
              AND r.active = true
          )
          AND NOT EXISTS (
            SELECT 1
            FROM public.dispute_lines dl
            JOIN public.disputes d ON d.id = dl.dispute_id
            WHERE dl.supplier_invoice_line_id = sil.id
              AND dl.resolved_at IS NULL
              AND d.resolved_at IS NULL
          )
      )::integer AS unresolved_active_line_count
    FROM public.supplier_invoices si
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    WHERE COALESCE(si.is_current_for_order, true) = true
      AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
      AND NOT (
        si.review_status = 'rejected_resubmit_required'
        AND si.rejection_requires_resubmission_yn = false
      )
    GROUP BY si.order_id
  ), corrected AS (
    SELECT
      b.*,
      CASE
        WHEN COALESCE(aic.active_invoice_count, 0) = 0 THEN 'missing'
        WHEN COALESCE(aic.genuine_rejected_count, 0) > 0 THEN 'rejected_resubmit_required'
        WHEN COALESCE(aic.approved_invoice_count, 0) = COALESCE(aic.active_invoice_count, 0) THEN 'approved_current'
        ELSE 'review_needed'
      END::text AS corrected_supplier_state,
      CASE
        WHEN COALESCE(alc.active_line_count, 0) = 0 THEN 'not_started'
        WHEN COALESCE(alc.unresolved_active_line_count, 0) = 0 THEN 'complete'
        ELSE 'incomplete'
      END::text AS corrected_reconciliation_state
    FROM base b
    LEFT JOIN active_invoice_counts aic ON aic.order_id = b.order_id
    LEFT JOIN active_line_counts alc ON alc.order_id = b.order_id
  ), staged AS (
    SELECT
      c.*,
      CASE
        WHEN c.current_stage IN (
          'supplier_evidence_rejected',
          'supplier_evidence_review_needed',
          'supplier_reconciliation_incomplete'
        ) THEN
          CASE
            WHEN c.corrected_supplier_state = 'rejected_resubmit_required' THEN 'supplier_evidence_rejected'
            WHEN c.corrected_supplier_state = 'review_needed' THEN 'supplier_evidence_review_needed'
            WHEN c.corrected_reconciliation_state = 'incomplete' THEN 'supplier_reconciliation_incomplete'
            WHEN c.corrected_reconciliation_state = 'complete' AND c.tracking_state = 'missing' THEN 'tracking_missing'
            WHEN c.corrected_reconciliation_state = 'complete' AND c.tracking_state = 'allocation_incomplete' THEN 'tracking_allocation_incomplete'
            ELSE c.current_stage
          END
        ELSE c.current_stage
      END::text AS corrected_current_stage
    FROM corrected c
  )
  SELECT
    s.order_id,
    s.order_ref,
    s.raw_order_status,
    s.lifecycle_status,
    s.order_type,
    s.importer_id,
    s.importer_name,
    s.retailer_id,
    s.retailer_name,
    s.created_at,
    s.accepted_estimate_gbp,
    s.amount_received_gbp,
    s.signed_final_sale_value_gbp,
    s.final_balance_due_gbp,
    s.potential_credit_pending_review_gbp,
    s.funding_state,
    s.corrected_supplier_state,
    s.corrected_reconciliation_state,
    s.exception_state,
    s.hold_state,
    s.tracking_state,
    s.shipment_state,
    s.export_evidence_state,
    s.pod_delivery_state,
    s.customer_sales_state,
    s.shipper_ap_state,
    s.corrected_current_stage,
    CASE s.corrected_current_stage
      WHEN 'supplier_evidence_rejected' THEN 'Supplier evidence rejected'
      WHEN 'supplier_evidence_review_needed' THEN 'Supplier evidence review needed'
      WHEN 'supplier_reconciliation_incomplete' THEN 'Supplier reconciliation incomplete'
      WHEN 'tracking_missing' THEN 'Tracking missing'
      WHEN 'tracking_allocation_incomplete' THEN 'Tracking/package allocation incomplete'
      ELSE s.current_stage_label
    END::text,
    CASE s.corrected_current_stage
      WHEN 'supplier_evidence_rejected' THEN 'Operator'
      WHEN 'supplier_evidence_review_needed' THEN 'Supervisor'
      WHEN 'supplier_reconciliation_incomplete' THEN 'Operator'
      WHEN 'tracking_missing' THEN 'Operator'
      WHEN 'tracking_allocation_incomplete' THEN 'Operator/Supervisor'
      ELSE s.next_owner
    END::text,
    CASE s.corrected_current_stage
      WHEN 'supplier_evidence_rejected' THEN 'Upload corrected supplier evidence'
      WHEN 'supplier_evidence_review_needed' THEN 'Review supplier evidence'
      WHEN 'supplier_reconciliation_incomplete' THEN 'Complete supplier line reconciliation'
      WHEN 'tracking_missing' THEN 'Submit tracking'
      WHEN 'tracking_allocation_incomplete' THEN 'Allocate all active tracking refs and physical lines to shipment'
      ELSE s.next_action
    END::text,
    CASE s.corrected_current_stage
      WHEN 'supplier_evidence_rejected' THEN '/internal/invoice-review'
      WHEN 'supplier_evidence_review_needed' THEN '/internal/invoice-review'
      WHEN 'supplier_reconciliation_incomplete' THEN '/internal/invoice-review'
      WHEN 'tracking_missing' THEN '/internal/shipping-control'
      WHEN 'tracking_allocation_incomplete' THEN '/internal/shipping-control'
      ELSE s.next_href
    END::text,
    CASE
      WHEN s.corrected_current_stage = 'supplier_evidence_rejected' THEN 'blocked'
      WHEN s.corrected_current_stage IN ('supplier_reconciliation_incomplete', 'tracking_missing', 'tracking_allocation_incomplete') THEN 'action'
      WHEN s.corrected_current_stage = 'supplier_evidence_review_needed' THEN 'review'
      ELSE s.status_tone
    END::text,
    CASE s.corrected_current_stage
      WHEN 'supplier_evidence_rejected' THEN 31
      WHEN 'supplier_evidence_review_needed' THEN 32
      WHEN 'supplier_reconciliation_incomplete' THEN 40
      WHEN 'tracking_missing' THEN 50
      WHEN 'tracking_allocation_incomplete' THEN 55
      ELSE s.status_priority
    END::integer
  FROM staged s
  ORDER BY 33 ASC, s.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_platform_order_status_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_platform_order_status_v1() TO authenticated;

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
        WHEN COALESCE(b.canonical_balance_due_gbp, 0) > 0.01 THEN b.importer_status_label
        WHEN COALESCE(b.internal_current_stage, '') = 'exception_or_hold_open' THEN b.importer_status_label
        WHEN COALESCE(rs.genuine_resubmission_required_count, 0) > 0 THEN 'Evidence attention'
        WHEN COALESCE(qs.open_query_count, 0) > 0 THEN 'Evidence query open'
        WHEN b.reconciliation_state = 'incomplete' THEN 'Invoice reconciliation open'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'missing' THEN 'Invoice reconciled; tracking open'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'allocation_incomplete' THEN 'Tracking submitted'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'submitted' AND b.pod_delivery_state = 'accepted_current' THEN 'Order complete'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'submitted' THEN 'No importer action required'
        ELSE b.importer_status_label
      END::text AS projected_importer_status_label,
      CASE
        WHEN COALESCE(b.canonical_balance_due_gbp, 0) > 0.01 THEN b.importer_next_action
        WHEN COALESCE(b.internal_current_stage, '') = 'exception_or_hold_open' THEN b.importer_next_action
        WHEN COALESCE(rs.genuine_resubmission_required_count, 0) > 0 THEN 'Resolve evidence issue'
        WHEN COALESCE(qs.open_query_count, 0) > 0 THEN 'Answer query'
        WHEN b.reconciliation_state = 'incomplete' THEN 'Continue invoice reconciliation'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'missing' THEN 'Add tracking'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'allocation_incomplete' THEN 'Assign tracking'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'submitted' AND b.pod_delivery_state = 'accepted_current' THEN 'Order complete'
        WHEN b.reconciliation_state = 'complete' AND b.tracking_state = 'submitted' THEN 'No importer action required'
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
    COALESCE(p.projected_importer_next_action IN ('No importer action required', 'Order complete'), false) AS importer_complete_yn,
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

COMMENT ON FUNCTION public.internal_platform_order_status_v1() IS
'Canonical platform status using active supplier invoices and active-line reconciliation. Genuine current replacement-evidence rejection outranks approval; approval requires every active invoice to be explicitly approved.';

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'Platform-wide canonical audience status. Importer action precedence covers balances, exceptions/holds, genuine replacement evidence, open evidence queries, active reconciliation and tracking allocation. Importer completion is derived from the projected importer action. Customer and shipper projections pass through unchanged.';

NOTIFY pgrst, 'reload schema';

COMMIT;
