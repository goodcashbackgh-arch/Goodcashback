-- =============================================================================
-- supplier_line_accounting_coding_v4_invoice_vat_totals.sql
-- Multi Tenant Platform Build — invoice net/VAT/gross reconciliation totals
--
-- Run after supplier_line_accounting_coding_v3_bulk_save.sql.
--
-- Purpose:
--   Compare coded net/VAT/gross against invoice OCR net/VAT/gross.
--   Drops/recreates the view to avoid Postgres CREATE OR REPLACE restrictions
--   on existing view column type modifiers/order.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DROP VIEW IF EXISTS public.supplier_invoice_accounting_coding_totals_vw;

CREATE VIEW public.supplier_invoice_accounting_coding_totals_vw AS
WITH line_codes AS (
  SELECT
    sil.supplier_invoice_id,
    COALESCE(SUM(codes.net_amount_gbp), 0)::numeric(12,2) AS coded_net_gbp,
    COALESCE(SUM(codes.vat_amount_gbp), 0)::numeric(12,2) AS coded_vat_gbp,
    COALESCE(SUM(codes.gross_amount_gbp), 0)::numeric(12,2) AS coded_gross_gbp,
    COUNT(*) FILTER (WHERE lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1'))::int AS progressed_line_count,
    COUNT(codes.id)::int AS coded_line_count
  FROM public.supplier_invoice_lines sil
  LEFT JOIN public.supplier_invoice_line_accounting_codes codes
    ON codes.supplier_invoice_line_id = sil.id
  GROUP BY sil.supplier_invoice_id
), adjustment_codes AS (
  SELECT
    aal.supplier_invoice_id,
    COALESCE(SUM(aal.net_amount_gbp), 0)::numeric(12,2) AS adjustment_net_gbp,
    COALESCE(SUM(aal.vat_amount_gbp), 0)::numeric(12,2) AS adjustment_vat_gbp,
    COALESCE(SUM(aal.gross_amount_gbp), 0)::numeric(12,2) AS adjustment_gross_gbp,
    COUNT(*)::int AS adjustment_line_count
  FROM public.supplier_invoice_accounting_adjustment_lines aal
  GROUP BY aal.supplier_invoice_id
), invoice_ocr AS (
  SELECT
    si.id AS supplier_invoice_id,
    COALESCE(
      NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_net,value}', '')::numeric,
      CASE
        WHEN NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_amount,value}', '') IS NOT NULL
         AND NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_tax,value}', '') IS NOT NULL
        THEN (NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_amount,value}', '')::numeric - NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_tax,value}', '')::numeric)
        ELSE NULL
      END
    )::numeric(12,2) AS invoice_net_gbp,
    NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_tax,value}', '')::numeric(12,2) AS invoice_vat_gbp,
    COALESCE(
      si.ocr_invoice_total_gbp,
      NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_amount,value}', '')::numeric
    )::numeric(12,2) AS invoice_gross_gbp
  FROM public.supplier_invoices si
)
SELECT
  si.id AS supplier_invoice_id,
  si.order_id,
  io.invoice_gross_gbp AS accepted_invoice_gross_gbp,
  (COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0))::numeric(12,2) AS total_coded_net_gbp,
  (COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0))::numeric(12,2) AS total_coded_vat_gbp,
  (COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0))::numeric(12,2) AS total_coded_gross_gbp,
  COALESCE(ac.adjustment_gross_gbp, 0)::numeric(12,2) AS adjustment_gross_gbp,
  COALESCE(lc.progressed_line_count, 0) AS progressed_line_count,
  COALESCE(lc.coded_line_count, 0) AS coded_line_count,
  COALESCE(ac.adjustment_line_count, 0) AS adjustment_line_count,
  (COALESCE(lc.progressed_line_count, 0) = COALESCE(lc.coded_line_count, 0)) AS all_progressed_lines_coded_yn,
  (abs((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - COALESCE(io.invoice_gross_gbp, 0)) <= 0.01) AS gross_reconciled_to_invoice_yn,
  ((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - COALESCE(io.invoice_gross_gbp, 0))::numeric(12,2) AS gross_variance_gbp,
  io.invoice_net_gbp AS accepted_invoice_net_gbp,
  io.invoice_vat_gbp AS accepted_invoice_vat_gbp,
  (abs((COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0)) - COALESCE(io.invoice_net_gbp, 0)) <= 0.01) AS net_reconciled_to_invoice_yn,
  (abs((COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0)) - COALESCE(io.invoice_vat_gbp, 0)) <= 0.01) AS vat_reconciled_to_invoice_yn,
  ((COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0)) - COALESCE(io.invoice_net_gbp, 0))::numeric(12,2) AS net_variance_gbp,
  ((COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0)) - COALESCE(io.invoice_vat_gbp, 0))::numeric(12,2) AS vat_variance_gbp
FROM public.supplier_invoices si
LEFT JOIN invoice_ocr io ON io.supplier_invoice_id = si.id
LEFT JOIN line_codes lc ON lc.supplier_invoice_id = si.id
LEFT JOIN adjustment_codes ac ON ac.supplier_invoice_id = si.id;

COMMIT;
