-- Supplier invoice header Net/VAT review override.
-- Scope locked by docs/governing-pack/ui/SUPPLIER_INVOICE_HEADER_NET_VAT_REVIEW_ADDENDUM_v1.md.
-- Adds reviewed header Net/VAT only, extends the existing header-review RPC,
-- and makes the existing accounting totals view prefer reviewed values.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

ALTER TABLE public.supplier_invoices
  ADD COLUMN IF NOT EXISTS reviewed_invoice_net_gbp numeric(12,2),
  ADD COLUMN IF NOT EXISTS reviewed_invoice_vat_gbp numeric(12,2);

COMMENT ON COLUMN public.supplier_invoices.reviewed_invoice_net_gbp IS
  'Supervisor-reviewed invoice header net amount. Raw OCR remains unchanged.';
COMMENT ON COLUMN public.supplier_invoices.reviewed_invoice_vat_gbp IS
  'Supervisor-reviewed invoice header VAT amount. Raw OCR remains unchanged.';

-- The live seven-argument signature has one repo caller. Replace it atomically
-- with the scoped nine-argument signature so PostgREST does not retain an
-- ambiguous overload with the same RPC name.
DROP FUNCTION IF EXISTS public.staff_save_supplier_invoice_header_review(uuid, text, text, text, date, numeric, text);

CREATE FUNCTION public.staff_save_supplier_invoice_header_review(
  p_supplier_invoice_id uuid,
  p_corrected_invoice_ref text DEFAULT NULL,
  p_ocr_invoice_ref text DEFAULT NULL,
  p_ocr_retailer_name text DEFAULT NULL,
  p_ocr_invoice_date date DEFAULT NULL,
  p_ocr_invoice_total_gbp numeric DEFAULT NULL,
  p_reviewed_invoice_net_gbp numeric DEFAULT NULL,
  p_reviewed_invoice_vat_gbp numeric DEFAULT NULL,
  p_review_notes text DEFAULT NULL
)
RETURNS TABLE(order_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_role_type text;
  v_invoice record;
  v_now timestamptz := now();
  v_corrected_ref text;
  v_notes text;
BEGIN
  SELECT s.id, s.role_type::text
    INTO v_staff_id, v_role_type
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL OR v_role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can review invoice headers.';
  END IF;

  SELECT si.id, si.order_id, si.invoice_ref, si.review_status
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF v_invoice.review_status IN ('rejected_resubmit_required', 'superseded', 'duplicate_blocked') THEN
    RAISE EXCEPTION 'Cannot save header review for a rejected, superseded, or duplicate-blocked invoice.';
  END IF;

  IF p_reviewed_invoice_net_gbp IS NOT NULL AND p_reviewed_invoice_net_gbp < 0 THEN
    RAISE EXCEPTION 'Reviewed invoice net cannot be negative.';
  END IF;

  IF p_reviewed_invoice_vat_gbp IS NOT NULL AND p_reviewed_invoice_vat_gbp < 0 THEN
    RAISE EXCEPTION 'Reviewed invoice VAT cannot be negative.';
  END IF;

  IF p_ocr_invoice_total_gbp IS NOT NULL
     AND p_reviewed_invoice_net_gbp IS NOT NULL
     AND p_reviewed_invoice_vat_gbp IS NOT NULL
     AND abs((p_reviewed_invoice_net_gbp + p_reviewed_invoice_vat_gbp) - p_ocr_invoice_total_gbp) > 0.01 THEN
    RAISE EXCEPTION 'Reviewed Net + VAT must equal invoice total within £0.01.';
  END IF;

  v_corrected_ref := NULLIF(trim(COALESCE(p_corrected_invoice_ref, '')), '');
  v_notes := COALESCE(NULLIF(trim(p_review_notes), ''), 'Header/OCR values reviewed by supervisor.');

  UPDATE public.supplier_invoices si
  SET
    invoice_ref = COALESCE(v_corrected_ref, si.invoice_ref),
    ocr_invoice_ref = NULLIF(trim(COALESCE(p_ocr_invoice_ref, '')), ''),
    ocr_retailer_name = NULLIF(trim(COALESCE(p_ocr_retailer_name, '')), ''),
    ocr_invoice_date = p_ocr_invoice_date,
    ocr_invoice_total_gbp = p_ocr_invoice_total_gbp,
    reviewed_invoice_net_gbp = p_reviewed_invoice_net_gbp,
    reviewed_invoice_vat_gbp = p_reviewed_invoice_vat_gbp,
    review_status = 'pending_review',
    blocked_from_sage_yn = true,
    is_current_for_order = false,
    reviewed_by_staff_id = v_staff_id,
    reviewed_at = v_now,
    review_notes = v_notes
  WHERE si.id = p_supplier_invoice_id;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff_id,
    resolved_at = v_now,
    resolution_notes = v_notes,
    updated_at = v_now
  WHERE f.supplier_invoice_id = p_supplier_invoice_id
    AND f.status IN ('open', 'under_review');

  RETURN QUERY SELECT v_invoice.order_id::uuid;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_save_supplier_invoice_header_review(uuid, text, text, text, date, numeric, numeric, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_save_supplier_invoice_header_review(uuid, text, text, text, date, numeric, numeric, numeric, text) TO authenticated;

-- Recreate the latest accounting totals contract exactly, changing only the
-- accepted Net/VAT source precedence. Physical/non-physical codability,
-- adjustments, gross precedence and reconciliation guards remain unchanged.
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
      si.reviewed_invoice_net_gbp,
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
    COALESCE(
      si.reviewed_invoice_vat_gbp,
      NULLIF(si.ocr_raw_json #>> '{inference,result,fields,total_tax,value}', '')::numeric
    )::numeric(12,2) AS invoice_vat_gbp,
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
  'Supplier invoice accounting coding totals. Reviewed invoice header Net/VAT override raw OCR when present; accounting-codable lines include progressed physical lines and active parked non-physical financial lines. Physical shipment/tracking flows remain controlled elsewhere.';

NOTIFY pgrst, 'reload schema';

COMMIT;
