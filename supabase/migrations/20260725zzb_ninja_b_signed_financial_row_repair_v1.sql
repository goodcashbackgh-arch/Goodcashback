BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Controlled historical repair and installation proof for NIN-240726-B.
-- The retained Mindee result is parsed into the same JSON shape received by the
-- permanent materialiser. No direct line INSERT, classification, accounting,
-- approval, progression, shipment, freeze or posting action occurs here.
--
-- B already has its two ordinary goods rows progressed. That is compatible with
-- this repair because the materialiser adds only the two missing non-physical
-- financial rows and verifies all retained OCR line identities. Protected later
-- work (coding, resolutions, disputes, tracking, shipment or Sage snapshots)
-- remains a hard blocker.

DO $repair_b$
DECLARE
  v_invoice_id uuid;
  v_review_status text;
  v_mindee_status text;
  v_blocked boolean;
  v_header_total numeric;
  v_entered_total numeric;
  v_raw_json jsonb;
  v_lines jsonb;
  v_raw_count integer;
  v_raw_total numeric;
  v_goods_count integer;
  v_goods_total numeric;
  v_discount_count integer;
  v_discount_total numeric;
  v_delivery_count integer;
  v_delivery_total numeric;
  v_declared_discount numeric;
  v_declared_delivery numeric;
  v_inserted integer;
BEGIN
  IF to_regprocedure('public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Permanent OCR financial-row materialiser is missing.';
  END IF;

  SELECT
    si.id,
    si.review_status::text,
    si.mindee_ocr_status::text,
    COALESCE(si.blocked_from_sage_yn, true),
    round(si.ocr_invoice_total_gbp::numeric, 2),
    round(fs.invoice_total_gbp::numeric, 2),
    si.ocr_raw_json
  INTO
    v_invoice_id,
    v_review_status,
    v_mindee_status,
    v_blocked,
    v_header_total,
    v_entered_total,
    v_raw_json
  FROM public.supplier_invoices si
  LEFT JOIN public.supplier_invoice_financial_summary fs
    ON fs.supplier_invoice_id = si.id
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-B'
  ORDER BY si.uploaded_at DESC, si.id DESC
  LIMIT 1
  FOR UPDATE OF si;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Controlled B repair target was not found.';
  END IF;

  IF v_review_status IS DISTINCT FROM 'pending_review'
     OR v_mindee_status IS DISTINCT FROM 'completed'
     OR NOT v_blocked
     OR v_header_total IS DISTINCT FROM 249.99::numeric
     OR v_entered_total IS DISTINCT FROM 249.99::numeric
     OR v_raw_json IS NULL THEN
    RAISE EXCEPTION
      'Controlled B preflight failed: review %, Mindee %, blocked %, OCR total %, entered total %, raw %.',
      v_review_status, v_mindee_status, v_blocked,
      v_header_total, v_entered_total, v_raw_json IS NOT NULL;
  END IF;

  -- Existing progression of B's two ordinary goods rows is intentionally
  -- permitted. The permanent materialiser verifies those retained OCR identities
  -- and inserts only the absent financial rows. Any later protected work still
  -- makes a historical source repair unsafe.
  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    JOIN public.supplier_invoice_line_accounting_codes c
      ON c.supplier_invoice_line_id = sil.id
    WHERE sil.supplier_invoice_id = v_invoice_id
  ) OR EXISTS (
    SELECT 1
    FROM public.supplier_invoice_line_resolutions r
    WHERE r.supplier_invoice_id = v_invoice_id
  ) OR EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.supplier_invoice_lines sil
      ON sil.id = dl.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice_id
  ) OR EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    JOIN public.supplier_invoice_lines sil
      ON sil.id = a.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice_id
  ) OR EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.supplier_invoice_lines sil
      ON sil.id = m.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice_id
  ) OR EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    WHERE s.source_table = 'supplier_invoices'
      AND s.source_id = v_invoice_id
      AND COALESCE(s.active, true) = true
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  ) THEN
    RAISE EXCEPTION 'Controlled B repair refused because protected downstream work already exists.';
  END IF;

  WITH payload AS (
    SELECT COALESCE(
      v_raw_json #> '{inference,result,fields,line_items,items}',
      v_raw_json #> '{inference,result,fields,items,items}',
      v_raw_json #> '{inference,result,fields,invoice_lines,items}',
      v_raw_json #> '{inference,result,fields,line_items}',
      v_raw_json #> '{inference,result,fields,items}',
      v_raw_json #> '{inference,result,fields,invoice_lines}',
      v_raw_json #> '{inference,result,prediction,line_items}',
      v_raw_json #> '{result,fields,line_items}',
      v_raw_json #> '{document,inference,prediction,line_items}',
      '[]'::jsonb
    ) AS items
  ), expanded AS (
    SELECT
      item.ordinality::integer AS line_order,
      CASE
        WHEN jsonb_typeof(item.value->'fields') = 'object'
          THEN item.value->'fields'
        ELSE item.value
      END AS row_json
    FROM payload p
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(p.items) = 'array' THEN p.items ELSE '[]'::jsonb END
    ) WITH ORDINALITY AS item(value, ordinality)
  ), parsed AS (
    SELECT
      e.line_order,
      COALESCE(
        NULLIF(btrim(e.row_json #>> '{description,value}'), ''),
        NULLIF(btrim(e.row_json->>'description'), ''),
        NULLIF(btrim(e.row_json #>> '{name,value}'), ''),
        NULLIF(btrim(e.row_json->>'name'), ''),
        NULLIF(btrim(e.row_json #>> '{label,value}'), ''),
        NULLIF(btrim(e.row_json->>'label'), ''),
        'OCR line ' || e.line_order::text
      ) AS description,
      COALESCE(
        NULLIF(regexp_replace(COALESCE(
          e.row_json #>> '{quantity,value}',
          e.row_json->>'quantity',
          e.row_json #>> '{qty,value}',
          e.row_json->>'qty',
          '1'
        ), '[^0-9.\-]', '', 'g'), '')::numeric,
        1
      ) AS qty,
      NULLIF(regexp_replace(replace(replace(COALESCE(
        e.row_json #>> '{total_amount,value}',
        e.row_json->>'total_amount',
        e.row_json #>> '{total_price,value}',
        e.row_json->>'total_price',
        e.row_json #>> '{amount,value}',
        e.row_json->>'amount',
        e.row_json #>> '{line_total,value}',
        e.row_json->>'line_total',
        ''
      ), '−', '-'), '–', '-'), '[^0-9.\-]', '', 'g'), '')::numeric AS amount_gbp,
      NULLIF(btrim(COALESCE(
        e.row_json #>> '{product_code,value}',
        e.row_json->>'product_code',
        e.row_json #>> '{sku,value}',
        e.row_json->>'sku',
        e.row_json #>> '{reference,value}',
        e.row_json->>'reference',
        ''
      )), '') AS retailer_sku
    FROM expanded e
  )
  SELECT
    jsonb_agg(jsonb_build_object(
      'line_order', p.line_order,
      'retailer_sku', p.retailer_sku,
      'description', p.description,
      'qty', p.qty,
      'amount_inc_vat_gbp', p.amount_gbp
    ) ORDER BY p.line_order),
    COUNT(*)::integer,
    round(COALESCE(SUM(p.amount_gbp), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE p.amount_gbp > 0
        AND lower(regexp_replace(p.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          !~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    )::integer,
    round(COALESCE(SUM(p.amount_gbp) FILTER (
      WHERE p.amount_gbp > 0
        AND lower(regexp_replace(p.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          !~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    ), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE p.amount_gbp < 0
        AND lower(regexp_replace(p.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)'
    )::integer,
    round(COALESCE(SUM(p.amount_gbp) FILTER (
      WHERE p.amount_gbp < 0
        AND lower(regexp_replace(p.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)'
    ), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE p.amount_gbp > 0
        AND lower(regexp_replace(p.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    )::integer,
    round(COALESCE(SUM(p.amount_gbp) FILTER (
      WHERE p.amount_gbp > 0
        AND lower(regexp_replace(p.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    ), 0)::numeric, 2)
  INTO
    v_lines,
    v_raw_count,
    v_raw_total,
    v_goods_count,
    v_goods_total,
    v_discount_count,
    v_discount_total,
    v_delivery_count,
    v_delivery_total
  FROM parsed p;

  SELECT
    round(COALESCE(SUM(ova.amount_gbp) FILTER (
      WHERE ova.adjustment_type = 'retailer_discount'
    ), 0)::numeric, 2),
    round(COALESCE(SUM(ova.amount_gbp) FILTER (
      WHERE ova.adjustment_type = 'retailer_delivery'
    ), 0)::numeric, 2)
  INTO v_declared_discount, v_declared_delivery
  FROM public.order_value_adjustments ova
  WHERE ova.supplier_invoice_id = v_invoice_id
    AND ova.approval_status <> 'rejected';

  IF v_raw_count <> 4
     OR v_raw_total IS DISTINCT FROM 249.99::numeric
     OR v_goods_count <> 2
     OR v_goods_total IS DISTINCT FROM 249.98::numeric
     OR v_discount_count <> 1
     OR v_discount_total IS DISTINCT FROM -10.00::numeric
     OR v_delivery_count <> 1
     OR v_delivery_total IS DISTINCT FROM 10.01::numeric
     OR v_declared_discount IS DISTINCT FROM 10.00::numeric
     OR v_declared_delivery IS DISTINCT FROM 10.01::numeric THEN
    RAISE EXCEPTION
      'Controlled B raw-evidence preflight failed: rows %, signed %, goods %/%, discount %/%/%, delivery %/%/%.',
      v_raw_count, v_raw_total,
      v_goods_count, v_goods_total,
      v_discount_count, v_discount_total, v_declared_discount,
      v_delivery_count, v_delivery_total, v_declared_delivery;
  END IF;

  v_inserted :=
    public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(
      v_invoice_id,
      v_lines
    );

  IF v_inserted NOT IN (0, 1, 2) THEN
    RAISE EXCEPTION 'Controlled B repair inserted an unexpected number of rows: %.', v_inserted;
  END IF;
END
$repair_b$;

DO $postconditions$
DECLARE
  v_invoice_id uuid;
  v_line_count integer;
  v_signed_total numeric;
  v_discount_count integer;
  v_discount_total numeric;
  v_delivery_count integer;
  v_delivery_total numeric;
BEGIN
  SELECT si.id
  INTO v_invoice_id
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-B'
  ORDER BY si.uploaded_at DESC, si.id DESC
  LIMIT 1;

  SELECT
    COUNT(*)::integer,
    round(COALESCE(SUM(sil.amount_inc_vat_gbp), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE sil.amount_inc_vat_gbp < 0
        AND lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)'
    )::integer,
    round(COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (
      WHERE sil.amount_inc_vat_gbp < 0
    ), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE sil.amount_inc_vat_gbp > 0
        AND lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    )::integer,
    round(COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (
      WHERE sil.amount_inc_vat_gbp > 0
        AND lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    ), 0)::numeric, 2)
  INTO
    v_line_count,
    v_signed_total,
    v_discount_count,
    v_discount_total,
    v_delivery_count,
    v_delivery_total
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = v_invoice_id
    AND sil.line_source = 'ocr_extracted';

  IF v_line_count <> 4
     OR v_signed_total IS DISTINCT FROM 249.99::numeric
     OR v_discount_count <> 1
     OR v_discount_total IS DISTINCT FROM -10.00::numeric
     OR v_delivery_count <> 1
     OR v_delivery_total IS DISTINCT FROM 10.01::numeric THEN
    RAISE EXCEPTION
      'Controlled B postcondition failed: rows %, signed %, discount %/%, delivery %/%.',
      v_line_count, v_signed_total,
      v_discount_count, v_discount_total,
      v_delivery_count, v_delivery_total;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = v_invoice_id
      AND (
        sil.amount_inc_vat_gbp < 0
        OR lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
             ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
      )
      AND lower(btrim(COALESCE(sil.eligible_for_invoice_yn, 'n')))
          IN ('y', 'yes', 'true', '1')
  ) THEN
    RAISE EXCEPTION 'Controlled B repair made a financial row physically eligible.';
  END IF;

  IF EXISTS (
    SELECT sil.line_order
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = v_invoice_id
      AND sil.line_source = 'ocr_extracted'
    GROUP BY sil.line_order
    HAVING COUNT(*) <> 1
  ) THEN
    RAISE EXCEPTION 'Controlled B repair left duplicate OCR line-order identity.';
  END IF;
END
$postconditions$;

COMMIT;