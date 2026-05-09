-- Add quantity to supervisor/manual supplier accounting adjustment rows.
-- Purpose: manual rows on the supervisor reconciliation page should mirror OCR/progressed
-- invoice-line fields closely enough for later Sage payload preparation.
--
-- This is additive: existing adjustment rows receive qty = 1, totals remain based on
-- net/VAT/gross, and no supplier invoice/order state is changed.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

ALTER TABLE public.supplier_invoice_accounting_adjustment_lines
  ADD COLUMN IF NOT EXISTS qty numeric(12,3) NOT NULL DEFAULT 1;

UPDATE public.supplier_invoice_accounting_adjustment_lines
SET qty = 1
WHERE qty IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'supplier_invoice_accounting_adjustment_qty_positive_check'
      AND conrelid = 'public.supplier_invoice_accounting_adjustment_lines'::regclass
  ) THEN
    ALTER TABLE public.supplier_invoice_accounting_adjustment_lines
      ADD CONSTRAINT supplier_invoice_accounting_adjustment_qty_positive_check
      CHECK (qty > 0);
  END IF;
END $$;

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

  IF NOT EXISTS (SELECT 1 FROM public.supplier_invoices si WHERE si.id = p_supplier_invoice_id) THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
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

GRANT EXECUTE ON FUNCTION public.staff_create_supplier_invoice_accounting_adjustment_line_v2(
  uuid, text, numeric, varchar, varchar, varchar, varchar, varchar, varchar, numeric, numeric, numeric
) TO authenticated;

COMMIT;
