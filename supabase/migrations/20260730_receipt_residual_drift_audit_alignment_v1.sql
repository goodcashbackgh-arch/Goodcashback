BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Align the release-blocking drift audit with the repaired receipt-residual
-- audience balance without changing canonical settlement semantics.
--
-- Canonical status is still checked against the established canonical formula.
-- Audience status is checked against canonical status less only the active,
-- non-reversed physical receipt residual that still belongs to the order after
-- exact linked overfunding credit conversion.
--
-- No funding, DVA, FX/card, sales, credit, supplier, tracking or business-data
-- write path is changed by this migration.

DO $$
DECLARE
  v_audit_definition text;
  v_normalized_definition text;
  v_result_signature text;
  v_prosecdef boolean;
  v_proconfig text[];
  v_is_pre_alignment boolean;
  v_is_post_alignment boolean;
BEGIN
  IF to_regprocedure('public.internal_order_status_drift_audit_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_order_status_drift_audit_v1()';
  END IF;

  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
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
    v_audit_definition,
    v_result_signature,
    v_prosecdef,
    v_proconfig
  FROM pg_proc p
  WHERE p.oid = 'public.internal_order_status_drift_audit_v1()'::regprocedure;

  v_normalized_definition := regexp_replace(v_audit_definition, '\s+', ' ', 'g');

  IF v_result_signature IS DISTINCT FROM
    'TABLE(order_id uuid, order_ref text, importer_name text, retailer_name text, drift_result text, final_sale_value_gbp numeric, legacy_local_balance_due_gbp numeric, expected_canonical_balance_due_gbp numeric, canonical_status_balance_due_gbp numeric, audience_balance_due_gbp numeric, confirmed_final_balance_payment_gbp numeric, details jsonb)'
  THEN
    RAISE EXCEPTION 'Status drift audit return signature changed; stop before aligning receipt-residual expectations: %', v_result_signature;
  END IF;

  IF NOT COALESCE(v_prosecdef, false)
     OR NOT COALESCE(v_proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[]
  THEN
    RAISE EXCEPTION 'Status drift audit execution boundary changed; stop before aligning receipt-residual expectations.';
  END IF;

  IF position('if auth.uid() is null then' IN v_normalized_definition) = 0
     OR position('if not public.is_active_staff() then' IN v_normalized_definition) = 0
  THEN
    RAISE EXCEPTION 'Status drift audit authentication/staff boundary changed; stop before aligning receipt-residual expectations.';
  END IF;

  IF position('select * from public.order_audience_status_v1(null)' IN v_normalized_definition) = 0
  THEN
    RAISE EXCEPTION 'Status drift audit no longer calls the canonical audience RPC directly; stop before patching.';
  END IF;

  IF position(
       'greatest(coalesce(s.signed_final_sale_value_gbp, 0) - coalesce(f.accepted_estimate_amount_received_gbp, 0) - coalesce(fbp.confirmed_final_balance_payment_gbp, 0), 0)'
       IN v_normalized_definition
     ) = 0
     OR position(
       'abs(a.canonical_status_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01'
       IN v_normalized_definition
     ) = 0
  THEN
    RAISE EXCEPTION 'Established canonical-status drift formula changed; stop before aligning audience expectations.';
  END IF;

  v_is_pre_alignment := position(
    'abs(a.audience_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01'
    IN v_normalized_definition
  ) > 0;

  v_is_post_alignment :=
    position('expected_audience_balance_due_gbp' IN v_normalized_definition) > 0
    AND position(
      'abs(a.audience_balance_due_gbp - a.expected_audience_balance_due_gbp) > 0.01'
      IN v_normalized_definition
    ) > 0
    AND position('active_pending_receipt_gbp' IN v_normalized_definition) > 0
    AND position('linked_confirmed_credit_gbp' IN v_normalized_definition) > 0
    AND position('still_order_applied_residual_gbp' IN v_normalized_definition) > 0
    AND position('c.entry_type = ''manual_credit''' IN v_normalized_definition) > 0
    AND position('c.source_type = ''overfunding''' IN v_normalized_definition) > 0
    AND position('c.source_table = ''orders''' IN v_normalized_definition) > 0
    AND position('c.source_entity_type = ''order''' IN v_normalized_definition) > 0;

  IF NOT v_is_pre_alignment AND NOT v_is_post_alignment THEN
    RAISE EXCEPTION 'Drift audit is neither the proven pre-alignment form nor the proven post-alignment form; stop before patching.';
  END IF;
END $$;

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
  ), active_pending AS (
    SELECT
      p.order_id,
      ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS active_pending_receipt_gbp
    FROM public.order_pending_funding_surplus p
    JOIN active_orders o ON o.order_id = p.order_id
    WHERE p.status IN ('pending_evidence', 'credit_confirmed')
      AND p.reversed_at IS NULL
    GROUP BY p.order_id
  ), distinct_credit_links AS (
    SELECT DISTINCT
      p.order_id,
      p.importer_id,
      p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    JOIN active_orders o ON o.order_id = p.order_id
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
      ROUND(
        CASE
          WHEN COALESCE(ap.active_pending_receipt_gbp, 0) > 0.01
          THEN GREATEST(
            COALESCE(cs.final_balance_due_gbp, 0)
              - GREATEST(
                  COALESCE(ap.active_pending_receipt_gbp, 0)
                    - COALESCE(lcc.linked_confirmed_credit_gbp, 0),
                  0
                ),
            0
          )
          ELSE COALESCE(cs.final_balance_due_gbp, 0)
        END::numeric,
        2
      ) AS expected_audience_balance_due_gbp,
      COALESCE(aus.canonical_balance_due_gbp, 0)::numeric AS audience_balance_due_gbp,
      COALESCE(fbp.confirmed_final_balance_payment_gbp, 0)::numeric AS confirmed_final_balance_payment_gbp,
      COALESCE(ap.active_pending_receipt_gbp, 0)::numeric AS active_pending_receipt_gbp,
      COALESCE(lcc.linked_confirmed_credit_gbp, 0)::numeric AS linked_confirmed_credit_gbp,
      ROUND(
        GREATEST(
          COALESCE(ap.active_pending_receipt_gbp, 0)
            - COALESCE(lcc.linked_confirmed_credit_gbp, 0),
          0
        )::numeric,
        2
      ) AS still_order_applied_residual_gbp,
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
    LEFT JOIN active_pending ap ON ap.order_id = o.order_id
    LEFT JOIN linked_confirmed_credit lcc ON lcc.order_id = o.order_id
  )
  SELECT
    a.order_id,
    a.order_ref::text,
    a.importer_name::text,
    a.retailer_name::text,
    CASE
      WHEN ABS(a.canonical_status_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01 THEN 'CANONICAL_STATUS_BALANCE_DRIFT'
      WHEN ABS(a.audience_balance_due_gbp - a.expected_audience_balance_due_gbp) > 0.01
        AND ABS(a.audience_balance_due_gbp - a.legacy_local_balance_due_gbp) <= 0.01 THEN 'LOCAL_PAGE_BALANCE_DRIFT'
      WHEN ABS(a.audience_balance_due_gbp - a.expected_audience_balance_due_gbp) > 0.01 THEN 'AUDIENCE_STATUS_DRIFT'
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
      'importer_next_action', a.importer_next_action,
      'legacy_formula_risk_gbp', a.legacy_local_balance_due_gbp,
      'expected_canonical_balance_due_gbp', a.expected_canonical_balance_due_gbp,
      'expected_audience_balance_due_gbp', a.expected_audience_balance_due_gbp,
      'active_pending_receipt_gbp', a.active_pending_receipt_gbp,
      'linked_confirmed_credit_gbp', a.linked_confirmed_credit_gbp,
      'still_order_applied_residual_gbp', a.still_order_applied_residual_gbp
    ) AS details
  FROM audit a
  WHERE ABS(a.canonical_status_balance_due_gbp - a.expected_canonical_balance_due_gbp) > 0.01
     OR ABS(a.audience_balance_due_gbp - a.expected_audience_balance_due_gbp) > 0.01
  ORDER BY a.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_order_status_drift_audit_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.internal_order_status_drift_audit_v1() TO authenticated;

COMMENT ON FUNCTION public.internal_order_status_drift_audit_v1() IS
'Release-blocking order-status drift audit. Canonical status remains checked against the established canonical settlement formula; audience balance is checked against canonical status less only active non-reversed physical receipt residual still belonging to the order after exact linked overfunding-credit conversion. FX/card and attributed-receipt amounts are excluded.';

NOTIFY pgrst, 'reload schema';

COMMIT;
