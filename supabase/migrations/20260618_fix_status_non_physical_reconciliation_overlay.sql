BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Read-model-only corrective overlay.
-- Problem: the live pre-shipper-AP base status function still counts every
-- eligible_for_invoice_yn <> 'Y' supplier line as open. That wrongly leaves
-- orders stuck at supplier_reconciliation_incomplete after delivery/discount/fee
-- lines have been explicitly parked in supplier_invoice_line_resolutions.
--
-- This wrapper keeps the existing base function and shipper-AP completion
-- blocker, but recalculates the supplier-line reconciliation blocker using the
-- locked contract:
--   Y = progressed physical line
--   N + active non_physical_financial resolution = parked non-physical line
--   N + active dispute link = exception-linked line
--   N + neither = open unresolved line
--
-- It only advances rows where the base status is supplier_reconciliation_incomplete
-- but the corrected open-line count is zero. No order data, Sage data, shipment
-- data, VAT data, or payment data is changed.

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
    FROM public.internal_platform_order_status_v1_before_shipper_ap_blocker()
  ), corrected_supplier_lines AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y','yes','true','1')
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
      )::integer AS corrected_open_supplier_lines
    FROM public.supplier_invoices si
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    WHERE COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required', 'duplicate_blocked', 'superseded')
      AND COALESCE(si.is_current_for_order, true) = true
    GROUP BY si.order_id
  ), corrected AS (
    SELECT
      b.*,
      COALESCE(csl.corrected_open_supplier_lines, 0) AS corrected_open_supplier_lines,
      CASE
        WHEN b.current_stage = 'supplier_reconciliation_incomplete'
          AND COALESCE(csl.corrected_open_supplier_lines, 0) = 0
        THEN 'complete'
        ELSE b.reconciliation_state
      END::text AS corrected_reconciliation_state,
      CASE
        WHEN b.current_stage = 'supplier_reconciliation_incomplete'
          AND COALESCE(csl.corrected_open_supplier_lines, 0) = 0
        THEN
          CASE
            WHEN b.tracking_state = 'missing' THEN 'tracking_missing'
            WHEN b.shipment_state = 'missing' THEN 'shipment_batch_missing'
            WHEN b.shipment_state = 'allocation_incomplete' THEN 'shipment_allocation_incomplete'
            WHEN b.shipment_state = 'receipt_issue' THEN 'shipment_receipt_issue'
            WHEN b.export_evidence_state = 'submitted_for_review' THEN 'export_evidence_review_needed'
            WHEN b.export_evidence_state = 'missing' THEN 'export_evidence_missing'
            WHEN b.customer_sales_state = 'not_posted' THEN 'customer_sale_not_posted'
            WHEN COALESCE(b.final_balance_due_gbp, 0) > 0.01 THEN 'final_balance_due'
            WHEN b.pod_delivery_state = 'submitted_for_review' THEN 'pod_delivery_review_needed'
            WHEN b.pod_delivery_state = 'missing' THEN 'awaiting_delivery_confirmation'
            ELSE 'complete'
          END
        ELSE b.current_stage
      END::text AS corrected_current_stage
    FROM base b
    LEFT JOIN corrected_supplier_lines csl ON csl.order_id = b.order_id
  ), adjusted AS (
    SELECT
      c.*,
      CASE
        WHEN c.corrected_current_stage = 'complete'
          AND COALESCE(c.shipper_ap_state, '') <> 'apportionment_approved'
        THEN 'shipper_ap_not_ready'
        ELSE c.corrected_current_stage
      END AS adjusted_current_stage
    FROM corrected c
  ), labelled AS (
    SELECT
      a.*,
      CASE a.adjusted_current_stage
        WHEN 'exception_or_hold_open' THEN 'Exception or customer hold open'
        WHEN 'funding_incomplete' THEN 'Initial payment incomplete'
        WHEN 'supplier_evidence_missing' THEN 'Supplier evidence missing'
        WHEN 'supplier_evidence_rejected' THEN 'Supplier evidence rejected'
        WHEN 'supplier_evidence_review_needed' THEN 'Supplier evidence review needed'
        WHEN 'supplier_reconciliation_incomplete' THEN 'Supplier reconciliation incomplete'
        WHEN 'tracking_missing' THEN 'Tracking missing'
        WHEN 'shipment_batch_missing' THEN 'Shipment batch missing'
        WHEN 'shipment_allocation_incomplete' THEN 'Shipment allocation incomplete'
        WHEN 'shipment_receipt_issue' THEN 'Shipment receipt issue'
        WHEN 'export_evidence_review_needed' THEN 'Export evidence review needed'
        WHEN 'export_evidence_missing' THEN 'Export evidence missing'
        WHEN 'customer_sale_not_posted' THEN 'Customer sale not posted'
        WHEN 'final_balance_due' THEN 'Final balance due'
        WHEN 'shipper_ap_not_ready' THEN 'Shipper AP not ready'
        WHEN 'pod_delivery_review_needed' THEN 'Delivery/POD review needed'
        WHEN 'awaiting_delivery_confirmation' THEN 'Awaiting delivery confirmation'
        ELSE 'Complete'
      END::text AS adjusted_current_stage_label,
      CASE a.adjusted_current_stage
        WHEN 'exception_or_hold_open' THEN 'Supervisor'
        WHEN 'funding_incomplete' THEN 'Supervisor'
        WHEN 'supplier_evidence_missing' THEN 'Operator'
        WHEN 'supplier_evidence_rejected' THEN 'Operator'
        WHEN 'supplier_evidence_review_needed' THEN 'Supervisor'
        WHEN 'supplier_reconciliation_incomplete' THEN 'Operator'
        WHEN 'tracking_missing' THEN 'Operator'
        WHEN 'shipment_batch_missing' THEN 'Supervisor/Shipper'
        WHEN 'shipment_allocation_incomplete' THEN 'Supervisor/Shipper'
        WHEN 'shipment_receipt_issue' THEN 'Supervisor/Shipper'
        WHEN 'export_evidence_review_needed' THEN 'Supervisor'
        WHEN 'export_evidence_missing' THEN 'Shipper'
        WHEN 'customer_sale_not_posted' THEN 'Supervisor'
        WHEN 'final_balance_due' THEN 'Customer/Operator'
        WHEN 'shipper_ap_not_ready' THEN 'Supervisor/Shipper'
        WHEN 'pod_delivery_review_needed' THEN 'Supervisor'
        WHEN 'awaiting_delivery_confirmation' THEN 'Shipper/Customer'
        ELSE 'None'
      END::text AS adjusted_next_owner,
      CASE a.adjusted_current_stage
        WHEN 'exception_or_hold_open' THEN 'Resolve exception or customer hold'
        WHEN 'funding_incomplete' THEN 'Match/apply initial funding'
        WHEN 'supplier_evidence_missing' THEN 'Upload supplier invoice/evidence'
        WHEN 'supplier_evidence_rejected' THEN 'Upload corrected supplier evidence'
        WHEN 'supplier_evidence_review_needed' THEN 'Review supplier evidence'
        WHEN 'supplier_reconciliation_incomplete' THEN 'Complete supplier line reconciliation'
        WHEN 'tracking_missing' THEN 'Submit tracking'
        WHEN 'shipment_batch_missing' THEN 'Create or allocate shipment batch'
        WHEN 'shipment_allocation_incomplete' THEN 'Allocate packages/contents to shipment'
        WHEN 'shipment_receipt_issue' THEN 'Resolve shipper receipt issue'
        WHEN 'export_evidence_review_needed' THEN 'Review submitted export evidence'
        WHEN 'export_evidence_missing' THEN 'Upload final export evidence'
        WHEN 'customer_sale_not_posted' THEN 'Create/post customer sale document'
        WHEN 'final_balance_due' THEN 'Collect final balance'
        WHEN 'shipper_ap_not_ready' THEN 'Complete shipper AP/apportionment'
        WHEN 'pod_delivery_review_needed' THEN 'Review submitted delivery/POD evidence'
        WHEN 'awaiting_delivery_confirmation' THEN 'Upload or accept delivery/POD evidence'
        ELSE 'No action required'
      END::text AS adjusted_next_action,
      CASE a.adjusted_current_stage
        WHEN 'exception_or_hold_open' THEN '/internal/exceptions'
        WHEN 'funding_incomplete' THEN '/internal/funding'
        WHEN 'supplier_evidence_missing' THEN '/internal/invoice-review'
        WHEN 'supplier_evidence_rejected' THEN '/internal/invoice-review'
        WHEN 'supplier_evidence_review_needed' THEN '/internal/invoice-review'
        WHEN 'supplier_reconciliation_incomplete' THEN '/internal/invoice-review'
        WHEN 'tracking_missing' THEN '/internal/shipping-control'
        WHEN 'shipment_batch_missing' THEN '/internal/shipping-control'
        WHEN 'shipment_allocation_incomplete' THEN '/internal/shipping-control'
        WHEN 'shipment_receipt_issue' THEN '/internal/shipping-control'
        WHEN 'export_evidence_review_needed' THEN '/internal/shipping-control'
        WHEN 'export_evidence_missing' THEN '/internal/shipping-control'
        WHEN 'customer_sale_not_posted' THEN '/internal/shipping-control/customer-invoice-release'
        WHEN 'final_balance_due' THEN '/internal/dva-reconciliation/workspace'
        WHEN 'shipper_ap_not_ready' THEN '/internal/shipping-control/shipper-documents'
        WHEN 'pod_delivery_review_needed' THEN '/internal/shipping-control'
        WHEN 'awaiting_delivery_confirmation' THEN '/internal/shipping-control'
        ELSE '/internal/supervisor-command-centre'
      END::text AS adjusted_next_href,
      CASE
        WHEN a.adjusted_current_stage IN ('complete') THEN 'complete'
        WHEN a.adjusted_current_stage IN ('exception_or_hold_open', 'supplier_evidence_rejected', 'shipment_receipt_issue') THEN 'blocked'
        WHEN a.adjusted_current_stage IN ('funding_incomplete', 'supplier_evidence_missing', 'supplier_reconciliation_incomplete', 'tracking_missing', 'shipment_batch_missing', 'shipment_allocation_incomplete', 'export_evidence_missing', 'customer_sale_not_posted', 'final_balance_due', 'shipper_ap_not_ready', 'awaiting_delivery_confirmation') THEN 'action'
        WHEN a.adjusted_current_stage IN ('supplier_evidence_review_needed', 'export_evidence_review_needed', 'pod_delivery_review_needed') THEN 'review'
        ELSE 'progress'
      END::text AS adjusted_status_tone,
      CASE a.adjusted_current_stage
        WHEN 'exception_or_hold_open' THEN 10
        WHEN 'funding_incomplete' THEN 20
        WHEN 'supplier_evidence_missing' THEN 30
        WHEN 'supplier_evidence_rejected' THEN 31
        WHEN 'supplier_evidence_review_needed' THEN 32
        WHEN 'supplier_reconciliation_incomplete' THEN 40
        WHEN 'tracking_missing' THEN 50
        WHEN 'shipment_batch_missing' THEN 60
        WHEN 'shipment_allocation_incomplete' THEN 61
        WHEN 'shipment_receipt_issue' THEN 62
        WHEN 'export_evidence_review_needed' THEN 70
        WHEN 'export_evidence_missing' THEN 71
        WHEN 'customer_sale_not_posted' THEN 80
        WHEN 'final_balance_due' THEN 90
        WHEN 'shipper_ap_not_ready' THEN 95
        WHEN 'pod_delivery_review_needed' THEN 100
        WHEN 'awaiting_delivery_confirmation' THEN 101
        ELSE 999
      END::integer AS adjusted_status_priority
    FROM adjusted a
  )
  SELECT
    l.order_id,
    l.order_ref,
    l.raw_order_status,
    l.lifecycle_status,
    l.order_type,
    l.importer_id,
    l.importer_name,
    l.retailer_id,
    l.retailer_name,
    l.created_at,
    l.accepted_estimate_gbp,
    l.amount_received_gbp,
    l.signed_final_sale_value_gbp,
    l.final_balance_due_gbp,
    l.potential_credit_pending_review_gbp,
    l.funding_state,
    l.supplier_state,
    l.corrected_reconciliation_state,
    l.exception_state,
    l.hold_state,
    l.tracking_state,
    l.shipment_state,
    l.export_evidence_state,
    l.pod_delivery_state,
    l.customer_sales_state,
    l.shipper_ap_state,
    l.adjusted_current_stage,
    l.adjusted_current_stage_label,
    l.adjusted_next_owner,
    l.adjusted_next_action,
    l.adjusted_next_href,
    l.adjusted_status_tone,
    l.adjusted_status_priority
  FROM labelled l
  ORDER BY l.adjusted_status_priority ASC, l.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_platform_order_status_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_platform_order_status_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
