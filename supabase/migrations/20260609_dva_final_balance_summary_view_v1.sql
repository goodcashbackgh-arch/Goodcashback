BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- DVA/card statement-line allocation summary v1 update.
-- Adds confirmed final-balance payment total to the existing summary view.
-- IMPORTANT: existing view columns must remain in their current order.
-- Therefore final_balance_payment_allocated_gbp is appended at the end.

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
END $$;

CREATE OR REPLACE VIEW public.dva_statement_line_allocation_summary_vw AS
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
  COALESCE(SUM(a.allocated_gbp_amount) FILTER (
    WHERE a.allocation_status = 'confirmed'
  ), 0) AS confirmed_allocated_gbp,
  COALESCE(SUM(a.allocated_gbp_amount) FILTER (
    WHERE a.allocation_status IN ('draft', 'held')
  ), 0) AS open_allocated_gbp,
  COALESCE(SUM(a.allocated_gbp_amount) FILTER (
    WHERE a.allocation_status = 'confirmed'
      AND a.allocation_type = 'supplier_invoice'
  ), 0) AS supplier_invoice_allocated_gbp,
  COALESCE(SUM(a.allocated_gbp_amount) FILTER (
    WHERE a.allocation_status = 'confirmed'
      AND a.allocation_type = 'retailer_refund'
  ), 0) AS retailer_refund_allocated_gbp,
  COALESCE(SUM(a.allocated_gbp_amount) FILTER (
    WHERE a.allocation_status = 'confirmed'
      AND a.allocation_type IN ('fx_card_difference', 'bank_fee')
  ), 0) AS fx_card_or_fee_allocated_gbp,
  COALESCE(SUM(a.allocated_gbp_amount) FILTER (
    WHERE a.allocation_status = 'confirmed'
      AND a.allocation_type IN ('exception_hold', 'not_charged_closure', 'unmatched_hold')
  ), 0) AS exception_or_hold_allocated_gbp,
  COUNT(a.id) FILTER (WHERE a.allocation_status <> 'reversed') AS active_allocation_count,
  (
    l.amount_gbp_equivalent
    - COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)
  ) AS confirmed_unallocated_gbp,
  (
    ABS(
      l.amount_gbp_equivalent
      - COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)
    ) < 0.01
  ) AS confirmed_balanced_yn,
  COALESCE(SUM(a.allocated_gbp_amount) FILTER (
    WHERE a.allocation_status = 'confirmed'
      AND a.allocation_type = 'final_balance_payment'
  ), 0) AS final_balance_payment_allocated_gbp
FROM public.dva_statement_lines l
JOIN public.dva_statements s
  ON s.id = l.dva_statement_id
LEFT JOIN public.dva_statement_line_allocations a
  ON a.dva_statement_line_id = l.id
GROUP BY
  l.id,
  l.dva_statement_id,
  s.importer_id,
  l.statement_date,
  l.reference_raw,
  l.direction,
  l.amount_local_ccy,
  l.local_ccy,
  l.fx_rate_applied,
  l.card_markup_pct_applied,
  l.amount_gbp_equivalent,
  l.auth_id_ref,
  l.retailer_name_ref,
  l.match_status;

COMMENT ON VIEW public.dva_statement_line_allocation_summary_vw IS
'Read model showing allocation totals and remaining balance for each DVA/card statement line, including supplier, refund, final-balance, FX/card, fee, and hold allocations.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke check after execution:
-- select * from public.dva_statement_line_allocation_summary_vw limit 5;
