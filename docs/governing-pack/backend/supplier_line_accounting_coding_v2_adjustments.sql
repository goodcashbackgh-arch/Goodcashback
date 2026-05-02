-- =============================================================================
-- supplier_line_accounting_coding_v2_adjustments.sql
-- Multi Tenant Platform Build — editable net/VAT + accounting adjustments
--
-- Run after supplier_line_accounting_coding_v1.sql.
-- Purpose:
--   - Let supervisor/admin edit net and VAT directly while gross remains locked
--     to the approved OCR/reconciled line amount.
--   - Add manual accounting adjustment lines for rounding/delivery/accounting
--     corrections without changing OCR source lines.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoice_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: supplier_invoice_line_accounting_codes. Run v1 first.';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: supplier_invoices';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.supplier_invoice_accounting_adjustment_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  description text NOT NULL,
  sku varchar,
  size varchar,
  sage_ledger_account_id varchar,
  nominal_code varchar,
  tax_rate_id varchar,
  tax_rate_label varchar,
  vat_rate_percent numeric(7,4) NOT NULL DEFAULT 20.0000,
  net_amount_gbp numeric(12,2) NOT NULL,
  vat_amount_gbp numeric(12,2) NOT NULL,
  gross_amount_gbp numeric(12,2) NOT NULL,
  created_by_staff_id uuid REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_invoice_accounting_adjustment_net_vat_gross_check CHECK (
    abs((net_amount_gbp + vat_amount_gbp) - gross_amount_gbp) <= 0.01
  )
);

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_accounting_adjustments_invoice
  ON public.supplier_invoice_accounting_adjustment_lines (supplier_invoice_id);

DROP FUNCTION IF EXISTS public.staff_upsert_supplier_invoice_line_accounting_code(
  uuid, text, varchar, varchar, varchar, varchar, varchar, varchar, numeric, boolean, text
);

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
  p_net_amount_gbp numeric DEFAULT NULL,
  p_vat_amount_gbp numeric DEFAULT NULL,
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

  IF p_net_amount_gbp IS NULL AND p_vat_amount_gbp IS NULL THEN
    v_net := round((v_gross / (1 + (v_rate / 100.0)))::numeric, 2);
    v_vat := round((v_gross - v_net)::numeric, 2);
  ELSE
    v_net := COALESCE(p_net_amount_gbp, 0)::numeric(12,2);
    v_vat := COALESCE(p_vat_amount_gbp, 0)::numeric(12,2);

    IF v_net < 0 OR v_vat < 0 THEN
      RAISE EXCEPTION 'Net and VAT cannot be negative.';
    END IF;

    IF abs((v_net + v_vat) - v_gross) > 0.01 THEN
      RAISE EXCEPTION 'Net plus VAT must equal locked gross %. Got net %, VAT %.', v_gross, v_net, v_vat;
    END IF;
  END IF;

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

CREATE OR REPLACE FUNCTION public.staff_create_supplier_invoice_accounting_adjustment_line(
  p_supplier_invoice_id uuid,
  p_description text,
  p_sku varchar,
  p_size varchar,
  p_sage_ledger_account_id varchar,
  p_nominal_code varchar,
  p_tax_rate_id varchar,
  p_tax_rate_label varchar,
  p_vat_rate_percent numeric,
  p_net_amount_gbp numeric,
  p_vat_amount_gbp numeric
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_adjustment_id uuid;
  v_net numeric(12,2);
  v_vat numeric(12,2);
  v_gross numeric(12,2);
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can add accounting adjustment lines.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.supplier_invoices si WHERE si.id = p_supplier_invoice_id) THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  v_net := COALESCE(p_net_amount_gbp, 0)::numeric(12,2);
  v_vat := COALESCE(p_vat_amount_gbp, 0)::numeric(12,2);
  v_gross := round((v_net + v_vat)::numeric, 2);

  IF NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Adjustment description is required.';
  END IF;

  INSERT INTO public.supplier_invoice_accounting_adjustment_lines (
    supplier_invoice_id,
    description,
    sku,
    size,
    sage_ledger_account_id,
    nominal_code,
    tax_rate_id,
    tax_rate_label,
    vat_rate_percent,
    net_amount_gbp,
    vat_amount_gbp,
    gross_amount_gbp,
    created_by_staff_id,
    updated_at
  ) VALUES (
    p_supplier_invoice_id,
    btrim(p_description),
    NULLIF(btrim(COALESCE(p_sku, '')), ''),
    NULLIF(btrim(COALESCE(p_size, '')), ''),
    NULLIF(btrim(COALESCE(p_sage_ledger_account_id, '')), ''),
    NULLIF(btrim(COALESCE(p_nominal_code, '')), ''),
    NULLIF(btrim(COALESCE(p_tax_rate_id, '')), ''),
    NULLIF(btrim(COALESCE(p_tax_rate_label, '')), ''),
    COALESCE(p_vat_rate_percent, 20.0000),
    v_net,
    v_vat,
    v_gross,
    v_staff_id,
    now()
  )
  RETURNING id INTO v_adjustment_id;

  RETURN v_adjustment_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_delete_supplier_invoice_accounting_adjustment_line(
  p_adjustment_line_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can delete accounting adjustment lines.';
  END IF;

  DELETE FROM public.supplier_invoice_accounting_adjustment_lines
  WHERE id = p_adjustment_line_id;
END;
$$;

CREATE OR REPLACE VIEW public.supplier_invoice_accounting_coding_totals_vw AS
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
)
SELECT
  si.id AS supplier_invoice_id,
  si.order_id,
  si.ocr_invoice_total_gbp::numeric(12,2) AS accepted_invoice_gross_gbp,
  COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0) AS total_coded_net_gbp,
  COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0) AS total_coded_vat_gbp,
  COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0) AS total_coded_gross_gbp,
  COALESCE(ac.adjustment_gross_gbp, 0) AS adjustment_gross_gbp,
  COALESCE(lc.progressed_line_count, 0) AS progressed_line_count,
  COALESCE(lc.coded_line_count, 0) AS coded_line_count,
  COALESCE(ac.adjustment_line_count, 0) AS adjustment_line_count,
  (COALESCE(lc.progressed_line_count, 0) = COALESCE(lc.coded_line_count, 0)) AS all_progressed_lines_coded_yn,
  (abs((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - COALESCE(si.ocr_invoice_total_gbp, 0)) <= 0.01) AS gross_reconciled_to_invoice_yn,
  ((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - COALESCE(si.ocr_invoice_total_gbp, 0))::numeric(12,2) AS gross_variance_gbp
FROM public.supplier_invoices si
LEFT JOIN line_codes lc ON lc.supplier_invoice_id = si.id
LEFT JOIN adjustment_codes ac ON ac.supplier_invoice_id = si.id;

COMMIT;
