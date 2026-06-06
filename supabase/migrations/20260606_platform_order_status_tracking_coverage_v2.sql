BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Canonical status v2: separate physical invoice progression from AP approval,
-- and prevent shipment/export/POD/customer-final status from completing the whole
-- order while active tracking refs or physical invoice lines are not covered.

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
      COUNT(*) FILTER (WHERE si.review_status IN ('approved_current', 'ref_corrected_approved') AND COALESCE(si.blocked_from_sage_yn, false) = false AND COALESCE(si.is_current_for_order, false) = true)::integer AS approved_invoice_count,
      COUNT(*) FILTER (WHERE si.review_status = 'rejected_resubmit_required')::integer AS rejected_invoice_count,
      COUNT(*) FILTER (WHERE si.review_status IN ('pending_review', 'needs_action', 'duplicate_blocked') OR COALESCE(si.blocked_from_sage_yn, false) = true OR COALESCE(si.is_current_for_order, false) = false)::integer AS review_invoice_count
    FROM public.supplier_invoices si
    GROUP BY si.order_id
  ), supplier_lines AS (
    SELECT
      si.order_id,
      COUNT(sil.id)::integer AS total_supplier_lines,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y','yes','true','1')
      )::integer AS physical_supplier_lines,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y','yes','true','1')
          AND sil.qty_confirmed IS NOT NULL
          AND sil.amount_confirmed IS NOT NULL
      )::integer AS progressed_supplier_lines,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y','yes','true','1')
          AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL)
      )::integer AS open_supplier_lines,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y','yes','true','1')
      )::integer AS parked_supplier_lines,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y','yes','true','1')
          AND NOT EXISTS (
            SELECT 1
            FROM public.order_tracking_line_allocations otla
            WHERE otla.supplier_invoice_line_id = sil.id
              AND COALESCE(otla.qty_allocated, 0) > 0
          )
      )::integer AS unallocated_physical_supplier_lines
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
      COUNT(*) FILTER (WHERE ots.superseded_at IS NULL AND COALESCE(ots.is_final_delivery_yn, false) = true)::integer AS final_tracking_count,
      COUNT(*) FILTER (
        WHERE ots.superseded_at IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.order_tracking_line_allocations otla
            WHERE otla.tracking_submission_id = ots.id
              AND COALESCE(otla.qty_allocated, 0) > 0
          )
      )::integer AS unallocated_tracking_count,
      COUNT(*) FILTER (
        WHERE ots.superseded_at IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.shipper_shipment_batch_packages p
            WHERE p.tracking_submission_id = ots.id
              AND p.active = true
          )
      )::integer AS unpackaged_tracking_count
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
      COALESCE(sl.physical_supplier_lines, 0) AS physical_supplier_lines,
      COALESCE(sl.progressed_supplier_lines, 0) AS progressed_supplier_lines,
      COALESCE(sl.open_supplier_lines, 0) AS open_supplier_lines,
      COALESCE(sl.parked_supplier_lines, 0) AS parked_supplier_lines,
      COALESCE(sl.unallocated_physical_supplier_lines, 0) AS unallocated_physical_supplier_lines,
      COALESCE(ex.active_exception_count, 0) AS active_exception_count,
      COALESCE(h.active_hold_count, 0) AS active_hold_count,
      COALESCE(tr.active_tracking_count, 0) AS active_tracking_count,
      COALESCE(tr.final_tracking_count, 0) AS final_tracking_count,
      COALESCE(tr.unallocated_tracking_count, 0) AS unallocated_tracking_count,
      COALESCE(tr.unpackaged_tracking_count, 0) AS unpackaged_tracking_count,
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
      (
        j.physical_supplier_lines > 0
        AND j.open_supplier_lines = 0
        AND j.unallocated_physical_supplier_lines = 0
        AND j.active_tracking_count > 0
        AND j.unallocated_tracking_count = 0
        AND j.unpackaged_tracking_count = 0
        AND j.unallocated_package_count = 0
      ) AS full_physical_shipment_coverage_yn,
      CASE
        WHEN j.posted_sale_charge_docs + j.posted_sale_credit_docs > 0 THEN j.signed_final_sale_value_gbp
        ELSE j.accepted_estimate_gbp
      END AS effective_final_sale_value_gbp
    FROM joined j
  ), balances AS (
    SELECT
      r.*,
      CASE
        WHEN r.posted_sale_charge_docs + r.posted_sale_credit_docs > 0
          AND r.full_physical_shipment_coverage_yn
        THEN GREATEST(r.signed_final_sale_value_gbp - r.amount_received_gbp, 0)
        ELSE 0::numeric
      END AS final_balance_due_gbp,
      CASE
        WHEN r.posted_sale_charge_docs + r.posted_sale_credit_docs > 0
          AND r.full_physical_shipment_coverage_yn
        THEN GREATEST(r.amount_received_gbp - r.signed_final_sale_value_gbp, 0)
        ELSE 0::numeric
      END AS potential_credit_pending_review_gbp
    FROM resolved r
  ), staged AS (
    SELECT
      b.*,
      CASE
        WHEN b.active_exception_count > 0 OR b.active_hold_count > 0 THEN 'exception_or_hold_open'
        WHEN NOT b.threshold_met_yn THEN 'funding_incomplete'
        WHEN b.supplier_invoice_count = 0 THEN 'supplier_evidence_missing'
        WHEN b.rejected_invoice_count > 0 AND b.approved_invoice_count = 0 THEN 'supplier_evidence_rejected'
        WHEN b.review_invoice_count > 0 AND b.approved_invoice_count = 0 THEN 'supplier_evidence_review_needed'
        WHEN b.physical_supplier_lines > 0 AND b.open_supplier_lines > 0 THEN 'supplier_reconciliation_incomplete'
        WHEN b.active_tracking_count = 0 THEN 'tracking_missing'
        WHEN b.unallocated_physical_supplier_lines > 0 OR b.unallocated_tracking_count > 0 OR b.unpackaged_tracking_count > 0 THEN 'tracking_allocation_incomplete'
        WHEN b.shipment_batch_count = 0 THEN 'shipment_batch_missing'
        WHEN b.unallocated_package_count > 0 THEN 'shipment_allocation_incomplete'
        WHEN b.receipt_issue_count > 0 THEN 'shipment_receipt_issue'
        WHEN b.accepted_export_evidence_count = 0 AND b.submitted_export_evidence_count > 0 THEN 'export_evidence_review_needed'
        WHEN b.accepted_export_evidence_count = 0 THEN 'export_evidence_missing'
        WHEN b.posted_sale_charge_docs + b.posted_sale_credit_docs = 0 THEN 'customer_sale_not_posted'
        WHEN b.final_balance_due_gbp > 0.01 THEN 'final_balance_due'
        WHEN b.accepted_pod_count = 0 AND b.submitted_pod_count > 0 THEN 'pod_delivery_review_needed'
        WHEN b.accepted_pod_count = 0 THEN 'awaiting_delivery_confirmation'
        ELSE 'complete'
      END AS current_stage
    FROM balances b
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
      WHEN s.physical_supplier_lines = 0 THEN 'not_started'
      WHEN s.open_supplier_lines = 0 THEN 'complete'
      ELSE 'incomplete'
    END::text AS reconciliation_state,
    CASE WHEN s.active_exception_count > 0 THEN 'open' ELSE 'clean' END::text AS exception_state,
    CASE WHEN s.active_hold_count > 0 THEN 'open' ELSE 'clean' END::text AS hold_state,
    CASE
      WHEN s.active_tracking_count = 0 THEN 'missing'
      WHEN s.unallocated_physical_supplier_lines > 0 OR s.unallocated_tracking_count > 0 OR s.unpackaged_tracking_count > 0 THEN 'allocation_incomplete'
      ELSE 'submitted'
    END::text AS tracking_state,
    CASE
      WHEN s.shipment_batch_count = 0 THEN 'missing'
      WHEN s.unallocated_tracking_count > 0 OR s.unpackaged_tracking_count > 0 OR s.unallocated_package_count > 0 OR s.unallocated_physical_supplier_lines > 0 THEN 'allocation_incomplete'
      WHEN s.receipt_issue_count > 0 THEN 'receipt_issue'
      ELSE 'allocated'
    END::text AS shipment_state,
    CASE
      WHEN NOT s.full_physical_shipment_coverage_yn AND s.accepted_export_evidence_count > 0 THEN 'partial_accepted_current'
      WHEN s.accepted_export_evidence_count > 0 THEN 'accepted_current'
      WHEN s.submitted_export_evidence_count > 0 THEN 'submitted_for_review'
      ELSE 'missing'
    END::text AS export_evidence_state,
    CASE
      WHEN NOT s.full_physical_shipment_coverage_yn AND s.accepted_pod_count > 0 THEN 'partial_accepted_current'
      WHEN s.accepted_pod_count > 0 THEN 'accepted_current'
      WHEN s.submitted_pod_count > 0 THEN 'submitted_for_review'
      ELSE 'missing'
    END::text AS pod_delivery_state,
    CASE
      WHEN s.posted_sale_charge_docs + s.posted_sale_credit_docs > 0 AND NOT s.full_physical_shipment_coverage_yn THEN 'partial_posted'
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
      WHEN 'tracking_allocation_incomplete' THEN 'Tracking/package allocation incomplete'
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
      WHEN 'tracking_allocation_incomplete' THEN 'Operator/Supervisor'
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
      WHEN 'tracking_allocation_incomplete' THEN 'Allocate all active tracking refs and physical lines to shipment'
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
      WHEN 'tracking_allocation_incomplete' THEN '/internal/shipping-control'
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
      WHEN s.current_stage IN ('funding_incomplete', 'supplier_evidence_missing', 'supplier_reconciliation_incomplete', 'tracking_missing', 'tracking_allocation_incomplete', 'shipment_batch_missing', 'shipment_allocation_incomplete', 'export_evidence_missing', 'customer_sale_not_posted', 'final_balance_due', 'awaiting_delivery_confirmation') THEN 'action'
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
      WHEN 'tracking_allocation_incomplete' THEN 55
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

CREATE OR REPLACE FUNCTION public.internal_platform_order_progress_v1()
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  gate_total integer,
  gate_complete_count integer,
  gate_summary_json jsonb,
  exception_summary_state text,
  exception_categories_json jsonb,
  dva_state text,
  final_settlement_state text,
  accounting_sage_state text,
  vat_compliance_state text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: platform order progress requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for platform order progress.';
  END IF;

  RETURN QUERY
  WITH status_rows AS (
    SELECT *
    FROM public.internal_platform_order_status_v1()
  ), derived AS (
    SELECT
      s.*,
      CASE
        WHEN s.funding_state <> 'complete' THEN 'not_reached'
        ELSE 'complete'
      END AS dva_state_derived,
      CASE
        WHEN s.customer_sales_state = 'partial_posted' THEN 'partial'
        WHEN s.customer_sales_state <> 'posted' THEN 'not_reached'
        WHEN s.final_balance_due_gbp > 0.01 THEN 'blocked'
        ELSE 'complete'
      END AS final_settlement_state_derived,
      CASE
        WHEN s.customer_sales_state NOT IN ('posted', 'partial_posted') THEN 'not_reached'
        WHEN s.customer_sales_state = 'partial_posted' THEN 'partial'
        WHEN s.shipper_ap_state <> 'apportionment_approved' THEN 'not_ready'
        ELSE 'complete'
      END AS accounting_sage_state_derived,
      CASE
        WHEN s.customer_sales_state NOT IN ('posted', 'partial_posted') THEN 'not_reached'
        WHEN s.export_evidence_state <> 'accepted_current'
          OR s.pod_delivery_state <> 'accepted_current'
        THEN 'not_ready'
        ELSE 'complete'
      END AS vat_compliance_state_derived
    FROM status_rows s
  ), gates AS (
    SELECT
      d.*,
      jsonb_build_array(
        jsonb_build_object('key','funding_customer_payment','label','Funding / customer payment','state',d.funding_state,'complete',d.funding_state = 'complete'),
        jsonb_build_object('key','dva_card_allocation','label','DVA / card allocation','state',d.dva_state_derived,'complete',d.dva_state_derived = 'complete'),
        jsonb_build_object('key','supplier_evidence','label','Supplier evidence','state',d.supplier_state,'complete',d.supplier_state = 'approved_current'),
        jsonb_build_object('key','supplier_reconciliation','label','Supplier reconciliation','state',d.reconciliation_state,'complete',d.reconciliation_state = 'complete'),
        jsonb_build_object('key','tracking','label','Tracking','state',d.tracking_state,'complete',d.tracking_state = 'submitted'),
        jsonb_build_object('key','shipment_package_allocation','label','Shipment / package allocation','state',d.shipment_state,'complete',d.shipment_state = 'allocated'),
        jsonb_build_object('key','export_evidence','label','Export evidence','state',d.export_evidence_state,'complete',d.export_evidence_state = 'accepted_current'),
        jsonb_build_object('key','delivery_pod','label','Delivery / POD','state',d.pod_delivery_state,'complete',d.pod_delivery_state = 'accepted_current'),
        jsonb_build_object('key','customer_sales_final_settlement','label','Customer sales / final settlement','state',d.final_settlement_state_derived,'complete',d.final_settlement_state_derived = 'complete'),
        jsonb_build_object('key','shipper_ap','label','Shipper AP','state',d.shipper_ap_state,'complete',d.shipper_ap_state = 'apportionment_approved'),
        jsonb_build_object('key','accounting_sage','label','Accounting / Sage','state',d.accounting_sage_state_derived,'complete',d.accounting_sage_state_derived = 'complete'),
        jsonb_build_object('key','vat_compliance_evidence','label','VAT / compliance evidence','state',d.vat_compliance_state_derived,'complete',d.vat_compliance_state_derived = 'complete')
      ) AS gate_summary_json_derived
    FROM derived d
  ), exceptions AS (
    SELECT
      g.*,
      (
        SELECT COALESCE(jsonb_agg(category ORDER BY category), '[]'::jsonb)
        FROM (
          VALUES
            (CASE WHEN g.exception_state = 'open' THEN 'order_exception' END),
            (CASE WHEN g.hold_state = 'open' THEN 'customer_hold' END),
            (CASE WHEN g.current_stage = 'funding_incomplete' THEN 'funding_exception' END),
            (CASE WHEN g.current_stage IN ('supplier_evidence_missing','supplier_evidence_rejected','supplier_evidence_review_needed') THEN 'supplier_invoice_exception' END),
            (CASE WHEN g.current_stage = 'supplier_reconciliation_incomplete' THEN 'supplier_reconciliation_exception' END),
            (CASE WHEN g.current_stage IN ('tracking_missing','tracking_allocation_incomplete','shipment_allocation_incomplete') THEN 'tracking_package_exception' END),
            (CASE WHEN g.current_stage IN ('shipment_batch_missing','shipment_receipt_issue') THEN 'shipment_logistics_exception' END),
            (CASE WHEN g.current_stage IN ('export_evidence_missing','export_evidence_review_needed') THEN 'export_evidence_exception' END),
            (CASE WHEN g.current_stage IN ('pod_delivery_review_needed','awaiting_delivery_confirmation') THEN 'pod_delivery_exception' END),
            (CASE WHEN g.current_stage = 'final_balance_due' THEN 'customer_sale_final_balance_exception' END)
        ) AS v(category)
        WHERE category IS NOT NULL
      ) AS exception_categories_json_derived
    FROM gates g
  )
  SELECT
    e.order_id,
    e.order_ref,
    12::integer AS gate_total,
    (
      SELECT COUNT(*)::integer
      FROM jsonb_array_elements(e.gate_summary_json_derived) gate
      WHERE COALESCE((gate ->> 'complete')::boolean, false) = true
    ) AS gate_complete_count,
    e.gate_summary_json_derived AS gate_summary_json,
    CASE
      WHEN e.exception_state = 'open' OR e.hold_state = 'open' THEN 'open'
      WHEN jsonb_array_length(e.exception_categories_json_derived) > 0 THEN 'attention'
      ELSE 'clean'
    END::text AS exception_summary_state,
    e.exception_categories_json_derived AS exception_categories_json,
    e.dva_state_derived::text AS dva_state,
    e.final_settlement_state_derived::text AS final_settlement_state,
    e.accounting_sage_state_derived::text AS accounting_sage_state,
    e.vat_compliance_state_derived::text AS vat_compliance_state
  FROM exceptions e
  ORDER BY e.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_platform_order_progress_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_platform_order_progress_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
