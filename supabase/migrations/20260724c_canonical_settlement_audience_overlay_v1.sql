BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Preserve the existing audience-status implementation and add only the
-- canonical settlement pending-credit overlay. Operational status, shipment,
-- funding threshold, Sage, VAT, holds and disputes remain governed by the
-- existing function.

DO $$
BEGIN
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_canonical_settlement_v1(uuid)') IS NULL THEN
    IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
      RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid) prerequisite';
    END IF;

    ALTER FUNCTION public.order_audience_status_v1(uuid)
      RENAME TO order_audience_status_pre_canonical_settlement_v1;
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
    FROM public.order_audience_status_pre_canonical_settlement_v1(p_order_id)
  )
  SELECT
    b.order_id,
    b.order_ref,
    b.raw_order_status,
    b.lifecycle_status,
    b.importer_id,
    b.importer_name,
    b.retailer_id,
    b.retailer_name,
    b.accepted_estimate_gbp,
    b.final_sale_value_gbp,
    b.canonical_amount_received_gbp,
    b.canonical_balance_due_gbp,
    CASE
      WHEN settlement.final_sale_document_count > 0
        THEN ROUND(GREATEST(COALESCE(settlement.remaining_unresolved_gbp, 0), 0)::numeric, 2)
      ELSE COALESCE(b.potential_credit_pending_review_gbp, 0)::numeric
    END AS potential_credit_pending_review_gbp,
    b.internal_current_stage,
    b.internal_current_stage_label,
    b.internal_next_owner,
    b.internal_next_action,
    b.internal_next_href,
    b.internal_status_tone,
    b.gate_complete_count,
    b.gate_total,
    b.funding_state,
    b.dva_state,
    b.supplier_state,
    b.reconciliation_state,
    b.tracking_state,
    b.shipment_state,
    b.export_evidence_state,
    b.pod_delivery_state,
    b.customer_sales_state,
    b.shipper_ap_state,
    b.accounting_sage_state,
    b.vat_compliance_state,
    b.internal_complete_yn,
    b.customer_complete_yn,
    b.importer_complete_yn,
    b.shipper_complete_yn,
    b.customer_status_label,
    b.customer_next_action,
    b.importer_status_label,
    b.importer_next_action,
    b.shipper_status_label,
    b.shipper_next_action
  FROM base b
  LEFT JOIN public.order_settlement_resolution_position_v1 settlement
    ON settlement.order_id = b.order_id
  ORDER BY b.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'Existing audience-safe operational status with canonical incremental settlement remaining amount overlaid for customer and importer displays. It does not expose FX/card classification.';

NOTIFY pgrst, 'reload schema';
COMMIT;
