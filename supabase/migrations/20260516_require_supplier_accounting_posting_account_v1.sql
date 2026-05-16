-- =============================================================================
-- 20260516_require_supplier_accounting_posting_account_v1.sql
-- Multi Tenant Platform Build — supplier accounting posting-account guard
--
-- Purpose:
--   Prevent supplier invoice line accounting codes and manual adjustment rows
--   from being saved as Sage-ready when both nominal_code and
--   sage_ledger_account_id are blank.
--
-- Safety:
--   - Add NOT VALID constraints so historical bad rows remain visible for repair.
--   - New inserts/updates are blocked by DB constraints.
--   - RPCs are recreated with clearer supervisor-facing errors.
--   - Does not alter existing net/VAT/gross balancing rules.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoice_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_line_accounting_codes';
  END IF;

  IF to_regclass('public.supplier_invoice_accounting_adjustment_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_accounting_adjustment_lines';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoice_line_accounting_codes_posting_account_required'
      AND conrelid = 'public.supplier_invoice_line_accounting_codes'::regclass
  ) THEN
    ALTER TABLE public.supplier_invoice_line_accounting_codes
      ADD CONSTRAINT supplier_invoice_line_accounting_codes_posting_account_required
      CHECK (
        NULLIF(btrim(COALESCE(nominal_code, '')), '') IS NOT NULL
        OR NULLIF(btrim(COALESCE(sage_ledger_account_id, '')), '') IS NOT NULL
      ) NOT VALID;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoice_accounting_adjustments_posting_account_required'
      AND conrelid = 'public.supplier_invoice_accounting_adjustment_lines'::regclass
  ) THEN
    ALTER TABLE public.supplier_invoice_accounting_adjustment_lines
      ADD CONSTRAINT supplier_invoice_accounting_adjustments_posting_account_required
      CHECK (
        NULLIF(btrim(COALESCE(nominal_code, '')), '') IS NOT NULL
        OR NULLIF(btrim(COALESCE(sage_ledger_account_id, '')), '') IS NOT NULL
      ) NOT VALID;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_bulk_save_supplier_invoice_line_accounting_codes_v2(
  p_supplier_invoice_id uuid,
  p_lines jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_submitted_count integer := COALESCE(jsonb_array_length(p_lines), 0);
  v_expected_count integer;
  v_bad_count integer;
  v_line jsonb;
  v_line_id uuid;
  v_net numeric;
  v_vat numeric;
  v_gross numeric;
BEGIN
  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only supervisor/admin staff can save supplier invoice accounting codes';
  END IF;

  IF p_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice id is required';
  END IF;

  IF v_submitted_count = 0 THEN
    RAISE EXCEPTION 'No accounting coding lines submitted';
  END IF;

  SELECT COUNT(*)
    INTO v_expected_count
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND (
      sil.eligible_for_invoice_yn = 'Y'
      OR EXISTS (
        SELECT 1
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_line_id = sil.id
          AND r.supplier_invoice_id = p_supplier_invoice_id
          AND r.resolution_type = 'non_physical_financial'
          AND r.active = true
      )
    );

  IF v_submitted_count <> v_expected_count THEN
    RAISE EXCEPTION 'All codable supplier invoice lines must be submitted. Expected %, submitted %.', v_expected_count, v_submitted_count;
  END IF;

  WITH submitted AS (
    SELECT (x.value->>'supplier_invoice_line_id')::uuid AS supplier_invoice_line_id
    FROM jsonb_array_elements(p_lines) x(value)
  )
  SELECT COUNT(*)
    INTO v_bad_count
  FROM submitted s
  LEFT JOIN public.supplier_invoice_lines sil
    ON sil.id = s.supplier_invoice_line_id
   AND sil.supplier_invoice_id = p_supplier_invoice_id
  WHERE sil.id IS NULL
     OR NOT (
       sil.eligible_for_invoice_yn = 'Y'
       OR EXISTS (
         SELECT 1
         FROM public.supplier_invoice_line_resolutions r
         WHERE r.supplier_invoice_line_id = sil.id
           AND r.supplier_invoice_id = p_supplier_invoice_id
           AND r.resolution_type = 'non_physical_financial'
           AND r.active = true
       )
     );

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION 'Submitted lines include non-codable, unresolved, or wrong-invoice line(s).';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    v_line_id := (v_line->>'supplier_invoice_line_id')::uuid;
    v_net := COALESCE(NULLIF(v_line->>'net_amount_gbp','')::numeric, 0);
    v_vat := COALESCE(NULLIF(v_line->>'vat_amount_gbp','')::numeric, 0);
    v_gross := round((v_net + v_vat)::numeric, 2);

    IF NULLIF(btrim(COALESCE(v_line->>'sage_ledger_account_id', '')), '') IS NULL
       AND NULLIF(btrim(COALESCE(v_line->>'nominal_code', '')), '') IS NULL THEN
      RAISE EXCEPTION 'Nominal code or Sage ledger account id is required for every supplier accounting coding line.';
    END IF;

    IF abs((v_net + v_vat) - v_gross) > 0.01 THEN
      RAISE EXCEPTION 'Line % net/VAT/gross does not reconcile', v_line_id;
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
    )
    VALUES (
      v_line_id,
      NULLIF(v_line->>'description_override',''),
      NULLIF(v_line->>'sku_override',''),
      NULLIF(v_line->>'size_override',''),
      NULLIF(v_line->>'sage_ledger_account_id',''),
      NULLIF(v_line->>'nominal_code',''),
      NULLIF(v_line->>'tax_rate_id',''),
      NULLIF(v_line->>'tax_rate_label',''),
      COALESCE(NULLIF(v_line->>'vat_rate_percent','')::numeric, 20),
      v_net,
      v_vat,
      v_gross,
      v_staff_id,
      now(),
      COALESCE((v_line->>'admin_review_required_yn')::boolean, false),
      NULLIF(v_line->>'review_reason',''),
      now()
    )
    ON CONFLICT (supplier_invoice_line_id) DO UPDATE SET
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
      coded_at = EXCLUDED.coded_at,
      admin_review_required_yn = EXCLUDED.admin_review_required_yn,
      review_reason = EXCLUDED.review_reason,
      updated_at = now();
  END LOOP;

  RETURN v_submitted_count;
END;
$$;

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

  IF NULLIF(btrim(COALESCE(p_sage_ledger_account_id, '')), '') IS NULL
     AND NULLIF(btrim(COALESCE(p_nominal_code, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Nominal code or Sage ledger account id is required for supplier accounting coding.';
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

CREATE OR REPLACE FUNCTION public.staff_create_supplier_invoice_accounting_adjustment_line_v2(
  p_supplier_invoice_id uuid,
  p_description text,
  p_qty numeric,
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
  v_qty numeric(12,3);
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

  IF NULLIF(btrim(COALESCE(p_sage_ledger_account_id, '')), '') IS NULL
     AND NULLIF(btrim(COALESCE(p_nominal_code, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Nominal code or Sage ledger account id is required for supplier accounting adjustment lines.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.id = p_supplier_invoice_id
      AND COALESCE(si.is_current_for_order, false) = false
  ) THEN
    RAISE EXCEPTION 'Supplier invoice not found or already approved current.';
  END IF;

  IF NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Adjustment description is required.';
  END IF;

  v_qty := COALESCE(p_qty, 1)::numeric(12,3);
  IF v_qty <= 0 THEN
    RAISE EXCEPTION 'Adjustment quantity must be greater than zero.';
  END IF;

  v_net := COALESCE(p_net_amount_gbp, 0)::numeric(12,2);
  v_vat := COALESCE(p_vat_amount_gbp, 0)::numeric(12,2);
  v_gross := round((v_net + v_vat)::numeric, 2);

  IF v_net < 0 OR v_vat < 0 THEN
    RAISE EXCEPTION 'Adjustment net and VAT cannot be negative.';
  END IF;

  INSERT INTO public.supplier_invoice_accounting_adjustment_lines (
    supplier_invoice_id,
    description,
    qty,
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
    v_qty,
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

CREATE OR REPLACE FUNCTION public.staff_update_supplier_invoice_accounting_adjustment_line_v2(
  p_adjustment_line_id uuid,
  p_description text,
  p_qty numeric,
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
  v_invoice_id uuid;
  v_qty numeric(12,3);
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
    RAISE EXCEPTION 'Only active admin/supervisor staff can update accounting adjustment lines.';
  END IF;

  IF NULLIF(btrim(COALESCE(p_sage_ledger_account_id, '')), '') IS NULL
     AND NULLIF(btrim(COALESCE(p_nominal_code, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Nominal code or Sage ledger account id is required for supplier accounting adjustment lines.';
  END IF;

  SELECT aal.supplier_invoice_id
  INTO v_invoice_id
  FROM public.supplier_invoice_accounting_adjustment_lines aal
  JOIN public.supplier_invoices si ON si.id = aal.supplier_invoice_id
  WHERE aal.id = p_adjustment_line_id
    AND COALESCE(si.is_current_for_order, false) = false
  FOR UPDATE;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Adjustment line not found or supplier invoice already approved current.';
  END IF;

  IF NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Adjustment description is required.';
  END IF;

  v_qty := COALESCE(p_qty, 1)::numeric(12,3);
  IF v_qty <= 0 THEN
    RAISE EXCEPTION 'Adjustment quantity must be greater than zero.';
  END IF;

  v_net := COALESCE(p_net_amount_gbp, 0)::numeric(12,2);
  v_vat := COALESCE(p_vat_amount_gbp, 0)::numeric(12,2);
  v_gross := round((v_net + v_vat)::numeric, 2);

  IF v_net < 0 OR v_vat < 0 THEN
    RAISE EXCEPTION 'Adjustment net and VAT cannot be negative.';
  END IF;

  UPDATE public.supplier_invoice_accounting_adjustment_lines
     SET description = btrim(p_description),
         qty = v_qty,
         sku = NULLIF(btrim(COALESCE(p_sku, '')), ''),
         size = NULLIF(btrim(COALESCE(p_size, '')), ''),
         sage_ledger_account_id = NULLIF(btrim(COALESCE(p_sage_ledger_account_id, '')), ''),
         nominal_code = NULLIF(btrim(COALESCE(p_nominal_code, '')), ''),
         tax_rate_id = NULLIF(btrim(COALESCE(p_tax_rate_id, '')), ''),
         tax_rate_label = NULLIF(btrim(COALESCE(p_tax_rate_label, '')), ''),
         vat_rate_percent = COALESCE(p_vat_rate_percent, 20.0000),
         net_amount_gbp = v_net,
         vat_amount_gbp = v_vat,
         gross_amount_gbp = v_gross,
         updated_at = now()
   WHERE id = p_adjustment_line_id;

  RETURN p_adjustment_line_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.staff_bulk_save_supplier_invoice_line_accounting_codes_v2(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_upsert_supplier_invoice_line_accounting_code(uuid, text, varchar, varchar, varchar, varchar, varchar, varchar, numeric, numeric, numeric, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_create_supplier_invoice_accounting_adjustment_line_v2(uuid, text, numeric, varchar, varchar, varchar, varchar, varchar, varchar, numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_update_supplier_invoice_accounting_adjustment_line_v2(uuid, text, numeric, varchar, varchar, varchar, varchar, varchar, varchar, numeric, numeric, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
