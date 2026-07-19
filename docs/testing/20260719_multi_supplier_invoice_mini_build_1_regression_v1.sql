-- =============================================================================
-- 20260719_multi_supplier_invoice_mini_build_1_regression_v2.sql
-- Structural and live-data safety checks for Mini-build 1.
--
-- Run after:
--   supabase/migrations/20260719_multi_supplier_invoice_identity_bundle_foundation_v1.sql
--
-- Read-only. No business rows are changed.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_indexdef text;
  v_submit_def text;
  v_approve_def text;
  v_reject_def text;
  v_lines_view text;
  v_summary_view text;
  v_duplicate_family_count integer;
  v_execute_granted boolean;
  v_select_granted boolean;
BEGIN
  IF to_regclass('public.uq_supplier_invoices_one_current_per_order') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: retired one-current-invoice-per-order index still exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'supplier_invoices'
      AND c.conname = 'supplier_invoices_retailer_id_invoice_ref_order_id_key'
  ) THEN
    RAISE EXCEPTION 'FAIL: all-history same-reference constraint still exists';
  END IF;

  SELECT pg_get_indexdef(to_regclass('public.uq_supplier_invoices_current_reference_family'))
    INTO v_indexdef;

  IF v_indexdef IS NULL
     OR position('regexp_replace' in lower(v_indexdef)) = 0
     OR position('order_id' in lower(v_indexdef)) = 0
     OR position('retailer_id' in lower(v_indexdef)) = 0
     OR position('coalesce(review_status' in lower(v_indexdef)) = 0
     OR position('rejected_resubmit_required' in lower(v_indexdef)) = 0
     OR position('duplicate_blocked' in lower(v_indexdef)) = 0
     OR position('superseded' in lower(v_indexdef)) = 0
  THEN
    RAISE EXCEPTION 'FAIL: status-based reference-family uniqueness index is missing or incomplete';
  END IF;

  SELECT COUNT(*)::integer
    INTO v_duplicate_family_count
  FROM (
    SELECT
      order_id,
      retailer_id,
      lower(regexp_replace(btrim(invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) AS normalised_ref
    FROM public.supplier_invoices
    WHERE COALESCE(review_status, 'pending_review') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
    GROUP BY order_id, retailer_id, lower(regexp_replace(btrim(invoice_ref), '[^a-zA-Z0-9]+', '', 'g'))
    HAVING COUNT(*) > 1
  ) collisions;

  IF v_duplicate_family_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: live duplicate current reference families exist';
  END IF;

  SELECT pg_get_functiondef(
    to_regprocedure('public.operator_submit_supplier_invoice(uuid,text,text)')
  ) INTO v_submit_def;

  IF v_submit_def IS NULL
     OR position('regexp_replace(v_invoice_ref' in lower(v_submit_def)) = 0
     OR position('reference_family_current_yn' in v_submit_def) = 0
     OR position('is_current_for_order' in v_submit_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: operator submission is not reference-family aware';
  END IF;

  IF position('A current supplier invoice already exists for this order' in v_submit_def) > 0
     OR position('Original invoice_ref archived for corrected resubmission' in v_submit_def) > 0
  THEN
    RAISE EXCEPTION 'FAIL: retired order-wide block or reference-mutation workaround remains';
  END IF;

  SELECT pg_get_functiondef(
    to_regprocedure('public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)')
  ) INTO v_approve_def;

  IF v_approve_def IS NULL
     OR position('collides with another live version' in v_approve_def) = 0
     OR position('regexp_replace(btrim(sibling.invoice_ref)' in lower(v_approve_def)) = 0
  THEN
    RAISE EXCEPTION 'FAIL: approval is not protected by reference-family collision logic';
  END IF;

  IF position('superseded_by_supplier_invoice_id = v_invoice.id' in v_approve_def) > 0
     OR position('si.id <> v_invoice.id' in v_approve_def) > 0
  THEN
    RAISE EXCEPTION 'FAIL: approval still supersedes sibling invoice references';
  END IF;

  SELECT pg_get_functiondef(
    to_regprocedure('public.staff_reject_supplier_invoice_resubmission(uuid,text)')
  ) INTO v_reject_def;

  IF v_reject_def IS NULL
     OR position('order_tracking_line_allocations' in v_reject_def) = 0
     OR position('customer_order_review_links' in v_reject_def) = 0
     OR position('customer_pre_shipment_hold_requests' in v_reject_def) = 0
     OR position('dispute_lines' in v_reject_def) = 0
     OR position('sales_invoices' in v_reject_def) = 0
     OR position('dva_statement_line_allocations' in v_reject_def) = 0
     OR position('dispute_refund_evidence_submissions' in v_reject_def) = 0
     OR position('sage_posting_snapshots' in v_reject_def) = 0
     OR position('controlled correction route' in v_reject_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: rejection does not fail closed across irreversible downstream use';
  END IF;

  IF to_regclass('public.order_supplier_invoice_bundle_lines_v1') IS NULL
     OR to_regclass('public.order_supplier_invoice_bundle_summary_v1') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: required order bundle views are missing';
  END IF;

  SELECT pg_get_viewdef('public.order_supplier_invoice_bundle_lines_v1'::regclass, true)
    INTO v_lines_view;
  SELECT pg_get_viewdef('public.order_supplier_invoice_bundle_summary_v1'::regclass, true)
    INTO v_summary_view;

  IF position('supplier_invoice_line_id' in v_lines_view) = 0
     OR position('allocated_tracking_qty' in v_lines_view) = 0
     OR position('active_hold_yn' in v_lines_view) = 0
     OR position('open_exception_yn' in v_lines_view) = 0
     OR position('duplicate_blocked' in v_lines_view) = 0
  THEN
    RAISE EXCEPTION 'FAIL: bundle line view is missing exact source/state controls';
  END IF;

  IF position('active_invoice_count' in v_summary_view) = 0
     OR position('baseline_accounted_for_yn' in v_summary_view) = 0
     OR position('remaining_baseline_qty' in v_summary_view) = 0
     OR position('all_documents_resolved_yn' in v_summary_view) = 0
  THEN
    RAISE EXCEPTION 'FAIL: bundle summary view is incomplete';
  END IF;

  IF lower(v_lines_view) LIKE '%limit 1%'
     OR lower(v_summary_view) LIKE '%limit 1%'
  THEN
    RAISE EXCEPTION 'FAIL: bundle view retains a latest-invoice LIMIT 1 assumption';
  END IF;

  SELECT has_function_privilege(
    'authenticated',
    'public.operator_submit_supplier_invoice(uuid,text,text)',
    'EXECUTE'
  ) INTO v_execute_granted;

  IF v_execute_granted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: authenticated operator upload EXECUTE grant is missing';
  END IF;

  SELECT has_table_privilege(
    'authenticated',
    'public.order_supplier_invoice_bundle_lines_v1',
    'SELECT'
  ) INTO v_select_granted;

  IF v_select_granted IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: authenticated bundle-line SELECT grant is missing';
  END IF;
END $$;

SELECT
  'PASS: Mini-build 1 reference-family identity, sibling safety, and order bundle foundation are installed'
  AS regression_result;

ROLLBACK;
