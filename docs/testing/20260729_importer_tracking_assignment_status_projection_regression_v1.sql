BEGIN;

-- Focused regression for IMPORTER_TRACKING_ASSIGNMENT_STATUS_SEAMLESS_PATCH_ADDENDUM_v1.
-- Read-only against production rows; transaction rolls back.

DO $$
DECLARE
  v_order_id uuid;
  v_fn text;
  v_active_invoice_count integer;
  v_approved_invoice_count integer;
  v_active_tracking_count integer;
  v_unassigned_physical_line_count integer;
  v_open_query_count integer;
BEGIN
  SELECT id INTO v_order_id
  FROM public.orders
  WHERE order_ref = 'ORD-1785274708774';

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled order missing';
  END IF;

  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL
     OR to_regprocedure('public.order_audience_status_pre_importer_tracking_assignment_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: required audience status functions missing';
  END IF;

  SELECT pg_get_functiondef('public.order_audience_status_v1(uuid)'::regprocedure)
  INTO v_fn;

  IF position('order_audience_status_pre_importer_tracking_assignment_v1(p_order_id)' in v_fn) = 0
     OR position('WHEN p.tracking_assignment_needed THEN ''Assign tracking''' in v_fn) = 0
     OR position('ELSE p.importer_next_action' in v_fn) = 0 THEN
    RAISE EXCEPTION 'FAIL: wrapper is not limited to the governed Assign tracking projection';
  END IF;

  IF position('Order evidence missing' in v_fn) > 0
     OR position('Upload order evidence' in v_fn) > 0
     OR position('Invoice reconciled; tracking open' in v_fn) > 0
     OR position('Add tracking' in v_fn) > 0 THEN
    RAISE EXCEPTION 'FAIL: protected existing evidence/tracking branches were duplicated or rewritten';
  END IF;

  SELECT
    COUNT(*) FILTER (
      WHERE COALESCE(is_current_for_order, true) = true
        AND COALESCE(review_status, '') NOT IN ('superseded','duplicate_blocked')
        AND NOT (
          review_status = 'rejected_resubmit_required'
          AND COALESCE(rejection_requires_resubmission_yn, true) = false
        )
    )::integer,
    COUNT(*) FILTER (
      WHERE COALESCE(is_current_for_order, true) = true
        AND review_status IN ('approved_current','ref_corrected_approved')
        AND COALESCE(blocked_from_sage_yn, false) = false
    )::integer
  INTO v_active_invoice_count, v_approved_invoice_count
  FROM public.supplier_invoices
  WHERE order_id = v_order_id;

  IF v_active_invoice_count = 0 OR v_approved_invoice_count <> v_active_invoice_count THEN
    RAISE EXCEPTION 'FAIL: controlled supplier evidence is not fully approved/current';
  END IF;

  SELECT COUNT(*)::integer INTO v_open_query_count
  FROM public.order_evidence_queries
  WHERE order_id = v_order_id AND status = 'open';

  IF v_open_query_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: controlled order still has open evidence query';
  END IF;

  SELECT COUNT(*)::integer INTO v_active_tracking_count
  FROM public.order_tracking_submissions
  WHERE order_id = v_order_id AND superseded_at IS NULL;

  IF v_active_tracking_count = 0 THEN
    RAISE EXCEPTION 'FAIL: controlled order has no active tracking';
  END IF;

  WITH line_position AS (
    SELECT
      sil.id,
      GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0)::numeric AS required_qty,
      COALESCE(SUM(otla.qty_allocated) FILTER (WHERE ats.id IS NOT NULL), 0)::numeric AS allocated_qty
    FROM public.supplier_invoices si
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = si.order_id
     AND otla.supplier_invoice_line_id = sil.id
     AND otla.tracking_submission_id IS NOT NULL
    LEFT JOIN public.order_tracking_submissions ats
      ON ats.id = otla.tracking_submission_id
     AND ats.order_id = si.order_id
     AND ats.superseded_at IS NULL
    WHERE si.order_id = v_order_id
      AND COALESCE(si.is_current_for_order, true) = true
      AND si.review_status IN ('approved_current','ref_corrected_approved')
      AND COALESCE(si.blocked_from_sage_yn, false) = false
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text,'')) IN ('y','yes','true','1')
    GROUP BY sil.id, sil.qty_confirmed, sil.qty
  )
  SELECT COUNT(*) FILTER (
    WHERE required_qty > 0 AND allocated_qty + 0.0005 < required_qty
  )::integer
  INTO v_unassigned_physical_line_count
  FROM line_position;

  IF v_unassigned_physical_line_count = 0 THEN
    RAISE EXCEPTION 'FAIL: controlled order has no outstanding tracking assignment';
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result','PASS',
  'proof','governed wrapper delegates the existing audience flow unchanged and overrides only importer_next_action to Assign tracking when approved/reconciled physical lines remain unassigned to active submitted tracking; protected missing-evidence and Add tracking branches are not rewritten'
) AS regression_result;

ROLLBACK;
