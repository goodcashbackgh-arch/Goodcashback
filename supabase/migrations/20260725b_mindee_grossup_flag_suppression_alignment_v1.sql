BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- The adjustment-aware parser uses clearer mismatch wording. Preserve the
-- established no-adjustment 20% gross-up outcome by suppressing either wording
-- only when v_auto_gross_up_yn is actually true. Adjustment-bearing invoices
-- cannot enter this branch because the preceding migration disables gross-up for
-- them.
DO $patch$
DECLARE
  v_def text;
  v_old text := $old$AND NOT (
        v_auto_gross_up_yn
        AND flag_item.flag_type = 'invoice_total_mismatch'
        AND lower(flag_item.message) LIKE 'mindee ocr line total%ocr header total%'
      )$old$;
  v_new text := $new$AND NOT (
        v_auto_gross_up_yn
        AND flag_item.flag_type = 'invoice_total_mismatch'
        AND (
          lower(flag_item.message) LIKE 'mindee ocr line total%ocr header total%'
          OR lower(flag_item.message) LIKE 'ocr lines plus declared delivery/discount explain%not ocr header total%'
        )
      )$new$;
BEGIN
  IF to_regprocedure(
    'public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Mindee OCR save function is missing; suppression alignment not applied.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)'::regprocedure
  ) INTO v_def;

  IF position('ocr lines plus declared delivery/discount explain' in lower(v_def)) = 0 THEN
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'Expected established gross-up flag-suppression clause was not found; function left unchanged.';
    END IF;
    v_def := replace(v_def, v_old, v_new);
    EXECUTE v_def;
  END IF;
END
$patch$;

NOTIFY pgrst, 'reload schema';

COMMIT;
