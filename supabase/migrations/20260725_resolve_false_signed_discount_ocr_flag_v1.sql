BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_invoice_id constant uuid := '2a1a8bb8-5e8f-4c6f-bd39-fec38a9466df';
  v_flag_id constant uuid := '61add6c8-2dee-4742-b360-4b8b47e3bb45';
  v_header_total numeric;
  v_stored_line_total numeric;
  v_raw_text text;
  v_flag_type text;
  v_flag_status text;
  v_flag_message text;
BEGIN
  SELECT
    si.ocr_invoice_total_gbp,
    COALESCE((
      SELECT round(sum(sil.amount_inc_vat_gbp), 2)
      FROM public.supplier_invoice_lines sil
      WHERE sil.supplier_invoice_id = si.id
        AND sil.line_source = 'ocr_extracted'
    ), 0),
    si.ocr_raw_json::text
  INTO v_header_total, v_stored_line_total, v_raw_text
  FROM public.supplier_invoices si
  WHERE si.id = v_invoice_id
    AND si.invoice_ref = 'NIN-240726-B'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target NIN-240726-B invoice was not found; no cleanup applied.';
  END IF;

  IF round(v_header_total, 2) <> 249.99
     OR round(v_stored_line_total, 2) <> 259.99
     OR v_raw_text NOT LIKE '%Bundle discount%'
     OR v_raw_text NOT LIKE '%-10%'
     OR v_raw_text NOT LIKE '%Standard delivery%'
     OR v_raw_text NOT LIKE '%10.01%' THEN
    RAISE EXCEPTION 'Target OCR evidence no longer matches the proven signed-discount defect; no cleanup applied.';
  END IF;

  SELECT flag_type, status, message
  INTO v_flag_type, v_flag_status, v_flag_message
  FROM public.supplier_invoice_review_flags
  WHERE id = v_flag_id
    AND supplier_invoice_id = v_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target false OCR review flag was not found; no cleanup applied.';
  END IF;

  IF v_flag_type <> 'invoice_total_mismatch'
     OR v_flag_status NOT IN ('open', 'under_review', 'resolved')
     OR v_flag_message <> 'Mindee OCR line total 259.99 does not match OCR header total 249.99.' THEN
    RAISE EXCEPTION 'Target review flag no longer matches the proven false mismatch; no cleanup applied.';
  END IF;

  UPDATE public.supplier_invoice_review_flags
  SET status = 'resolved'
  WHERE id = v_flag_id
    AND status IN ('open', 'under_review');
END $$;

COMMIT;
