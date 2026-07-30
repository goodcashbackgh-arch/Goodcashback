BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow repair of the current 20260728 receipt-residual audience overlay only.
--
-- Current main contract:
--   order_audience_status_v1(uuid)
--     -> order_audience_status_pre_receipt_residual_overlay_v1(uuid)
--
-- Preserve that exact predecessor and change only the receipt-residual treatment.
-- No alternate funding/final-sale calculation is introduced here.
--
-- Accounting rule:
--   still_order_applied_residual
--     = max(active_non_reversed_physical_residual - exact_linked_overfunding_credit, 0)
--
--   collectible_balance
--     = max(existing_pre_overlay_canonical_balance - still_order_applied_residual, 0)
--
-- FX/card residuals and attributed-receipt totals are deliberately excluded.
-- This migration performs no financial or operational writes.

DO $$
DECLARE
  v_current_definition text;
  v_normalized_definition text;
  v_result_signature text;
  v_prosecdef boolean;
  v_proconfig text[];
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)';
  END IF;

  IF to_regclass('public.order_pending_funding_surplus') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_pending_funding_surplus';
  END IF;

  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing public.importer_credit_ledger';
  END IF;

  SELECT
    lower(pg_get_functiondef(p.oid)),
    pg_get_function_result(p.oid),
    p.prosecdef,
    p.proconfig
  INTO
    v_current_definition,
    v_result_signature,
    v_prosecdef,
    v_proconfig
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_v1(uuid)'::regprocedure;

  v_normalized_definition := regexp_replace(v_current_definition, '\s+', ' ', 'g');

  IF v_result_signature IS DISTINCT FROM
    'TABLE(order_id uuid, order_ref text, raw_order_status text, lifecycle_status text, importer_id uuid, importer_name text, retailer_id uuid, retailer_name text, accepted_estimate_gbp numeric, final_sale_value_gbp numeric, canonical_amount_received_gbp numeric, canonical_balance_due_gbp numeric, potential_credit_pending_review_gbp numeric, internal_current_stage text, internal_current_stage_label text, internal_next_owner text, internal_next_action text, internal_next_href text, internal_status_tone text, gate_complete_count integer, gate_total integer, funding_state text, dva_state text, supplier_state text, reconciliation_state text, tracking_state text, shipment_state text, export_evidence_state text, pod_delivery_state text, customer_sales_state text, shipper_ap_state text, accounting_sage_state text, vat_compliance_state text, internal_complete_yn boolean, customer_complete_yn boolean, importer_complete_yn boolean, shipper_complete_yn boolean, customer_status_label text, customer_next_action text, importer_status_label text, importer_next_action text, shipper_status_label text, shipper_next_action text)'
  THEN
    RAISE EXCEPTION 'Audience return signature has changed since the 28 July overlay; stop before patching: %', v_result_signature;
  END IF;

  IF NOT COALESCE(v_prosecdef, false)
     OR NOT COALESCE(v_proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[]
  THEN
    RAISE EXCEPTION 'Audience execution boundary has changed since the 28 July overlay; stop before patching.';
  END IF;

  IF position(
       'with base as ( select * from public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id) ), scoped as ('
       IN v_normalized_definition
     ) = 0
  THEN
    RAISE EXCEPTION 'Audience dependency chain has changed: the preserved 28 July predecessor is no longer the direct authoritative base call.';
  END IF;

  IF position('order_audience_status_pre_importer_tracking_assignment_v1' IN v_current_definition) > 0 THEN
    RAISE EXCEPTION 'Audience dependency chain contains an unexpected wrapper; stop before patching.';
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
    -- Exact predecessor preserved by the 28 July overlay.
    SELECT *
    FROM public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)
  ), active_pending AS (
    SELECT
      p.order_id,
      ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS active_pending_receipt_gbp
    FROM public.order_pending_funding_surplus p
    JOIN base b ON b.order_id = p.order_id
    WHERE p.status IN ('pending_evidence', 'credit_confirmed')
      AND p.reversed_at IS NULL
    GROUP BY p.order_id
  ), distinct_credit_links AS (
    -- The established confirmation route can attach one exact new credit to more
    -- than one pending row. Deduplicate by ledger identity before subtracting it.
    SELECT DISTINCT
      p.order_id,
      p.importer_id,
      p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    JOIN base b ON b.order_id = p.order_id
    WHERE p.status = 'credit_confirmed'
      AND p.reversed_at IS NULL
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_confirmed_credit AS (
    SELECT
      l.order_id,
      ROUND(COALESCE(SUM(ABS(c.amount_gbp)), 0)::numeric, 2) AS linked_confirmed_credit_gbp
    FROM distinct_credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.importer_id = l.importer_id
     AND c.direction = 'credit'
     AND c.entry_type = 'manual_credit'
     AND c.source_type = 'overfunding'
     AND c.source_table = 'orders'
     AND c.source_id = l.order_id
     AND c.linked_order_id = l.order_id
     AND c.source_entity_type = 'order'
     AND c.source_entity_id = l.order_id
    GROUP BY l.order_id
  ), scoped AS (
    SELECT
      b.*,
      COALESCE(ap.active_pending_receipt_gbp, 0)::numeric AS active_pending_receipt_gbp,
      ROUND(
        GREATEST(
          COALESCE(ap.active_pending_receipt_gbp, 0)
            - COALESCE(lcc.linked_confirmed_credit_gbp, 0),
          0
        )::numeric,
        2
      ) AS still_order_applied_residual_gbp,
      ROUND(
        CASE
          WHEN COALESCE(ap.active_pending_receipt_gbp, 0) > 0.01
          THEN GREATEST(
            COALESCE(b.canonical_balance_due_gbp, 0)
              - GREATEST(
                  COALESCE(ap.active_pending_receipt_gbp, 0)
                    - COALESCE(lcc.linked_confirmed_credit_gbp, 0),
                  0
                ),
            0
          )
          ELSE COALESCE(b.canonical_balance_due_gbp, 0)
        END::numeric,
        2
      ) AS corrected_balance_due_gbp
    FROM base b
    LEFT JOIN active_pending ap ON ap.order_id = b.order_id
    LEFT JOIN linked_confirmed_credit lcc ON lcc.order_id = b.order_id
  ), projected AS (
    SELECT
      q.*,
      (
        COALESCE(q.canonical_balance_due_gbp, 0) > 0.01
        AND COALESCE(q.corrected_balance_due_gbp, 0) <= 0.01
      ) AS balance_cleared_by_physical_residual
    FROM scoped q
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
    q.corrected_balance_due_gbp::numeric AS canonical_balance_due_gbp,
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
      WHEN NOT q.balance_cleared_by_physical_residual THEN q.customer_status_label
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Completed'
      WHEN q.export_evidence_state = 'accepted_current' THEN 'Shipment delivered'
      WHEN q.shipment_state = 'allocated' THEN 'Shipment arranged'
      WHEN q.funding_state = 'complete' THEN 'Payment received; processing'
      ELSE 'In progress'
    END::text AS customer_status_label,
    CASE
      WHEN NOT q.balance_cleared_by_physical_residual THEN q.customer_next_action
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN q.export_evidence_state = 'accepted_current' THEN 'Delivery confirmation received'
      WHEN q.shipment_state = 'allocated' THEN 'Waiting for delivery confirmation'
      ELSE 'No action needed right now'
    END::text AS customer_next_action,
    CASE
      WHEN NOT q.balance_cleared_by_physical_residual THEN q.importer_status_label
      WHEN COALESCE(q.internal_current_stage, '') = 'exception_or_hold_open' THEN q.importer_status_label
      WHEN q.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN q.importer_status_label
      WHEN q.reconciliation_state = 'incomplete' THEN 'Invoice reconciliation open'
      WHEN q.reconciliation_state = 'complete' AND q.tracking_state = 'missing' THEN 'Invoice reconciled; tracking open'
      WHEN q.reconciliation_state = 'complete' AND q.tracking_state IN ('allocation_incomplete', 'submitted') THEN 'Tracking submitted'
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      ELSE 'No importer action required'
    END::text AS importer_status_label,
    CASE
      WHEN NOT q.balance_cleared_by_physical_residual THEN q.importer_next_action
      WHEN COALESCE(q.internal_current_stage, '') = 'exception_or_hold_open' THEN q.importer_next_action
      WHEN q.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN q.importer_next_action
      WHEN q.reconciliation_state = 'incomplete' THEN 'Continue invoice reconciliation'
      WHEN q.reconciliation_state = 'complete' AND q.tracking_state = 'missing' THEN 'Add tracking'
      WHEN q.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      ELSE 'No importer action required'
    END::text AS importer_next_action,
    q.shipper_status_label,
    q.shipper_next_action
  FROM projected q
  ORDER BY q.order_ref;
END;
$$;

-- Preserve the existing public execution boundary of the canonical audience RPC.
REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'28 July receipt-residual audience overlay repaired in place. Existing predecessor canonical balance remains authoritative; active non-reversed physical receipt residual reduces that balance only to the extent it has not already been converted into the exact linked overfunding credit for the same order/importer. FX/card residuals and attributed-receipt totals are excluded. Existing supplier/reconciliation/tracking facts pass through unchanged.';

NOTIFY pgrst, 'reload schema';

COMMIT;
