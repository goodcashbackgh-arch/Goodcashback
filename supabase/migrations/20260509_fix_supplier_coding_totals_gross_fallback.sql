-- Fix supplier invoice accounting coding totals for operator-entered/manual invoices.
-- Purpose:
--   1. Use supplier_invoice_financial_summary.invoice_total_gbp as accepted gross fallback
--      where OCR header gross is unavailable.
--   2. Avoid treating missing invoice net/VAT as zero variance.
--   3. Avoid zero-progressed-line invoices passing all_progressed_lines_coded_yn.
--
-- This does not approve, post, or change any invoice/line state. It only corrects
-- the readiness totals view used by supplier coding save/approval guards.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DROP VIEW IF EXISTS public.supplier_invoice_accounting_coding_totals_vw;

CREATE VIEW public.supplier_invoice_accounting_coding_totals_vw AS
WITH line_codes AS (
  SELECT
    sil.supplier_invoice_id,
    COALESCE(SUM(codes.net_amount_gbp) FILTER (
      WHERE lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
    ), 0)::numeric(12,2) AS coded_net_gbp,
    COALESCE(SUM(codes.vat_amount_gbp) FILTER (
      WHERE lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
    ), 0)::numeric(12,2) AS coded_vat_gbp,
    COALESCE(SUM(codes.gross_amount_gbp) FILTER (
      WHERE lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
    ), 0)::numeric(12,2) AS coded_gross_gbp,
    COUNT(*) FILTER (
      WHERE lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
    )::int AS progressed_line_count,
    COUNT(codes.id) FILTER (
      WHERE lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
    )::int AS coded_line_count
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
), invoice_summary AS (
  SELECT
    si.id AS supplier_invoice_id,
    COALESCE(
      NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_net,value}', '')::numeric,
      CASE
        WHEN NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_amount,value}', '') IS NOT NULL
         AND NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_tax,value}', '') IS NOT NULL
        THEN (
          NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_amount,value}', '')::numeric
          - NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_tax,value}', '')::numeric
        )
        ELSE NULL
      END
    )::numeric(12,2) AS invoice_net_gbp,
    NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_tax,value}', '')::numeric(12,2) AS invoice_vat_gbp,
    COALESCE(
      si.ocr_invoice_total_gbp,
      NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_amount,value}', '')::numeric,
      fs.invoice_total_gbp
    )::numeric(12,2) AS invoice_gross_gbp
  FROM public.supplier_invoices si
  LEFT JOIN public.supplier_invoice_financial_summary fs
    ON fs.supplier_invoice_id = si.id
)
SELECT
  si.id AS supplier_invoice_id,
  si.order_id,
  inv.invoice_gross_gbp AS accepted_invoice_gross_gbp,
  (COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0))::numeric(12,2) AS total_coded_net_gbp,
  (COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0))::numeric(12,2) AS total_coded_vat_gbp,
  (COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0))::numeric(12,2) AS total_coded_gross_gbp,
  COALESCE(ac.adjustment_gross_gbp, 0)::numeric(12,2) AS adjustment_gross_gbp,
  COALESCE(lc.progressed_line_count, 0) AS progressed_line_count,
  COALESCE(lc.coded_line_count, 0) AS coded_line_count,
  COALESCE(ac.adjustment_line_count, 0) AS adjustment_line_count,
  (
    COALESCE(lc.progressed_line_count, 0) > 0
    AND COALESCE(lc.progressed_line_count, 0) = COALESCE(lc.coded_line_count, 0)
  ) AS all_progressed_lines_coded_yn,
  (
    inv.invoice_gross_gbp IS NOT NULL
    AND abs((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - inv.invoice_gross_gbp) <= 0.01
  ) AS gross_reconciled_to_invoice_yn,
  CASE
    WHEN inv.invoice_gross_gbp IS NULL THEN NULL
    ELSE ((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - inv.invoice_gross_gbp)::numeric(12,2)
  END AS gross_variance_gbp,
  inv.invoice_net_gbp AS accepted_invoice_net_gbp,
  inv.invoice_vat_gbp AS accepted_invoice_vat_gbp,
  (
    inv.invoice_net_gbp IS NULL
    OR abs((COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0)) - inv.invoice_net_gbp) <= 0.01
  ) AS net_reconciled_to_invoice_yn,
  (
    inv.invoice_vat_gbp IS NULL
    OR abs((COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0)) - inv.invoice_vat_gbp) <= 0.01
  ) AS vat_reconciled_to_invoice_yn,
  CASE
    WHEN inv.invoice_net_gbp IS NULL THEN NULL
    ELSE ((COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0)) - inv.invoice_net_gbp)::numeric(12,2)
  END AS net_variance_gbp,
  CASE
    WHEN inv.invoice_vat_gbp IS NULL THEN NULL
    ELSE ((COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0)) - inv.invoice_vat_gbp)::numeric(12,2)
  END AS vat_variance_gbp
FROM public.supplier_invoices si
LEFT JOIN invoice_summary inv ON inv.supplier_invoice_id = si.id
LEFT JOIN line_codes lc ON lc.supplier_invoice_id = si.id
LEFT JOIN adjustment_codes ac ON ac.supplier_invoice_id = si.id;

GRANT SELECT ON public.supplier_invoice_accounting_coding_totals_vw TO authenticated;

COMMIT;
