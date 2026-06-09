BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final sale settlement v2 wrapper.
-- Counts confirmed DVA/card final_balance_payment allocations as amount received.
-- This is read-only and does not mutate funding, credit, Sage, VAT, orders, or statement rows.

DO $$
BEGIN
  IF to_regprocedure('public.internal_order_final_sale_settlement_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_order_final_sale_settlement_v1(uuid)';
  END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_line_allocations';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_order_final_sale_settlement_v2(
  p_order_id uuid DEFAULT NULL
)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_id uuid,
  authorisation_ref text,
  accepted_estimate_gbp numeric,
  amount_received_gbp numeric,
  posted_sale_charge_gbp numeric,
  posted_sale_credit_gbp numeric,
  signed_final_sale_value_gbp numeric,
  final_sale_value_for_calc_gbp numeric,
  final_sale_value_exists boolean,
  posted_sale_document_count integer,
  posted_sale_documents_json jsonb,
  final_balance_due_gbp numeric,
  raw_potential_credit_gbp numeric,
  potential_credit_pending_review_gbp numeric,
  approved_account_credit_gbp numeric,
  approved_account_credit_rows integer,
  customer_sales_state text,
  shipment_state text,
  export_evidence_state text,
  pod_delivery_state text,
  exception_state text,
  hold_state text,
  current_stage text,
  final_settlement_state text,
  completion_state text,
  completion_blocker text,
  show_final_sale_section_yn boolean,
  show_balance_due_yn boolean,
  show_potential_credit_yn boolean,
  show_credit_added_to_account_yn boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  WITH base AS (
    SELECT b.*
    FROM public.internal_order_final_sale_settlement_v1(p_order_id) b
  ), final_balance_allocations AS (
    SELECT
      a.order_id,
      ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) AS final_balance_payment_gbp
    FROM public.dva_statement_line_allocations a
    WHERE a.allocation_type = 'final_balance_payment'
      AND a.allocation_status = 'confirmed'
      AND a.order_id IS NOT NULL
      AND (p_order_id IS NULL OR a.order_id = p_order_id)
    GROUP BY a.order_id
  ), adjusted AS (
    SELECT
      b.*,
      ROUND((COALESCE(b.amount_received_gbp, 0) + COALESCE(fba.final_balance_payment_gbp, 0))::numeric, 2) AS adjusted_amount_received_gbp
    FROM base b
    LEFT JOIN final_balance_allocations fba ON fba.order_id = b.order_id
  ), calculated AS (
    SELECT
      a.*,
      CASE
        WHEN a.final_sale_value_exists
          AND COALESCE(a.customer_sales_state, '') <> 'partial_posted'
        THEN ROUND(GREATEST(a.signed_final_sale_value_gbp - a.adjusted_amount_received_gbp, 0)::numeric, 2)
        ELSE 0::numeric
      END AS adjusted_final_balance_due_gbp,
      CASE
        WHEN a.final_sale_value_exists
          AND COALESCE(a.customer_sales_state, '') <> 'partial_posted'
        THEN ROUND(GREATEST(a.adjusted_amount_received_gbp - a.signed_final_sale_value_gbp, 0)::numeric, 2)
        ELSE 0::numeric
      END AS adjusted_raw_potential_credit_gbp
    FROM adjusted a
  ), settled AS (
    SELECT
      c.*,
      CASE
        WHEN c.approved_account_credit_gbp > 0 THEN 0::numeric
        ELSE c.adjusted_raw_potential_credit_gbp
      END AS adjusted_potential_credit_pending_review_gbp,
      CASE
        WHEN NOT c.final_sale_value_exists THEN 'no_final_sale_documents'
        WHEN COALESCE(c.customer_sales_state, '') = 'partial_posted' THEN 'partial_final_sale_posted'
        WHEN c.adjusted_final_balance_due_gbp > 0.01 THEN 'balance_due'
        WHEN c.approved_account_credit_gbp > 0 THEN 'credit_added_to_account'
        WHEN c.adjusted_raw_potential_credit_gbp > 0.01 THEN 'potential_credit_pending_review'
        ELSE 'settled_nil'
      END AS adjusted_final_settlement_state
    FROM calculated c
  )
  SELECT
    s.order_id,
    s.order_ref,
    s.importer_id,
    s.authorisation_ref,
    s.accepted_estimate_gbp,
    s.adjusted_amount_received_gbp,
    s.posted_sale_charge_gbp,
    s.posted_sale_credit_gbp,
    s.signed_final_sale_value_gbp,
    s.final_sale_value_for_calc_gbp,
    s.final_sale_value_exists,
    s.posted_sale_document_count,
    s.posted_sale_documents_json,
    s.adjusted_final_balance_due_gbp,
    s.adjusted_raw_potential_credit_gbp,
    s.adjusted_potential_credit_pending_review_gbp,
    s.approved_account_credit_gbp,
    s.approved_account_credit_rows,
    s.customer_sales_state,
    s.shipment_state,
    s.export_evidence_state,
    s.pod_delivery_state,
    s.exception_state,
    s.hold_state,
    s.current_stage,
    s.adjusted_final_settlement_state,
    CASE
      WHEN s.adjusted_final_settlement_state IN ('settled_nil','credit_added_to_account')
        AND COALESCE(s.customer_sales_state, '') = 'posted'
        AND COALESCE(s.shipment_state, '') = 'allocated'
        AND COALESCE(s.export_evidence_state, '') = 'accepted_current'
        AND COALESCE(s.pod_delivery_state, '') = 'accepted_current'
        AND COALESCE(s.exception_state, '') = 'clean'
        AND COALESCE(s.hold_state, '') = 'clean'
      THEN 'complete'
      ELSE 'not_complete'
    END,
    CASE
      WHEN COALESCE(s.hold_state, '') <> 'clean' THEN 'active_hold_open'
      WHEN COALESCE(s.exception_state, '') <> 'clean' THEN 'open_exception_or_dispute'
      WHEN NOT s.final_sale_value_exists THEN 'final_sale_documents_missing'
      WHEN COALESCE(s.customer_sales_state, '') = 'partial_posted' THEN 'partial_customer_sale_or_partial_coverage'
      WHEN s.adjusted_final_balance_due_gbp > 0.01 THEN 'final_balance_due'
      WHEN COALESCE(s.shipment_state, '') <> 'allocated' THEN 'shipment_not_fully_allocated'
      WHEN COALESCE(s.export_evidence_state, '') <> 'accepted_current' THEN 'export_evidence_not_complete'
      WHEN COALESCE(s.pod_delivery_state, '') <> 'accepted_current' THEN 'pod_delivery_not_complete'
      ELSE NULL::text
    END,
    s.final_sale_value_exists,
    (s.final_sale_value_exists AND s.adjusted_final_balance_due_gbp > 0.01),
    (s.final_sale_value_exists AND s.adjusted_potential_credit_pending_review_gbp > 0.01),
    (s.approved_account_credit_gbp > 0.01)
  FROM settled s
  ORDER BY s.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_order_final_sale_settlement_v2(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_order_final_sale_settlement_v2(uuid) TO authenticated;

COMMENT ON FUNCTION public.internal_order_final_sale_settlement_v2(uuid) IS
'Final sale settlement read model v2. Read-only wrapper over v1 that adds confirmed DVA/card final_balance_payment allocations to amount received and recomputes final balance/credit state. Does not create credit or overfunding.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke check after execution:
-- select * from public.internal_order_final_sale_settlement_v2(null) limit 5;
