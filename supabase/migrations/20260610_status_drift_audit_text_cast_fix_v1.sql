BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
      o.order_ref::text AS order_ref,
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
      COALESCE(
        f.funded_total_gbp,
        COALESCE(f.confirmed_dva_funding_gbp, 0) + COALESCE(f.applied_credit_gbp, 0),
        0
      )::numeric AS accepted_estimate_amount_received_gbp
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
      cs.current_stage::text AS current_stage,
      cs.next_action::text AS next_action,
      aus.importer_status_label::text AS importer_status_label,
      aus.importer_next_action::text AS importer_next_action
    FROM active_orders o
    LEFT JOIN funding f ON f.order_id = o.order_id
    LEFT JOIN final_balance_payments fbp ON fbp.order_id = o.order_id
    LEFT JOIN sales s ON s.order_id = o.order_id
    LEFT JOIN canonical_status cs ON cs.order_id = o.order_id
    LEFT JOIN audience_status aus ON aus.order_id = o.order_id
  )
  SELECT
    a.order_id,
    a.order_ref::text,
    a.importer_name::text,
    a.retailer_name::text,
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
