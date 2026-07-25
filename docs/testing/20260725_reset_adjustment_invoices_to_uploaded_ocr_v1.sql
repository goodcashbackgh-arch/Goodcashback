BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- One-time controlled test reset for the current Ninja order. Only live invoices
-- that already have a delivery and/or discount classification are selected.
-- Uploaded files, operator totals, invoice references, adjustments and all API
-- audit calls are retained. The script aborts before changing anything if any
-- target has crossed into human reconciliation or downstream/accounting use.
DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
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
     OR to_regclass('public.invoice_adjustment_consumption_ledger') IS NULL THEN
    RAISE EXCEPTION 'OCR reset prerequisite relation is missing.';
  END IF;
END $$;

CREATE TEMP TABLE reset_target_invoices ON COMMIT DROP AS
SELECT DISTINCT
  si.id AS supplier_invoice_id,
  si.order_id,
  si.invoice_ref,
  si.invoice_pdf_url,
  si.review_status,
  si.mindee_ocr_status
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
    OR si.mindee_ocr_status <> 'not_started'
    OR EXISTS (
      SELECT 1
      FROM public.supplier_invoice_lines sil
      WHERE sil.supplier_invoice_id = si.id
        AND sil.line_source = 'ocr_extracted'
    )
  );

DO $$
DECLARE
  v_target_count integer;
  v_blocker text;
BEGIN
  SELECT COUNT(*)::integer INTO v_target_count FROM reset_target_invoices;
  IF v_target_count = 0 THEN
    RAISE EXCEPTION 'No live OCR-completed invoice with delivery/discount exists on the target order; nothing was reset.';
  END IF;

  -- Lock the exact source invoices before all checks so the preflight and reset
  -- operate on one stable state.
  PERFORM 1
  FROM public.supplier_invoices si
  JOIN reset_target_invoices t ON t.supplier_invoice_id = si.id
  FOR UPDATE OF si;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    JOIN reset_target_invoices t ON t.supplier_invoice_id = si.id
    WHERE COALESCE(si.review_status, 'pending_review') <> 'pending_review'
       OR COALESCE(si.blocked_from_sage_yn, true) = false
       OR COALESCE(si.is_current_for_order, false) = true
       OR si.reviewed_by_staff_id IS NOT NULL
       OR si.reviewed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Reset blocked: a target invoice has been approved, made current, or manually header-reviewed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    JOIN reset_target_invoices t ON t.supplier_invoice_id = sil.supplier_invoice_id
    WHERE sil.line_source <> 'ocr_extracted'
       OR sil.eligible_for_invoice_yn = 'Y'
       OR sil.qty_confirmed IS NOT NULL
       OR sil.amount_confirmed IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Reset blocked: manual or progressed invoice-line work exists.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_line_accounting_codes codes
    JOIN public.supplier_invoice_lines sil ON sil.id = codes.supplier_invoice_line_id
    JOIN reset_target_invoices t ON t.supplier_invoice_id = sil.supplier_invoice_id
  ) THEN v_blocker := 'supplier line accounting coding';
  ELSIF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_line_resolutions r
    JOIN reset_target_invoices t ON t.supplier_invoice_id = r.supplier_invoice_id
    WHERE r.active = true
  ) THEN v_blocker := 'active line resolution';
  ELSIF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
    JOIN reset_target_invoices t ON t.supplier_invoice_id = sil.supplier_invoice_id
  ) THEN v_blocker := 'tracking allocation';
  ELSIF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_basis b
    JOIN reset_target_invoices t ON t.supplier_invoice_id = b.supplier_invoice_id
  ) THEN v_blocker := 'locked invoice-adjustment basis';
  ELSIF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_consumption_ledger l
    JOIN reset_target_invoices t ON t.supplier_invoice_id = l.supplier_invoice_id
    WHERE l.active = true
  ) THEN v_blocker := 'invoice-adjustment consumption';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    JOIN reset_target_invoices t ON t.supplier_invoice_id = a.supplier_invoice_id
    WHERE a.allocation_type::text = 'supplier_invoice'
      AND a.allocation_status::text <> 'reversed'
  ) THEN v_blocker := 'supplier-payment allocation or draft allocation work';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_order_review_links l
    JOIN reset_target_invoices t ON t.order_id = l.order_id
    WHERE l.is_active = true
      AND (l.expires_at IS NULL OR l.expires_at > now())
  ) THEN v_blocker := 'active customer review';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    JOIN reset_target_invoices t ON t.order_id = h.order_id
    WHERE h.resolved_at IS NULL
      AND h.status IN ('requested','supervisor_approved','converted_to_exception')
      AND (
        h.requested_scope = 'order'
        OR (
          h.requested_scope = 'line'
          AND EXISTS (
            SELECT 1
            FROM public.supplier_invoice_lines sil
            JOIN reset_target_invoices scoped ON scoped.supplier_invoice_id = sil.supplier_invoice_id
            WHERE sil.id = h.supplier_invoice_line_id
              AND scoped.order_id = h.order_id
          )
        )
        OR (
          h.requested_scope = 'tracking'
          AND EXISTS (
            SELECT 1
            FROM public.order_tracking_line_allocations otla
            JOIN public.supplier_invoice_lines sil ON sil.id = otla.supplier_invoice_line_id
            JOIN reset_target_invoices scoped ON scoped.supplier_invoice_id = sil.supplier_invoice_id
            WHERE otla.tracking_submission_id = h.tracking_submission_id
              AND scoped.order_id = h.order_id
              AND COALESCE(otla.qty_allocated, 0) > 0
          )
        )
      )
  ) THEN v_blocker := 'active customer hold';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
    JOIN reset_target_invoices t ON t.supplier_invoice_id = sil.supplier_invoice_id
    JOIN public.disputes d ON d.id = dl.dispute_id
    WHERE dl.resolved_at IS NULL
      AND d.resolved_at IS NULL
  ) THEN v_blocker := 'unresolved exception';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sales_invoices sales
    JOIN reset_target_invoices t ON t.order_id = sales.order_id
    WHERE COALESCE(sales.invoice_type::text, '') IN ('main','supplementary')
      AND COALESCE(sales.sage_status::text, '') <> 'void'
  ) THEN v_blocker := 'non-void customer sales document';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_refund_evidence_submissions e
    JOIN reset_target_invoices t ON t.supplier_invoice_id = e.original_supplier_invoice_id
  ) THEN v_blocker := 'supplier refund or credit evidence';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    JOIN reset_target_invoices t ON t.supplier_invoice_id = s.source_id
    WHERE s.source_table = 'supplier_invoices'
      AND COALESCE(s.active, true) = true
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  ) OR EXISTS (
    SELECT 1
    FROM public.sage_postings p
    JOIN reset_target_invoices t ON t.supplier_invoice_id = p.source_id
    WHERE p.source_table = 'supplier_invoices'
  ) THEN v_blocker := 'frozen or posted supplier accounting artefact';
  END IF;

  IF v_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Reset blocked: target adjustment invoice has downstream or in-progress use (%). No rows were changed.', v_blocker;
  END IF;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'cancelled',
    resolved_at = now(),
    resolution_notes = concat_ws(
      E'\n',
      NULLIF(f.resolution_notes, ''),
      'Cancelled by controlled OCR reset. Uploaded evidence, entered total and delivery/discount classifications were retained.'
    ),
    updated_at = now()
  FROM reset_target_invoices t
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
  USING reset_target_invoices t
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
  FROM reset_target_invoices t
  WHERE si.id = t.supplier_invoice_id;

  IF EXISTS (
    SELECT 1
    FROM reset_target_invoices t
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
    RAISE EXCEPTION 'Reset postcondition failed; transaction rolled back.';
  END IF;
END $$;

SELECT
  t.invoice_ref,
  si.review_status,
  si.mindee_ocr_status,
  (si.invoice_pdf_url IS NOT NULL) AS uploaded_file_retained,
  fs.invoice_total_gbp AS entered_total_retained,
  COALESCE(adj.delivery_retained_gbp, 0) AS delivery_retained_gbp,
  COALESCE(adj.discount_retained_gbp, 0) AS discount_retained_gbp,
  COALESCE(lines.remaining_ocr_line_count, 0) AS remaining_ocr_line_count,
  COALESCE(audit.retained_mindee_audit_call_count, 0) AS retained_mindee_audit_call_count
FROM reset_target_invoices t
JOIN public.supplier_invoices si ON si.id = t.supplier_invoice_id
JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id
LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(CASE WHEN ova.adjustment_type = 'retailer_delivery' THEN ova.amount_gbp ELSE 0 END), 0) AS delivery_retained_gbp,
    COALESCE(SUM(CASE WHEN ova.adjustment_type = 'retailer_discount' THEN ova.amount_gbp ELSE 0 END), 0) AS discount_retained_gbp
  FROM public.order_value_adjustments ova
  WHERE ova.supplier_invoice_id = si.id
    AND ova.approval_status <> 'rejected'
) adj ON true
LEFT JOIN LATERAL (
  SELECT COUNT(*) FILTER (WHERE sil.line_source = 'ocr_extracted')::integer AS remaining_ocr_line_count
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = si.id
) lines ON true
LEFT JOIN LATERAL (
  SELECT COUNT(*)::integer AS retained_mindee_audit_call_count
  FROM public.mindee_api_calls mac
  WHERE mac.supplier_invoice_id = si.id
) audit ON true
ORDER BY t.invoice_ref;

COMMIT;
