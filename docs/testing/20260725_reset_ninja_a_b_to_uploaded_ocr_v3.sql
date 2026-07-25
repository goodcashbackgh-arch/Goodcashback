BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Exact one-time reset for the two current Ninja test invoices that contain
-- delivery/discount classifications. Operational target: uploaded evidence is
-- retained, OCR is not started, and the existing Start document extraction
-- control becomes available again.
--
-- Deliberately retained:
--   * uploaded PDF and invoice reference
--   * operator-entered gross invoice total
--   * delivery/discount classifications
--   * Mindee API-call audit history
--   * prior staff header-review fields (audit only; they do not block OCR start)
--   * legacy reference-family marker is_current_for_order
--
-- Deliberately cleared:
--   * OCR-derived lines and OCR/header result fields
--   * current Mindee job/inference state
--   * OCR-generated open review flags

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
    RAISE EXCEPTION 'Exact A/B OCR reset prerequisite relation is missing.';
  END IF;
END $$;

CREATE TEMP TABLE reset_targets ON COMMIT DROP AS
SELECT
  si.id AS supplier_invoice_id,
  si.order_id,
  si.invoice_ref,
  si.invoice_pdf_url,
  si.reviewed_by_staff_id,
  si.reviewed_at,
  si.review_notes,
  si.is_current_for_order,
  fs.invoice_total_gbp
FROM public.supplier_invoices si
JOIN public.supplier_invoice_financial_summary fs
  ON fs.supplier_invoice_id = si.id
WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
  AND si.invoice_ref IN ('NIN-240726-A','NIN-240726-B')
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
  );

DO $$
DECLARE
  v_count integer;
  v_refs text;
  v_blocker text;
BEGIN
  SELECT COUNT(*)::integer, string_agg(invoice_ref, ', ' ORDER BY invoice_ref)
    INTO v_count, v_refs
  FROM reset_targets;

  IF v_count <> 2 OR v_refs <> 'NIN-240726-A, NIN-240726-B' THEN
    RAISE EXCEPTION 'Expected exactly NIN-240726-A and NIN-240726-B, found % row(s): %.', v_count, COALESCE(v_refs, 'none');
  END IF;

  PERFORM 1
  FROM public.supplier_invoices si
  JOIN reset_targets t ON t.supplier_invoice_id = si.id
  FOR UPDATE OF si;

  -- OCR may be discarded only where no human-created/progressed line work exists.
  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    JOIN reset_targets t ON t.supplier_invoice_id = sil.supplier_invoice_id
    WHERE sil.line_source <> 'ocr_extracted'
       OR sil.eligible_for_invoice_yn = 'Y'
       OR sil.qty_confirmed IS NOT NULL
       OR sil.amount_confirmed IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Reset blocked: A or B contains manual/progressed invoice-line work. No rows were changed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_line_accounting_codes c
    JOIN public.supplier_invoice_lines sil ON sil.id = c.supplier_invoice_line_id
    JOIN reset_targets t ON t.supplier_invoice_id = sil.supplier_invoice_id
  ) THEN v_blocker := 'supplier-line accounting coding';
  ELSIF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_line_resolutions r
    JOIN reset_targets t ON t.supplier_invoice_id = r.supplier_invoice_id
    WHERE r.active = true
  ) THEN v_blocker := 'active line resolution';
  ELSIF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
    JOIN reset_targets t ON t.supplier_invoice_id = sil.supplier_invoice_id
  ) THEN v_blocker := 'tracking allocation';
  ELSIF EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.supplier_invoice_lines sil ON sil.id = m.supplier_invoice_line_id
    JOIN reset_targets t ON t.supplier_invoice_id = sil.supplier_invoice_id
  ) THEN v_blocker := 'shipment membership';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines r
    JOIN reset_targets t ON t.supplier_invoice_id = r.supplier_invoice_id
  ) THEN v_blocker := 'customer-sales release membership';
  ELSIF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_basis b
    JOIN reset_targets t ON t.supplier_invoice_id = b.supplier_invoice_id
  ) THEN v_blocker := 'locked invoice-adjustment basis';
  ELSIF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_consumption_ledger l
    JOIN reset_targets t ON t.supplier_invoice_id = l.supplier_invoice_id
    WHERE l.active = true
  ) THEN v_blocker := 'invoice-adjustment consumption';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    JOIN reset_targets t ON t.supplier_invoice_id = a.supplier_invoice_id
    WHERE a.allocation_type::text = 'supplier_invoice'
      AND a.allocation_status::text <> 'reversed'
  ) THEN v_blocker := 'supplier-payment allocation or draft allocation';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_order_review_links l
    JOIN reset_targets t ON t.order_id = l.order_id
    WHERE l.is_active = true
      AND (l.expires_at IS NULL OR l.expires_at > now())
  ) THEN v_blocker := 'active customer review';
  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    JOIN reset_targets t ON t.order_id = h.order_id
    WHERE h.resolved_at IS NULL
      AND h.status IN ('requested','supervisor_approved','converted_to_exception')
      AND (
        h.requested_scope = 'order'
        OR (
          h.requested_scope = 'line'
          AND EXISTS (
            SELECT 1
            FROM public.supplier_invoice_lines sil
            JOIN reset_targets scoped ON scoped.supplier_invoice_id = sil.supplier_invoice_id
            WHERE sil.id = h.supplier_invoice_line_id
              AND scoped.order_id = h.order_id
          )
        )
        OR (
          h.requested_scope = 'tracking'
          AND EXISTS (
            SELECT 1
            FROM public.order_tracking_line_allocations a
            JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
            JOIN reset_targets scoped ON scoped.supplier_invoice_id = sil.supplier_invoice_id
            WHERE a.tracking_submission_id = h.tracking_submission_id
              AND scoped.order_id = h.order_id
              AND COALESCE(a.qty_allocated, 0) > 0
          )
        )
      )
  ) THEN v_blocker := 'active customer hold';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
    JOIN reset_targets t ON t.supplier_invoice_id = sil.supplier_invoice_id
    JOIN public.disputes d ON d.id = dl.dispute_id
    WHERE dl.resolved_at IS NULL
      AND d.resolved_at IS NULL
  ) THEN v_blocker := 'unresolved exception';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sales_invoices sales
    JOIN reset_targets t ON t.order_id = sales.order_id
    WHERE COALESCE(sales.invoice_type::text, '') IN ('main','supplementary')
      AND COALESCE(sales.sage_status::text, '') <> 'void'
  ) THEN v_blocker := 'non-void customer sales document';
  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_refund_evidence_submissions e
    JOIN reset_targets t ON t.supplier_invoice_id = e.original_supplier_invoice_id
  ) THEN v_blocker := 'supplier refund or credit evidence';
  ELSIF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    JOIN reset_targets t ON t.supplier_invoice_id = s.source_id
    WHERE s.source_table = 'supplier_invoices'
      AND COALESCE(s.active, true) = true
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  ) OR EXISTS (
    SELECT 1
    FROM public.sage_postings p
    JOIN reset_targets t ON t.supplier_invoice_id = p.source_id
    WHERE p.source_table = 'supplier_invoices'
  ) THEN v_blocker := 'frozen or posted supplier accounting artefact';
  END IF;

  IF v_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Reset blocked by genuine downstream use (%). No rows were changed.', v_blocker;
  END IF;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'cancelled',
    resolved_at = now(),
    resolution_notes = concat_ws(
      E'\n',
      NULLIF(f.resolution_notes, ''),
      'Cancelled by exact A/B OCR reset; source evidence and declared adjustments retained.'
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
           AND fs.invoice_total_gbp = t.invoice_total_gbp
       )
       OR NOT EXISTS (
         SELECT 1
         FROM public.order_value_adjustments ova
         WHERE ova.supplier_invoice_id = si.id
           AND ova.adjustment_type IN ('retailer_delivery','retailer_discount')
           AND ova.approval_status <> 'rejected'
       )
       OR si.reviewed_by_staff_id IS DISTINCT FROM t.reviewed_by_staff_id
       OR si.reviewed_at IS DISTINCT FROM t.reviewed_at
       OR si.review_notes IS DISTINCT FROM t.review_notes
       OR si.is_current_for_order IS DISTINCT FROM t.is_current_for_order
  ) THEN
    RAISE EXCEPTION 'A/B OCR reset postcondition failed; transaction rolled back.';
  END IF;
END $$;

SELECT
  si.invoice_ref,
  si.review_status,
  si.mindee_ocr_status,
  (si.mindee_job_id IS NULL AND si.mindee_inference_id IS NULL) AS no_active_mindee_job,
  (si.invoice_pdf_url IS NOT NULL) AS uploaded_file_retained,
  fs.invoice_total_gbp AS entered_total_retained,
  COALESCE(adj.delivery_gbp, 0) AS delivery_retained_gbp,
  COALESCE(adj.discount_gbp, 0) AS discount_retained_gbp,
  COALESCE(lines.ocr_line_count, 0) AS remaining_ocr_line_count,
  (si.reviewed_at IS NOT NULL OR si.reviewed_by_staff_id IS NOT NULL) AS prior_staff_review_audit_retained,
  si.is_current_for_order AS reference_family_marker_retained,
  COALESCE(audit.call_count, 0) AS retained_mindee_audit_call_count
FROM reset_targets t
JOIN public.supplier_invoices si ON si.id = t.supplier_invoice_id
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
ORDER BY si.invoice_ref;

COMMIT;
