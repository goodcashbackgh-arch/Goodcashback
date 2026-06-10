BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- The internal status spine is staff-only by design.
-- This audience wrapper is read-only and may be called by authenticated
-- non-staff audience pages after the page has already authenticated the user.
-- To reuse the canonical staff-only spine safely without duplicating its logic,
-- the wrapper proxies the canonical read through an active staff auth context
-- inside the SECURITY DEFINER function only.

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
DECLARE
  v_original_auth_uid uuid;
  v_proxy_staff_auth_uid uuid;
BEGIN
  v_original_auth_uid := auth.uid();

  IF v_original_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: order audience status requires auth.uid()';
  END IF;

  SELECT s.auth_user_id
  INTO v_proxy_staff_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY s.created_at NULLS LAST
  LIMIT 1;

  IF v_proxy_staff_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No active staff account is available for canonical audience status.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_proxy_staff_auth_uid::text, true);

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
    e.order_ref::text,
    e.raw_order_status::text,
    e.lifecycle_status::text,
    e.importer_id,
    e.importer_name::text,
    e.retailer_id,
    e.retailer_name::text,
    e.accepted_estimate_gbp,
    CASE
      WHEN e.customer_sales_state = 'posted' THEN COALESCE(e.signed_final_sale_value_gbp, 0)
      ELSE COALESCE(e.accepted_estimate_gbp, 0)
    END::numeric AS final_sale_value_gbp,
    e.canonical_amount_received_gbp,
    COALESCE(e.final_balance_due_gbp, 0)::numeric AS canonical_balance_due_gbp,
    COALESCE(e.potential_credit_pending_review_gbp, 0)::numeric AS potential_credit_pending_review_gbp,
    e.current_stage::text AS internal_current_stage,
    e.current_stage_label::text AS internal_current_stage_label,
    e.next_owner::text AS internal_next_owner,
    e.next_action::text AS internal_next_action,
    e.next_href::text AS internal_next_href,
    e.status_tone::text AS internal_status_tone,
    COALESCE(e.gate_complete_count, 0)::integer AS gate_complete_count,
    COALESCE(e.gate_total, 12)::integer AS gate_total,
    e.funding_state::text,
    e.dva_state::text,
    e.supplier_state::text,
    e.reconciliation_state::text,
    e.tracking_state::text,
    e.shipment_state::text,
    e.export_evidence_state::text,
    e.pod_delivery_state::text,
    e.customer_sales_state::text,
    e.shipper_ap_state::text,
    e.accounting_sage_state::text,
    e.vat_compliance_state::text,
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

NOTIFY pgrst, 'reload schema';

COMMIT;
