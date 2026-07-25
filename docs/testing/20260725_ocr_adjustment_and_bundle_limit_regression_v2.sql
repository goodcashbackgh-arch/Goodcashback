DO $$
DECLARE
  v_save_def text;
  v_view_def text;
  v_flag_constraint text;
  v_trigger_count integer;
  v_invalid_negative_goods integer;
BEGIN
  IF to_regprocedure(
    'public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Regression failed: canonical Mindee save function is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)'::regprocedure
  ) INTO v_save_def;

  IF position('v_has_active_adjustment' in v_save_def) = 0
     OR position('IF NOT v_has_active_adjustment' in v_save_def) = 0
     OR position('v_raw_line_total * 1.20' in v_save_def) = 0 THEN
    RAISE EXCEPTION 'Regression failed: adjustment-safe OCR storage guard or established no-adjustment gross-up compatibility is missing.';
  END IF;

  IF to_regprocedure('public.flag_order_bundle_limit_after_summary_v1()') IS NULL THEN
    RAISE EXCEPTION 'Regression failed: order bundle-limit trigger function is missing.';
  END IF;

  SELECT count(*)::integer
    INTO v_trigger_count
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.supplier_invoice_financial_summary'::regclass
    AND t.tgname = 'trg_flag_order_bundle_limit_after_summary_v1'
    AND NOT t.tgisinternal;

  IF v_trigger_count <> 1 THEN
    RAISE EXCEPTION 'Regression failed: expected one order bundle-limit trigger, found %.', v_trigger_count;
  END IF;

  SELECT pg_get_viewdef('public.supplier_invoice_match_decision_vw'::regclass, true)
    INTO v_view_def;

  IF position('order_bundle_limit_breach' in v_view_def) = 0
     OR position('delivery_discount_query' in v_view_def) = 0 THEN
    RAISE EXCEPTION 'Regression failed: existing supervisor review view does not include the new serious flag types.';
  END IF;

  SELECT pg_get_constraintdef(c.oid)
    INTO v_flag_constraint
  FROM pg_constraint c
  JOIN pg_attribute a
    ON a.attrelid = c.conrelid
   AND a.attnum = ANY(c.conkey)
  WHERE c.conrelid = 'public.supplier_invoice_review_flags'::regclass
    AND c.contype = 'c'
    AND a.attname = 'flag_type';

  IF v_flag_constraint IS NULL
     OR position('order_bundle_limit_breach' in v_flag_constraint) = 0 THEN
    RAISE EXCEPTION 'Regression failed: supplier invoice review flag constraint does not allow order_bundle_limit_breach.';
  END IF;

  SELECT count(*)::integer
    INTO v_invalid_negative_goods
  FROM public.supplier_invoice_lines sil
  WHERE sil.line_source = 'ocr_extracted'
    AND sil.amount_inc_vat_gbp < 0;

  IF v_invalid_negative_goods <> 0 THEN
    RAISE EXCEPTION 'Regression failed: % negative OCR adjustment rows were stored as supplier goods lines.', v_invalid_negative_goods;
  END IF;
END $$;

SELECT
  'PASS'::text AS regression_result,
  'Adjustment-bearing OCR saves bypass only the legacy VAT gross-up heuristic, no-adjustment compatibility remains, accepted-estimate breaches use the existing supervisor review gate, and negative discount rows are not stored as supplier goods lines.'::text AS details;
