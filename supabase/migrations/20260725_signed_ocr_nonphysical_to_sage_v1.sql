BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow bridge for source-signed OCR financial rows.
-- Existing OCR save, invoice approval, accounting coding, Sage queue, freeze and
-- posting implementations remain authoritative. This migration wraps only the
-- two established functions whose current filters omit negative/non-physical
-- source rows.

DO $guard$
DECLARE
  v_save_shape text;
  v_goods_shape text;
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_line_accounting_coding_vw') IS NULL
     OR to_regclass('public.order_value_adjustments') IS NULL THEN
    RAISE EXCEPTION 'Signed OCR non-physical bridge prerequisite relation is missing.';
  END IF;

  IF to_regprocedure('public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL
     AND to_regprocedure('public.staff_save_mindee_invoice_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,varchar,varchar,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Current Mindee supplier-invoice OCR save function is missing.';
  END IF;

  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Current supplier goods AP ready helper is missing.';
  END IF;

  SELECT pg_get_function_result('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure)
    INTO v_goods_shape;
  IF v_goods_shape IS NULL THEN
    RAISE EXCEPTION 'Could not resolve supplier goods AP helper return shape.';
  END IF;
END
$guard$;

-- -----------------------------------------------------------------------------
-- 1. Preserve the deployed OCR save implementation, then add signed source rows.
-- -----------------------------------------------------------------------------
DO $rename_save$
BEGIN
  IF to_regprocedure('public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL
     AND to_regprocedure('public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(uuid,varchar,integer,varchar,varchar,jsonb,varchar,varchar,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    ALTER FUNCTION public.staff_save_mindee_invoice_ocr_result(
      uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
      date, numeric, integer, jsonb, jsonb
    ) RENAME TO staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1;
  END IF;
END
$rename_save$;

REVOKE ALL ON FUNCTION public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) FROM anon;
REVOKE ALL ON FUNCTION public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) FROM authenticated;

CREATE OR REPLACE FUNCTION public.staff_save_mindee_invoice_ocr_result(
  p_supplier_invoice_id uuid,
  p_model_id varchar,
  p_http_status integer,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar,
  p_raw_json jsonb,
  p_ocr_invoice_ref varchar,
  p_ocr_retailer_name varchar,
  p_ocr_invoice_date date,
  p_ocr_invoice_total_gbp numeric,
  p_pages_consumed integer,
  p_lines jsonb,
  p_flags jsonb DEFAULT '[]'::jsonb
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  order_id uuid,
  inserted_line_count integer,
  inserted_flag_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_base record;
  v_signed_count integer := 0;
BEGIN
  -- The preserved implementation retains all authentication, invoice-state,
  -- human-work, gross-up, audit and review-flag controls. It continues to insert
  -- the non-negative rows exactly as before.
  SELECT *
    INTO v_base
  FROM public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(
    p_supplier_invoice_id,
    p_model_id,
    p_http_status,
    p_mindee_job_id,
    p_mindee_inference_id,
    p_raw_json,
    p_ocr_invoice_ref,
    p_ocr_retailer_name,
    p_ocr_invoice_date,
    p_ocr_invoice_total_gbp,
    p_pages_consumed,
    p_lines,
    p_flags
  );

  -- Materialise only source-negative rows omitted by the preserved function.
  -- They remain unresolved and non-physical until explicitly classified.
  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    INSERT INTO public.supplier_invoice_lines (
      supplier_invoice_id,
      line_order,
      retailer_sku,
      description,
      qty,
      amount_inc_vat_gbp,
      line_source,
      eligible_for_invoice_yn
    )
    SELECT
      p_supplier_invoice_id,
      arr.ord::integer,
      NULLIF(btrim(COALESCE(arr.line_item->>'retailer_sku', '')), ''),
      COALESCE(
        NULLIF(btrim(COALESCE(arr.line_item->>'description', '')), ''),
        'OCR signed financial line ' || arr.ord::text
      ),
      GREATEST(COALESCE(NULLIF(arr.line_item->>'qty', '')::numeric, 1), 0),
      NULLIF(arr.line_item->>'amount_inc_vat_gbp', '')::numeric,
      'ocr_extracted',
      'N'
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS arr(line_item, ord)
    WHERE COALESCE(NULLIF(arr.line_item->>'amount_inc_vat_gbp', '')::numeric, 0) < 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.supplier_invoice_lines existing
        WHERE existing.supplier_invoice_id = p_supplier_invoice_id
          AND existing.line_source = 'ocr_extracted'
          AND existing.line_order = arr.ord::integer
      )
    ORDER BY arr.ord;

    GET DIAGNOSTICS v_signed_count = ROW_COUNT;
  END IF;

  RETURN QUERY
  SELECT
    v_base.supplier_invoice_id::uuid,
    v_base.order_id::uuid,
    (COALESCE(v_base.inserted_line_count, 0) + v_signed_count)::integer,
    COALESCE(v_base.inserted_flag_count, 0)::integer;
END;
$func$;

REVOKE ALL ON FUNCTION public.staff_save_mindee_invoice_ocr_result(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_save_mindee_invoice_ocr_result(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) TO authenticated;

COMMENT ON FUNCTION public.staff_save_mindee_invoice_ocr_result(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) IS
'Canonical Mindee supplier-invoice OCR save. Preserves the deployed save controls and additionally materialises source-negative OCR rows as unresolved, non-physical invoice evidence for explicit classification.';

-- -----------------------------------------------------------------------------
-- 2. Repair the already-completed exact A test invoice from retained raw evidence.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE signed_discount_a_candidate ON COMMIT DROP AS
WITH target AS (
  SELECT si.id AS supplier_invoice_id, si.order_id, si.ocr_raw_json
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-A'
    AND si.mindee_ocr_status = 'completed'
    AND si.ocr_raw_json IS NOT NULL
), payload AS (
  SELECT
    t.*,
    COALESCE(
      t.ocr_raw_json #> '{inference,result,fields,line_items,items}',
      t.ocr_raw_json #> '{inference,result,fields,items,items}',
      t.ocr_raw_json #> '{inference,result,fields,invoice_lines,items}',
      t.ocr_raw_json #> '{inference,result,fields,line_items}',
      t.ocr_raw_json #> '{inference,result,fields,items}',
      t.ocr_raw_json #> '{inference,result,fields,invoice_lines}',
      t.ocr_raw_json #> '{inference,result,prediction,line_items}',
      t.ocr_raw_json #> '{result,fields,line_items}',
      t.ocr_raw_json #> '{document,inference,prediction,line_items}',
      '[]'::jsonb
    ) AS line_items
  FROM target t
), expanded AS (
  SELECT
    p.supplier_invoice_id,
    p.order_id,
    item.ordinality::integer AS line_order,
    CASE
      WHEN jsonb_typeof(item.value->'fields') = 'object' THEN item.value->'fields'
      ELSE item.value
    END AS row_json
  FROM payload p
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(p.line_items) = 'array' THEN p.line_items ELSE '[]'::jsonb END
  ) WITH ORDINALITY AS item(value, ordinality)
), parsed AS (
  SELECT
    e.supplier_invoice_id,
    e.order_id,
    e.line_order,
    COALESCE(
      NULLIF(btrim(e.row_json #>> '{description,value}'), ''),
      NULLIF(btrim(e.row_json->>'description'), ''),
      NULLIF(btrim(e.row_json #>> '{name,value}'), ''),
      NULLIF(btrim(e.row_json->>'name'), ''),
      NULLIF(btrim(e.row_json #>> '{label,value}'), ''),
      NULLIF(btrim(e.row_json->>'label'), ''),
      'OCR signed financial line ' || e.line_order::text
    ) AS description,
    COALESCE(
      NULLIF(regexp_replace(COALESCE(e.row_json #>> '{quantity,value}', e.row_json->>'quantity', e.row_json #>> '{qty,value}', e.row_json->>'qty', '1'), '[^0-9.\-]', '', 'g'), '')::numeric,
      1
    ) AS qty,
    NULLIF(regexp_replace(COALESCE(
      e.row_json #>> '{total_amount,value}', e.row_json->>'total_amount',
      e.row_json #>> '{total_price,value}', e.row_json->>'total_price',
      e.row_json #>> '{amount,value}', e.row_json->>'amount',
      e.row_json #>> '{line_total,value}', e.row_json->>'line_total',
      ''
    ), '[^0-9.\-]', '', 'g'), '')::numeric AS amount_gbp,
    NULLIF(btrim(COALESCE(
      e.row_json #>> '{product_code,value}', e.row_json->>'product_code',
      e.row_json #>> '{sku,value}', e.row_json->>'sku',
      e.row_json #>> '{reference,value}', e.row_json->>'reference',
      ''
    )), '') AS retailer_sku
  FROM expanded e
)
SELECT *
FROM parsed p
WHERE p.amount_gbp < 0
  AND lower(regexp_replace(p.description, '[^a-zA-Z0-9]+', ' ', 'g')) ~ '(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)';

DO $backfill_a$
DECLARE
  v_invoice_id uuid;
  v_candidate_count integer;
  v_candidate_amount numeric;
  v_declared_discount numeric;
BEGIN
  SELECT si.id
    INTO v_invoice_id
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-A'
    AND si.mindee_ocr_status = 'completed'
  LIMIT 1;

  IF v_invoice_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = v_invoice_id
      AND sil.line_source = 'ocr_extracted'
      AND sil.amount_inc_vat_gbp < 0
  ) THEN
    RETURN;
  END IF;

  SELECT COUNT(*)::integer, MIN(amount_gbp)
    INTO v_candidate_count, v_candidate_amount
  FROM signed_discount_a_candidate
  WHERE supplier_invoice_id = v_invoice_id;

  SELECT round(COALESCE(SUM(ova.amount_gbp), 0)::numeric, 2)
    INTO v_declared_discount
  FROM public.order_value_adjustments ova
  WHERE ova.supplier_invoice_id = v_invoice_id
    AND ova.adjustment_type = 'retailer_discount'
    AND ova.approval_status <> 'rejected';

  IF v_candidate_count <> 1 THEN
    RAISE EXCEPTION 'A signed-discount backfill expected exactly one raw discount row; found %. No A row added.', v_candidate_count;
  END IF;

  IF v_declared_discount <= 0
     OR abs(abs(v_candidate_amount) - v_declared_discount) > 0.01 THEN
    RAISE EXCEPTION 'A raw discount % does not match declared discount %. No A row added.', v_candidate_amount, v_declared_discount;
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
  )
  SELECT
    c.supplier_invoice_id,
    c.line_order,
    c.retailer_sku,
    c.description,
    GREATEST(COALESCE(c.qty, 1), 0),
    c.amount_gbp,
    'ocr_extracted',
    'N'
  FROM signed_discount_a_candidate c
  WHERE c.supplier_invoice_id = v_invoice_id;
END
$backfill_a$;

-- -----------------------------------------------------------------------------
-- 3. Preserve the deployed supplier AP helper, then append coded active
--    non-physical source lines to its signed Sage payload.
-- -----------------------------------------------------------------------------
DO $rename_goods$
BEGIN
  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()') IS NULL THEN
    ALTER FUNCTION public.internal_supplier_goods_ap_ready_rows_v1()
      RENAME TO internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1;
  END IF;
END
$rename_goods$;

REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1() FROM anon;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1() FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1() FROM service_role;

CREATE OR REPLACE FUNCTION public.internal_supplier_goods_ap_ready_rows_v1()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
  WITH base AS (
    SELECT *
    FROM public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()
  ), enriched AS (
    SELECT
      b.*,
      COALESCE(existing_stats.line_total_gbp, 0)::numeric(18,2) AS existing_line_total_gbp,
      COALESCE(np.extra_line_count, 0)::integer AS extra_line_count,
      COALESCE(np.missing_ledger_count, 0)::integer AS extra_missing_ledger_count,
      COALESCE(np.missing_tax_count, 0)::integer AS extra_missing_tax_count,
      COALESCE(np.extra_gross_total_gbp, 0)::numeric(18,2) AS extra_gross_total_gbp,
      COALESCE(np.extra_lines, '[]'::jsonb) AS extra_lines
    FROM base b
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(
        CASE
          WHEN COALESCE(line.value->>'gross_amount_gbp', line.value->>'total_line_amount_gbp', line.value->>'amount_gbp', line.value->>'unit_price_gbp', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
            THEN COALESCE(line.value->>'gross_amount_gbp', line.value->>'total_line_amount_gbp', line.value->>'amount_gbp', line.value->>'unit_price_gbp')::numeric
          ELSE 0
        END
      ), 0)::numeric(18,2) AS line_total_gbp
      FROM jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(b.source_payload->'resolved_lines') = 'array' THEN b.source_payload->'resolved_lines'
          ELSE '[]'::jsonb
        END
      ) AS line(value)
    ) existing_stats ON true
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*)::integer AS extra_line_count,
        COUNT(*) FILTER (
          WHERE NULLIF(trim(COALESCE(
            v.sage_ledger_account_id,
            b.source_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}',
            ''
          )), '') IS NULL
        )::integer AS missing_ledger_count,
        COUNT(*) FILTER (
          WHERE NULLIF(trim(COALESCE(
            v.tax_rate_id,
            b.source_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}',
            ''
          )), '') IS NULL
        )::integer AS missing_tax_count,
        COALESCE(SUM(COALESCE(v.gross_amount_gbp, v.approved_gross_amount_gbp, 0)), 0)::numeric(18,2) AS extra_gross_total_gbp,
        COALESCE(jsonb_agg(
          jsonb_build_object(
            'line_kind', 'supplier_non_physical_line',
            'financial_type', r.financial_type,
            'source_line_id', v.supplier_invoice_line_id,
            'description', COALESCE(NULLIF(v.posting_description, ''), NULLIF(v.source_description, ''), 'Supplier non-physical financial line'),
            'quantity', COALESCE(v.qty, 1),
            'unit_price_gbp', COALESCE(v.gross_amount_gbp, v.approved_gross_amount_gbp, 0),
            'net_amount_gbp', COALESCE(v.net_amount_gbp, 0),
            'vat_amount_gbp', COALESCE(v.vat_amount_gbp, 0),
            'gross_amount_gbp', COALESCE(v.gross_amount_gbp, v.approved_gross_amount_gbp, 0),
            'total_line_amount_gbp', COALESCE(v.gross_amount_gbp, v.approved_gross_amount_gbp, 0),
            'nominal_code', v.nominal_code,
            'vat_rate_percent', COALESCE(v.vat_rate_percent, 0),
            'sage_ledger_account_id', COALESCE(v.sage_ledger_account_id, b.source_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_LEDGER,sage_external_id}'),
            'sage_tax_rate_id', COALESCE(v.tax_rate_id, b.source_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_external_id}'),
            'sage_tax_rate_display', COALESCE(v.tax_rate_label, b.source_payload #>> '{mapping_snapshot,SUPPLIER_GOODS_AP_TAX_RATE,sage_display_name}')
          ) ORDER BY v.line_order, v.supplier_invoice_line_id
        ), '[]'::jsonb) AS extra_lines
      FROM public.supplier_invoice_line_accounting_coding_vw v
      JOIN public.supplier_invoice_line_resolutions r
        ON r.supplier_invoice_line_id = v.supplier_invoice_line_id
       AND r.supplier_invoice_id = v.supplier_invoice_id
       AND r.resolution_type = 'non_physical_financial'
       AND r.active = true
      WHERE v.supplier_invoice_id = b.source_id
        AND COALESCE(v.coded_yn, false) = true
        AND NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements(
            CASE
              WHEN jsonb_typeof(b.source_payload->'resolved_lines') = 'array' THEN b.source_payload->'resolved_lines'
              ELSE '[]'::jsonb
            END
          ) existing(value)
          WHERE existing.value->>'source_line_id' = v.supplier_invoice_line_id::text
        )
    ) np ON true
  )
  SELECT
    e.queue_row_id,
    e.document_lane,
    e.document_type,
    e.source_table,
    e.source_id,
    e.order_id,
    e.order_ref,
    e.shipment_batch_id,
    e.booking_ref,
    e.counterparty_name,
    e.amount_gbp,
    e.currency_code,
    e.invoice_type,
    e.sage_status,
    e.sage_invoice_id,
    e.sage_posted_at,
    CASE
      WHEN COALESCE(e.readiness_status, '') NOT LIKE 'ready%' THEN e.readiness_status
      WHEN e.extra_missing_ledger_count > 0 THEN 'blocked_supplier_goods_ap_ledger_mapping_missing'
      WHEN e.extra_missing_tax_count > 0 THEN 'blocked_supplier_goods_ap_tax_mapping_missing'
      WHEN abs(round((e.existing_line_total_gbp + e.extra_gross_total_gbp)::numeric, 2) - round(COALESCE(e.amount_gbp, 0)::numeric, 2)) > 0.01
        THEN 'blocked_supplier_goods_ap_resolved_lines_do_not_match_header'
      ELSE e.readiness_status
    END::text AS readiness_status,
    CASE
      WHEN COALESCE(e.readiness_status, '') NOT LIKE 'ready%' THEN e.blocker
      WHEN e.extra_missing_ledger_count > 0 THEN e.extra_missing_ledger_count::text || ' non-physical supplier AP line(s) missing ledger mapping'
      WHEN e.extra_missing_tax_count > 0 THEN e.extra_missing_tax_count::text || ' non-physical supplier AP line(s) missing tax mapping'
      WHEN abs(round((e.existing_line_total_gbp + e.extra_gross_total_gbp)::numeric, 2) - round(COALESCE(e.amount_gbp, 0)::numeric, 2)) > 0.01
        THEN 'signed resolved line total ' || round((e.existing_line_total_gbp + e.extra_gross_total_gbp)::numeric, 2)::text || ' does not match supplier invoice amount ' || round(COALESCE(e.amount_gbp, 0)::numeric, 2)::text
      ELSE e.blocker
    END::text AS blocker,
    e.reference_text,
    e.notes_text,
    e.detail_href,
    jsonb_set(
      jsonb_set(
        COALESCE(e.source_payload, '{}'::jsonb),
        '{resolved_lines}',
        COALESCE(e.source_payload->'resolved_lines', '[]'::jsonb) || e.extra_lines,
        true
      ),
      '{totals,line_gross_total_gbp}',
      to_jsonb(round((e.existing_line_total_gbp + e.extra_gross_total_gbp)::numeric, 2)),
      true
    ) AS source_payload
  FROM enriched e;
$func$;

REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() TO service_role;

COMMENT ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() IS
'Canonical supplier goods AP ready helper. Preserves the deployed helper and appends coded active non-physical source rows, including signed discounts, to the Sage purchase-invoice payload with signed line-total validation.';

-- -----------------------------------------------------------------------------
-- 4. Installation postconditions.
-- -----------------------------------------------------------------------------
DO $postconditions$
DECLARE
  v_a_invoice_id uuid;
  v_a_discount numeric;
BEGIN
  IF to_regprocedure('public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL
     AND to_regprocedure('public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(uuid,varchar,integer,varchar,varchar,jsonb,varchar,varchar,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Preserved OCR save implementation is missing after installation.';
  END IF;

  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()') IS NULL THEN
    RAISE EXCEPTION 'Preserved supplier AP helper is missing after installation.';
  END IF;

  SELECT si.id
    INTO v_a_invoice_id
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-A'
    AND si.mindee_ocr_status = 'completed'
  LIMIT 1;

  IF v_a_invoice_id IS NOT NULL THEN
    SELECT round(COALESCE(SUM(sil.amount_inc_vat_gbp), 0)::numeric, 2)
      INTO v_a_discount
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = v_a_invoice_id
      AND sil.line_source = 'ocr_extracted'
      AND sil.amount_inc_vat_gbp < 0;

    IF v_a_discount IS DISTINCT FROM -50.01::numeric THEN
      RAISE EXCEPTION 'A signed OCR discount postcondition failed: expected -50.01, found %.', v_a_discount;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.supplier_invoice_lines sil
      WHERE sil.supplier_invoice_id = v_a_invoice_id
        AND sil.amount_inc_vat_gbp < 0
        AND lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
    ) THEN
      RAISE EXCEPTION 'A signed discount was incorrectly made physically progressable.';
    END IF;
  END IF;
END
$postconditions$;

NOTIFY pgrst, 'reload schema';

COMMIT;
