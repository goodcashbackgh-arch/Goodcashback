-- Include active parked non-physical financial invoice lines in supplier invoice
-- accounting coding totals/readiness.
--
-- This aligns the totals view with:
--   staff_bulk_save_supplier_invoice_line_accounting_codes_v2
-- and preserves downstream physical controls because this view is accounting-readiness only.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DROP VIEW IF EXISTS public.supplier_invoice_accounting_coding_totals_vw;

CREATE VIEW public.supplier_invoice_accounting_coding_totals_vw AS
WITH codable_invoice_lines AS (
  SELECT
    sil.id,
    sil.supplier_invoice_id,
    (
      lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
      OR EXISTS (
        SELECT 1
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_line_id = sil.id
          AND r.supplier_invoice_id = sil.supplier_invoice_id
          AND r.resolution_type = 'non_physical_financial'
          AND r.active = true
      )
    ) AS is_accounting_codable
  FROM public.supplier_invoice_lines sil
), line_codes AS (
  SELECT
    cil.supplier_invoice_id,
    COALESCE(SUM(codes.net_amount_gbp) FILTER (WHERE cil.is_accounting_codable), 0)::numeric(12,2) AS coded_net_gbp,
    COALESCE(SUM(codes.vat_amount_gbp) FILTER (WHERE cil.is_accounting_codable), 0)::numeric(12,2) AS coded_vat_gbp,
    COALESCE(SUM(codes.gross_amount_gbp) FILTER (WHERE cil.is_accounting_codable), 0)::numeric(12,2) AS coded_gross_gbp,
    COUNT(*) FILTER (WHERE cil.is_accounting_codable)::int AS progressed_line_count,
    COUNT(codes.id) FILTER (WHERE cil.is_accounting_codable)::int AS coded_line_count
  FROM codable_invoice_lines cil
  LEFT JOIN public.supplier_invoice_line_accounting_codes codes
    ON codes.supplier_invoice_line_id = cil.id
  GROUP BY cil.supplier_invoice_id
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

COMMENT ON VIEW public.supplier_invoice_accounting_coding_totals_vw IS
'Supplier invoice accounting coding totals. Accounting-codable lines include progressed physical lines and active parked non-physical financial lines. Physical shipment/tracking flows remain controlled elsewhere.';

COMMIT;
