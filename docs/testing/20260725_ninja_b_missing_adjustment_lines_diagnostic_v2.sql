-- V2: one-row, read-only SQL Editor diagnostic for NIN-240726-B.
--
-- Returns the invoice state, declared delivery/discount, saved invoice lines,
-- retained raw Mindee line items and OCR audit history in one JSON result.
--
-- SELECT only: no INSERT, UPDATE, DELETE, RPC, trigger change or auth.uid().

WITH target AS (
  SELECT
    si.id AS supplier_invoice_id,
    si.order_id,
    si.invoice_ref,
    si.review_status,
    si.mindee_ocr_status,
    si.ocr_extracted_at,
    si.mindee_result_saved_at,
    si.ocr_invoice_total_gbp,
    si.ocr_raw_json,
    fs.invoice_total_gbp AS entered_invoice_total_gbp
  FROM public.supplier_invoices si
  LEFT JOIN public.supplier_invoice_financial_summary fs
    ON fs.supplier_invoice_id = si.id
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-B'
  ORDER BY si.uploaded_at DESC
  LIMIT 1
),
payload AS (
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
    ) AS raw_line_items
  FROM target t
),
raw_lines AS (
  SELECT
    p.supplier_invoice_id,
    item.ordinality::integer AS line_order,
    CASE
      WHEN jsonb_typeof(item.value->'fields') = 'object' THEN item.value->'fields'
      ELSE item.value
    END AS row_json
  FROM payload p
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(p.raw_line_items) = 'array' THEN p.raw_line_items
      ELSE '[]'::jsonb
    END
  ) WITH ORDINALITY AS item(value, ordinality)
)
SELECT jsonb_build_object(
  'invoice', jsonb_build_object(
    'supplier_invoice_id', p.supplier_invoice_id,
    'order_id', p.order_id,
    'invoice_ref', p.invoice_ref,
    'review_status', p.review_status,
    'mindee_ocr_status', p.mindee_ocr_status,
    'ocr_extracted_at', p.ocr_extracted_at,
    'mindee_result_saved_at', p.mindee_result_saved_at,
    'ocr_invoice_total_gbp', p.ocr_invoice_total_gbp,
    'entered_invoice_total_gbp', p.entered_invoice_total_gbp
  ),
  'declared_adjustments', COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'adjustment_type', ova.adjustment_type,
        'amount_gbp', ova.amount_gbp,
        'approval_status', ova.approval_status
      )
      ORDER BY ova.adjustment_type, ova.id
    )
    FROM public.order_value_adjustments ova
    WHERE ova.supplier_invoice_id = p.supplier_invoice_id
      AND ova.approval_status <> 'rejected'
  ), '[]'::jsonb),
  'saved_lines', COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'supplier_invoice_line_id', sil.id,
        'line_order', sil.line_order,
        'line_source', sil.line_source,
        'description', sil.description,
        'qty', sil.qty,
        'amount_inc_vat_gbp', sil.amount_inc_vat_gbp,
        'eligible_for_invoice_yn', sil.eligible_for_invoice_yn,
        'qty_confirmed', sil.qty_confirmed,
        'amount_confirmed', sil.amount_confirmed
      )
      ORDER BY sil.line_order, sil.id
    )
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = p.supplier_invoice_id
  ), '[]'::jsonb),
  'raw_mindee_lines', COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'line_order', r.line_order,
        'description', COALESCE(
          NULLIF(btrim(r.row_json #>> '{description,value}'), ''),
          NULLIF(btrim(r.row_json->>'description'), ''),
          NULLIF(btrim(r.row_json #>> '{name,value}'), ''),
          NULLIF(btrim(r.row_json->>'name'), ''),
          NULLIF(btrim(r.row_json #>> '{label,value}'), ''),
          NULLIF(btrim(r.row_json->>'label'), '')
        ),
        'amount_text', COALESCE(
          r.row_json #>> '{total_amount,value}',
          r.row_json->>'total_amount',
          r.row_json #>> '{total_price,value}',
          r.row_json->>'total_price',
          r.row_json #>> '{amount,value}',
          r.row_json->>'amount',
          r.row_json #>> '{line_total,value}',
          r.row_json->>'line_total'
        ),
        'raw_line_json', r.row_json
      )
      ORDER BY r.line_order
    )
    FROM raw_lines r
    WHERE r.supplier_invoice_id = p.supplier_invoice_id
  ), '[]'::jsonb),
  'mindee_audit_history', COALESCE((
    SELECT jsonb_agg(a.audit_row ORDER BY a.request_started_at DESC NULLS LAST, a.id DESC)
    FROM (
      SELECT
        mac.id,
        mac.request_started_at,
        jsonb_build_object(
          'action_type', mac.action_type,
          'success_yn', mac.success_yn,
          'http_status', mac.http_status,
          'mindee_job_id', mac.mindee_job_id,
          'mindee_inference_id', mac.mindee_inference_id,
          'request_started_at', mac.request_started_at,
          'request_completed_at', mac.request_completed_at,
          'result_saved_at', mac.result_saved_at,
          'error_message', mac.error_message
        ) AS audit_row
      FROM public.mindee_api_calls mac
      WHERE mac.supplier_invoice_id = p.supplier_invoice_id
      ORDER BY mac.request_started_at DESC NULLS LAST, mac.id DESC
      LIMIT 10
    ) a
  ), '[]'::jsonb)
) AS diagnostic
FROM payload p;
