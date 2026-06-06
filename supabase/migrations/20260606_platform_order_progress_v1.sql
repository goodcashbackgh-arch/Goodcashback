BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Adds a fixed 12-gate progress read model beside the existing canonical order status function.
-- This is additive/read-only. It does not update orders, funding, Sage, shipment, VAT or credit-ledger state.

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
        WHEN s.customer_sales_state <> 'posted' THEN 'not_reached'
        WHEN s.final_balance_due_gbp > 0.01 THEN 'blocked'
        ELSE 'complete'
      END AS final_settlement_state_derived,
      CASE
        WHEN s.customer_sales_state = 'posted'
         AND s.shipper_ap_state = 'apportionment_approved'
        THEN 'complete'
        WHEN s.customer_sales_state = 'posted'
        THEN 'not_ready'
        ELSE 'not_reached'
      END AS accounting_sage_state_derived,
      CASE
        WHEN s.customer_sales_state = 'posted'
         AND s.export_evidence_state = 'accepted_current'
         AND s.pod_delivery_state = 'accepted_current'
        THEN 'complete'
        WHEN s.customer_sales_state = 'posted'
        THEN 'not_ready'
        ELSE 'not_reached'
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
            (CASE WHEN g.funding_state <> 'complete' AND g.current_stage = 'funding_incomplete' THEN 'funding_exception' END),
            (CASE WHEN g.supplier_state IN ('rejected_resubmit_required','review_needed') THEN 'supplier_invoice_exception' END),
            (CASE WHEN g.reconciliation_state = 'incomplete' THEN 'supplier_reconciliation_exception' END),
            (CASE WHEN g.tracking_state = 'missing' AND g.current_stage = 'tracking_missing' THEN 'tracking_package_exception' END),
            (CASE WHEN g.shipment_state IN ('allocation_incomplete','receipt_issue') THEN 'shipment_logistics_exception' END),
            (CASE WHEN g.export_evidence_state IN ('missing','submitted_for_review') AND g.current_stage LIKE 'export_evidence%' THEN 'export_evidence_exception' END),
            (CASE WHEN g.pod_delivery_state IN ('missing','submitted_for_review') AND g.current_stage IN ('pod_delivery_review_needed','awaiting_delivery_confirmation') THEN 'pod_delivery_exception' END),
            (CASE WHEN g.final_settlement_state_derived = 'blocked' THEN 'customer_sale_final_balance_exception' END),
            (CASE WHEN g.shipper_ap_state IN ('not_ready','apportionment_pending') AND g.current_stage = 'shipper_ap_not_ready' THEN 'shipper_ap_exception' END),
            (CASE WHEN g.accounting_sage_state_derived = 'not_ready' THEN 'accounting_sage_exception' END),
            (CASE WHEN g.vat_compliance_state_derived = 'not_ready' THEN 'vat_compliance_exception' END)
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
