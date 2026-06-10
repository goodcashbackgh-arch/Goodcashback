BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Canonical audience status wrapper.
-- All user-facing pages should consume this or a thin route/helper backed by it.
-- It derives from the canonical internal status/progress functions and does not mutate state.

CREATE OR REPLACE FUNCTION public.order_audience_status_v1(p_order_id uuid DEFAULT NULL)
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
  WITH status_rows AS (
    SELECT *
    FROM public.internal_platform_order_status_v1()
    WHERE p_order_id IS NULL OR internal_platform_order_status_v1.order_id = p_order_id
  ), progress_rows AS (
    SELECT *
    FROM public.internal_platform_order_progress_v1()
    WHERE p_order_id IS NULL OR internal_platform_order_progress_v1.order_id = p_order_id
  ), final_balance_payments AS (
    SELECT
      a.order_id,
      COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric AS confirmed_final_balance_payment_gbp
    FROM public.dva_statement_line_allocations a
    JOIN status_rows s ON s.order_id = a.order_id
    WHERE a.order_id IS NOT NULL
      AND a.allocation_type = 'final_balance_payment'
      AND a.allocation_status = 'confirmed'
    GROUP BY a.order_id
  ), enriched AS (
    SELECT
      s.*,
      p.gate_complete_count,
      p.gate_total,
      p.dva_state,
      p.final_settlement_state,
      p.accounting_sage_state,
      p.vat_compliance_state,
      (COALESCE(s.amount_received_gbp, 0) + COALESCE(fbp.confirmed_final_balance_payment_gbp, 0))::numeric AS canonical_amount_received_gbp
    FROM status_rows s
    LEFT JOIN progress_rows p ON p.order_id = s.order_id
    LEFT JOIN final_balance_payments fbp ON fbp.order_id = s.order_id
  )
  SELECT
    e.order_id,
    e.order_ref,
    e.raw_order_status,
    e.lifecycle_status,
    e.importer_id,
    e.importer_name,
    e.retailer_id,
    e.retailer_name,
    e.accepted_estimate_gbp,
    CASE
      WHEN e.customer_sales_state = 'posted' THEN COALESCE(e.signed_final_sale_value_gbp, 0)
      ELSE COALESCE(e.accepted_estimate_gbp, 0)
    END::numeric AS final_sale_value_gbp,
    e.canonical_amount_received_gbp,
    COALESCE(e.final_balance_due_gbp, 0)::numeric AS canonical_balance_due_gbp,
    COALESCE(e.potential_credit_pending_review_gbp, 0)::numeric AS potential_credit_pending_review_gbp,
    e.current_stage AS internal_current_stage,
    e.current_stage_label AS internal_current_stage_label,
    e.next_owner AS internal_next_owner,
    e.next_action AS internal_next_action,
    e.next_href AS internal_next_href,
    e.status_tone AS internal_status_tone,
    COALESCE(e.gate_complete_count, 0)::integer AS gate_complete_count,
    COALESCE(e.gate_total, 12)::integer AS gate_total,
    e.funding_state,
    e.dva_state,
    e.supplier_state,
    e.reconciliation_state,
    e.tracking_state,
    e.shipment_state,
    e.export_evidence_state,
    e.pod_delivery_state,
    e.customer_sales_state,
    e.shipper_ap_state,
    e.accounting_sage_state,
    e.vat_compliance_state,
    (COALESCE(e.gate_complete_count, 0) = COALESCE(e.gate_total, 12) AND COALESCE(e.gate_total, 12) > 0) AS internal_complete_yn,
    (COALESCE(e.final_balance_due_gbp, 0) <= 0.01 AND e.pod_delivery_state = 'accepted_current') AS customer_complete_yn,
    (COALESCE(e.final_balance_due_gbp, 0) <= 0.01 AND COALESCE(e.current_stage, '') NOT IN ('exception_or_hold_open', 'funding_incomplete', 'supplier_evidence_rejected', 'supplier_evidence_review_needed', 'supplier_reconciliation_incomplete', 'tracking_missing')) AS importer_complete_yn,
    (e.export_evidence_state = 'accepted_current' AND e.pod_delivery_state = 'accepted_current') AS shipper_complete_yn,
    CASE
      WHEN COALESCE(e.final_balance_due_gbp, 0) > 0.01 THEN 'Final balance due'
      WHEN COALESCE(e.final_balance_due_gbp, 0) <= 0.01 AND e.pod_delivery_state = 'accepted_current' THEN 'Completed'
      WHEN e.export_evidence_state = 'accepted_current' THEN 'Shipment delivered'
      WHEN e.shipment_state = 'allocated' THEN 'Shipment arranged'
      WHEN e.funding_state = 'complete' THEN 'Payment received; processing'
      ELSE 'In progress'
    END::text AS customer_status_label,
    CASE
      WHEN COALESCE(e.final_balance_due_gbp, 0) > 0.01 THEN 'Pay final balance'
      WHEN COALESCE(e.final_balance_due_gbp, 0) <= 0.01 AND e.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN e.export_evidence_state = 'accepted_current' THEN 'Delivery confirmation received'
      WHEN e.shipment_state = 'allocated' THEN 'Waiting for delivery confirmation'
      ELSE 'No action needed right now'
    END::text AS customer_next_action,
    CASE
      WHEN COALESCE(e.final_balance_due_gbp, 0) > 0.01 THEN 'Final balance due'
      WHEN COALESCE(e.current_stage, '') = 'exception_or_hold_open' THEN 'Exception or hold open'
      WHEN e.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN 'Evidence attention'
      WHEN e.reconciliation_state = 'incomplete' THEN 'Invoice reconciliation open'
      WHEN e.tracking_state = 'missing' THEN 'Tracking missing'
      WHEN COALESCE(e.final_balance_due_gbp, 0) <= 0.01 AND e.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN COALESCE(e.final_balance_due_gbp, 0) <= 0.01 THEN 'No importer action required'
      ELSE COALESCE(e.current_stage_label, 'In progress')
    END::text AS importer_status_label,
    CASE
      WHEN COALESCE(e.final_balance_due_gbp, 0) > 0.01 THEN 'Collect final balance'
      WHEN COALESCE(e.current_stage, '') = 'exception_or_hold_open' THEN 'Resolve exception or hold'
      WHEN e.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN 'Resolve evidence issue'
      WHEN e.reconciliation_state = 'incomplete' THEN 'Continue invoice reconciliation'
      WHEN e.tracking_state = 'missing' THEN 'Add tracking'
      WHEN COALESCE(e.final_balance_due_gbp, 0) <= 0.01 AND e.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN COALESCE(e.final_balance_due_gbp, 0) <= 0.01 THEN 'No importer action required'
      ELSE COALESCE(e.next_action, 'In progress')
    END::text AS importer_next_action,
    CASE
      WHEN e.export_evidence_state = 'missing' THEN 'Export evidence missing'
      WHEN e.pod_delivery_state = 'missing' THEN 'POD missing'
      WHEN e.export_evidence_state = 'accepted_current' AND e.pod_delivery_state = 'accepted_current' THEN 'Shipper complete'
      ELSE COALESCE(e.current_stage_label, 'In progress')
    END::text AS shipper_status_label,
    CASE
      WHEN e.export_evidence_state = 'missing' THEN 'Upload final export evidence'
      WHEN e.pod_delivery_state = 'missing' THEN 'Upload delivery/POD evidence'
      WHEN e.export_evidence_state = 'accepted_current' AND e.pod_delivery_state = 'accepted_current' THEN 'No shipper action required'
      ELSE COALESCE(e.next_action, 'In progress')
    END::text AS shipper_next_action
  FROM enriched e
  ORDER BY e.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

-- Permanent drift audit for status-related release checks.
CREATE OR REPLACE FUNCTION public.internal_order_status_drift_audit_v1()
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_name text,
  retailer_name text,
  drift_result text,
  final_sale_value_gbp numeric,
  legacy_local_balance_due_gbp numeric,
  expected_canonical_balance_due_gbp numeric,
  canonical_status_balance_due_gbp numeric,
  audience_balance_due_gbp numeric,
  confirmed_final_balance_payment_gbp numeric,
  details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: status drift audit requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for status drift audit.';
  END IF;

  RETURN QUERY
  WITH active_orders AS (
    SELECT
      o.id AS order_id,
      o.order_ref,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
      r.name::text AS retailer_name
    FROM public.orders o
    LEFT JOIN public.importers i ON i.id = o.importer_id
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    WHERE COALESCE(o.order_type, 'original') = 'original'
      AND COALESCE(o.status, '') <> 'archived'
  ), funding AS (
    SELECT
      f.order_id,
      COALESCE(f.funded_total_gbp, COALESCE(f.confirmed_dva_funding_gbp, 0) + COALESCE(f.applied_credit_gbp, 0), 0)::numeric AS accepted_estimate_amount_received_gbp
    FROM public.order_funding_position_vw f
  ), final_balance_payments AS (
    SELECT
      a.order_id,
      COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric AS confirmed_final_balance_payment_gbp
    FROM public.dva_statement_line_allocations a
    WHERE a.order_id IS NOT NULL
      AND a.allocation_type = 'final_balance_payment'
      AND a.allocation_status = 'confirmed'
    GROUP BY a.order_id
  ), sales AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE si.sage_status = 'posted'
          AND si.sage_invoice_id IS NOT NULL
          AND si.invoice_type IN ('main', 'supplementary')
      ) AS posted_sale_charge_docs,
      COUNT(*) FILTER (
        WHERE si.sage_status = 'posted'
          AND si.sage_invoice_id IS NOT NULL
          AND si.invoice_type = 'credit_note'
      ) AS posted_sale_credit_docs,
      COALESCE(SUM(
        CASE
          WHEN si.sage_status = 'posted' AND si.sage_invoice_id IS NOT NULL AND si.invoice_type = 'credit_note'
            THEN -ABS(COALESCE(si.amount_gbp, 0))
          WHEN si.sage_status = 'posted' AND si.sage_invoice_id IS NOT NULL AND si.invoice_type IN ('main', 'supplementary')
            THEN COALESCE(si.amount_gbp, 0)
          ELSE 0
        END
      ), 0)::numeric AS signed_final_sale_value_gbp
    FROM public.sales_invoices si
    GROUP BY si.order_id
  ), canonical_status AS (
    SELECT * FROM public.internal_platform_order_status_v1()
  ), audience_status AS (
    SELECT * FROM public.order_audience_status_v1(NULL)
  ), audit AS (
    SELECT
      o.order_id,
      o.order_ref,
      o.importer_name,
      o.retailer_name,
      COALESCE(s.signed_final_sale_value_gbp, 0)::numeric AS final_sale_value_gbp,
      CASE
        WHEN COALESCE(s.posted_sale_charge_docs, 0) + COALESCE(s.posted_sale_credit_docs, 0) > 0
          THEN GREATEST(COALESCE(s.signed_final_sale_value_gbp, 0) - COALESCE(f.accepted_estimate_amount_received_gbp, 0), 0)
        ELSE 0
      END::numeric AS legacy_local_balance_due_gbp,
      CASE
        WHEN COALESCE(s.posted_sale_charge_docs, 0) + COALESCE(s.posted_sale_credit_docs, 0) > 0
          THEN GREATEST(COALESCE(s.signed_final_sale_value_gbp, 0) - COALESCE(f.accepted_estimate_amount_received_gbp, 0) - COALESCE(fbp.confirmed_final_balance_payment_gbp, 0), 0)
        ELSE 0
      END::numeric AS expected_canonical_balance_due_gbp,
      COALESCE(cs.final_balance_due_gbp, 0)::numeric AS canonical_status_balance_due_gbp,
      COALESCE(aus.canonical_balance_due_gbp, 0)::numeric AS audience_balance_due_gbp,
      COALESCE(fbp.confirmed_final_balance_payment_gbp, 0)::numeric AS confirmed_final_balance_payment_gbp,
      cs.current_stage,
      cs.next_action,
      aus.importer_status_label,
      aus.importer_next_action
    FROM active_orders o
    LEFT JOIN funding f ON f.order_id = o.order_id
    LEFT JOIN final_balance_payments fbp ON fbp.order_id = o.order_id
    LEFT JOIN sales s ON s.order_id = o.order_id
    LEFT JOIN canonical_status cs ON cs.order_id = o.order_id
    LEFT JOIN audience_status aus ON aus.order_id = o.order_id
  )
  SELECT
    a.order_id,
    a.order_ref,
    a.importer_name,
    a.retailer_name,
    CASE
      WHEN ABS(a.canonical_status_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01 THEN 'CANONICAL_STATUS_BALANCE_DRIFT'
      WHEN ABS(a.audience_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01 THEN 'AUDIENCE_STATUS_DRIFT'
      WHEN ABS(a.legacy_local_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01 THEN 'LOCAL_PAGE_BALANCE_DRIFT'
      ELSE 'OK'
    END::text AS drift_result,
    a.final_sale_value_gbp,
    a.legacy_local_balance_due_gbp,
    a.expected_canonical_balance_due_gbp,
    a.canonical_status_balance_due_gbp,
    a.audience_balance_due_gbp,
    a.confirmed_final_balance_payment_gbp,
    jsonb_build_object(
      'current_stage', a.current_stage,
      'next_action', a.next_action,
      'importer_status_label', a.importer_status_label,
      'importer_next_action', a.importer_next_action
    ) AS details
  FROM audit a
  WHERE ABS(a.canonical_status_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01
     OR ABS(a.audience_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01
     OR ABS(a.legacy_local_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01
  ORDER BY a.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_order_status_drift_audit_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_order_status_drift_audit_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
