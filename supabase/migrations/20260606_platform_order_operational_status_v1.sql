BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Canonical read model for cross-platform order status.
-- This is intentionally read-only and additive. It does not update orders, funding,
-- Sage, shipment, VAT or credit-ledger state.

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
  WITH order_scope AS (
    SELECT
      o.id,
      o.order_ref::text,
      o.status::text AS raw_order_status,
      o.order_type::text,
      o.importer_id,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
      o.retailer_id,
      r.name::text AS retailer_name,
      o.created_at,
      COALESCE(o.order_total_gbp_declared, 0)::numeric AS accepted_estimate_gbp,
      o.funded_at
    FROM public.orders o
    LEFT JOIN public.importers i ON i.id = o.importer_id
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    WHERE COALESCE(o.order_type, 'original') = 'original'
      AND COALESCE(o.status, '') <> 'archived'
  ), funding AS (
    SELECT
      f.order_id,
      COALESCE(f.threshold_met_yn, false) AS threshold_met_yn,
      COALESCE(f.funded_total_gbp, COALESCE(f.confirmed_dva_funding_gbp, 0) + COALESCE(f.applied_credit_gbp, 0), 0)::numeric AS amount_received_gbp,
      COALESCE(f.gap_remaining_gbp, 0)::numeric AS funding_gap_gbp
    FROM public.order_funding_position_vw f
  ), supplier AS (
    SELECT
      si.order_id,
      COUNT(*)::integer AS supplier_invoice_count,
      COUNT(*) FILTER (WHERE si.review_status IN ('approved_current', 'ref_corrected_approved') AND COALESCE(si.blocked_from_sage_yn, false) = false)::integer AS approved_invoice_count,
      COUNT(*) FILTER (WHERE si.review_status = 'rejected_resubmit_required')::integer AS rejected_invoice_count,
      COUNT(*) FILTER (WHERE si.review_status IN ('pending_review', 'needs_action', 'duplicate_blocked') OR COALESCE(si.blocked_from_sage_yn, false) = true)::integer AS review_invoice_count
    FROM public.supplier_invoices si
    GROUP BY si.order_id
  ), supplier_lines AS (
    SELECT
      si.order_id,
      COUNT(sil.id)::integer AS total_supplier_lines,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y','yes','true','1')
      )::integer AS progressed_supplier_lines,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y','yes','true','1')
      )::integer AS open_supplier_lines
    FROM public.supplier_invoices si
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    GROUP BY si.order_id
  ), exceptions AS (
    SELECT
      d.order_id,
      COUNT(*) FILTER (
        WHERE COALESCE(d.status, '') NOT IN ('closed', 'resolved', 'refunded', 'replaced', 'closed_no_action')
          AND d.resolved_at IS NULL
      )::integer AS active_exception_count
    FROM public.disputes d
    GROUP BY d.order_id
  ), holds AS (
    SELECT
      h.order_id,
      COUNT(*) FILTER (
        WHERE h.status IN ('requested', 'supervisor_approved', 'converted_to_exception')
          AND h.resolved_at IS NULL
      )::integer AS active_hold_count
    FROM public.customer_pre_shipment_hold_requests h
    GROUP BY h.order_id
  ), tracking AS (
    SELECT
      ots.order_id,
      COUNT(*) FILTER (WHERE ots.superseded_at IS NULL)::integer AS active_tracking_count,
      COUNT(*) FILTER (WHERE ots.superseded_at IS NULL AND COALESCE(ots.is_final_delivery_yn, false) = true)::integer AS final_tracking_count
    FROM public.order_tracking_submissions ots
    GROUP BY ots.order_id
  ), package_scope AS (
    SELECT
      p.order_id,
      p.shipment_batch_id,
      b.booking_ref,
      b.dispatched_at,
      p.tracking_submission_id,
      COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
      latest_receipt.receipt_status::text AS latest_receipt_status
    FROM public.shipper_shipment_batch_packages p
    JOIN public.shipper_shipment_batches b ON b.id = p.shipment_batch_id
    LEFT JOIN LATERAL (
      SELECT SUM(otla.qty_allocated) AS allocated_qty
      FROM public.order_tracking_line_allocations otla
      WHERE otla.tracking_submission_id = p.tracking_submission_id
    ) alloc ON p.tracking_submission_id IS NOT NULL
    LEFT JOIN LATERAL (
      SELECT spr.receipt_status
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = p.tracking_submission_id
      ORDER BY spr.created_at DESC
      LIMIT 1
    ) latest_receipt ON p.tracking_submission_id IS NOT NULL
    WHERE p.active = true
  ), shipment AS (
    SELECT
      ps.order_id,
      COUNT(*)::integer AS package_count,
      COUNT(DISTINCT ps.shipment_batch_id)::integer AS shipment_batch_count,
      COUNT(*) FILTER (WHERE COALESCE(ps.allocated_qty, 0) > 0)::integer AS allocated_package_count,
      COUNT(*) FILTER (WHERE COALESCE(ps.allocated_qty, 0) = 0)::integer AS unallocated_package_count,
      COUNT(*) FILTER (WHERE ps.latest_receipt_status IN ('received_damaged','held_query','not_received'))::integer AS receipt_issue_count,
      MAX(ps.dispatched_at) AS latest_dispatched_at,
      MAX(ps.booking_ref)::text AS latest_booking_ref
    FROM package_scope ps
    GROUP BY ps.order_id
  ), shipment_docs AS (
    SELECT DISTINCT ON (sd.shipment_batch_id)
      sd.id AS shipping_document_id,
      sd.shipment_batch_id,
      sd.review_status,
      sd.ocr_status
    FROM public.shipping_documents sd
    WHERE sd.active = true
    ORDER BY sd.shipment_batch_id, sd.created_at DESC
  ), shipper_ap AS (
    SELECT
      ps.order_id,
      COUNT(*) FILTER (WHERE sd.review_status = 'accepted_current')::integer AS accepted_shipper_doc_count,
      COUNT(*) FILTER (WHERE sca.allocation_status = 'approved')::integer AS approved_apportionment_count
    FROM package_scope ps
    LEFT JOIN shipment_docs sd ON sd.shipment_batch_id = ps.shipment_batch_id
    LEFT JOIN public.shipping_cost_allocations sca
      ON sca.shipping_document_id = sd.shipping_document_id
     AND sca.active = true
    GROUP BY ps.order_id
  ), export_docs AS (
    SELECT
      ps.order_id,
      COUNT(*) FILTER (
        WHERE e.document_kind <> 'pod_delivery_evidence'
          AND e.review_status = 'accepted_current'
      )::integer AS accepted_export_evidence_count,
      COUNT(*) FILTER (
        WHERE e.document_kind <> 'pod_delivery_evidence'
          AND e.review_status = 'submitted_for_review'
      )::integer AS submitted_export_evidence_count,
      COUNT(*) FILTER (
        WHERE e.document_kind = 'pod_delivery_evidence'
          AND e.review_status = 'accepted_current'
      )::integer AS accepted_pod_count,
      COUNT(*) FILTER (
        WHERE e.document_kind = 'pod_delivery_evidence'
          AND e.review_status = 'submitted_for_review'
      )::integer AS submitted_pod_count
    FROM package_scope ps
    LEFT JOIN public.shipper_final_export_evidence_documents e ON e.shipment_batch_id = ps.shipment_batch_id
    GROUP BY ps.order_id
  ), sales AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE si.sage_status = 'posted'
          AND si.sage_invoice_id IS NOT NULL
          AND si.invoice_type IN ('main', 'supplementary')
      )::integer AS posted_sale_charge_docs,
      COUNT(*) FILTER (
        WHERE si.sage_status = 'posted'
          AND si.sage_invoice_id IS NOT NULL
          AND si.invoice_type = 'credit_note'
      )::integer AS posted_sale_credit_docs,
      SUM(
        CASE
          WHEN si.sage_status = 'posted' AND si.sage_invoice_id IS NOT NULL AND si.invoice_type = 'credit_note'
            THEN -ABS(COALESCE(si.amount_gbp, 0))
          WHEN si.sage_status = 'posted' AND si.sage_invoice_id IS NOT NULL AND si.invoice_type IN ('main', 'supplementary')
            THEN COALESCE(si.amount_gbp, 0)
          ELSE 0
        END
      )::numeric AS signed_final_sale_value_gbp
    FROM public.sales_invoices si
    GROUP BY si.order_id
  ), joined AS (
    SELECT
      o.*,
      osv.lifecycle_status::text,
      COALESCE(f.threshold_met_yn, false) AS threshold_met_yn,
      COALESCE(f.amount_received_gbp, 0)::numeric AS amount_received_gbp,
      COALESCE(f.funding_gap_gbp, o.accepted_estimate_gbp)::numeric AS funding_gap_gbp,
      COALESCE(sup.supplier_invoice_count, 0) AS supplier_invoice_count,
      COALESCE(sup.approved_invoice_count, 0) AS approved_invoice_count,
      COALESCE(sup.rejected_invoice_count, 0) AS rejected_invoice_count,
      COALESCE(sup.review_invoice_count, 0) AS review_invoice_count,
      COALESCE(sl.total_supplier_lines, 0) AS total_supplier_lines,
      COALESCE(sl.progressed_supplier_lines, 0) AS progressed_supplier_lines,
      COALESCE(sl.open_supplier_lines, 0) AS open_supplier_lines,
      COALESCE(ex.active_exception_count, 0) AS active_exception_count,
      COALESCE(h.active_hold_count, 0) AS active_hold_count,
      COALESCE(tr.active_tracking_count, 0) AS active_tracking_count,
      COALESCE(tr.final_tracking_count, 0) AS final_tracking_count,
      COALESCE(sh.package_count, 0) AS package_count,
      COALESCE(sh.shipment_batch_count, 0) AS shipment_batch_count,
      COALESCE(sh.allocated_package_count, 0) AS allocated_package_count,
      COALESCE(sh.unallocated_package_count, 0) AS unallocated_package_count,
      COALESCE(sh.receipt_issue_count, 0) AS receipt_issue_count,
      sh.latest_dispatched_at,
      sh.latest_booking_ref,
      COALESCE(sa.accepted_shipper_doc_count, 0) AS accepted_shipper_doc_count,
      COALESCE(sa.approved_apportionment_count, 0) AS approved_apportionment_count,
      COALESCE(ed.accepted_export_evidence_count, 0) AS accepted_export_evidence_count,
      COALESCE(ed.submitted_export_evidence_count, 0) AS submitted_export_evidence_count,
      COALESCE(ed.accepted_pod_count, 0) AS accepted_pod_count,
      COALESCE(ed.submitted_pod_count, 0) AS submitted_pod_count,
      COALESCE(sales.posted_sale_charge_docs, 0) AS posted_sale_charge_docs,
      COALESCE(sales.posted_sale_credit_docs, 0) AS posted_sale_credit_docs,
      COALESCE(sales.signed_final_sale_value_gbp, 0)::numeric AS signed_final_sale_value_gbp
    FROM order_scope o
    LEFT JOIN public.order_state_vw osv ON osv.id = o.id
    LEFT JOIN funding f ON f.order_id = o.id
    LEFT JOIN supplier sup ON sup.order_id = o.id
    LEFT JOIN supplier_lines sl ON sl.order_id = o.id
    LEFT JOIN exceptions ex ON ex.order_id = o.id
    LEFT JOIN holds h ON h.order_id = o.id
    LEFT JOIN tracking tr ON tr.order_id = o.id
    LEFT JOIN shipment sh ON sh.order_id = o.id
    LEFT JOIN shipper_ap sa ON sa.order_id = o.id
    LEFT JOIN export_docs ed ON ed.order_id = o.id
    LEFT JOIN sales sales ON sales.order_id = o.id
  ), resolved AS (
    SELECT
      j.*,
      CASE
        WHEN j.posted_sale_charge_docs + j.posted_sale_credit_docs > 0 THEN j.signed_final_sale_value_gbp
        ELSE j.accepted_estimate_gbp
      END AS effective_final_sale_value_gbp,
      CASE
        WHEN j.posted_sale_charge_docs + j.posted_sale_credit_docs > 0 THEN GREATEST(j.signed_final_sale_value_gbp - j.amount_received_gbp, 0)
        ELSE 0::numeric
      END AS final_balance_due_gbp,
      CASE
        WHEN j.posted_sale_charge_docs + j.posted_sale_credit_docs > 0 THEN GREATEST(j.amount_received_gbp - j.signed_final_sale_value_gbp, 0)
        ELSE 0::numeric
      END AS potential_credit_pending_review_gbp
    FROM joined j
  ), staged AS (
    SELECT
      r.*,
      CASE
        WHEN r.active_exception_count > 0 OR r.active_hold_count > 0 THEN 'exception_or_hold_open'
        WHEN NOT r.threshold_met_yn THEN 'funding_incomplete'
        WHEN r.supplier_invoice_count = 0 THEN 'supplier_evidence_missing'
        WHEN r.rejected_invoice_count > 0 AND r.approved_invoice_count = 0 THEN 'supplier_evidence_rejected'
        WHEN r.review_invoice_count > 0 AND r.approved_invoice_count = 0 THEN 'supplier_evidence_review_needed'
        WHEN r.total_supplier_lines > 0 AND r.open_supplier_lines > 0 THEN 'supplier_reconciliation_incomplete'
        WHEN r.active_tracking_count = 0 THEN 'tracking_missing'
        WHEN r.shipment_batch_count = 0 THEN 'shipment_batch_missing'
        WHEN r.unallocated_package_count > 0 THEN 'shipment_allocation_incomplete'
        WHEN r.receipt_issue_count > 0 THEN 'shipment_receipt_issue'
        WHEN r.accepted_export_evidence_count = 0 AND r.submitted_export_evidence_count > 0 THEN 'export_evidence_review_needed'
        WHEN r.accepted_export_evidence_count = 0 THEN 'export_evidence_missing'
        WHEN r.posted_sale_charge_docs + r.posted_sale_credit_docs = 0 THEN 'customer_sale_not_posted'
        WHEN r.final_balance_due_gbp > 0.01 THEN 'final_balance_due'
        WHEN r.accepted_pod_count = 0 AND r.submitted_pod_count > 0 THEN 'pod_delivery_review_needed'
        WHEN r.accepted_pod_count = 0 THEN 'awaiting_delivery_confirmation'
        ELSE 'complete'
      END AS current_stage
    FROM resolved r
  )
  SELECT
    s.id,
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
    CASE WHEN s.threshold_met_yn THEN 'complete' ELSE 'incomplete' END::text AS funding_state,
    CASE
      WHEN s.supplier_invoice_count = 0 THEN 'missing'
      WHEN s.approved_invoice_count > 0 THEN 'approved_current'
      WHEN s.rejected_invoice_count > 0 THEN 'rejected_resubmit_required'
      WHEN s.review_invoice_count > 0 THEN 'review_needed'
      ELSE 'in_progress'
    END::text AS supplier_state,
    CASE
      WHEN s.total_supplier_lines = 0 THEN 'not_started'
      WHEN s.open_supplier_lines = 0 THEN 'complete'
      ELSE 'incomplete'
    END::text AS reconciliation_state,
    CASE WHEN s.active_exception_count > 0 THEN 'open' ELSE 'clean' END::text AS exception_state,
    CASE WHEN s.active_hold_count > 0 THEN 'open' ELSE 'clean' END::text AS hold_state,
    CASE WHEN s.active_tracking_count > 0 THEN 'submitted' ELSE 'missing' END::text AS tracking_state,
    CASE
      WHEN s.shipment_batch_count = 0 THEN 'missing'
      WHEN s.unallocated_package_count > 0 THEN 'allocation_incomplete'
      WHEN s.receipt_issue_count > 0 THEN 'receipt_issue'
      ELSE 'allocated'
    END::text AS shipment_state,
    CASE
      WHEN s.accepted_export_evidence_count > 0 THEN 'accepted_current'
      WHEN s.submitted_export_evidence_count > 0 THEN 'submitted_for_review'
      ELSE 'missing'
    END::text AS export_evidence_state,
    CASE
      WHEN s.accepted_pod_count > 0 THEN 'accepted_current'
      WHEN s.submitted_pod_count > 0 THEN 'submitted_for_review'
      ELSE 'missing'
    END::text AS pod_delivery_state,
    CASE
      WHEN s.posted_sale_charge_docs + s.posted_sale_credit_docs > 0 THEN 'posted'
      ELSE 'not_posted'
    END::text AS customer_sales_state,
    CASE
      WHEN s.approved_apportionment_count > 0 THEN 'apportionment_approved'
      WHEN s.accepted_shipper_doc_count > 0 THEN 'apportionment_pending'
      ELSE 'not_ready'
    END::text AS shipper_ap_state,
    s.current_stage,
    CASE s.current_stage
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
      WHEN 'pod_delivery_review_needed' THEN 'Delivery/POD review needed'
      WHEN 'awaiting_delivery_confirmation' THEN 'Awaiting delivery confirmation'
      ELSE 'Complete'
    END::text AS current_stage_label,
    CASE s.current_stage
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
      WHEN 'pod_delivery_review_needed' THEN 'Supervisor'
      WHEN 'awaiting_delivery_confirmation' THEN 'Shipper/Customer'
      ELSE 'None'
    END::text AS next_owner,
    CASE s.current_stage
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
      WHEN 'pod_delivery_review_needed' THEN 'Review submitted delivery/POD evidence'
      WHEN 'awaiting_delivery_confirmation' THEN 'Upload or accept delivery/POD evidence'
      ELSE 'No action required'
    END::text AS next_action,
    CASE s.current_stage
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
      WHEN 'pod_delivery_review_needed' THEN '/internal/shipping-control'
      WHEN 'awaiting_delivery_confirmation' THEN '/internal/shipping-control'
      ELSE '/internal/supervisor-command-centre'
    END::text AS next_href,
    CASE
      WHEN s.current_stage IN ('complete') THEN 'complete'
      WHEN s.current_stage IN ('exception_or_hold_open', 'supplier_evidence_rejected', 'shipment_receipt_issue') THEN 'blocked'
      WHEN s.current_stage IN ('funding_incomplete', 'supplier_evidence_missing', 'supplier_reconciliation_incomplete', 'tracking_missing', 'shipment_batch_missing', 'shipment_allocation_incomplete', 'export_evidence_missing', 'customer_sale_not_posted', 'final_balance_due', 'awaiting_delivery_confirmation') THEN 'action'
      WHEN s.current_stage IN ('supplier_evidence_review_needed', 'export_evidence_review_needed', 'pod_delivery_review_needed') THEN 'review'
      ELSE 'progress'
    END::text AS status_tone,
    CASE s.current_stage
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
      WHEN 'pod_delivery_review_needed' THEN 100
      WHEN 'awaiting_delivery_confirmation' THEN 101
      ELSE 999
    END::integer AS status_priority
  FROM staged s
  ORDER BY status_priority ASC, created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_platform_order_status_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_platform_order_status_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
