-- =============================================================================
-- supplier_line_accounting_coding_v1.sql
-- Multi Tenant Platform Build — supplier invoice line accounting coding
--
-- Purpose:
--   Staff accounting-codes reconciled supplier invoice lines before supplier AP
--   draft preparation. Gross remains locked to the approved OCR/reconciled line
--   gross. Net/VAT recalculate from VAT rate and must add back to gross.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.supplier_invoice_line_accounting_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE CASCADE,
  description_override text,
  sku_override varchar,
  size_override varchar,
  sage_ledger_account_id varchar,
  nominal_code varchar,
  tax_rate_id varchar,
  tax_rate_label varchar,
  vat_rate_percent numeric(7,4) NOT NULL DEFAULT 20.0000,
  net_amount_gbp numeric(12,2) NOT NULL,
  vat_amount_gbp numeric(12,2) NOT NULL,
  gross_amount_gbp numeric(12,2) NOT NULL,
  coded_by_staff_id uuid REFERENCES public.staff(id),
  coded_at timestamptz NOT NULL DEFAULT now(),
  admin_review_required_yn boolean NOT NULL DEFAULT false,
  review_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_invoice_line_accounting_codes_one_per_line UNIQUE (supplier_invoice_line_id),
  CONSTRAINT supplier_invoice_line_accounting_codes_amounts_non_negative CHECK (
    net_amount_gbp >= 0
    AND vat_amount_gbp >= 0
    AND gross_amount_gbp >= 0
    AND vat_rate_percent >= 0
  ),
  CONSTRAINT supplier_invoice_line_accounting_codes_net_vat_gross_check CHECK (
    abs((net_amount_gbp + vat_amount_gbp) - gross_amount_gbp) <= 0.01
  )
);

CREATE INDEX IF NOT EXISTS idx_supplier_line_accounting_codes_line
  ON public.supplier_invoice_line_accounting_codes (supplier_invoice_line_id);

CREATE OR REPLACE VIEW public.supplier_invoice_line_accounting_coding_vw AS
SELECT
  sil.id AS supplier_invoice_line_id,
  sil.supplier_invoice_id,
  sil.line_order,
  sil.line_source,
  sil.description AS source_description,
  sil.retailer_sku AS source_sku,
  sil.size AS source_size,
  sil.qty,
  sil.amount_inc_vat_gbp::numeric(12,2) AS approved_gross_amount_gbp,
  sil.eligible_for_invoice_yn,
  COALESCE(codes.description_override, sil.description) AS posting_description,
  COALESCE(codes.sku_override, sil.retailer_sku) AS posting_sku,
  COALESCE(codes.size_override, sil.size) AS posting_size,
  codes.sage_ledger_account_id,
  codes.nominal_code,
  codes.tax_rate_id,
  codes.tax_rate_label,
  codes.vat_rate_percent,
  codes.net_amount_gbp,
  codes.vat_amount_gbp,
  codes.gross_amount_gbp,
  codes.coded_by_staff_id,
  codes.coded_at,
  codes.admin_review_required_yn,
  codes.review_reason,
  (codes.id IS NOT NULL) AS coded_yn
FROM public.supplier_invoice_lines sil
LEFT JOIN public.supplier_invoice_line_accounting_codes codes
  ON codes.supplier_invoice_line_id = sil.id;

COMMENT ON TABLE public.supplier_invoice_line_accounting_codes IS
'Staff accounting coding for reconciled supplier invoice lines. Gross must remain locked to approved OCR/reconciled gross amount. Used to prepare later supplier AP draft/Sage posting queue.';

CREATE OR REPLACE FUNCTION public.staff_upsert_supplier_invoice_line_accounting_code(
  p_supplier_invoice_line_id uuid,
  p_description_override text,
  p_sku_override varchar,
  p_size_override varchar,
  p_sage_ledger_account_id varchar,
  p_nominal_code varchar,
  p_tax_rate_id varchar,
  p_tax_rate_label varchar,
  p_vat_rate_percent numeric,
  p_admin_review_required_yn boolean DEFAULT false,
  p_review_reason text DEFAULT NULL
)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  net_amount_gbp numeric,
  vat_amount_gbp numeric,
  gross_amount_gbp numeric,
  coded_yn boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_line public.supplier_invoice_lines%ROWTYPE;
  v_gross numeric(12,2);
  v_rate numeric(7,4);
  v_net numeric(12,2);
  v_vat numeric(12,2);
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can code supplier invoice lines.';
  END IF;

  SELECT *
  INTO v_line
  FROM public.supplier_invoice_lines sil
  WHERE sil.id = p_supplier_invoice_line_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice line not found.';
  END IF;

  IF NOT (lower(trim(COALESCE(v_line.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')) THEN
    RAISE EXCEPTION 'Only progressed supplier invoice lines can be accounting coded.';
  END IF;

  v_gross := COALESCE(v_line.amount_inc_vat_gbp, 0)::numeric(12,2);
  v_rate := COALESCE(p_vat_rate_percent, 20.0000)::numeric(7,4);

  IF v_rate < 0 THEN
    RAISE EXCEPTION 'VAT rate cannot be negative.';
  END IF;

  v_net := round((v_gross / (1 + (v_rate / 100.0)))::numeric, 2);
  v_vat := round((v_gross - v_net)::numeric, 2);

  INSERT INTO public.supplier_invoice_line_accounting_codes (
    supplier_invoice_line_id,
    description_override,
    sku_override,
    size_override,
    sage_ledger_account_id,
    nominal_code,
    tax_rate_id,
    tax_rate_label,
    vat_rate_percent,
    net_amount_gbp,
    vat_amount_gbp,
    gross_amount_gbp,
    coded_by_staff_id,
    coded_at,
    admin_review_required_yn,
    review_reason,
    updated_at
  ) VALUES (
    p_supplier_invoice_line_id,
    NULLIF(btrim(COALESCE(p_description_override, '')), ''),
    NULLIF(btrim(COALESCE(p_sku_override, '')), ''),
    NULLIF(btrim(COALESCE(p_size_override, '')), ''),
    NULLIF(btrim(COALESCE(p_sage_ledger_account_id, '')), ''),
    NULLIF(btrim(COALESCE(p_nominal_code, '')), ''),
    NULLIF(btrim(COALESCE(p_tax_rate_id, '')), ''),
    NULLIF(btrim(COALESCE(p_tax_rate_label, '')), ''),
    v_rate,
    v_net,
    v_vat,
    v_gross,
    v_staff_id,
    now(),
    COALESCE(p_admin_review_required_yn, false),
    NULLIF(btrim(COALESCE(p_review_reason, '')), ''),
    now()
  )
  ON CONFLICT (supplier_invoice_line_id)
  DO UPDATE SET
    description_override = EXCLUDED.description_override,
    sku_override = EXCLUDED.sku_override,
    size_override = EXCLUDED.size_override,
    sage_ledger_account_id = EXCLUDED.sage_ledger_account_id,
    nominal_code = EXCLUDED.nominal_code,
    tax_rate_id = EXCLUDED.tax_rate_id,
    tax_rate_label = EXCLUDED.tax_rate_label,
    vat_rate_percent = EXCLUDED.vat_rate_percent,
    net_amount_gbp = EXCLUDED.net_amount_gbp,
    vat_amount_gbp = EXCLUDED.vat_amount_gbp,
    gross_amount_gbp = EXCLUDED.gross_amount_gbp,
    coded_by_staff_id = EXCLUDED.coded_by_staff_id,
    coded_at = now(),
    admin_review_required_yn = EXCLUDED.admin_review_required_yn,
    review_reason = EXCLUDED.review_reason,
    updated_at = now();

  RETURN QUERY SELECT p_supplier_invoice_line_id, v_net, v_vat, v_gross, true;
END;
$$;

COMMIT;
