-- Multi-supplier-invoice order control — Mini-build 1 regression v1
-- Run after:
--   supabase/migrations/20260719_multi_supplier_invoice_identity_bundle_foundation_v1.sql
--
-- Structural/live-catalog checks only. No business data is changed.

BEGIN;

DO $$
DECLARE
  v_definition text;
  v_index_definition text;
  v_collision_count integer;
BEGIN
  IF to_regclass('public.uq_supplier_invoices_one_current_per_order') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: retired one-current-invoice-per-order index still exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'public'
      AND r.relname = 'supplier_invoices'
      AND c.conname = 'supplier_invoices_retailer_id_invoice_ref_order_id_key'
  ) THEN
    RAISE EXCEPTION 'FAIL: retired all-history same-reference constraint still exists';
  END IF;

  SELECT pg_get_indexdef(c.oid)
    INTO v_index_definition
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'uq_supplier_invoices_current_reference_family';

  IF v_index_definition IS NULL THEN
    RAISE EXCEPTION 'FAIL: current reference-family unique index is missing';
  END IF;

  IF position('order_id' in v_index_definition) = 0
     OR position('retailer_id' in v_index_definition) = 0
     OR position('regexp_replace' in v_index_definition) = 0
     OR position('is_current_for_order = true' in lower(v_index_definition)) = 0
  THEN
    RAISE EXCEPTION 'FAIL: current reference-family unique index definition is incomplete';
  END IF;

  SELECT COUNT(*)::integer
    INTO v_collision_count
  FROM (
    SELECT
      si.order_id,
      si.retailer_id,
      lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) AS normalised_ref
    FROM public.supplier_invoices si
    WHERE si.is_current_for_order = true
      AND COALESCE(si.review_status, 'pending_review') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
    GROUP BY
      si.order_id,
      si.retailer_id,
      lower(regexp_replace(btrim(si.invoice_ref), '[^a-zA-Z0-9]+', '', 'g'))
    HAVING COUNT(*) > 1
  ) collisions;

  IF v_collision_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: live current reference-family collisions remain: %', v_collision_count;
  END IF;

  SELECT pg_get_functiondef(
    'public.operator_submit_supplier_invoice(uuid,text,text)'::regprocedure
  ) INTO v_definition;

  IF position('v_normalised_ref' in v_definition) = 0
     OR position('reference family' in lower(v_definition)) = 0
     OR position('is_current_for_order' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: upload RPC is not reference-family aware';
  END IF;

  IF position('A current supplier invoice already exists for this order' in v_definition) > 0
     OR position('Original invoice_ref archived for corrected resubmission' in v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: upload RPC still contains the retired order-wide guard or ref-mutation workaround';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)'::regprocedure
  ) INTO v_definition;

  IF position('collides with another live version' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: approval RPC lacks reference-family collision protection';
  END IF;

  IF v_definition ~* 'UPDATE\s+public\.supplier_invoices\s+si\s+SET[\s\S]*review_status\s*=\s*''superseded''[\s\S]*WHERE\s+si\.order_id\s*=\s*v_invoice\.order_id' THEN
    RAISE EXCEPTION 'FAIL: approval RPC still supersedes sibling invoice references';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_reject_supplier_invoice_resubmission(uuid,text)'::regprocedure
  ) INTO v_definition;

  IF position('tracking allocation' in v_definition) = 0
     OR position('active customer review' in v_definition) = 0
     OR position('active customer hold' in v_definition) = 0
     OR position('unresolved exception' in v_definition) = 0
     OR position('non-void customer sales document' in v_definition) = 0
     OR position('supplier-payment allocation' in v_definition) = 0
     OR position('supplier refund or credit evidence' in v_definition) = 0
     OR position('frozen or posted supplier accounting artefact' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: rejection RPC does not cover every required irreversible-use blocker';
  END IF;

  IF to_regclass('public.order_supplier_invoice_bundle_lines_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: order bundle line view is missing';
  END IF;

  IF to_regclass('public.order_supplier_invoice_bundle_summary_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: order bundle summary view is missing';
  END IF;

  SELECT pg_get_viewdef('public.order_supplier_invoice_bundle_lines_v1'::regclass, true)
    INTO v_definition;

  IF position('supplier_invoice_line_id' in v_definition) = 0
     OR position('allocated_tracking_qty' in v_definition) = 0
     OR position('open_exception_yn' in v_definition) = 0
     OR position('active_hold_yn' in v_definition) = 0
     OR position('is_current_for_order' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: order bundle line view is missing required provenance or active-state controls';
  END IF;

  IF v_definition ~* '\mLIMIT\M\s+1' THEN
    RAISE EXCEPTION 'FAIL: order bundle line view contains a latest/one-invoice LIMIT 1 assumption';
  END IF;

  SELECT pg_get_viewdef('public.order_supplier_invoice_bundle_summary_v1'::regclass, true)
    INTO v_definition;

  IF position('active_invoice_count' in v_definition) = 0
     OR position('approved_invoice_count' in v_definition) = 0
     OR position('remaining_baseline_qty' in v_definition) = 0
     OR position('remaining_baseline_value_gbp' in v_definition) = 0
     OR position('all_documents_resolved_yn' in v_definition) = 0
     OR position('baseline_accounted_for_yn' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: order bundle summary view is incomplete';
  END IF;

  IF NOT has_table_privilege(
    'authenticated',
    'public.order_supplier_invoice_bundle_lines_v1',
    'SELECT'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated SELECT grant is missing on bundle line view';
  END IF;

  IF NOT has_table_privilege(
    'authenticated',
    'public.order_supplier_invoice_bundle_summary_v1',
    'SELECT'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated SELECT grant is missing on bundle summary view';
  END IF;
END $$;

SELECT 'PASS: multi-supplier-invoice Mini-build 1 structural controls are installed' AS regression_result;

ROLLBACK;
