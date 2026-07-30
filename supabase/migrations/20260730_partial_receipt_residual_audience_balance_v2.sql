BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow successor to the 20260728 audience receipt-residual overlay.
--
-- Accounting rule:
--   1. Start from the final-sale shortfall before the old receipt-residual overlay:
--        max(final order value - payment already applied to the order, 0)
--   2. Determine how much of the physical receipt residual still belongs to this order:
--        active pending receipt residual
--        less any exact customer credit already created from that same residual
--   3. If an active receipt-residual position exists, recompute the collectible balance
--      from canonical settlement facts and reduce it only by the still-order-applied
--      physical residual, floored at zero.
--   4. If there is no active receipt-residual position, preserve the existing audience
--      balance exactly.
--
-- This is deliberately NOT an FX calculation. FX/card residuals, attributed-receipt
-- totals and supplier-side FX never enter the customer collectible-balance formula.
--
-- The wrapper is read-only and changes only the shared audience projection. It does
-- not write or reclassify funding, account credit, DVA evidence/allocations,
-- customer sales, Sage/accounting, VAT, shipment, tracking, holds or disputes.

DO $$
BEGIN
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1';
  END IF;
  IF to_regclass('public.order_pending_funding_surplus') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_pending_funding_surplus';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing public.importer_credit_ledger';
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
  WITH base AS (
    -- Preserve every later audience/status/tracking correction already installed.
    SELECT *
    FROM public.order_audience_status_pre_partial_receipt_residual_balance_v1(p_order_id)
  ), active_pending AS (
    -- Physical receipt residuals remain economically attached to the order while
    -- pending_evidence or credit_confirmed. Reversed rows are historical only.
    SELECT
      p.order_id,
      ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS active_pending_receipt_gbp
    FROM public.order_pending_funding_surplus p
    JOIN base b ON b.order_id = p.order_id
    WHERE p.status IN ('pending_evidence', 'credit_confirmed')
    GROUP BY p.order_id
  ), distinct_credit_links AS (
    -- One confirmed customer-credit row can be linked to multiple pending rows;
    -- deduplicate by ledger identity before summing so the credit is removed once.
    SELECT DISTINCT
      p.order_id,
      p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    JOIN base b ON b.order_id = p.order_id
    WHERE p.status = 'credit_confirmed'
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_confirmed_credit AS (
    SELECT
      l.order_id,
      ROUND(COALESCE(SUM(ABS(c.amount_gbp)), 0)::numeric, 2) AS linked_confirmed_credit_gbp
    FROM distinct_credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.direction = 'credit'
    GROUP BY l.order_id
  ), receipt_application AS (
    SELECT
      b.order_id,
      COALESCE(ap.active_pending_receipt_gbp, 0)::numeric AS active_pending_receipt_gbp,
      ROUND(
        GREATEST(
          COALESCE(ap.active_pending_receipt_gbp, 0)
            - COALESCE(lcc.linked_confirmed_credit_gbp, 0),
          0
        )::numeric,
        2
      ) AS physical_residual_applied_to_order_gbp
    FROM base b
    LEFT JOIN active_pending ap ON ap.order_id = b.order_id
    LEFT JOIN linked_confirmed_credit lcc ON lcc.order_id = b.order_id
  ), scoped AS (
    SELECT
      b.*,
      COALESCE(ra.active_pending_receipt_gbp, 0)::numeric AS active_pending_receipt_gbp,
      COALESCE(ra.physical_residual_applied_to_order_gbp, 0)::numeric AS physical_residual_applied_to_order_gbp,
      COALESCE(s.final_sale_document_count, 0)::integer AS final_sale_document_count,
      ROUND(
        CASE
          -- Any active residual position must be recalculated here, even when the
          -- residual has been fully converted to linked customer credit. This avoids
          -- inheriting the 20260728 overlay's broader credit_confirmed coverage rule.
          WHEN COALESCE(ra.active_pending_receipt_gbp, 0) > 0.01
           AND COALESCE(s.final_sale_document_count, 0) > 0
          THEN GREATEST(
            GREATEST(
              COALESCE(s.final_order_value_gbp, 0)
                - COALESCE(s.payment_applied_to_order_gbp, 0),
              0
            )
              - COALESCE(ra.physical_residual_applied_to_order_gbp, 0),
            0
          )
          ELSE COALESCE(b.canonical_balance_due_gbp, 0)
        END::numeric,
        2
      ) AS safe_collectible_balance_due_gbp
    FROM base b
    LEFT JOIN receipt_application ra ON ra.order_id = b.order_id
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
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01 THEN false
      ELSE q.customer_complete_yn
    END AS customer_complete_yn,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01 THEN false
      ELSE q.importer_complete_yn
    END AS importer_complete_yn,
    q.shipper_complete_yn,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
      THEN 'Final balance due'
      ELSE q.customer_status_label
    END::text AS customer_status_label,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
      THEN 'Pay final balance'
      ELSE q.customer_next_action
    END::text AS customer_next_action,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
      THEN 'Final balance due'
      ELSE q.importer_status_label
    END::text AS importer_status_label,
    CASE
      WHEN q.safe_collectible_balance_due_gbp > 0.01
       AND COALESCE(q.canonical_balance_due_gbp, 0) <= 0.01
      THEN 'Collect final balance'
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
'Current shared audience status with an FX-excluding physical receipt-residual balance correction. Any active residual position is recalculated from final order value and payment already applied; only the portion not already converted into exact linked customer credit reduces the balance. Reversed residuals and all FX/card amounts are excluded. Orders with no active residual position pass through unchanged. Positive corrected balances force customer/importer completion false; all other completion/status fields pass through. No financial or operational write occurs.';

NOTIFY pgrst, 'reload schema';

COMMIT;
