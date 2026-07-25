BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $prerequisites$
DECLARE
  v_preserved_shape text;
  v_enriched_shape text;
  v_canonical_shape text;
BEGIN
  IF to_regprocedure('public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL
     AND to_regprocedure('public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(uuid,varchar,integer,varchar,varchar,jsonb,varchar,varchar,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Preserved OCR save implementation is missing.';
  END IF;

  IF to_regprocedure('public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL
     AND to_regprocedure('public.staff_save_mindee_invoice_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,varchar,varchar,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Canonical signed OCR save implementation is missing.';
  END IF;

  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()') IS NULL
     OR to_regprocedure('public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1()') IS NULL
     OR to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Supplier goods AP preserved/enriched/canonical helper chain is incomplete.';
  END IF;

  SELECT
    pg_get_function_result('public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()'::regprocedure),
    pg_get_function_result('public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1()'::regprocedure),
    pg_get_function_result('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure)
  INTO v_preserved_shape, v_enriched_shape, v_canonical_shape;

  IF v_preserved_shape IS DISTINCT FROM v_enriched_shape
     OR v_preserved_shape IS DISTINCT FROM v_canonical_shape THEN
    RAISE EXCEPTION 'Supplier goods AP helper return shape changed.';
  END IF;

  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
    RAISE EXCEPTION 'Canonical Sage-ready queue is missing.';
  END IF;

  IF position(
    'internal_supplier_goods_ap_ready_rows_v1'
    IN pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  ) = 0 THEN
    RAISE EXCEPTION 'Canonical Sage-ready queue no longer composes the supplier goods AP helper.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid = 'public.supplier_invoice_lines'::regclass
      AND t.tgname = 'trg_prevent_ocr_supplier_invoice_line_delete'
      AND NOT t.tgisinternal
      AND t.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'OCR invoice-line delete protection is not enabled.';
  END IF;
END
$prerequisites$;

DO $target_a$
DECLARE
  v_invoice_id uuid;
  v_header_total numeric;
  v_signed_line_total numeric;
  v_negative_total numeric;
  v_negative_count integer;
  v_declared_discount numeric;
BEGIN
  SELECT si.id, round(si.ocr_invoice_total_gbp::numeric, 2)
    INTO v_invoice_id, v_header_total
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-A'
    AND si.mindee_ocr_status = 'completed'
  LIMIT 1;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Target invoice NIN-240726-A is not OCR-completed.';
  END IF;

  SELECT
    round(COALESCE(SUM(sil.amount_inc_vat_gbp), 0)::numeric, 2),
    round(COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (WHERE sil.amount_inc_vat_gbp < 0), 0)::numeric, 2),
    COUNT(*) FILTER (WHERE sil.amount_inc_vat_gbp < 0)::integer
  INTO v_signed_line_total, v_negative_total, v_negative_count
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = v_invoice_id
    AND sil.line_source = 'ocr_extracted';

  SELECT round(COALESCE(SUM(ova.amount_gbp), 0)::numeric, 2)
    INTO v_declared_discount
  FROM public.order_value_adjustments ova
  WHERE ova.supplier_invoice_id = v_invoice_id
    AND ova.adjustment_type = 'retailer_discount'
    AND ova.approval_status <> 'rejected';

  IF v_negative_count <> 1 OR v_negative_total IS DISTINCT FROM -50.01::numeric THEN
    RAISE EXCEPTION 'A must contain one signed OCR discount of -50.01; count %, total %.', v_negative_count, v_negative_total;
  END IF;

  IF abs(v_signed_line_total - v_header_total) > 0.01 THEN
    RAISE EXCEPTION 'A signed OCR line total % does not equal OCR header total %.', v_signed_line_total, v_header_total;
  END IF;

  IF abs(abs(v_negative_total) - v_declared_discount) > 0.01 THEN
    RAISE EXCEPTION 'A signed OCR discount % does not match declared discount %.', v_negative_total, v_declared_discount;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = v_invoice_id
      AND sil.amount_inc_vat_gbp < 0
      AND lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
  ) THEN
    RAISE EXCEPTION 'A signed OCR discount is incorrectly physically progressed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice_id
      AND sil.amount_inc_vat_gbp < 0
  ) THEN
    RAISE EXCEPTION 'A signed OCR discount is incorrectly linked to tracking.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.supplier_invoice_lines sil ON sil.id = m.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice_id
      AND sil.amount_inc_vat_gbp < 0
  ) THEN
    RAISE EXCEPTION 'A signed OCR discount is incorrectly linked to a shipment batch.';
  END IF;
END
$target_a$;

SELECT
  'PASS'::text AS regression_result,
  'NIN-240726-A retains its -50.01 OCR discount as visible unresolved source evidence; signed lines equal the OCR header; physical progression/tracking/shipment remain blocked; OCR delete protection and canonical Sage helper composition remain intact.'::text AS details;

ROLLBACK;
