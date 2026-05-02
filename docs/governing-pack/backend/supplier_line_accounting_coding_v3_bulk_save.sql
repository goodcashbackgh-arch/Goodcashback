-- =============================================================================
-- supplier_line_accounting_coding_v3_bulk_save.sql
-- Multi Tenant Platform Build — atomic save-all supplier line accounting coding
--
-- Run after supplier_line_accounting_coding_v2_adjustments.sql.
--
-- Purpose:
--   Save all progressed supplier invoice line coding in one transaction.
--   If any line is invalid, or totals do not reconcile back to the accepted
--   invoice gross, the whole save is rejected.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoice_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: supplier_invoice_line_accounting_codes.';
  END IF;

  IF to_regclass('public.supplier_invoice_accounting_coding_totals_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: supplier_invoice_accounting_coding_totals_vw. Run v2 first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_bulk_save_supplier_invoice_line_accounting_codes(
  p_supplier_invoice_id uuid,
  p_lines jsonb
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  saved_line_count int,
  total_coded_net_gbp numeric,
  total_coded_vat_gbp numeric,
  total_coded_gross_gbp numeric,
  gross_variance_gbp numeric,
  balanced_yn boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_progressed_line_count int;
  v_submitted_line_count int;
  v_saved_line_count int := 0;
  v_row record;
  v_line public.supplier_invoice_lines%ROWTYPE;
  v_gross numeric(12,2);
  v_net numeric(12,2);
  v_vat numeric(12,2);
  v_rate numeric(7,4);
  v_totals record;
BEGIN
  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can bulk save supplier invoice line coding.';
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF jsonb_typeof(COALESCE(p_lines, 'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Coding payload must be a JSON array.';
  END IF;

  SELECT count(*)
  INTO v_progressed_line_count
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1');

  SELECT count(DISTINCT x.supplier_invoice_line_id)
  INTO v_submitted_line_count
  FROM jsonb_to_recordset(p_lines) AS x(supplier_invoice_line_id uuid);

  IF COALESCE(v_submitted_line_count, 0) <> COALESCE(v_progressed_line_count, 0) THEN
    RAISE EXCEPTION 'All progressed lines must be submitted. Progressed %, submitted %.', v_progressed_line_count, v_submitted_line_count;
  END IF;

  FOR v_row IN
    SELECT *
    FROM jsonb_to_recordset(p_lines) AS x(
      supplier_invoice_line_id uuid,
      description_override text,
      sku_override varchar,
      size_override varchar,
      sage_ledger_account_id varchar,
      nominal_code varchar,
      tax_rate_id varchar,
      tax_rate_label varchar,
      vat_rate_percent numeric,
      net_amount_gbp numeric,
      vat_amount_gbp numeric,
      admin_review_required_yn boolean,
      review_reason text
    )
  LOOP
    SELECT *
    INTO v_line
    FROM public.supplier_invoice_lines sil
    WHERE sil.id = v_row.supplier_invoice_line_id
      AND sil.supplier_invoice_id = p_supplier_invoice_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Submitted line % does not belong to supplier invoice %.', v_row.supplier_invoice_line_id, p_supplier_invoice_id;
    END IF;

    IF NOT (lower(trim(COALESCE(v_line.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')) THEN
      RAISE EXCEPTION 'Line % is not progressed and cannot be accounting coded.', v_line.id;
    END IF;

    v_gross := COALESCE(v_line.amount_inc_vat_gbp, 0)::numeric(12,2);
    v_net := COALESCE(v_row.net_amount_gbp, 0)::numeric(12,2);
    v_vat := COALESCE(v_row.vat_amount_gbp, 0)::numeric(12,2);
    v_rate := COALESCE(v_row.vat_rate_percent, 20.0000)::numeric(7,4);

    IF v_rate < 0 THEN
      RAISE EXCEPTION 'VAT rate cannot be negative for line %.', v_line.id;
    END IF;

    IF v_net < 0 OR v_vat < 0 THEN
      RAISE EXCEPTION 'Net/VAT cannot be negative for line %.', v_line.id;
    END IF;

    IF abs((v_net + v_vat) - v_gross) > 0.01 THEN
      RAISE EXCEPTION 'Line % does not balance. Net % + VAT % must equal locked gross %.', v_line.line_order, v_net, v_vat, v_gross;
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
      v_line.id,
      NULLIF(btrim(COALESCE(v_row.description_override, '')), ''),
      NULLIF(btrim(COALESCE(v_row.sku_override, '')), ''),
      NULLIF(btrim(COALESCE(v_row.size_override, '')), ''),
      NULLIF(btrim(COALESCE(v_row.sage_ledger_account_id, '')), ''),
      NULLIF(btrim(COALESCE(v_row.nominal_code, '')), ''),
      NULLIF(btrim(COALESCE(v_row.tax_rate_id, '')), ''),
      NULLIF(btrim(COALESCE(v_row.tax_rate_label, '')), ''),
      v_rate,
      v_net,
      v_vat,
      v_gross,
      v_staff_id,
      now(),
      COALESCE(v_row.admin_review_required_yn, false),
      NULLIF(btrim(COALESCE(v_row.review_reason, '')), ''),
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

    v_saved_line_count := v_saved_line_count + 1;
  END LOOP;

  SELECT *
  INTO v_totals
  FROM public.supplier_invoice_accounting_coding_totals_vw totals
  WHERE totals.supplier_invoice_id = p_supplier_invoice_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not calculate accounting coding totals.';
  END IF;

  IF NOT COALESCE(v_totals.all_progressed_lines_coded_yn, false) THEN
    RAISE EXCEPTION 'Not all progressed lines are coded.';
  END IF;

  IF NOT COALESCE(v_totals.gross_reconciled_to_invoice_yn, false) THEN
    RAISE EXCEPTION 'Coding does not reconcile to accepted invoice gross. Variance %.', v_totals.gross_variance_gbp;
  END IF;

  RETURN QUERY SELECT
    p_supplier_invoice_id,
    v_saved_line_count,
    v_totals.total_coded_net_gbp,
    v_totals.total_coded_vat_gbp,
    v_totals.total_coded_gross_gbp,
    v_totals.gross_variance_gbp,
    true;
END;
$$;

COMMIT;
