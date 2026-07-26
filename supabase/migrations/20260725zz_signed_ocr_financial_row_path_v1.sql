BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Permanent private materialiser for omitted OCR financial rows.
-- It creates unresolved source evidence only. Classification, accounting,
-- approval, progression, shipment, freeze and posting remain on existing routes.

DO $guard$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Signed OCR financial-row materialiser prerequisites are missing.';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(
  p_supplier_invoice_id uuid,
  p_lines jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_item record;
  v_existing record;
  v_existing_count integer;
  v_line_order integer;
  v_description text;
  v_retailer_sku text;
  v_qty numeric;
  v_qty_text text;
  v_amount numeric;
  v_amount_text text;
  v_normalised_description text;
  v_is_financial boolean;
  v_inserted integer := 0;
BEGIN
  IF p_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice id is required.';
  END IF;

  -- Serialise save/repair attempts for one invoice so the established
  -- invoice + OCR source + line-order identity remains deterministic.
  PERFORM 1
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice % was not found.', p_supplier_invoice_id;
  END IF;

  IF p_lines IS NULL THEN
    RETURN 0;
  END IF;

  IF jsonb_typeof(p_lines) <> 'array' THEN
    RAISE EXCEPTION 'OCR financial rows must be supplied as a JSON array.';
  END IF;

  FOR v_item IN
    SELECT arr.line_item, arr.ord
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS arr(line_item, ord)
    ORDER BY arr.ord
  LOOP
    v_line_order := CASE
      WHEN COALESCE(v_item.line_item->>'line_order', '') ~ '^[1-9][0-9]*$'
        THEN (v_item.line_item->>'line_order')::integer
      ELSE v_item.ord::integer
    END;

    v_description := COALESCE(
      NULLIF(btrim(COALESCE(v_item.line_item->>'description', '')), ''),
      'OCR financial line ' || v_line_order::text
    );
    v_retailer_sku := NULLIF(btrim(COALESCE(v_item.line_item->>'retailer_sku', '')), '');

    v_qty_text := btrim(COALESCE(v_item.line_item->>'qty', '1'));
    v_qty := CASE
      WHEN v_qty_text ~ '^-?[0-9]+(\.[0-9]+)?$'
        THEN GREATEST(v_qty_text::numeric, 0)
      ELSE 1
    END;

    v_amount_text := btrim(COALESCE(v_item.line_item->>'amount_inc_vat_gbp', ''));
    v_amount := CASE
      WHEN v_amount_text ~ '^-?[0-9]+(\.[0-9]+)?$'
        THEN round(v_amount_text::numeric, 2)
      ELSE NULL
    END;

    v_normalised_description := lower(
      regexp_replace(v_description, '[^a-zA-Z0-9]+', ' ', 'g')
    );
    v_is_financial :=
      COALESCE(v_amount, 0) < 0
      OR (
        COALESCE(v_amount, 0) > 0
        AND v_normalised_description ~
          '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
      );

    IF NOT v_is_financial THEN
      CONTINUE;
    END IF;

    IF v_amount IS NULL OR v_amount = 0 THEN
      RAISE EXCEPTION
        'OCR financial row % for invoice % has no valid non-zero amount.',
        v_line_order, p_supplier_invoice_id;
    END IF;

    SELECT COUNT(*)::integer
    INTO v_existing_count
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = p_supplier_invoice_id
      AND sil.line_source = 'ocr_extracted'
      AND sil.line_order = v_line_order;

    IF v_existing_count > 1 THEN
      RAISE EXCEPTION
        'OCR identity conflict for invoice %, line order %: % rows exist.',
        p_supplier_invoice_id, v_line_order, v_existing_count;
    END IF;

    IF v_existing_count = 1 THEN
      SELECT
        sil.id,
        sil.description,
        sil.retailer_sku,
        sil.qty,
        sil.amount_inc_vat_gbp,
        sil.eligible_for_invoice_yn
      INTO v_existing
      FROM public.supplier_invoice_lines sil
      WHERE sil.supplier_invoice_id = p_supplier_invoice_id
        AND sil.line_source = 'ocr_extracted'
        AND sil.line_order = v_line_order
      LIMIT 1;

      IF round(COALESCE(v_existing.amount_inc_vat_gbp, 0)::numeric, 2)
           IS DISTINCT FROM v_amount
         OR round(COALESCE(v_existing.qty, 0)::numeric, 4)
           IS DISTINCT FROM round(v_qty::numeric, 4)
         OR btrim(COALESCE(v_existing.description, ''))
           IS DISTINCT FROM btrim(v_description)
         OR COALESCE(NULLIF(btrim(v_existing.retailer_sku), ''), '')
           IS DISTINCT FROM COALESCE(v_retailer_sku, '') THEN
        RAISE EXCEPTION
          'OCR identity conflict for invoice %, line order %: retained row % differs from source.',
          p_supplier_invoice_id, v_line_order, v_existing.id;
      END IF;

      IF lower(btrim(COALESCE(v_existing.eligible_for_invoice_yn, 'n')))
           IN ('y', 'yes', 'true', '1') THEN
        RAISE EXCEPTION
          'OCR financial row % for invoice % is physically eligible.',
          v_line_order, p_supplier_invoice_id;
      END IF;

      CONTINUE;
    END IF;

    INSERT INTO public.supplier_invoice_lines (
      supplier_invoice_id,
      line_order,
      retailer_sku,
      description,
      qty,
      amount_inc_vat_gbp,
      line_source,
      eligible_for_invoice_yn
    ) VALUES (
      p_supplier_invoice_id,
      v_line_order,
      v_retailer_sku,
      v_description,
      v_qty,
      v_amount,
      'ocr_extracted',
      'N'
    );

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN v_inserted;
END;
$func$;

REVOKE ALL ON FUNCTION public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid, jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid, jsonb) FROM service_role;

COMMENT ON FUNCTION public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid, jsonb) IS
'Private invoice-locked materialiser for omitted OCR financial rows. It preserves source order, description, quantity and signed amount, inserts unresolved non-physical evidence only, rejects conflicting identities and is idempotent for exact repeats.';

COMMIT;