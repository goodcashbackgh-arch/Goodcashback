BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Selective replacement for v1.
-- Exact scope: the current Ninja test order and only invoices carrying a live
-- delivery and/or discount classification. Protected invoices are reported as
-- SKIPPED instead of aborting the safe reset of another eligible invoice.
DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_financial_summary') IS NULL
     OR to_regclass('public.order_value_adjustments') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.mindee_api_calls') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.customer_order_review_links') IS NULL
     OR to_regclass('public.customer_pre_shipment_hold_requests') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.dispute_refund_evidence_submissions') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.sage_postings') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_line_accounting_codes') IS NULL
     OR to_regclass('public.invoice_adjustment_basis') IS NULL
     OR to_regclass('public.invoice_adjustment_consumption_ledger') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL THEN
    RAISE EXCEPTION 'Selective OCR reset prerequisite relation is missing.';
  END IF;
END $$;

CREATE TEMP TABLE reset_candidates ON COMMIT DROP AS
SELECT DISTINCT
  si.id AS supplier_invoice_id,
  si.order_id,
  si.invoice_ref,
  si.invoice_pdf_url,
  si.review_status,
  si.mindee_ocr_status,
  CASE
    WHEN COALESCE(si.review_status, 'pending_review') <> 'pending_review'
      THEN 'Invoice status is ' || COALESCE(si.review_status, 'NULL') || '.'
    WHEN COALESCE(si.blocked_from_sage_yn, true) = false
      THEN 'Supplier-accounting gate has already been released.'
    WHEN COALESCE(si.is_current_for_order, false) = true
      THEN 'Invoice is already current/approved.'
    WHEN si.reviewed_by_staff_id IS NOT NULL OR si.reviewed_at IS NOT NULL
      THEN 'A staff header review has already been completed.'
    WHEN EXISTS (
      SELECT 1
      FROM public.supplier_invoice_lines sil
      WHERE sil.supplier_invoice_id = si.id
        AND (
          sil.line_source <> 'ocr_extracted'
          OR sil.eligible_for_invoice_yn = 'Y'
          OR sil.qty_confirmed IS NOT NULL
          OR sil.amount_confirmed IS NOT NULL
        )
    ) THEN 'Manual or progressed invoice-line work exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_accounting_codes c
      JOIN public.supplier_invoice_lines sil ON sil.id = c.supplier_invoice_line_id
      WHERE sil.supplier_invoice_id = si.id
    ) THEN 'Supplier-line accounting coding exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_id = si.id
        AND r.active = true
    ) THEN 'An active line resolution exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.order_tracking_line_allocations a
      JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
      WHERE sil.supplier_invoice_id = si.id
    ) THEN 'Tracking allocation exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_line_memberships m
      JOIN public.supplier_invoice_lines sil ON sil.id = m.supplier_invoice_line_id
      WHERE sil.supplier_invoice_id = si.id
    ) THEN 'Shipment membership exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines r
      WHERE r.supplier_invoice_id = si.id
    ) THEN 'Customer-sales release membership exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.invoice_adjustment_basis b
      WHERE b.supplier_invoice_id = si.id
    ) THEN 'A locked invoice-adjustment basis exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.invoice_adjustment_consumption_ledger l
      WHERE l.supplier_invoice_id = si.id
        AND l.active = true
    ) THEN 'Invoice-adjustment consumption exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.dva_statement_line_allocations a
      WHERE a.supplier_invoice_id = si.id
        AND a.allocation_type::text = 'supplier_invoice'
        AND a.allocation_status::text <> 'reversed'
    ) THEN 'Supplier-payment allocation or draft allocation work exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.customer_order_review_links l
      WHERE l.order_id = si.order_id
        AND l.is_active = true
        AND (l.expires_at IS NULL OR l.expires_at > now())
    ) THEN 'An active customer review exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = si.order_id
        AND h.resolved_at IS NULL
        AND h.status IN ('requested','supervisor_approved','converted_to_exception')
        AND (
          h.requested_scope = 'order'
          OR (
            h.requested_scope = 'line'
            AND EXISTS (
              SELECT 1
              FROM public.supplier_invoice_lines sil
              WHERE sil.supplier_invoice_id = si.id
                AND sil.id = h.supplier_invoice_line_id
            )
          )
          OR (
            h.requested_scope = 'tracking'
            AND EXISTS (
              SELECT 1
              FROM public.order_tracking_line_allocations a
              JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
              WHERE sil.supplier_invoice_id = si.id
                AND a.tracking_submission_id = h.tracking_submission_id
                AND COALESCE(a.qty_allocated, 0) > 0
            )
          )
        )
    ) THEN 'An active customer hold affects this invoice.'
    WHEN EXISTS (
      SELECT 1
      FROM public.dispute_lines dl
      JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
      JOIN public.disputes d ON d.id = dl.dispute_id
      WHERE sil.supplier_invoice_id = si.id
        AND dl.resolved_at IS NULL
        AND d.resolved_at IS NULL
    ) THEN 'An unresolved exception affects this invoice.'
    WHEN EXISTS (
      SELECT 1
      FROM public.sales_invoices sales
      WHERE sales.order_id = si.order_id
        AND COALESCE(sales.invoice_type::text, '') IN ('main','supplementary')
        AND COALESCE(sales.sage_status::text, '') <> 'void'
    ) THEN 'A non-void customer sales document exists for the order.'
    WHEN EXISTS (
      SELECT 1
      FROM public.dispute_refund_evidence_submissions e
      WHERE e.original_supplier_invoice_id = si.id
    ) THEN 'Supplier refund or credit evidence exists.'
    WHEN EXISTS (
      SELECT 1
      FROM public.sage_posting_snapshots s
      WHERE s.source_table = 'supplier_invoices'
        AND s.source_id = si.id
        AND COALESCE(s.active, true) = true
        AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
    ) OR EXISTS (
      SELECT 1
      FROM public.sage_postings p
      WHERE p.source_table = 'supplier_invoices'
        AND p.source_id = si.id
    ) THEN 'A frozen or posted supplier-accounting artefact exists.'
    ELSE NULL
  END AS skip_reason
FROM public.supplier_invoices si
WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
  AND COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  )
  AND EXISTS (
    SELECT 1
    FROM public.order_value_adjustments ova
    WHERE ova.supplier_invoice_id = si.id
      AND ova.adjustment_type IN ('retailer_delivery','retailer_discount')
      AND ova.approval_status <> 'rejected'
      AND COALESCE(ova.amount_gbp, 0) > 0
  )
  AND (
    si.ocr_raw_json IS NOT NULL
    OR si.ocr_extracted_at IS NOT NULL
    OR si.ocr_invoice_total_gbp IS NOT NULL
    OR si.mindee_job_id IS NOT NULL
    OR si.mindee_inference_id IS NOT NULL
    OR COALESCE(si.mindee_ocr_status, 'not_started') <> 'not_started'
    OR EXISTS (
      SELECT 1
      FROM public.supplier_invoice_lines sil
      WHERE sil.supplier_invoice_id = si.id
        AND sil.line_source = 'ocr_extracted'
    )
  );

CREATE TEMP TABLE reset_targets ON COMMIT DROP AS
SELECT *
FROM reset_candidates
WHERE skip_reason IS NULL;

DO $$
BEGIN
  -- Lock only the rows that will actually be reset, then recheck the identity and
  -- human-review gates to close the race between selection and mutation.
  PERFORM 1
  FROM public.supplier_invoices si
  JOIN reset_targets t ON t.supplier_invoice_id = si.id
  FOR UPDATE OF si;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    JOIN reset_targets t ON t.supplier_invoice_id = si.id
    WHERE COALESCE(si.review_status, 'pending_review') <> 'pending_review'
       OR COALESCE(si.blocked_from_sage_yn, true) = false
       OR COALESCE(si.is_current_for_order, false) = true
       OR si.reviewed_by_staff_id IS NOT NULL
       OR si.reviewed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'A reset target changed during preflight; no rows were changed.';
  END IF;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'cancelled',
    resolved_at = now(),
    resolution_notes = concat_ws(
      E'\n',
      NULLIF(f.resolution_notes, ''),
      'Cancelled by selective OCR reset. Uploaded evidence, entered total and delivery/discount classifications were retained.'
    ),
    updated_at = now()
  FROM reset_targets t
  WHERE f.supplier_invoice_id = t.supplier_invoice_id
    AND f.status IN ('open','under_review')
    AND f.flag_type IN (
      'invoice_total_mismatch',
      'ocr_unclear',
      'wrong_invoice',
      'delivery_discount_query',
      'manual_line_needed'
    )
    AND (
      f.message ILIKE '%Mindee%'
      OR f.message ILIKE 'OCR %'
      OR f.message ILIKE '%OCR %'
      OR f.message ILIKE '%document read%'
    );

  DELETE FROM public.supplier_invoice_lines sil
  USING reset_targets t
  WHERE sil.supplier_invoice_id = t.supplier_invoice_id
    AND sil.line_source = 'ocr_extracted';

  UPDATE public.supplier_invoices si
  SET
    ocr_service_used = 'manual',
    ocr_raw_json = NULL,
    ocr_extracted_at = NULL,
    ocr_invoice_ref = NULL,
    ocr_retailer_name = NULL,
    ocr_invoice_date = NULL,
    ocr_invoice_total_gbp = NULL,
    mindee_job_id = NULL,
    mindee_inference_id = NULL,
    mindee_model_id = NULL,
    mindee_ocr_status = 'not_started',
    mindee_enqueued_at = NULL,
    mindee_completed_at = NULL,
    mindee_result_saved_at = NULL,
    mindee_last_http_status = NULL,
    mindee_pages_consumed = NULL,
    mindee_error_message = NULL,
    review_status = 'pending_review',
    blocked_from_sage_yn = true
  FROM reset_targets t
  WHERE si.id = t.supplier_invoice_id;

  IF EXISTS (
    SELECT 1
    FROM reset_targets t
    JOIN public.supplier_invoices si ON si.id = t.supplier_invoice_id
    WHERE si.invoice_pdf_url IS DISTINCT FROM t.invoice_pdf_url
       OR si.invoice_ref IS DISTINCT FROM t.invoice_ref
       OR si.mindee_ocr_status <> 'not_started'
       OR si.ocr_raw_json IS NOT NULL
       OR si.ocr_extracted_at IS NOT NULL
       OR si.ocr_invoice_total_gbp IS NOT NULL
       OR si.mindee_job_id IS NOT NULL
       OR si.mindee_inference_id IS NOT NULL
       OR EXISTS (
         SELECT 1
         FROM public.supplier_invoice_lines sil
         WHERE sil.supplier_invoice_id = si.id
           AND sil.line_source = 'ocr_extracted'
       )
       OR NOT EXISTS (
         SELECT 1
         FROM public.supplier_invoice_financial_summary fs
         WHERE fs.supplier_invoice_id = si.id
       )
       OR NOT EXISTS (
         SELECT 1
         FROM public.order_value_adjustments ova
         WHERE ova.supplier_invoice_id = si.id
           AND ova.adjustment_type IN ('retailer_delivery','retailer_discount')
           AND ova.approval_status <> 'rejected'
       )
  ) THEN
    RAISE EXCEPTION 'Selective reset postcondition failed; transaction rolled back.';
  END IF;
END $$;

-- Run OCR again only for rows marked RESET. SKIPPED rows are intentionally
-- preserved and the reason is shown alongside them.
SELECT
  CASE WHEN t.supplier_invoice_id IS NULL THEN 'SKIPPED' ELSE 'RESET' END AS reset_action,
  c.invoice_ref,
  COALESCE(c.skip_reason, 'OCR returned to uploaded/not-started; run OCR again.') AS result,
  si.review_status,
  si.mindee_ocr_status,
  (si.invoice_pdf_url IS NOT NULL) AS uploaded_file_retained,
  fs.invoice_total_gbp AS entered_total_retained,
  COALESCE(adj.delivery_gbp, 0) AS delivery_retained_gbp,
  COALESCE(adj.discount_gbp, 0) AS discount_retained_gbp,
  COALESCE(lines.ocr_line_count, 0) AS remaining_ocr_line_count,
  COALESCE(audit.call_count, 0) AS retained_mindee_audit_call_count
FROM reset_candidates c
LEFT JOIN reset_targets t ON t.supplier_invoice_id = c.supplier_invoice_id
JOIN public.supplier_invoices si ON si.id = c.supplier_invoice_id
JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id
LEFT JOIN LATERAL (
  SELECT
    SUM(ova.amount_gbp) FILTER (WHERE ova.adjustment_type = 'retailer_delivery') AS delivery_gbp,
    SUM(ova.amount_gbp) FILTER (WHERE ova.adjustment_type = 'retailer_discount') AS discount_gbp
  FROM public.order_value_adjustments ova
  WHERE ova.supplier_invoice_id = si.id
    AND ova.approval_status <> 'rejected'
) adj ON true
LEFT JOIN LATERAL (
  SELECT COUNT(*) FILTER (WHERE sil.line_source = 'ocr_extracted')::integer AS ocr_line_count
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = si.id
) lines ON true
LEFT JOIN LATERAL (
  SELECT COUNT(*)::integer AS call_count
  FROM public.mindee_api_calls mac
  WHERE mac.supplier_invoice_id = si.id
) audit ON true
ORDER BY CASE WHEN t.supplier_invoice_id IS NULL THEN 1 ELSE 0 END, c.invoice_ref;

COMMIT;
