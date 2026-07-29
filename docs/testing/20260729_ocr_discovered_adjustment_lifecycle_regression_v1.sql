/* =============================================================================
   OCR-DISCOVERED DELIVERY / DISCOUNT ADJUSTMENT LIFECYCLE REGRESSION v1
   -----------------------------------------------------------------------------
   Run AFTER:
     supabase/migrations/20260729_ocr_discovered_adjustment_lifecycle_v1.sql

   Controlled invoice:
     NK-INV-310726-73

   This regression is read-only except for a rollback-only approval simulation.
   No authenticated RPC calls are used.
   ============================================================================= */

DO $$
DECLARE
  v_invoice_id uuid;
  v_adjustment_id uuid;
  v_adjustment_count integer;
  v_open_flag_count integer;
  v_trigger_count integer;
  v_operator_def text;
  v_staff_def text;
BEGIN
  SELECT si.id
    INTO v_invoice_id
  FROM public.supplier_invoices si
  WHERE si.invoice_ref = 'NK-INV-310726-73'
  LIMIT 1;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: controlled invoice NK-INV-310726-73 not found';
  END IF;

  IF to_regprocedure('public.internal_materialize_ocr_financial_adjustment_v1(uuid,text)') IS NULL
     OR to_regprocedure('public.internal_resolve_delivery_discount_query_if_satisfied_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: lifecycle helper function(s) missing';
  END IF;

  SELECT count(*)::integer
    INTO v_trigger_count
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal
    AND n.nspname = 'public'
    AND (
      (c.relname = 'supplier_invoice_line_resolutions' AND t.tgname = 'trg_sync_ocr_financial_resolution_adjustment_v1')
      OR
      (c.relname = 'order_value_adjustments' AND t.tgname = 'trg_recheck_delivery_discount_query_after_adjustment_v1')
    );

  IF v_trigger_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: expected exactly 2 lifecycle triggers, found %', v_trigger_count;
  END IF;

  SELECT pg_get_functiondef('public.operator_resolve_supplier_invoice_line_non_physical(uuid,uuid,text,text)'::regprocedure)
    INTO v_operator_def;
  SELECT pg_get_functiondef('public.staff_resolve_supplier_invoice_line_non_physical(uuid,uuid,text,text)'::regprocedure)
    INTO v_staff_def;

  IF v_operator_def ILIKE '%order_value_adjustments%'
     OR v_operator_def ILIKE '%internal_materialize_ocr_financial_adjustment_v1%'
     OR v_staff_def ILIKE '%order_value_adjustments%'
     OR v_staff_def ILIKE '%internal_materialize_ocr_financial_adjustment_v1%' THEN
    RAISE EXCEPTION 'FAIL: existing non-physical resolver RPC bodies were modified instead of preserved';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoice_line_resolutions r
    WHERE r.supplier_invoice_id = v_invoice_id
      AND r.active = true
      AND r.resolution_type = 'non_physical_financial'
      AND r.financial_type = 'delivery'
      AND abs(abs(r.amount_gbp) - 11.42) <= 0.01
  ) THEN
    RAISE EXCEPTION 'FAIL: controlled active £11.42 delivery resolution missing';
  END IF;

  SELECT count(*)::integer, min(a.id)
    INTO v_adjustment_count, v_adjustment_id
  FROM public.order_value_adjustments a
  WHERE a.supplier_invoice_id = v_invoice_id
    AND a.adjustment_type = 'retailer_delivery'
    AND a.approval_status <> 'rejected';

  IF v_adjustment_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: controlled invoice expected exactly one live retailer_delivery adjustment, found %', v_adjustment_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.order_value_adjustments a
    WHERE a.id = v_adjustment_id
      AND abs(a.amount_gbp - 11.42) <= 0.01
      AND a.approval_status = 'pending_supervisor'
      AND a.requires_supervisor_approval = true
  ) THEN
    RAISE EXCEPTION 'FAIL: controlled £11.42 delivery was not materialised as pending_supervisor';
  END IF;

  SELECT count(*)::integer
    INTO v_open_flag_count
  FROM public.supplier_invoice_review_flags f
  WHERE f.supplier_invoice_id = v_invoice_id
    AND f.flag_type = 'delivery_discount_query'
    AND f.status IN ('open', 'under_review');

  IF v_open_flag_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: delivery_discount_query must remain open before supervisor approval';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_get_functiondef('public.internal_materialize_ocr_financial_adjustment_v1(uuid,text)'::regprocedure) AS d(definition)
    WHERE definition ILIKE '%delivery_auto_approve_limit_gbp%'
      AND definition ILIKE '%10.00%'
      AND definition ILIKE '%pending_supervisor%'
      AND definition ILIKE '%auto_approved%'
      AND definition ILIKE '%retailer_discount%'
  ) THEN
    RAISE EXCEPTION 'FAIL: existing delivery threshold / discount approval policy is not preserved in materialisation helper';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_value_adjustments a
    WHERE a.supplier_invoice_id = v_invoice_id
      AND a.adjustment_type = 'retailer_delivery'
      AND a.approval_status = 'auto_approved'
  ) THEN
    RAISE EXCEPTION 'FAIL: controlled over-limit £11.42 delivery was auto-approved';
  END IF;
END $$;

-- Rollback-only proof that the existing adjustment approval state change causes
-- the exact review flag to resolve, without approving the supplier invoice or
-- touching downstream artefacts.
BEGIN;

DO $$
DECLARE
  v_invoice_id uuid;
  v_adjustment_id uuid;
  v_staff_id uuid;
  v_before_invoice jsonb;
  v_before_resolution jsonb;
BEGIN
  SELECT si.id, to_jsonb(si)
    INTO v_invoice_id, v_before_invoice
  FROM public.supplier_invoices si
  WHERE si.invoice_ref = 'NK-INV-310726-73'
  LIMIT 1;

  SELECT a.id
    INTO v_adjustment_id
  FROM public.order_value_adjustments a
  WHERE a.supplier_invoice_id = v_invoice_id
    AND a.adjustment_type = 'retailer_delivery'
    AND a.approval_status = 'pending_supervisor'
    AND abs(a.amount_gbp - 11.42) <= 0.01
  ORDER BY a.created_at DESC, a.id DESC
  LIMIT 1;

  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE s.active = true
    AND s.role_type IN ('admin', 'supervisor')
  ORDER BY s.created_at, s.id
  LIMIT 1;

  IF v_adjustment_id IS NULL OR v_staff_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: rollback-only approval prerequisites missing';
  END IF;

  SELECT to_jsonb(r)
    INTO v_before_resolution
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.supplier_invoice_id = v_invoice_id
    AND r.active = true
    AND r.resolution_type = 'non_physical_financial'
    AND r.financial_type = 'delivery'
    AND abs(abs(r.amount_gbp) - 11.42) <= 0.01
  LIMIT 1;

  UPDATE public.order_value_adjustments a
  SET approval_status = 'approved',
      approved_by_staff_id = v_staff_id,
      approved_at = now(),
      updated_at = now()
  WHERE a.id = v_adjustment_id;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = v_invoice_id
      AND f.flag_type = 'delivery_discount_query'
      AND f.status IN ('open', 'under_review')
  ) THEN
    RAISE EXCEPTION 'FAIL: accepted matching adjustment did not resolve delivery_discount_query';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = v_invoice_id
      AND f.flag_type = 'delivery_discount_query'
      AND f.status = 'resolved'
      AND f.resolved_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: resolved delivery_discount_query lifecycle fields missing';
  END IF;

  IF (SELECT to_jsonb(si) FROM public.supplier_invoices si WHERE si.id = v_invoice_id) IS DISTINCT FROM v_before_invoice THEN
    RAISE EXCEPTION 'FAIL: adjustment approval lifecycle changed supplier_invoices row';
  END IF;

  IF (SELECT to_jsonb(r)
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_id = v_invoice_id
        AND r.active = true
        AND r.resolution_type = 'non_physical_financial'
        AND r.financial_type = 'delivery'
        AND abs(abs(r.amount_gbp) - 11.42) <= 0.01
      LIMIT 1) IS DISTINCT FROM v_before_resolution THEN
    RAISE EXCEPTION 'FAIL: adjustment approval lifecycle changed the existing line resolution';
  END IF;
END $$;

ROLLBACK;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'controlled £11.42 OCR delivery materialises exactly one pending supervisor adjustment; review flag stays open before approval; rollback-only matching approval resolves only the delivery/discount query; existing non-physical resolver RPC bodies remain untouched'
) AS regression_result;
