BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Platform-wide presentation overlay for canonical receipt-residual settlement.
--
-- Preserve the current audience projection (including supplier-rejection and
-- tracking corrections) and change only the audience-facing final-balance
-- amount/status/action when BOTH:
--   1. the current audience projection is reporting a positive final balance; and
--   2. the existing canonical settlement position proves that an already-attributed
--      pending receipt residual covers the final sale.
--
-- This does not allocate the pending residual, alter funding, create credit,
-- change settlement arithmetic, or modify customer/importer page code.

DO $$
BEGIN
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL THEN
    IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
      RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid) prerequisite';
    END IF;

    ALTER FUNCTION public.order_audience_status_v1(uuid)
      RENAME TO order_audience_status_pre_receipt_residual_overlay_v1;
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
    FROM public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)
  ), scoped AS (
    SELECT
      b.*,
      (
        COALESCE(b.canonical_balance_due_gbp, 0) > 0.01
        AND COALESCE(s.pending_receipt_residual_gbp, 0) > 0.01
        AND COALESCE(s.final_sale_document_count, 0) > 0
        AND COALESCE(s.order_attributed_receipt_gbp, 0) + 0.005 >= COALESCE(s.final_order_value_gbp, 0)
      ) AS false_positive_final_balance
    FROM base b
    LEFT JOIN public.order_settlement_resolution_position_v1 s
      ON s.order_id = b.order_id
  )
  SELECT
    q.order_id,
    q.order_ref,
    q.raw_order_status,
    q.lifecycle_status,
    q.importer_id,
    q.importer_name,
    q.retailer_id,
    q.retailer_name,
    q.accepted_estimate_gbp,
    q.final_sale_value_gbp,
    q.canonical_amount_received_gbp,
    CASE
      WHEN q.false_positive_final_balance THEN 0::numeric
      ELSE q.canonical_balance_due_gbp
    END AS canonical_balance_due_gbp,
    q.potential_credit_pending_review_gbp,
    q.internal_current_stage,
    q.internal_current_stage_label,
    q.internal_next_owner,
    q.internal_next_action,
    q.internal_next_href,
    q.internal_status_tone,
    q.gate_complete_count,
    q.gate_total,
    q.funding_state,
    q.dva_state,
    q.supplier_state,
    q.reconciliation_state,
    q.tracking_state,
    q.shipment_state,
    q.export_evidence_state,
    q.pod_delivery_state,
    q.customer_sales_state,
    q.shipper_ap_state,
    q.accounting_sage_state,
    q.vat_compliance_state,
    q.internal_complete_yn,
    q.customer_complete_yn,
    q.importer_complete_yn,
    q.shipper_complete_yn,
    CASE
      WHEN NOT q.false_positive_final_balance THEN q.customer_status_label
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Completed'
      WHEN q.export_evidence_state = 'accepted_current' THEN 'Shipment delivered'
      WHEN q.shipment_state = 'allocated' THEN 'Shipment arranged'
      WHEN q.funding_state = 'complete' THEN 'Payment received; processing'
      ELSE 'In progress'
    END::text AS customer_status_label,
    CASE
      WHEN NOT q.false_positive_final_balance THEN q.customer_next_action
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN q.export_evidence_state = 'accepted_current' THEN 'Delivery confirmation received'
      WHEN q.shipment_state = 'allocated' THEN 'Waiting for delivery confirmation'
      ELSE 'No action needed right now'
    END::text AS customer_next_action,
    CASE
      WHEN NOT q.false_positive_final_balance THEN q.importer_status_label
      WHEN COALESCE(q.internal_current_stage, '') = 'exception_or_hold_open' THEN q.importer_status_label
      WHEN q.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN q.importer_status_label
      WHEN q.reconciliation_state = 'incomplete' THEN 'Invoice reconciliation open'
      WHEN q.reconciliation_state = 'complete' AND q.tracking_state = 'missing' THEN 'Invoice reconciled; tracking open'
      WHEN q.reconciliation_state = 'complete' AND q.tracking_state IN ('allocation_incomplete', 'submitted') THEN 'Tracking submitted'
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      ELSE 'No importer action required'
    END::text AS importer_status_label,
    CASE
      WHEN NOT q.false_positive_final_balance THEN q.importer_next_action
      WHEN COALESCE(q.internal_current_stage, '') = 'exception_or_hold_open' THEN q.importer_next_action
      WHEN q.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN q.importer_next_action
      WHEN q.reconciliation_state = 'incomplete' THEN 'Continue invoice reconciliation'
      WHEN q.reconciliation_state = 'complete' AND q.tracking_state = 'missing' THEN 'Add tracking'
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      ELSE 'No importer action required'
    END::text AS importer_next_action,
    q.shipper_status_label,
    q.shipper_next_action
  FROM scoped q
  ORDER BY q.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'Current audience-safe status plus a narrow false-positive final-balance overlay. Only when the existing audience projection shows a positive balance and the canonical pending receipt already covers the final sale is collectible balance set to zero and customer/importer balance-collection messaging suppressed. Applied amount, pending credit, completion facts and shipper output remain unchanged.';

NOTIFY pgrst, 'reload schema';

COMMIT;
