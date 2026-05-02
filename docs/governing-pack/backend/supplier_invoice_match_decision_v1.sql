-- =============================================================================
-- supplier_invoice_match_decision_v1.sql
-- Multi Tenant Platform Build — invoice OCR matching/routing layer
--
-- Purpose:
--   Route uploaded supplier invoices after OCR/header extraction:
--     - clean/full matches go to operator reconciliation;
--     - mismatches/OCR problems go to internal invoice review;
--     - rejected/superseded invoices stay audit-only.
--
-- This is matching/routing only. It does not prepare supplier AP drafts,
-- customer sales invoices, Sage postings, VAT workings, or shipping release.
--
-- Governing alignment:
--   - Operator upload fields are only invoice ref, final invoice total, invoice
--     file, optional delivery and discount.
--   - VAT amount/rate/VAT number are preserved for later accounting but are not
--     first-stage routing variables.
--   - Pending delivery/discount approval blocks supplier approval/Sage readiness,
--     not operator line reconciliation when OCR item lines are usable.
--
-- Important fix:
--   Normalize by lowercasing first, then stripping non [a-z0-9]. If regexp_replace
--   strips before lower(), uppercase retailer letters such as NINJA become blank.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.retailers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.retailers';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regclass('public.supplier_invoice_financial_summary') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_financial_summary';
  END IF;

  IF to_regclass('public.supplier_invoice_review_flags') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_review_flags';
  END IF;
END $$;

CREATE OR REPLACE VIEW public.supplier_invoice_match_decision_vw AS
WITH active_summary AS (
  SELECT DISTINCT ON (sifs.supplier_invoice_id)
    sifs.supplier_invoice_id,
    sifs.invoice_total_gbp::numeric(12,2) AS operator_total_gbp
  FROM public.supplier_invoice_financial_summary sifs
  ORDER BY sifs.supplier_invoice_id, sifs.created_at DESC NULLS LAST
), line_counts AS (
  SELECT
    sil.supplier_invoice_id,
    COUNT(*) FILTER (WHERE sil.line_source = 'ocr_extracted')::int AS ocr_line_count,
    COUNT(*) FILTER (WHERE sil.eligible_for_invoice_yn = 'Y')::int AS progressed_line_count,
    COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (WHERE sil.line_source = 'ocr_extracted'), 0)::numeric(12,2) AS ocr_line_total_gbp
  FROM public.supplier_invoice_lines sil
  GROUP BY sil.supplier_invoice_id
), open_flags AS (
  SELECT
    sfrf.supplier_invoice_id,
    COUNT(*) FILTER (WHERE sfrf.status IN ('open','under_review'))::int AS open_review_flag_count,
    COUNT(*) FILTER (
      WHERE sfrf.status IN ('open','under_review')
        AND sfrf.flag_type IN ('wrong_invoice','ocr_unclear','invoice_total_mismatch','manual_line_needed')
    )::int AS serious_open_review_flag_count
  FROM public.supplier_invoice_review_flags sfrf
  GROUP BY sfrf.supplier_invoice_id
), pending_adjustments AS (
  SELECT
    ova.supplier_invoice_id,
    COUNT(*) FILTER (WHERE ova.approval_status = 'pending_supervisor')::int AS pending_adjustment_count
  FROM public.order_value_adjustments ova
  GROUP BY ova.supplier_invoice_id
), normalized AS (
  SELECT
    si.id AS supplier_invoice_id,
    si.order_id,
    o.order_ref,
    r.name AS order_retailer_name,
    si.invoice_ref AS operator_invoice_ref,
    si.ocr_invoice_ref,
    si.ocr_retailer_name,
    si.ocr_invoice_date,
    si.ocr_invoice_total_gbp::numeric(12,2) AS ocr_total_gbp,
    asum.operator_total_gbp,
    COALESCE(lc.ocr_line_count, 0) AS ocr_line_count,
    COALESCE(lc.progressed_line_count, 0) AS progressed_line_count,
    COALESCE(lc.ocr_line_total_gbp, 0)::numeric(12,2) AS ocr_line_total_gbp,
    COALESCE(ofl.open_review_flag_count, 0) AS open_review_flag_count,
    COALESCE(ofl.serious_open_review_flag_count, 0) AS serious_open_review_flag_count,
    COALESCE(pa.pending_adjustment_count, 0) AS pending_adjustment_count,
    si.review_status,
    COALESCE(si.blocked_from_sage_yn, true) AS blocked_from_sage_yn,
    si.ocr_raw_json IS NOT NULL AS has_ocr_raw_json,
    si.ocr_extracted_at,
    regexp_replace(lower(COALESCE(r.name, '')), '[^a-z0-9]+', '', 'g') AS norm_order_retailer,
    regexp_replace(lower(COALESCE(si.ocr_retailer_name, '')), '[^a-z0-9]+', '', 'g') AS norm_ocr_retailer,
    regexp_replace(lower(COALESCE(si.invoice_ref, '')), '[^a-z0-9]+', '', 'g') AS norm_operator_ref,
    regexp_replace(lower(COALESCE(si.ocr_invoice_ref, '')), '[^a-z0-9]+', '', 'g') AS norm_ocr_ref
  FROM public.supplier_invoices si
  JOIN public.orders o ON o.id = si.order_id
  JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN active_summary asum ON asum.supplier_invoice_id = si.id
  LEFT JOIN line_counts lc ON lc.supplier_invoice_id = si.id
  LEFT JOIN open_flags ofl ON ofl.supplier_invoice_id = si.id
  LEFT JOIN pending_adjustments pa ON pa.supplier_invoice_id = si.id
)
SELECT
  n.supplier_invoice_id,
  n.order_id,
  n.order_ref,
  n.order_retailer_name,
  n.operator_invoice_ref,
  n.ocr_invoice_ref,
  CASE
    WHEN n.ocr_invoice_ref IS NULL OR btrim(n.ocr_invoice_ref) = '' THEN false
    ELSE n.norm_operator_ref = n.norm_ocr_ref
  END AS invoice_ref_match_yn,
  n.operator_total_gbp,
  n.ocr_total_gbp,
  CASE
    WHEN n.operator_total_gbp IS NULL OR n.ocr_total_gbp IS NULL THEN false
    ELSE abs(n.operator_total_gbp - n.ocr_total_gbp) <= 0.01
  END AS total_match_yn,
  n.ocr_retailer_name,
  CASE
    WHEN n.ocr_retailer_name IS NULL OR btrim(n.ocr_retailer_name) = '' THEN false
    WHEN n.norm_order_retailer = '' OR n.norm_ocr_retailer = '' THEN false
    WHEN n.norm_order_retailer = n.norm_ocr_retailer THEN true
    WHEN position(n.norm_order_retailer in n.norm_ocr_retailer) > 0 THEN true
    WHEN position(n.norm_ocr_retailer in n.norm_order_retailer) > 0 THEN true
    ELSE false
  END AS retailer_match_yn,
  n.ocr_invoice_date,
  n.ocr_line_count,
  n.progressed_line_count,
  n.ocr_line_total_gbp,
  (n.pending_adjustment_count > 0) AS pending_adjustment_yn,
  n.pending_adjustment_count,
  n.open_review_flag_count,
  n.serious_open_review_flag_count,
  n.review_status,
  n.blocked_from_sage_yn,
  n.has_ocr_raw_json,
  n.ocr_extracted_at,
  CASE
    WHEN n.review_status IN ('rejected_resubmit_required','superseded','duplicate_blocked') THEN 'rejected_audit_only'
    WHEN NOT n.has_ocr_raw_json AND n.ocr_invoice_ref IS NULL AND n.ocr_total_gbp IS NULL AND n.ocr_retailer_name IS NULL THEN 'ocr_pending'
    WHEN n.ocr_line_count = 0 THEN 'needs_invoice_review'
    WHEN n.serious_open_review_flag_count > 0 THEN 'needs_invoice_review'
    WHEN NOT (
      CASE
        WHEN n.ocr_retailer_name IS NULL OR btrim(n.ocr_retailer_name) = '' THEN false
        WHEN n.norm_order_retailer = '' OR n.norm_ocr_retailer = '' THEN false
        WHEN n.norm_order_retailer = n.norm_ocr_retailer THEN true
        WHEN position(n.norm_order_retailer in n.norm_ocr_retailer) > 0 THEN true
        WHEN position(n.norm_ocr_retailer in n.norm_order_retailer) > 0 THEN true
        ELSE false
      END
    ) THEN 'needs_invoice_review'
    WHEN n.ocr_invoice_ref IS NULL OR btrim(n.ocr_invoice_ref) = '' OR n.norm_operator_ref <> n.norm_ocr_ref THEN 'needs_invoice_review'
    WHEN n.operator_total_gbp IS NULL OR n.ocr_total_gbp IS NULL OR abs(n.operator_total_gbp - n.ocr_total_gbp) > 0.01 THEN 'needs_invoice_review'
    ELSE 'ready_for_operator_reconciliation'
  END AS routing_decision,
  CASE
    WHEN n.review_status IN ('rejected_resubmit_required','superseded','duplicate_blocked') THEN 'Invoice is audit-only due to rejected/superseded/duplicate status.'
    WHEN NOT n.has_ocr_raw_json AND n.ocr_invoice_ref IS NULL AND n.ocr_total_gbp IS NULL AND n.ocr_retailer_name IS NULL THEN 'OCR has not been saved yet.'
    WHEN n.ocr_line_count = 0 THEN 'No OCR invoice lines exist for reconciliation.'
    WHEN n.serious_open_review_flag_count > 0 THEN 'Serious open invoice review flag exists.'
    WHEN NOT (
      CASE
        WHEN n.ocr_retailer_name IS NULL OR btrim(n.ocr_retailer_name) = '' THEN false
        WHEN n.norm_order_retailer = '' OR n.norm_ocr_retailer = '' THEN false
        WHEN n.norm_order_retailer = n.norm_ocr_retailer THEN true
        WHEN position(n.norm_order_retailer in n.norm_ocr_retailer) > 0 THEN true
        WHEN position(n.norm_ocr_retailer in n.norm_order_retailer) > 0 THEN true
        ELSE false
      END
    ) THEN 'OCR supplier/retailer does not match the order-created retailer.'
    WHEN n.ocr_invoice_ref IS NULL OR btrim(n.ocr_invoice_ref) = '' THEN 'OCR invoice reference is missing.'
    WHEN n.norm_operator_ref <> n.norm_ocr_ref THEN 'Operator invoice reference does not match OCR invoice reference.'
    WHEN n.operator_total_gbp IS NULL THEN 'Operator-entered final invoice total is missing.'
    WHEN n.ocr_total_gbp IS NULL THEN 'OCR final invoice total is missing.'
    WHEN abs(n.operator_total_gbp - n.ocr_total_gbp) > 0.01 THEN 'Operator-entered final invoice total does not match OCR final invoice total.'
    ELSE 'Matched on order retailer, invoice reference, final gross total, and OCR line existence.'
  END AS routing_reason,
  CASE
    WHEN n.pending_adjustment_count > 0 THEN true
    WHEN n.serious_open_review_flag_count > 0 THEN true
    WHEN n.ocr_line_count = 0 THEN true
    ELSE false
  END AS supplier_approval_blocked_yn,
  CASE
    WHEN n.pending_adjustment_count > 0 THEN 'Pending delivery/discount adjustment blocks approve-current/Sage readiness, but not operator line reconciliation.'
    WHEN n.serious_open_review_flag_count > 0 THEN 'Serious invoice review flag blocks supplier approval.'
    WHEN n.ocr_line_count = 0 THEN 'No OCR lines exist.'
    ELSE NULL
  END AS supplier_approval_block_reason
FROM normalized n;

COMMENT ON VIEW public.supplier_invoice_match_decision_vw IS
'Routes OCR supplier invoices after upload/OCR. Clean matches go to operator reconciliation; mismatches go to internal invoice review. Pending adjustments block supplier approval/Sage, not line reconciliation.';

COMMIT;
