-- =============================================================================
-- 20260726_clean_flow_cross_user_status_check_v1.sql
--
-- READ ONLY. This script rolls back and makes no database changes.
--
-- It proves, from the live database:
--   1. The target order's canonical supervisor/customer/importer/shipper status.
--   2. The exact importer-dashboard button gates, including when the green
--      "Assign tracking" button is live.
--   3. Real clean-flow comparator orders at the next stages of the journey.
--   4. The canonical 12-gate position for those orders.
--   5. Whether notification/action-centre/reminder database objects currently
--      exist. No object is assumed to exist.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_auth_uid uuid;
BEGIN
  IF to_regprocedure('public.internal_platform_order_status_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_platform_order_status_v1()';
  END IF;
  IF to_regprocedure('public.internal_platform_order_progress_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_platform_order_progress_v1()';
  END IF;
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY
    CASE
      WHEN s.role_type::text = 'admin' THEN 0
      WHEN s.role_type::text = 'supervisor' THEN 1
      ELSE 2
    END,
    s.created_at
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'No active staff auth user is available for canonical status reads.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
END $$;

-- =============================================================================
-- RESULT 1
-- Target order plus real live clean-flow comparator orders.
--
-- Importer dashboard gates reproduced exactly from app/importer/page.tsx:
--   needs_resubmission = rejected invoice exists AND no live invoice exists
--   can_upload_invoice = needs_resubmission OR no invoice exists
--   can_add_tracking = NOT needs_resubmission AND no active tracking exists
--   can_match_evidence = NOT needs_resubmission AND an invoice exists
--   can_assign_tracking = NOT needs_resubmission AND invoice + tracking exist
-- =============================================================================
WITH
status_rows AS (
  SELECT *
  FROM public.internal_platform_order_status_v1()
),
progress_rows AS (
  SELECT *
  FROM public.internal_platform_order_progress_v1()
),
audience_rows AS (
  SELECT *
  FROM public.order_audience_status_v1(NULL)
),
invoice_rollup AS (
  SELECT
    si.order_id,
    COUNT(*)::integer AS invoice_count,
    COUNT(*) FILTER (
      WHERE COALESCE(si.review_status, 'pending_review') NOT IN
        ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
    )::integer AS live_invoice_count,
    COUNT(*) FILTER (
      WHERE si.review_status IN ('approved_current', 'ref_corrected_approved')
        AND COALESCE(si.blocked_from_sage_yn, false) = false
        AND COALESCE(si.is_current_for_order, false) = true
    )::integer AS approved_current_invoice_count,
    COUNT(*) FILTER (
      WHERE si.review_status = 'rejected_resubmit_required'
    )::integer AS rejected_invoice_count,
    COUNT(*) FILTER (
      WHERE si.review_status = 'pending_review'
    )::integer AS pending_review_invoice_count,
    jsonb_agg(
      jsonb_build_object(
        'invoice_id', si.id,
        'invoice_ref', si.invoice_ref,
        'review_status', si.review_status,
        'blocked_from_sage_yn', si.blocked_from_sage_yn,
        'is_current_for_order', si.is_current_for_order,
        'reviewed_at', si.reviewed_at,
        'review_notes', si.review_notes
      )
      ORDER BY si.uploaded_at NULLS LAST, si.invoice_ref
    ) AS invoices_json
  FROM public.supplier_invoices si
  GROUP BY si.order_id
),
line_rollup AS (
  SELECT
    si.order_id,
    COUNT(sil.id) FILTER (
      WHERE COALESCE(si.review_status, 'pending_review') NOT IN
        ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
    )::integer AS live_line_count,
    COUNT(sil.id) FILTER (
      WHERE COALESCE(si.review_status, 'pending_review') NOT IN
        ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
        AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN
          ('y','yes','true','1')
    )::integer AS live_physical_line_count,
    COUNT(sil.id) FILTER (
      WHERE COALESCE(si.review_status, 'pending_review') NOT IN
        ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
        AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN
          ('y','yes','true','1')
        AND sil.qty_confirmed IS NOT NULL
        AND sil.amount_confirmed IS NOT NULL
    )::integer AS live_progressed_physical_line_count,
    COUNT(sil.id) FILTER (
      WHERE COALESCE(si.review_status, 'pending_review') NOT IN
        ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
        AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN
          ('y','yes','true','1')
        AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL)
    )::integer AS live_open_physical_line_count,
    COUNT(sil.id) FILTER (
      WHERE COALESCE(si.review_status, 'pending_review') NOT IN
        ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
        AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN
          ('y','yes','true','1')
    )::integer AS live_parked_line_count
  FROM public.supplier_invoices si
  LEFT JOIN public.supplier_invoice_lines sil
    ON sil.supplier_invoice_id = si.id
  GROUP BY si.order_id
),
tracking_rollup AS (
  SELECT
    ots.order_id,
    COUNT(*) FILTER (
      WHERE ots.superseded_at IS NULL
    )::integer AS active_tracking_count,
    COUNT(*) FILTER (
      WHERE ots.superseded_at IS NULL
        AND COALESCE(ots.is_final_delivery_yn, false) = true
    )::integer AS active_final_tracking_count,
    jsonb_agg(
      jsonb_build_object(
        'tracking_id', ots.id,
        'tracking_ref', ots.tracking_ref,
        'tracking_date', ots.tracking_date,
        'is_final_delivery_yn', ots.is_final_delivery_yn,
        'superseded_at', ots.superseded_at
      )
      ORDER BY ots.submitted_at NULLS LAST, ots.id
    ) FILTER (WHERE ots.superseded_at IS NULL) AS active_tracking_json
  FROM public.order_tracking_submissions ots
  GROUP BY ots.order_id
),
allocation_rollup AS (
  SELECT
    a.order_id,
    COUNT(*) FILTER (
      WHERE COALESCE(a.qty_allocated, 0) > 0
    )::integer AS tracking_allocation_row_count,
    COALESCE(SUM(a.qty_allocated) FILTER (
      WHERE COALESCE(a.qty_allocated, 0) > 0
    ), 0)::numeric AS tracking_allocated_qty
  FROM public.order_tracking_line_allocations a
  GROUP BY a.order_id
),
flag_rollup AS (
  SELECT
    f.order_id,
    COUNT(*) FILTER (
      WHERE f.status IN ('open', 'under_review')
    )::integer AS open_review_flag_count,
    jsonb_agg(
      jsonb_build_object(
        'supplier_invoice_id', f.supplier_invoice_id,
        'flag_type', f.flag_type,
        'status', f.status,
        'message', f.message,
        'resolution_notes', f.resolution_notes
      )
      ORDER BY f.created_at, f.id
    ) AS review_flags_json
  FROM public.supplier_invoice_review_flags f
  GROUP BY f.order_id
),
base AS (
  SELECT
    s.*,
    p.gate_complete_count,
    p.gate_total,
    p.gate_summary_json,
    p.exception_summary_state,
    p.exception_categories_json,
    p.dva_state,
    p.final_settlement_state,
    p.accounting_sage_state,
    p.vat_compliance_state,
    a.customer_status_label,
    a.customer_next_action,
    a.importer_status_label,
    a.importer_next_action,
    a.shipper_status_label,
    a.shipper_next_action,
    COALESCE(i.invoice_count, 0) AS invoice_count,
    COALESCE(i.live_invoice_count, 0) AS live_invoice_count,
    COALESCE(i.approved_current_invoice_count, 0) AS approved_current_invoice_count,
    COALESCE(i.rejected_invoice_count, 0) AS rejected_invoice_count,
    COALESCE(i.pending_review_invoice_count, 0) AS pending_review_invoice_count,
    i.invoices_json,
    COALESCE(l.live_line_count, 0) AS live_line_count,
    COALESCE(l.live_physical_line_count, 0) AS live_physical_line_count,
    COALESCE(l.live_progressed_physical_line_count, 0) AS live_progressed_physical_line_count,
    COALESCE(l.live_open_physical_line_count, 0) AS live_open_physical_line_count,
    COALESCE(l.live_parked_line_count, 0) AS live_parked_line_count,
    COALESCE(t.active_tracking_count, 0) AS active_tracking_count,
    COALESCE(t.active_final_tracking_count, 0) AS active_final_tracking_count,
    t.active_tracking_json,
    COALESCE(ar.tracking_allocation_row_count, 0) AS tracking_allocation_row_count,
    COALESCE(ar.tracking_allocated_qty, 0) AS tracking_allocated_qty,
    COALESCE(f.open_review_flag_count, 0) AS open_review_flag_count,
    f.review_flags_json
  FROM status_rows s
  LEFT JOIN progress_rows p ON p.order_id = s.order_id
  LEFT JOIN audience_rows a ON a.order_id = s.order_id
  LEFT JOIN invoice_rollup i ON i.order_id = s.order_id
  LEFT JOIN line_rollup l ON l.order_id = s.order_id
  LEFT JOIN tracking_rollup t ON t.order_id = s.order_id
  LEFT JOIN allocation_rollup ar ON ar.order_id = s.order_id
  LEFT JOIN flag_rollup f ON f.order_id = s.order_id
),
classified AS (
  SELECT
    b.*,
    (b.rejected_invoice_count > 0 AND b.live_invoice_count = 0) AS needs_resubmission,
    (b.invoice_count > 0) AS has_invoice,
    (b.active_tracking_count > 0) AS has_tracking,
    CASE
      WHEN b.order_ref = 'ORD-1784976429191'
        THEN 'TARGET_CURRENT_STATE'
      WHEN b.exception_state = 'clean'
        AND b.hold_state = 'clean'
        AND b.supplier_state = 'approved_current'
        AND b.reconciliation_state = 'complete'
        AND b.tracking_state = 'missing'
        THEN 'REAL_CLEAN_EVIDENCE_PROGRESS_COMPLETE_TRACKING_OPEN'
      WHEN b.exception_state = 'clean'
        AND b.hold_state = 'clean'
        AND b.supplier_state = 'approved_current'
        AND b.reconciliation_state = 'complete'
        AND b.active_tracking_count > 0
        AND b.tracking_state = 'allocation_incomplete'
        THEN 'REAL_TRACKING_SUBMITTED_ASSIGNMENT_OPEN'
      WHEN b.exception_state = 'clean'
        AND b.hold_state = 'clean'
        AND b.supplier_state = 'approved_current'
        AND b.reconciliation_state = 'complete'
        AND b.tracking_state = 'submitted'
        AND b.shipment_state IN ('missing', 'allocation_incomplete')
        THEN 'REAL_TRACKING_ASSIGNED_SHIPMENT_OPEN'
      WHEN b.current_stage = 'complete'
        THEN 'REAL_COMPLETE_ORDER'
      ELSE NULL
    END AS comparison_stage
  FROM base b
),
ranked AS (
  SELECT
    c.*,
    ROW_NUMBER() OVER (
      PARTITION BY c.comparison_stage
      ORDER BY
        CASE WHEN c.order_ref = 'ORD-1784976429191' THEN 0 ELSE 1 END,
        c.created_at DESC NULLS LAST,
        c.order_ref
    ) AS stage_rank
  FROM classified c
  WHERE c.comparison_stage IS NOT NULL
)
SELECT
  r.comparison_stage,
  r.order_id,
  r.order_ref,
  r.raw_order_status,

  r.current_stage AS supervisor_current_stage,
  r.current_stage_label AS supervisor_status_label,
  r.next_owner AS supervisor_next_owner,
  r.next_action AS supervisor_next_action,
  r.next_href AS supervisor_next_href,
  r.status_tone AS supervisor_status_tone,

  r.customer_status_label,
  r.customer_next_action,
  r.importer_status_label AS canonical_importer_status_label,
  r.importer_next_action AS canonical_importer_next_action,
  CASE
    WHEN lower(COALESCE(r.raw_order_status, '')) IN
      ('partially_progressed', 'invoice_reconciled_tracking_open')
      AND r.importer_status_label = 'Invoice reconciliation open'
      AND r.importer_next_action = 'Continue invoice reconciliation'
      THEN CASE
        WHEN r.has_tracking THEN 'Tracking submitted'
        ELSE 'Invoice reconciled; tracking open'
      END
    ELSE r.importer_status_label
  END AS importer_dashboard_display_status,
  CASE
    WHEN lower(COALESCE(r.raw_order_status, '')) IN
      ('partially_progressed', 'invoice_reconciled_tracking_open')
      AND r.importer_status_label = 'Invoice reconciliation open'
      AND r.importer_next_action = 'Continue invoice reconciliation'
      THEN CASE
        WHEN r.has_tracking THEN 'Assign tracking'
        ELSE 'Add tracking'
      END
    ELSE r.importer_next_action
  END AS importer_dashboard_display_next_action,
  r.shipper_status_label,
  r.shipper_next_action,

  r.needs_resubmission,
  r.has_invoice,
  r.has_tracking,
  (r.needs_resubmission OR NOT r.has_invoice) AS importer_can_upload_invoice,
  (NOT r.needs_resubmission AND NOT r.has_tracking) AS importer_can_add_tracking,
  (NOT r.needs_resubmission AND r.has_invoice) AS importer_can_match_evidence,
  (NOT r.needs_resubmission AND r.has_invoice AND r.has_tracking) AS importer_can_assign_tracking,
  CASE
    WHEN NOT r.needs_resubmission AND r.has_invoice AND r.has_tracking
      THEN 'GREEN LIVE: Assign tracking'
    WHEN r.has_invoice AND NOT r.has_tracking AND NOT r.needs_resubmission
      THEN 'DISABLED: Assign after tracking'
    ELSE 'HIDDEN'
  END AS importer_assign_tracking_button_state,

  r.gate_complete_count,
  r.gate_total,
  r.gate_summary_json,
  r.exception_summary_state,
  r.exception_categories_json,
  r.funding_state,
  r.supplier_state,
  r.reconciliation_state,
  r.tracking_state,
  r.shipment_state,
  r.export_evidence_state,
  r.pod_delivery_state,
  r.customer_sales_state,
  r.shipper_ap_state,
  r.dva_state,
  r.final_settlement_state,
  r.accounting_sage_state,
  r.vat_compliance_state,

  r.invoice_count,
  r.live_invoice_count,
  r.approved_current_invoice_count,
  r.rejected_invoice_count,
  r.pending_review_invoice_count,
  r.live_line_count,
  r.live_physical_line_count,
  r.live_progressed_physical_line_count,
  r.live_open_physical_line_count,
  r.live_parked_line_count,
  r.open_review_flag_count,
  r.active_tracking_count,
  r.active_final_tracking_count,
  r.tracking_allocation_row_count,
  r.tracking_allocated_qty,
  r.invoices_json,
  r.review_flags_json,
  r.active_tracking_json
FROM ranked r
WHERE r.comparison_stage = 'TARGET_CURRENT_STATE'
   OR r.stage_rank <= 3
ORDER BY
  CASE r.comparison_stage
    WHEN 'TARGET_CURRENT_STATE' THEN 0
    WHEN 'REAL_CLEAN_EVIDENCE_PROGRESS_COMPLETE_TRACKING_OPEN' THEN 1
    WHEN 'REAL_TRACKING_SUBMITTED_ASSIGNMENT_OPEN' THEN 2
    WHEN 'REAL_TRACKING_ASSIGNED_SHIPMENT_OPEN' THEN 3
    WHEN 'REAL_COMPLETE_ORDER' THEN 4
    ELSE 9
  END,
  r.stage_rank;

-- =============================================================================
-- RESULT 2
-- Exact target invoice/header/line/flag facts after the mistaken rejection.
-- =============================================================================
SELECT
  o.order_ref,
  si.id AS supplier_invoice_id,
  si.invoice_ref,
  si.review_status,
  si.blocked_from_sage_yn,
  si.is_current_for_order,
  si.reviewed_at,
  si.review_notes,
  COUNT(sil.id)::integer AS line_count,
  COUNT(sil.id) FILTER (
    WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN
      ('y','yes','true','1')
  )::integer AS physical_line_count,
  COUNT(sil.id) FILTER (
    WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN
      ('y','yes','true','1')
      AND sil.qty_confirmed IS NOT NULL
      AND sil.amount_confirmed IS NOT NULL
  )::integer AS progressed_physical_line_count,
  COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'flag_type', f.flag_type,
        'status', f.status,
        'message', f.message,
        'resolved_at', f.resolved_at,
        'resolution_notes', f.resolution_notes
      )
      ORDER BY f.created_at, f.id
    )
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = si.id
  ), '[]'::jsonb) AS flags_json
FROM public.orders o
JOIN public.supplier_invoices si ON si.order_id = o.id
LEFT JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
WHERE o.order_ref = 'ORD-1784976429191'
GROUP BY
  o.order_ref,
  si.id,
  si.invoice_ref,
  si.review_status,
  si.blocked_from_sage_yn,
  si.is_current_for_order,
  si.reviewed_at,
  si.review_notes
ORDER BY si.uploaded_at NULLS LAST, si.invoice_ref;

-- =============================================================================
-- RESULT 3
-- Database inventory for notification/action-centre/reminder/alert objects.
-- Empty result means no matching database object was found; it does not guess.
-- =============================================================================
WITH relation_objects AS (
  SELECT
    CASE c.relkind
      WHEN 'r' THEN 'table'
      WHEN 'v' THEN 'view'
      WHEN 'm' THEN 'materialized_view'
      WHEN 'p' THEN 'partitioned_table'
      ELSE c.relkind::text
    END AS object_type,
    n.nspname AS schema_name,
    c.relname AS object_name,
    NULL::text AS definition_excerpt
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND c.relkind IN ('r', 'v', 'm', 'p')
    AND lower(c.relname) ~ '(notification|reminder|action.?cent(re|er)|alert)'
),
function_objects AS (
  SELECT
    'function'::text AS object_type,
    n.nspname AS schema_name,
    p.proname AS object_name,
    left(regexp_replace(pg_get_functiondef(p.oid), E'[\n\r\t]+', ' ', 'g'), 500) AS definition_excerpt
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND (
      lower(p.proname) ~ '(notification|reminder|action.?cent(re|er)|alert)'
      OR lower(pg_get_functiondef(p.oid)) ~ '(notification|reminder|action.?cent(re|er)|alert)'
    )
),
trigger_objects AS (
  SELECT
    'trigger'::text AS object_type,
    n.nspname AS schema_name,
    t.tgname AS object_name,
    left(regexp_replace(pg_get_triggerdef(t.oid, true), E'[\n\r\t]+', ' ', 'g'), 500) AS definition_excerpt
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND (
      lower(t.tgname) ~ '(notification|reminder|action.?cent(re|er)|alert)'
      OR lower(pg_get_triggerdef(t.oid, true)) ~ '(notification|reminder|action.?cent(re|er)|alert)'
    )
)
SELECT * FROM relation_objects
UNION ALL
SELECT * FROM function_objects
UNION ALL
SELECT * FROM trigger_objects
ORDER BY object_type, schema_name, object_name;

ROLLBACK;
