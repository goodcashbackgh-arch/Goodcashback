BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Supplier Payment Funding Provenance Governing Addendum v1 — micro implementation 2.
-- Read-only readiness function and candidate/status view only.

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoices'; END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoice_lines'; END IF;
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_events'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regclass('public.dva_reconciliation') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_reconciliation'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.order_funding_position_vw') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_position_vw'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_supplier_payment_readiness_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  order_type text,
  funding_required_yn boolean,
  threshold_met_yn boolean,
  funding_provenance_ready_yn boolean,
  supplier_payment_ready_yn boolean,
  blocker text,
  funding_total_gbp numeric,
  gap_remaining_gbp numeric,
  credit_event_count integer,
  broken_credit_event_count integer,
  loyalty_credit_event_count integer,
  unresolved_loyalty_event_count integer,
  cash_funding_event_count integer,
  broken_cash_funding_event_count integer,
  manual_adjustment_event_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH order_scope AS (
    SELECT o.id AS order_id, o.importer_id, COALESCE(o.order_type, 'original')::text AS order_type
    FROM public.orders o
    WHERE o.id = p_order_id
  ), funding_position AS (
    SELECT
      os.order_id,
      os.importer_id,
      os.order_type,
      (os.order_type = 'original') AS funding_required_yn,
      CASE WHEN os.order_type = 'original' THEN COALESCE(ofp.threshold_met_yn, false) ELSE true END AS threshold_met_yn,
      ROUND(COALESCE(ofp.funded_total_gbp, 0)::numeric, 2) AS funding_total_gbp,
      CASE WHEN os.order_type = 'original' THEN ROUND(COALESCE(ofp.gap_remaining_gbp, 0)::numeric, 2) ELSE 0::numeric END AS gap_remaining_gbp
    FROM order_scope os
    LEFT JOIN public.order_funding_position_vw ofp ON ofp.order_id = os.order_id
  ), credit_events AS (
    SELECT
      ofe.id AS funding_event_id,
      ofe.source_entity_type AS event_source_entity_type,
      ofe.source_entity_id AS debit_id,
      debit.importer_id AS debit_importer_id,
      debit.direction AS debit_direction,
      debit.source_type::text AS debit_source_type,
      debit.applied_to_order_id,
      debit.linked_order_id,
      debit.source_table::text AS debit_source_table,
      debit.source_id AS debit_source_id,
      debit.source_entity_type::text AS debit_source_entity_type,
      debit.source_entity_id AS debit_source_entity_id
    FROM public.order_funding_events ofe
    LEFT JOIN public.importer_credit_ledger debit ON debit.id = ofe.source_entity_id
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'credit_applied'
      AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
  ), credit_checks AS (
    SELECT
      ce.*,
      credit.id AS resolved_credit_id,
      credit.importer_id AS credit_importer_id,
      credit.direction AS credit_direction,
      credit.source_type::text AS credit_source_type,
      CASE
        WHEN ce.event_source_entity_type IS DISTINCT FROM 'importer_credit_ledger' THEN 'credit_event_application_source_type_invalid'
        WHEN ce.debit_id IS NULL OR ce.debit_importer_id IS NULL THEN 'credit_event_missing_application_debit'
        WHEN ce.debit_importer_id IS DISTINCT FROM fp.importer_id THEN 'credit_application_importer_mismatch'
        WHEN ce.debit_direction IS DISTINCT FROM 'debit' THEN 'credit_application_row_not_debit'
        WHEN ce.debit_source_type IS DISTINCT FROM 'credit_application' THEN 'credit_application_source_type_invalid'
        WHEN COALESCE(ce.applied_to_order_id, ce.linked_order_id) IS DISTINCT FROM p_order_id THEN 'credit_application_order_link_invalid'
        WHEN ce.debit_source_table IS DISTINCT FROM 'importer_credit_ledger'
          OR ce.debit_source_entity_type IS DISTINCT FROM 'importer_credit_ledger'
          OR ce.debit_source_id IS NULL
          OR ce.debit_source_entity_id IS NULL THEN 'credit_application_source_lot_link_missing'
        WHEN ce.debit_source_id IS DISTINCT FROM ce.debit_source_entity_id THEN 'credit_application_source_lot_links_disagree'
        WHEN credit.id IS NULL THEN 'credit_application_source_lot_not_found'
        WHEN credit.importer_id IS DISTINCT FROM fp.importer_id THEN 'credit_application_source_lot_importer_mismatch'
        WHEN credit.direction IS DISTINCT FROM 'credit' THEN 'credit_application_source_lot_not_credit'
        ELSE NULL::text
      END AS credit_blocker
    FROM credit_events ce
    CROSS JOIN funding_position fp
    LEFT JOIN public.importer_credit_ledger credit ON credit.id = ce.debit_source_id
  ), loyalty_checks AS (
    SELECT
      cc.funding_event_id,
      COUNT(lm.id) FILTER (
        WHERE lm.match_status = 'released_available_dashboard_credit'
          AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
          AND lm.destination_in_statement_line_id IS NOT NULL
          AND resolver.blocker IS NULL
          AND resolver.resolved_wallet_code IN ('virtual_gbp_wallet', 'dva_ghs_wallet')
      )::integer AS valid_match_count,
      COUNT(lm.id) FILTER (
        WHERE lm.match_status = 'released_available_dashboard_credit'
          AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
      )::integer AS released_match_count
    FROM credit_checks cc
    LEFT JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = cc.resolved_credit_id
     AND lm.importer_id = (SELECT importer_id FROM funding_position)
    LEFT JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(lm.destination_in_statement_line_id) resolver
      ON lm.destination_in_statement_line_id IS NOT NULL
    WHERE cc.credit_source_type = 'completion_loyalty_reward'
    GROUP BY cc.funding_event_id
  ), cash_events AS (
    SELECT
      ofe.id AS funding_event_id,
      ofe.source_entity_type,
      ofe.source_entity_id,
      dr.id AS reconciliation_id,
      dr.order_id AS reconciliation_order_id,
      dr.reconciliation_type,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS event_amount_gbp,
      ROUND(ABS(COALESCE(dr.reconciled_gbp_amount, 0))::numeric, 2) AS reconciliation_amount_gbp
    FROM public.order_funding_events ofe
    LEFT JOIN public.dva_reconciliation dr ON dr.id = ofe.source_entity_id
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'funding_contribution'
      AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
  ), aggregates AS (
    SELECT
      fp.*,
      (SELECT COUNT(*) FROM credit_checks)::integer AS credit_event_count,
      (SELECT COUNT(*) FROM credit_checks WHERE credit_blocker IS NOT NULL)::integer AS broken_credit_event_count,
      (SELECT COUNT(*) FROM credit_checks WHERE credit_source_type = 'completion_loyalty_reward')::integer AS loyalty_credit_event_count,
      (
        SELECT COUNT(*)
        FROM credit_checks cc
        LEFT JOIN loyalty_checks lc ON lc.funding_event_id = cc.funding_event_id
        WHERE cc.credit_source_type = 'completion_loyalty_reward'
          AND (COALESCE(lc.valid_match_count, 0) <> 1 OR COALESCE(lc.released_match_count, 0) <> 1)
      )::integer AS unresolved_loyalty_event_count,
      (SELECT COUNT(*) FROM cash_events)::integer AS cash_funding_event_count,
      (
        SELECT COUNT(*) FROM cash_events ce
        WHERE ce.source_entity_type IS DISTINCT FROM 'dva_reconciliation'
           OR ce.source_entity_id IS NULL
           OR ce.reconciliation_id IS NULL
           OR ce.reconciliation_order_id IS DISTINCT FROM p_order_id
           OR ce.reconciliation_type IS DISTINCT FROM 'order_funding'
           OR ABS(ce.event_amount_gbp - ce.reconciliation_amount_gbp) > 0.01
      )::integer AS broken_cash_funding_event_count,
      (
        SELECT COUNT(*) FROM public.order_funding_events ofe
        WHERE ofe.order_id = p_order_id
          AND ofe.event_type = 'manual_adjustment'
          AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
      )::integer AS manual_adjustment_event_count
    FROM funding_position fp
  ), resolved AS (
    SELECT
      a.*,
      CASE
        WHEN a.order_type = 'original' AND NOT a.threshold_met_yn THEN 'order_not_fully_funded'
        WHEN a.broken_credit_event_count > 0 THEN (
          SELECT cc.credit_blocker FROM credit_checks cc
          WHERE cc.credit_blocker IS NOT NULL
          ORDER BY cc.funding_event_id LIMIT 1
        )
        WHEN a.unresolved_loyalty_event_count > 0 THEN CASE
          WHEN EXISTS (
            SELECT 1 FROM loyalty_checks lc
            WHERE COALESCE(lc.valid_match_count, 0) > 1 OR COALESCE(lc.released_match_count, 0) > 1
          ) THEN 'source_funding_ambiguous_for_supplier_payment_bank_resolution'
          ELSE 'completion_loyalty_released_pairing_or_wallet_unresolved'
        END
        WHEN a.broken_cash_funding_event_count > 0 THEN 'cash_funding_dva_reconciliation_link_invalid'
        WHEN a.manual_adjustment_event_count > 0 THEN 'manual_adjustment_source_unresolved'
        ELSE NULL::text
      END AS blocker
    FROM aggregates a
  )
  SELECT
    r.order_id,
    r.order_type,
    r.funding_required_yn,
    r.threshold_met_yn,
    (r.blocker IS NULL) AS funding_provenance_ready_yn,
    (r.blocker IS NULL) AS supplier_payment_ready_yn,
    r.blocker,
    r.funding_total_gbp,
    r.gap_remaining_gbp,
    r.credit_event_count,
    r.broken_credit_event_count,
    r.loyalty_credit_event_count,
    r.unresolved_loyalty_event_count,
    r.cash_funding_event_count,
    r.broken_cash_funding_event_count,
    r.manual_adjustment_event_count
  FROM resolved r;
$$;

COMMENT ON FUNCTION public.internal_supplier_payment_readiness_v1(uuid) IS
'Read-only supplier-payment funding/provenance gate. Original orders require threshold_met_yn plus exact credit-lot, released completion-loyalty and DVA reconciliation provenance. Replacement children remain funding-not-required but fail closed on any present unresolved provenance.';

REVOKE ALL ON FUNCTION public.internal_supplier_payment_readiness_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supplier_payment_readiness_v1(uuid) TO authenticated;

CREATE OR REPLACE VIEW public.supplier_payment_candidate_status_vw AS
SELECT
  si.id AS supplier_invoice_id,
  si.order_id,
  o.order_ref,
  o.importer_id,
  o.retailer_id,
  COALESCE(o.order_type, 'original')::text AS order_type,
  COALESCE(si.ocr_invoice_ref, si.invoice_ref)::text AS invoice_ref,
  si.review_status::text AS review_status,
  totals.invoice_total_gbp,
  allocations.confirmed_matched_gbp,
  ROUND(GREATEST(totals.invoice_total_gbp - allocations.confirmed_matched_gbp, 0)::numeric, 2) AS remaining_unmatched_gbp,
  readiness.funding_required_yn,
  readiness.threshold_met_yn,
  readiness.funding_provenance_ready_yn,
  readiness.supplier_payment_ready_yn,
  CASE
    WHEN si.review_status IS DISTINCT FROM 'approved_current' THEN 'supplier_invoice_not_approved_current'
    WHEN totals.invoice_total_gbp <= 0 THEN 'supplier_invoice_total_missing_or_non_positive'
    WHEN ROUND(GREATEST(totals.invoice_total_gbp - allocations.confirmed_matched_gbp, 0)::numeric, 2) <= 0 THEN 'supplier_invoice_fully_matched'
    ELSE readiness.blocker
  END AS blocker,
  (
    si.review_status = 'approved_current'
    AND totals.invoice_total_gbp > 0
    AND ROUND(GREATEST(totals.invoice_total_gbp - allocations.confirmed_matched_gbp, 0)::numeric, 2) > 0
    AND readiness.supplier_payment_ready_yn
  ) AS selectable_yn
FROM public.supplier_invoices si
JOIN public.orders o ON o.id = si.order_id
JOIN LATERAL (
  SELECT ROUND(COALESCE(
    si.ocr_invoice_total_gbp,
    si.reconciliation_gbp_total,
    SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)),
    0
  )::numeric, 2) AS invoice_total_gbp
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = si.id
) totals ON true
JOIN LATERAL (
  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) AS confirmed_matched_gbp
  FROM public.dva_statement_line_allocations a
  WHERE a.supplier_invoice_id = si.id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed'
) allocations ON true
JOIN LATERAL public.internal_supplier_payment_readiness_v1(si.order_id) readiness ON true
WHERE public.is_active_staff();

COMMENT ON VIEW public.supplier_payment_candidate_status_vw IS
'Read-only governed supplier-payment invoice status exposing invoice total, confirmed matched amount, remaining unmatched amount, readiness, blocker and selectability.';

REVOKE ALL ON public.supplier_payment_candidate_status_vw FROM PUBLIC;
GRANT SELECT ON public.supplier_payment_candidate_status_vw TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
