BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final sale settlement read model v1.
-- Read-only canonical settlement layer for customer/importer display,
-- DVA/card matching, supervisor credit readiness, and completion-loyalty gating.
-- This function does not mutate orders, funding, sales invoices, credit ledger,
-- shipment/export/POD evidence, Sage state, or VAT return snapshots.

DO $$
BEGIN
  IF to_regprocedure('public.internal_platform_order_status_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_platform_order_status_v1()';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.sales_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sales_invoices';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_order_final_sale_settlement_v1(
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
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: final sale settlement read model requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for final sale settlement read model.';
  END IF;

  RETURN QUERY
  WITH status_rows AS (
    SELECT s.*
    FROM public.internal_platform_order_status_v1() s
    WHERE p_order_id IS NULL OR s.order_id = p_order_id
  ), sales_docs AS (
    SELECT
      si.order_id,
      si.id AS sales_invoice_id,
      si.invoice_type::text AS invoice_type,
      COALESCE(si.amount_gbp, 0)::numeric AS source_amount_gbp,
      CASE
        WHEN si.invoice_type::text = 'credit_note' THEN -ABS(COALESCE(si.amount_gbp, 0)::numeric)
        WHEN si.invoice_type::text IN ('main', 'supplementary') THEN COALESCE(si.amount_gbp, 0)::numeric
        ELSE 0::numeric
      END AS signed_impact_gbp,
      COALESCE(si.line_items_json #>> '{sage_header,reference}', si.id::text)::text AS reference_text,
      si.sage_invoice_id::text AS sage_invoice_id,
      si.sage_posted_at::timestamptz AS sage_posted_at
    FROM public.sales_invoices si
    WHERE COALESCE(si.sage_status::text, '') = 'posted'
      AND NULLIF(BTRIM(COALESCE(si.sage_invoice_id::text, '')), '') IS NOT NULL
      AND si.invoice_type::text IN ('main', 'supplementary', 'credit_note')
      AND (p_order_id IS NULL OR si.order_id = p_order_id)
  ), sales AS (
    SELECT
      sd.order_id,
      ROUND(COALESCE(SUM(sd.source_amount_gbp) FILTER (WHERE sd.invoice_type IN ('main','supplementary')), 0)::numeric, 2) AS posted_sale_charge_gbp,
      ROUND(COALESCE(SUM(ABS(sd.source_amount_gbp)) FILTER (WHERE sd.invoice_type = 'credit_note'), 0)::numeric, 2) AS posted_sale_credit_gbp,
      ROUND(COALESCE(SUM(sd.signed_impact_gbp), 0)::numeric, 2) AS signed_final_sale_value_gbp,
      COUNT(*)::integer AS posted_sale_document_count,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'sales_invoice_id', sd.sales_invoice_id,
            'invoice_type', sd.invoice_type,
            'customer_label', CASE sd.invoice_type
              WHEN 'main' THEN 'Sale document'
              WHEN 'supplementary' THEN 'Final sale adjustment'
              WHEN 'credit_note' THEN 'Sale credit'
              ELSE 'Sale document'
            END,
            'source_amount_gbp', ROUND(sd.source_amount_gbp, 2),
            'signed_impact_gbp', ROUND(sd.signed_impact_gbp, 2),
            'reference_text', sd.reference_text,
            'sage_invoice_id', sd.sage_invoice_id,
            'sage_posted_at', sd.sage_posted_at
          )
          ORDER BY sd.sage_posted_at NULLS LAST, sd.sales_invoice_id
        ),
        '[]'::jsonb
      ) AS posted_sale_documents_json
    FROM sales_docs sd
    GROUP BY sd.order_id
  ), approved_order_credit AS (
    SELECT
      icl.source_entity_id AS order_id,
      ROUND(COALESCE(SUM(CASE WHEN icl.direction = 'credit' THEN ABS(icl.amount_gbp) ELSE -ABS(icl.amount_gbp) END), 0)::numeric, 2) AS approved_account_credit_gbp,
      COUNT(*)::integer AS approved_account_credit_rows
    FROM public.importer_credit_ledger icl
    WHERE icl.source_type IN ('settlement_credit', 'overfunding')
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id IS NOT NULL
      AND icl.lock_reason IS NULL
    GROUP BY icl.source_entity_id
  ), base AS (
    SELECT
      sr.order_id,
      sr.order_ref,
      sr.importer_id,
      COALESCE(o.payment_auth_id::text, '') AS authorisation_ref,
      ROUND(COALESCE(sr.accepted_estimate_gbp, 0)::numeric, 2) AS accepted_estimate_gbp,
      ROUND(COALESCE(sr.amount_received_gbp, 0)::numeric, 2) AS amount_received_gbp,
      COALESCE(sa.posted_sale_charge_gbp, 0)::numeric AS posted_sale_charge_gbp,
      COALESCE(sa.posted_sale_credit_gbp, 0)::numeric AS posted_sale_credit_gbp,
      COALESCE(sa.signed_final_sale_value_gbp, 0)::numeric AS signed_final_sale_value_gbp,
      COALESCE(sa.posted_sale_document_count, 0)::integer AS posted_sale_document_count,
      COALESCE(sa.posted_sale_documents_json, '[]'::jsonb) AS posted_sale_documents_json,
      COALESCE(aoc.approved_account_credit_gbp, 0)::numeric AS approved_account_credit_gbp,
      COALESCE(aoc.approved_account_credit_rows, 0)::integer AS approved_account_credit_rows,
      sr.customer_sales_state,
      sr.shipment_state,
      sr.export_evidence_state,
      sr.pod_delivery_state,
      sr.exception_state,
      sr.hold_state,
      sr.current_stage
    FROM status_rows sr
    JOIN public.orders o ON o.id = sr.order_id
    LEFT JOIN sales sa ON sa.order_id = sr.order_id
    LEFT JOIN approved_order_credit aoc ON aoc.order_id = sr.order_id
  ), calculated AS (
    SELECT
      b.*,
      (b.posted_sale_document_count > 0) AS final_sale_value_exists,
      CASE
        WHEN b.posted_sale_document_count > 0 THEN b.signed_final_sale_value_gbp
        ELSE b.accepted_estimate_gbp
      END AS final_sale_value_for_calc_gbp,
      CASE
        WHEN b.posted_sale_document_count > 0
          AND COALESCE(b.customer_sales_state, '') <> 'partial_posted'
        THEN ROUND(GREATEST(b.signed_final_sale_value_gbp - b.amount_received_gbp, 0)::numeric, 2)
        ELSE 0::numeric
      END AS final_balance_due_gbp,
      CASE
        WHEN b.posted_sale_document_count > 0
          AND COALESCE(b.customer_sales_state, '') <> 'partial_posted'
        THEN ROUND(GREATEST(b.amount_received_gbp - b.signed_final_sale_value_gbp, 0)::numeric, 2)
        ELSE 0::numeric
      END AS raw_potential_credit_gbp
    FROM base b
  ), settled AS (
    SELECT
      c.*,
      CASE
        WHEN c.approved_account_credit_gbp > 0 THEN 0::numeric
        ELSE c.raw_potential_credit_gbp
      END AS potential_credit_pending_review_gbp,
      CASE
        WHEN NOT c.final_sale_value_exists THEN 'no_final_sale_documents'
        WHEN COALESCE(c.customer_sales_state, '') = 'partial_posted' THEN 'partial_final_sale_posted'
        WHEN c.final_balance_due_gbp > 0.01 THEN 'balance_due'
        WHEN c.approved_account_credit_gbp > 0 THEN 'credit_added_to_account'
        WHEN c.raw_potential_credit_gbp > 0.01 THEN 'potential_credit_pending_review'
        ELSE 'settled_nil'
      END AS final_settlement_state
    FROM calculated c
  )
  SELECT
    s.order_id,
    s.order_ref,
    s.importer_id,
    s.authorisation_ref,
    s.accepted_estimate_gbp,
    s.amount_received_gbp,
    s.posted_sale_charge_gbp,
    s.posted_sale_credit_gbp,
    s.signed_final_sale_value_gbp,
    s.final_sale_value_for_calc_gbp,
    s.final_sale_value_exists,
    s.posted_sale_document_count,
    s.posted_sale_documents_json,
    s.final_balance_due_gbp,
    s.raw_potential_credit_gbp,
    s.potential_credit_pending_review_gbp,
    s.approved_account_credit_gbp,
    s.approved_account_credit_rows,
    s.customer_sales_state,
    s.shipment_state,
    s.export_evidence_state,
    s.pod_delivery_state,
    s.exception_state,
    s.hold_state,
    s.current_stage,
    s.final_settlement_state,
    CASE
      WHEN s.final_settlement_state IN ('settled_nil','credit_added_to_account')
        AND COALESCE(s.customer_sales_state, '') = 'posted'
        AND COALESCE(s.shipment_state, '') = 'allocated'
        AND COALESCE(s.export_evidence_state, '') = 'accepted_current'
        AND COALESCE(s.pod_delivery_state, '') = 'accepted_current'
        AND COALESCE(s.exception_state, '') = 'clean'
        AND COALESCE(s.hold_state, '') = 'clean'
      THEN 'complete'
      ELSE 'not_complete'
    END AS completion_state,
    CASE
      WHEN COALESCE(s.hold_state, '') <> 'clean' THEN 'active_hold_open'
      WHEN COALESCE(s.exception_state, '') <> 'clean' THEN 'open_exception_or_dispute'
      WHEN NOT s.final_sale_value_exists THEN 'final_sale_documents_missing'
      WHEN COALESCE(s.customer_sales_state, '') = 'partial_posted' THEN 'partial_customer_sale_or_partial_coverage'
      WHEN s.final_balance_due_gbp > 0.01 THEN 'final_balance_due'
      WHEN COALESCE(s.shipment_state, '') <> 'allocated' THEN 'shipment_not_fully_allocated'
      WHEN COALESCE(s.export_evidence_state, '') <> 'accepted_current' THEN 'export_evidence_not_complete'
      WHEN COALESCE(s.pod_delivery_state, '') <> 'accepted_current' THEN 'pod_delivery_not_complete'
      ELSE NULL::text
    END AS completion_blocker,
    s.final_sale_value_exists AS show_final_sale_section_yn,
    (s.final_sale_value_exists AND s.final_balance_due_gbp > 0.01) AS show_balance_due_yn,
    (s.final_sale_value_exists AND s.potential_credit_pending_review_gbp > 0.01) AS show_potential_credit_yn,
    (s.approved_account_credit_gbp > 0.01) AS show_credit_added_to_account_yn
  FROM settled s
  ORDER BY s.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_order_final_sale_settlement_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_order_final_sale_settlement_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.internal_order_final_sale_settlement_v1(uuid) IS
'Canonical final sale settlement read model. Read-only. Keeps accepted-estimate funding threshold separate from final sale settlement, respects partial_posted, signed sale credits, and approved ledger credit boundaries.';

NOTIFY pgrst, 'reload schema';

COMMIT;
