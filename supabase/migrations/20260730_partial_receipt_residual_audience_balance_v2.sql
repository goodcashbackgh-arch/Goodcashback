BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow successor to the 20260728 audience receipt-residual overlay.
--
-- Accounting rule:
--   collectible balance = max(pre-receipt-residual canonical balance
--                             - pending physical receipt residual, 0)
--
-- Only public.order_settlement_resolution_position_v1.pending_receipt_residual_gbp
-- is allowed to reduce the balance here. Do not use order_attributed_receipt_gbp,
-- inbound FX receipt residuals, settlement FX/card differences or outbound supplier FX.
--
-- This wrapper changes only the shared audience projection. It does not write or
-- reclassify funding, account credit, DVA evidence/allocations, customer sales,
-- Sage/accounting, VAT, shipment, tracking, holds or disputes.

DO $$
BEGIN
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_partial_receipt_residual_balance_v1(uuid)') IS NULL THEN
    IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
      RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid) prerequisite';
    END IF;

    ALTER FUNCTION public.order_audience_status_v1(uuid)
      RENAME TO order_audience_status_pre_partial_receipt_residual_balance_v1;
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
  WITH current_base AS (
    SELECT *
    FROM public.order_audience_status_pre_partial_receipt_residual_balance_v1(p_order_id)
  ), pre_receipt_overlay AS (
    SELECT *
    FROM public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)
  ), scoped AS (
    SELECT
      b.*,
      pre.order_id IS NOT NULL AS pre_receipt_row_present_yn,
      pre.canonical_balance_due_gbp AS pre_receipt_balance_due_gbp,
      pre.customer_status_label AS pre_receipt_customer_status_label,
      pre.customer_next_action AS pre_receipt_customer_next_action,
      pre.importer_status_label AS pre_receipt_importer_status_label,
      pre.importer_next_action AS pre_receipt_importer_next_action,
      COALESCE(s.pending_receipt_residual_gbp, 0)::numeric AS pending_receipt_residual_gbp,
      COALESCE(s.final_sale_document_count, 0)::integer AS final_sale_document_count,
      ROUND(
        CASE
          WHEN pre.order_id IS NOT NULL
           AND COALESCE(s.pending_receipt_residual_gbp, 0) > 0.01
           AND COALESCE(s.final_sale_document_count, 0) > 0
          THEN GREATEST(
            COALESCE(pre.canonical_balance_due_gbp, 0)
              - COALESCE(s.pending_receipt_residual_gbp, 0),
            0
          )
          ELSE COALESCE(b.canonical_balance_due_gbp, 0)
        END::numeric,
        2
      ) AS safe_collectible_balance_due_gbp
    FROM current_base b
    LEFT JOIN pre_receipt_overlay pre
      ON pre.order_id = b.order_id
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
    q.safe_collectible_balance_due_gbp::numeric AS canonical_balance_due_gbp,
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
      -- Restore the pre-overlay balance-due wording only if the older 20260728
      -- overlay suppressed it but the FX-excluding physical-residual calculation
      -- proves a real balance still remains.
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
       AND q.pre_receipt_row_present_yn
      THEN COALESCE(q.pre_receipt_customer_status_label, q.customer_status_label)
      ELSE q.customer_status_label
    END::text AS customer_status_label,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
       AND q.pre_receipt_row_present_yn
      THEN COALESCE(q.pre_receipt_customer_next_action, q.customer_next_action)
      ELSE q.customer_next_action
    END::text AS customer_next_action,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
       AND q.pre_receipt_row_present_yn
      THEN COALESCE(q.pre_receipt_importer_status_label, q.importer_status_label)
      ELSE q.importer_status_label
    END::text AS importer_status_label,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
       AND q.pre_receipt_row_present_yn
      THEN COALESCE(q.pre_receipt_importer_next_action, q.importer_next_action)
      ELSE q.importer_next_action
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
'Current shared audience status with an FX-excluding partial physical receipt-residual balance correction. Collectible balance is the preserved pre-receipt-residual canonical balance less pending_receipt_residual_gbp, floored at zero. No FX residual, account-credit creation, funding mutation, DVA mutation or accounting mutation occurs here.';

NOTIFY pgrst, 'reload schema';

COMMIT;
