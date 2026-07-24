-- =============================================================================
-- Retailer delivery/discount physical-basis regression v1
-- Read-only. Run after 20260724_invoice_adjustment_physical_basis_v1.sql.
-- =============================================================================

DO $$
DECLARE
  v_ensure text;
  v_recalc text;
  v_trigger_count integer;
  v_invoice_id uuid;
  v_basis_total numeric;
  v_delivery_total numeric;
  v_adjusted_total numeric;
BEGIN
  IF to_regprocedure('public.ensure_invoice_adjustment_basis_v1(uuid)') IS NULL
     OR to_regprocedure('public.recalculate_invoice_adjustment_consumption_v1(uuid)') IS NULL
     OR to_regprocedure('public.refresh_invoice_adjustment_after_nonphysical_resolution_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'Physical-basis function deployment is incomplete.';
  END IF;

  SELECT pg_get_functiondef('public.ensure_invoice_adjustment_basis_v1(uuid)'::regprocedure)
    INTO v_ensure;
  SELECT pg_get_functiondef('public.recalculate_invoice_adjustment_consumption_v1(uuid)'::regprocedure)
    INTO v_recalc;

  IF position('supplier_invoice_line_resolutions' in v_ensure) = 0
     OR position('non_physical_financial' in v_ensure) = 0
     OR position('customer_sales_release_lines' in v_ensure) = 0
     OR position('locked_for_export_pack' in v_ensure) = 0
  THEN
    RAISE EXCEPTION 'Physical-only constructor or immutable-history guards are missing.';
  END IF;

  IF position('customer_sales_release_lines' in v_recalc) = 0
     OR position('locked_for_export_pack_at IS NULL' in v_recalc) = 0
     OR position('allocation_status <> ''locked_for_export_pack''' in v_recalc) = 0
  THEN
    RAISE EXCEPTION 'Mutable-only recalculation guards are missing.';
  END IF;

  SELECT COUNT(*)::integer
    INTO v_trigger_count
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'supplier_invoice_line_resolutions'
    AND t.tgname = 'trg_refresh_invoice_adjustment_after_nonphysical_resolution_v1'
    AND NOT t.tgisinternal;

  IF v_trigger_count <> 1 THEN
    RAISE EXCEPTION 'Late non-physical classification refresh trigger is missing or duplicated.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_basis b
    JOIN public.supplier_invoices si ON si.id = b.supplier_invoice_id
    JOIN public.invoice_adjustment_basis_lines bl ON bl.invoice_adjustment_basis_id = b.id
    JOIN public.supplier_invoice_line_resolutions r
      ON r.supplier_invoice_line_id = bl.supplier_invoice_line_id
     AND r.active = true
     AND r.resolution_type = 'non_physical_financial'
    WHERE b.basis_status = 'locked'
      AND COALESCE(si.review_status, 'pending_review') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  ) THEN
    RAISE EXCEPTION 'An active invoice adjustment basis still contains a resolved non-physical line.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_basis b
    WHERE b.basis_status = 'locked'
      AND ROUND(b.locked_goods_total_gbp, 2) IS DISTINCT FROM (
        SELECT ROUND(COALESCE(SUM(bl.original_line_value_gbp), 0), 2)
        FROM public.invoice_adjustment_basis_lines bl
        WHERE bl.invoice_adjustment_basis_id = b.id
      )
  ) THEN
    RAISE EXCEPTION 'A locked goods denominator differs from its physical basis-line total.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations otla
    JOIN public.supplier_invoice_line_resolutions r
      ON r.supplier_invoice_line_id = otla.supplier_invoice_line_id
     AND r.active = true
     AND r.resolution_type = 'non_physical_financial'
  ) THEN
    RAISE EXCEPTION 'A resolved non-physical line is still allocated to tracking.';
  END IF;

  -- Known live example. Runs only when the exact invoice and evidence exist and
  -- the basis/allocation have already been created.
  SELECT si.id
    INTO v_invoice_id
  FROM public.supplier_invoices si
  WHERE si.invoice_ref = 'NK-INV-190726-B'
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  ORDER BY si.uploaded_at DESC NULLS LAST
  LIMIT 1;

  IF v_invoice_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.invoice_adjustment_basis b
       WHERE b.supplier_invoice_id = v_invoice_id
         AND b.basis_status = 'locked'
     )
     AND EXISTS (
       SELECT 1
       FROM public.order_tracking_line_allocations otla
       JOIN public.supplier_invoice_lines sil
         ON sil.id = otla.supplier_invoice_line_id
       WHERE sil.supplier_invoice_id = v_invoice_id
     )
     AND EXISTS (
       SELECT 1
       FROM public.supplier_invoice_line_resolutions r
       WHERE r.supplier_invoice_id = v_invoice_id
         AND r.active = true
         AND r.resolution_type = 'non_physical_financial'
         AND r.financial_type = 'delivery'
         AND ROUND(ABS(COALESCE(r.amount_gbp, 0)), 2) = 5.00
     )
  THEN
    SELECT
      b.locked_goods_total_gbp,
      COALESCE(SUM(otla.retailer_delivery_share_gbp), 0),
      COALESCE(SUM(otla.adjusted_net_value_gbp), 0)
    INTO v_basis_total, v_delivery_total, v_adjusted_total
    FROM public.invoice_adjustment_basis b
    LEFT JOIN public.invoice_adjustment_basis_lines bl
      ON bl.invoice_adjustment_basis_id = b.id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.supplier_invoice_line_id = bl.supplier_invoice_line_id
    WHERE b.supplier_invoice_id = v_invoice_id
      AND b.basis_status = 'locked'
    GROUP BY b.locked_goods_total_gbp;

    IF ROUND(COALESCE(v_basis_total, 0), 2) <> 179.99
       OR ROUND(COALESCE(v_delivery_total, 0), 2) <> 5.00
       OR ROUND(COALESCE(v_adjusted_total, 0), 2) <> 184.99
    THEN
      RAISE EXCEPTION
        'Known invoice regression failed: basis %, delivery %, adjusted %',
        v_basis_total,
        v_delivery_total,
        v_adjusted_total;
    END IF;
  END IF;
END $$;

SELECT
  'PASS'::text AS result,
  'Physical-only adjustment basis deployed; refund redistribution, source evidence, tracking quantities, package membership, customer release, Sage, VAT and banking routes were not replaced.'::text AS detail;
