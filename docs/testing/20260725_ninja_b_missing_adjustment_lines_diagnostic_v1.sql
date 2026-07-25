-- Read-only SQL Editor diagnostic for NIN-240726-B.
--
-- Purpose:
--   1. show the invoice and declared delivery/discount facts;
--   2. show the supplier_invoice_lines actually saved;
--   3. show the line items retained in the raw Mindee payload;
--   4. show the recent Mindee audit calls.
--
-- This file contains SELECT statements only. It performs no INSERT, UPDATE,
-- DELETE, RPC call, trigger change or auth.uid()-dependent function call.

-- Result 1: invoice state and declared adjustments.
SELECT
  si.id AS supplier_invoice_id,
  si.order_id,
  si.invoice_ref,
  si.review_status,
  si.mindee_ocr_status,
  si.ocr_extracted_at,
  si.mindee_result_saved_at,
  si.ocr_invoice_total_gbp,
  fs.invoice_total_gbp AS entered_invoice_total_gbp,
  COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'adjustment_type', ova.adjustment_type,
        'amount_gbp', ova.amount_gbp,
        'approval_status', ova.approval_status
      )
      ORDER BY ova.adjustment_type
    )
    FROM public.order_value_adjustments ova
    WHERE ova.supplier_invoice_id = si.id
      AND ova.approval_status <> 'rejected'
  ), '[]'::jsonb) AS declared_adjustments
FROM public.supplier_invoices si
LEFT JOIN public.supplier_invoice_financial_summary fs
  ON fs.supplier_invoice_id = si.id
WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
  AND si.invoice_ref = 'NIN-240726-B'
ORDER BY si.uploaded_at DESC
LIMIT 1;

-- Result 2: lines actually saved for B.
SELECT
  sil.id AS supplier_invoice_line_id,
  sil.line_order,
  sil.line_source,
  sil.description,
  sil.qty,
  sil.amount_inc_vat_gbp,
  sil.eligible_for_invoice_yn,
  sil.qty_confirmed,
  sil.amount_confirmed
FROM public.supplier_invoice_lines sil
JOIN public.supplier_invoices si
  ON si.id = sil.supplier_invoice_id
WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
  AND si.invoice_ref = 'NIN-240726-B'
ORDER BY sil.line_order, sil.id;

-- Result 3: line items present in B's retained raw Mindee payload.
WITH target AS (
  SELECT si.ocr_raw_json
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-B'
  ORDER BY si.uploaded_at DESC
  LIMIT 1
),
payload AS (
  SELECT COALESCE(
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
),
expanded AS (
  SELECT
    item.ordinality::integer AS line_order,
    CASE
      WHEN jsonb_typeof(item.value->'fields') = 'object' THEN item.value->'fields'
      ELSE item.value
    END AS row_json
  FROM payload p
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(p.line_items) = 'array' THEN p.line_items
      ELSE '[]'::jsonb
    END
  ) WITH ORDINALITY AS item(value, ordinality)
)
SELECT
  e.line_order,
  COALESCE(
    NULLIF(btrim(e.row_json #>> '{description,value}'), ''),
    NULLIF(btrim(e.row_json->>'description'), ''),
    NULLIF(btrim(e.row_json #>> '{name,value}'), ''),
    NULLIF(btrim(e.row_json->>'name'), ''),
    NULLIF(btrim(e.row_json #>> '{label,value}'), ''),
    NULLIF(btrim(e.row_json->>'label'), '')
  ) AS extracted_description,
  NULLIF(regexp_replace(COALESCE(
    e.row_json #>> '{total_amount,value}',
    e.row_json->>'total_amount',
    e.row_json #>> '{total_price,value}',
    e.row_json->>'total_price',
    e.row_json #>> '{amount,value}',
    e.row_json->>'amount',
    e.row_json #>> '{line_total,value}',
    e.row_json->>'line_total',
    ''
  ), '[^0-9.\-]', '', 'g'), '')::numeric AS extracted_amount_gbp,
  e.row_json AS raw_line_json
FROM expanded e
ORDER BY e.line_order;

-- Result 4: recent Mindee audit history for B.
SELECT
  mac.action_type,
  mac.success_yn,
  mac.http_status,
  mac.mindee_job_id,
  mac.mindee_inference_id,
  mac.request_started_at,
  mac.request_completed_at,
  mac.result_saved_at,
  mac.error_message
FROM public.mindee_api_calls mac
WHERE mac.supplier_invoice_id = (
  SELECT si.id
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-B'
  ORDER BY si.uploaded_at DESC
  LIMIT 1
)
ORDER BY mac.request_started_at DESC NULLS LAST, mac.id DESC
LIMIT 10;
