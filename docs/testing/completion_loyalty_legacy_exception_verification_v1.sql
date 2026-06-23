-- Completion loyalty legacy exception verification v1
-- Purpose: classify legacy released OUT-only completion-loyalty rows after the stricter OUT+IN pairing contract.
-- Run in Supabase SQL Editor after any metadata cleanup.
-- This script is read-only and finishes with ROLLBACK.

BEGIN;

SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';

CREATE TEMP TABLE loyalty_legacy_exception_report (
  seq bigint GENERATED ALWAYS AS IDENTITY,
  status text NOT NULL CHECK (status IN ('PASS','WARN','INFO')),
  check_name text NOT NULL,
  rows_found bigint,
  amount_gbp numeric,
  finding text,
  sample jsonb
) ON COMMIT DROP;

WITH legacy_rows AS (
  SELECT
    lm.id AS loyalty_match_id,
    o.order_ref,
    lm.completed_order_id,
    lm.importer_id,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    lm.matched_gbp_amount,
    lm.match_status,
    lm.transfer_pair_status,
    lm.dva_statement_line_id AS source_out_statement_line_id,
    lm.destination_in_statement_line_id,
    lm.credit_ledger_id,
    lm.variance_reason,
    lm.notes,
    lm.created_at,
    CASE
      WHEN lm.variance_reason = 'documented_legacy_test_out_only_no_destination_in_available'
       AND coalesce(lm.notes, '') ILIKE '%No exact £13.50 importer DVA/card IN line exists%'
       AND coalesce(lm.notes, '') ILIKE '%No duplicate credit, no order funding event, no Sage/VAT action%'
      THEN true
      ELSE false
    END AS documented_legacy_exception
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  LEFT JOIN public.importers i ON i.id = lm.importer_id
  WHERE lm.match_status = 'released_available_dashboard_credit'
    AND lm.transfer_pair_status = 'legacy_released_out_only'
    AND lm.destination_in_statement_line_id IS NULL
), undocumented AS (
  SELECT * FROM legacy_rows WHERE documented_legacy_exception = false
), documented AS (
  SELECT * FROM legacy_rows WHERE documented_legacy_exception = true
)
INSERT INTO loyalty_legacy_exception_report(status, check_name, rows_found, amount_gbp, finding, sample)
SELECT
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'WARN' END AS status,
  'undocumented legacy OUT-only loyalty rows' AS check_name,
  count(*) AS rows_found,
  round(coalesce(sum(matched_gbp_amount), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'No undocumented legacy OUT-only completion-loyalty rows remain.'
    ELSE 'One or more legacy OUT-only completion-loyalty rows are still missing a documented exception note.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(undocumented) ORDER BY created_at DESC) FILTER (WHERE loyalty_match_id IS NOT NULL), '[]'::jsonb) AS sample
FROM undocumented;

WITH legacy_rows AS (
  SELECT
    lm.id AS loyalty_match_id,
    o.order_ref,
    lm.completed_order_id,
    lm.importer_id,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    lm.matched_gbp_amount,
    lm.match_status,
    lm.transfer_pair_status,
    lm.dva_statement_line_id AS source_out_statement_line_id,
    lm.destination_in_statement_line_id,
    lm.credit_ledger_id,
    lm.variance_reason,
    lm.notes,
    lm.created_at,
    CASE
      WHEN lm.variance_reason = 'documented_legacy_test_out_only_no_destination_in_available'
       AND coalesce(lm.notes, '') ILIKE '%No exact £13.50 importer DVA/card IN line exists%'
       AND coalesce(lm.notes, '') ILIKE '%No duplicate credit, no order funding event, no Sage/VAT action%'
      THEN true
      ELSE false
    END AS documented_legacy_exception
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  LEFT JOIN public.importers i ON i.id = lm.importer_id
  WHERE lm.match_status = 'released_available_dashboard_credit'
    AND lm.transfer_pair_status = 'legacy_released_out_only'
    AND lm.destination_in_statement_line_id IS NULL
), documented AS (
  SELECT * FROM legacy_rows WHERE documented_legacy_exception = true
)
INSERT INTO loyalty_legacy_exception_report(status, check_name, rows_found, amount_gbp, finding, sample)
SELECT
  'INFO' AS status,
  'documented legacy OUT-only test exceptions' AS check_name,
  count(*) AS rows_found,
  round(coalesce(sum(matched_gbp_amount), 0)::numeric, 2) AS amount_gbp,
  'Documented legacy test rows remain visible as control evidence. They must not be paired to unrelated IN lines or used to create duplicate credit.' AS finding,
  coalesce(jsonb_agg(to_jsonb(documented) ORDER BY created_at DESC) FILTER (WHERE loyalty_match_id IS NOT NULL), '[]'::jsonb) AS sample
FROM documented;

SELECT *
FROM loyalty_legacy_exception_report
ORDER BY seq;

SELECT
  status,
  count(*) AS checks,
  jsonb_agg(jsonb_build_object('check', check_name, 'finding', finding, 'rows_found', rows_found, 'amount_gbp', amount_gbp) ORDER BY seq) AS details
FROM loyalty_legacy_exception_report
GROUP BY status
ORDER BY CASE status WHEN 'WARN' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END;

ROLLBACK;
