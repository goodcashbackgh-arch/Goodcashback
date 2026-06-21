BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- DVA/card statement-line allocation summary: loyalty-aware read-model patch v1.
-- Purpose:
--   Fix the proven false-unmatched signal where a main-company-bank OUT line
--   consumed by main_bank_completion_loyalty_funding_matches still appears
--   unmatched in dva_statement_line_allocation_summary_vw.
--
-- Scope:
--   Read-model only. No writes to credit ledger, loyalty funding, statement lines,
--   allocations, Sage queues, order funding, shipper AP, or supplier AP.
--
-- Safety:
--   Preserve existing view column order and types. Append new explanatory columns
--   at the end only.

DO $$
BEGIN
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_line_allocations';
  END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_lines';
  END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statements';
  END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.main_bank_completion_loyalty_funding_matches';
  END IF;
END $$;

CREATE OR REPLACE VIEW public.dva_statement_line_allocation_summary_vw AS
WITH allocation_totals AS (
  SELECT
    a.dva_statement_line_id,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_status = 'confirmed'
    ), 0)::numeric AS normal_confirmed_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_status IN ('draft', 'held')
    ), 0)::numeric AS open_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_status = 'confirmed'
        AND a.allocation_type = 'supplier_invoice'
    ), 0)::numeric AS supplier_invoice_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_status = 'confirmed'
        AND a.allocation_type = 'retailer_refund'
    ), 0)::numeric AS retailer_refund_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_status = 'confirmed'
        AND a.allocation_type IN ('fx_card_difference', 'bank_fee')
    ), 0)::numeric AS fx_card_or_fee_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_status = 'confirmed'
        AND a.allocation_type IN ('exception_hold', 'not_charged_closure', 'unmatched_hold')
    ), 0)::numeric AS exception_or_hold_allocated_gbp,
    COUNT(a.id) FILTER (WHERE a.allocation_status <> 'reversed') AS active_allocation_count,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_status = 'confirmed'
        AND a.allocation_type = 'final_balance_payment'
    ), 0)::numeric AS final_balance_payment_allocated_gbp
  FROM public.dva_statement_line_allocations a
  GROUP BY a.dva_statement_line_id
), loyalty_totals AS (
  SELECT
    lm.dva_statement_line_id,
    ROUND(COALESCE(SUM(lm.matched_gbp_amount) FILTER (
      WHERE lm.match_status IN ('confirmed', 'released_available_dashboard_credit')
    ), 0)::numeric, 2) AS loyalty_credit_funding_allocated_gbp,
    COUNT(lm.id) FILTER (
      WHERE lm.match_status IN ('confirmed', 'released_available_dashboard_credit')
    ) AS main_bank_loyalty_match_count
  FROM public.main_bank_completion_loyalty_funding_matches lm
  GROUP BY lm.dva_statement_line_id
), base AS (
  SELECT
    l.id AS dva_statement_line_id,
    l.dva_statement_id,
    s.importer_id,
    l.statement_date,
    l.reference_raw,
    l.direction,
    l.amount_local_ccy,
    l.local_ccy,
    l.fx_rate_applied,
    l.card_markup_pct_applied,
    l.amount_gbp_equivalent AS statement_gbp_amount,
    l.auth_id_ref,
    l.retailer_name_ref,
    l.match_status,
    COALESCE(a.normal_confirmed_allocated_gbp, 0) AS normal_confirmed_allocated_gbp,
    COALESCE(a.open_allocated_gbp, 0) AS open_allocated_gbp,
    COALESCE(a.supplier_invoice_allocated_gbp, 0) AS supplier_invoice_allocated_gbp,
    COALESCE(a.retailer_refund_allocated_gbp, 0) AS retailer_refund_allocated_gbp,
    COALESCE(a.fx_card_or_fee_allocated_gbp, 0) AS fx_card_or_fee_allocated_gbp,
    COALESCE(a.exception_or_hold_allocated_gbp, 0) AS exception_or_hold_allocated_gbp,
    COALESCE(a.active_allocation_count, 0) AS active_allocation_count,
    COALESCE(a.final_balance_payment_allocated_gbp, 0) AS final_balance_payment_allocated_gbp,
    COALESCE(loyalty.loyalty_credit_funding_allocated_gbp, 0) AS loyalty_credit_funding_allocated_gbp,
    COALESCE(loyalty.main_bank_loyalty_match_count, 0) AS main_bank_loyalty_match_count,
    COALESCE(s.statement_account_context, 'importer_dva_card_account') AS statement_account_context,
    s.statement_account_label,
    s.source_bank
  FROM public.dva_statement_lines l
  JOIN public.dva_statements s
    ON s.id = l.dva_statement_id
  LEFT JOIN allocation_totals a
    ON a.dva_statement_line_id = l.id
  LEFT JOIN loyalty_totals loyalty
    ON loyalty.dva_statement_line_id = l.id
)
SELECT
  dva_statement_line_id,
  dva_statement_id,
  importer_id,
  statement_date,
  reference_raw,
  direction,
  amount_local_ccy,
  local_ccy,
  fx_rate_applied,
  card_markup_pct_applied,
  statement_gbp_amount,
  auth_id_ref,
  retailer_name_ref,
  match_status,
  (normal_confirmed_allocated_gbp + loyalty_credit_funding_allocated_gbp) AS confirmed_allocated_gbp,
  open_allocated_gbp,
  supplier_invoice_allocated_gbp,
  retailer_refund_allocated_gbp,
  fx_card_or_fee_allocated_gbp,
  exception_or_hold_allocated_gbp,
  active_allocation_count,
  (
    statement_gbp_amount
    - normal_confirmed_allocated_gbp
    - loyalty_credit_funding_allocated_gbp
  ) AS confirmed_unallocated_gbp,
  (
    ABS(
      statement_gbp_amount
      - normal_confirmed_allocated_gbp
      - loyalty_credit_funding_allocated_gbp
    ) < 0.01
  ) AS confirmed_balanced_yn,
  final_balance_payment_allocated_gbp,
  statement_account_context,
  statement_account_label,
  source_bank,
  loyalty_credit_funding_allocated_gbp,
  main_bank_loyalty_match_count,
  CASE
    WHEN loyalty_credit_funding_allocated_gbp > 0 THEN 'loyalty_credit_funding'
    WHEN final_balance_payment_allocated_gbp > 0 THEN 'final_balance_payment'
    WHEN supplier_invoice_allocated_gbp > 0 THEN 'supplier_invoice'
    WHEN retailer_refund_allocated_gbp > 0 THEN 'retailer_refund'
    WHEN fx_card_or_fee_allocated_gbp > 0 THEN 'fx_card_or_fee'
    WHEN exception_or_hold_allocated_gbp > 0 THEN 'exception_or_hold'
    ELSE NULL
  END AS control_match_reason
FROM base;

COMMENT ON VIEW public.dva_statement_line_allocation_summary_vw IS
'Read model showing allocation totals and remaining balance for each DVA/card/bank statement line. Includes supplier, refund, final-balance, FX/card, fee, hold allocations, and main-bank completion loyalty funding consumption without creating fake allocation rows.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks after execution:
-- 1) Known loyalty-funded line should be balanced by loyalty consumption:
-- select dva_statement_line_id, statement_gbp_amount, loyalty_credit_funding_allocated_gbp,
--        confirmed_allocated_gbp, confirmed_unallocated_gbp, confirmed_balanced_yn, control_match_reason
-- from public.dva_statement_line_allocation_summary_vw
-- where dva_statement_line_id = '6b957851-f0cc-4247-af89-dff88a0ff87e'::uuid;
--
-- 2) The line should not appear in unmatched OUT triage criteria:
-- select *
-- from public.dva_statement_line_allocation_summary_vw
-- where dva_statement_line_id = '6b957851-f0cc-4247-af89-dff88a0ff87e'::uuid
--   and direction = 'out'
--   and confirmed_balanced_yn = false
--   and confirmed_allocated_gbp = 0;
