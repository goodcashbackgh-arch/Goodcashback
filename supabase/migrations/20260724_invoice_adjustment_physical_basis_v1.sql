BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- Retailer delivery/discount apportionment: physical-goods basis correction.
--
-- This migration deliberately preserves:
--   * supplier invoice/OCR source rows and totals;
--   * value-weighted apportionment;
--   * delivery as an addition and discount as a reduction;
--   * the existing no-redistribution treatment after refund/write-off;
--   * tracking quantities, package membership and shipment batches;
--   * immutable customer-release and export-pack history;
--   * Mini-build 1-4, banking/treasury, Sage and VAT routes.
--
-- It changes only the derived invoice-adjustment basis so a line already proven
-- by the existing authoritative resolution table to be non-physical cannot also
-- sit inside the physical-goods denominator.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.invoice_adjustment_basis') IS NULL
     OR to_regclass('public.invoice_adjustment_basis_lines') IS NULL
     OR to_regclass('public.invoice_adjustment_consumption_ledger') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.order_value_adjustments') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.shipper_shipment_batch_packages') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.staff') IS NULL
     OR to_regclass('public.operators') IS NULL
     OR to_regclass('public.operator_importers') IS NULL
     OR to_regclass('public.orders') IS NULL
  THEN
    RAISE EXCEPTION 'Invoice-adjustment physical-basis prerequisite relation missing.';
  END IF;

  IF to_regprocedure('public.ensure_invoice_adjustment_basis_v1(uuid)') IS NULL
     OR to_regprocedure('public.recalculate_invoice_adjustment_consumption_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Invoice-adjustment physical-basis prerequisite function missing.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Existing constructor, narrowed to authoritative physical membership.
--
-- Existing bases are left byte-for-byte unchanged unless they contain a basis
-- line that now has an active non_physical_financial resolution. A contaminated
-- basis is corrected only while every affected allocation remains mutable.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_invoice_adjustment_basis_v1(
  p_supplier_invoice_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_basis_id uuid;
  v_order_id uuid;
  v_staff_id uuid;
  v_operator_id uuid;
  v_goods_total numeric := 0;
  v_discount_total numeric := 0;
  v_delivery_total numeric := 0;
  v_contaminated_count integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: invoice adjustment basis requires auth.uid()';
  END IF;

  SELECT id
    INTO v_staff_id
  FROM public.staff
  WHERE auth_user_id = auth.uid()
    AND active = true
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT id
    INTO v_operator_id
  FROM public.operators
  WHERE auth_user_id = auth.uid()
    AND active = true
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL AND v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active staff/operator account required for invoice adjustment basis.';
  END IF;

  SELECT si.order_id
    INTO v_order_id
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF v_staff_id IS NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.orders o
      JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
      WHERE o.id = v_order_id
        AND oi.operator_id = v_operator_id
        AND oi.revoked_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Operator is not authorised for this invoice.';
    END IF;
  END IF;

  SELECT iab.id
    INTO v_basis_id
  FROM public.invoice_adjustment_basis iab
  WHERE iab.supplier_invoice_id = p_supplier_invoice_id
    AND iab.basis_status = 'locked'
  FOR UPDATE;

  IF v_basis_id IS NOT NULL THEN
    SELECT COUNT(*)::integer
      INTO v_contaminated_count
    FROM public.invoice_adjustment_basis_lines bl
    WHERE bl.invoice_adjustment_basis_id = v_basis_id
      AND EXISTS (
        SELECT 1
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_line_id = bl.supplier_invoice_line_id
          AND r.resolution_type = 'non_physical_financial'
          AND r.active = true
      );

    IF v_contaminated_count = 0 THEN
      RETURN v_basis_id;
    END IF;

    -- A denominator change would alter every allocation share on the invoice.
    -- Never rewrite an allocation already frozen for export or durable customer
    -- release membership.
    IF EXISTS (
      SELECT 1
      FROM public.order_tracking_line_allocations otla
      JOIN public.supplier_invoice_lines sil
        ON sil.id = otla.supplier_invoice_line_id
      WHERE sil.supplier_invoice_id = p_supplier_invoice_id
        AND (
          otla.locked_for_export_pack_at IS NOT NULL
          OR otla.allocation_status = 'locked_for_export_pack'
          OR EXISTS (
            SELECT 1
            FROM public.customer_sales_release_lines csrl
            WHERE csrl.tracking_line_allocation_id = otla.id
              AND csrl.release_status = 'active'
          )
        )
    ) THEN
      RAISE EXCEPTION
        'Invoice adjustment basis % contains a resolved non-physical line but is already immutable through export/customer release. Use the controlled correction/reversal route.',
        p_supplier_invoice_id;
    END IF;

    -- Terminal outcome rows are retained under the established no-redistribution
    -- model. They are not silently rewritten by this constructor.
    IF EXISTS (
      SELECT 1
      FROM public.invoice_adjustment_consumption_ledger l
      WHERE l.supplier_invoice_id = p_supplier_invoice_id
        AND l.active = true
        AND l.outcome IN ('refunded_nil_charge','replacement_child','written_off_nil_charge')
    ) THEN
      RAISE EXCEPTION
        'Invoice adjustment basis % contains a resolved non-physical line and an active terminal consumption outcome. Supervisor correction is required; terminal history was not rewritten.',
        p_supplier_invoice_id;
    END IF;

    -- A non-physical line must never have been allocated as package contents.
    IF EXISTS (
      SELECT 1
      FROM public.invoice_adjustment_basis_lines bl
      JOIN public.order_tracking_line_allocations otla
        ON otla.supplier_invoice_line_id = bl.supplier_invoice_line_id
      WHERE bl.invoice_adjustment_basis_id = v_basis_id
        AND EXISTS (
          SELECT 1
          FROM public.supplier_invoice_line_resolutions r
          WHERE r.supplier_invoice_line_id = bl.supplier_invoice_line_id
            AND r.resolution_type = 'non_physical_financial'
            AND r.active = true
        )
    ) THEN
      RAISE EXCEPTION
        'Invoice adjustment basis % has a tracking allocation on a resolved non-physical line. No automatic correction was applied.',
        p_supplier_invoice_id;
    END IF;

    DELETE FROM public.invoice_adjustment_basis_lines bl
    WHERE bl.invoice_adjustment_basis_id = v_basis_id
      AND EXISTS (
        SELECT 1
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_line_id = bl.supplier_invoice_line_id
          AND r.resolution_type = 'non_physical_financial'
          AND r.active = true
      );

    SELECT COALESCE(SUM(bl.original_line_value_gbp), 0)
      INTO v_goods_total
    FROM public.invoice_adjustment_basis_lines bl
    WHERE bl.invoice_adjustment_basis_id = v_basis_id;

    IF v_goods_total <= 0 THEN
      RAISE EXCEPTION
        'Invoice adjustment basis % has no positive physical-goods value after excluding resolved non-physical lines.',
        p_supplier_invoice_id;
    END IF;

    UPDATE public.invoice_adjustment_basis b
       SET locked_goods_total_gbp = v_goods_total,
           notes = CONCAT_WS(
             E'\n',
             NULLIF(BTRIM(COALESCE(b.notes, '')), ''),
             'Physical-basis correction: explicitly resolved non-physical financial lines excluded from the goods denominator.'
           ),
           updated_at = now()
     WHERE b.id = v_basis_id;

    UPDATE public.invoice_adjustment_basis_lines bl
       SET line_share_ratio = ROUND(bl.original_line_value_gbp / v_goods_total, 8)
     WHERE bl.invoice_adjustment_basis_id = v_basis_id;

    RETURN v_basis_id;
  END IF;

  SELECT COALESCE(SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)), 0)
    INTO v_goods_total
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0) > 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_line_id = sil.id
        AND r.resolution_type = 'non_physical_financial'
        AND r.active = true
    );

  SELECT
    COALESCE(SUM(CASE WHEN ova.adjustment_type = 'retailer_discount' THEN ova.amount_gbp ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN ova.adjustment_type = 'retailer_delivery' THEN ova.amount_gbp ELSE 0 END), 0)
  INTO v_discount_total, v_delivery_total
  FROM public.order_value_adjustments ova
  WHERE ova.supplier_invoice_id = p_supplier_invoice_id
    AND ova.approval_status IN ('approved','auto_approved');

  INSERT INTO public.invoice_adjustment_basis (
    supplier_invoice_id,
    order_id,
    locked_goods_total_gbp,
    locked_discount_total_gbp,
    locked_delivery_total_gbp,
    locked_by_staff_id,
    locked_by_operator_id,
    notes
  ) VALUES (
    p_supplier_invoice_id,
    v_order_id,
    v_goods_total,
    v_discount_total,
    v_delivery_total,
    v_staff_id,
    CASE WHEN v_staff_id IS NULL THEN v_operator_id ELSE NULL END,
    'Locked from physical supplier invoice lines and approved retailer delivery/discount adjustments.'
  )
  RETURNING id INTO v_basis_id;

  INSERT INTO public.invoice_adjustment_basis_lines (
    invoice_adjustment_basis_id,
    supplier_invoice_id,
    supplier_invoice_line_id,
    original_qty,
    original_line_value_gbp,
    line_share_ratio
  )
  SELECT
    v_basis_id,
    p_supplier_invoice_id,
    sil.id,
    COALESCE(sil.qty_confirmed, sil.qty, 0),
    COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0),
    CASE
      WHEN v_goods_total > 0
        THEN ROUND(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0) / v_goods_total, 8)
      ELSE 0
    END
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0) > 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_line_id = sil.id
        AND r.resolution_type = 'non_physical_financial'
        AND r.active = true
    );

  RETURN v_basis_id;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_invoice_adjustment_basis_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_invoice_adjustment_basis_v1(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Existing recalculation route, preserving immutable allocations.
--
-- The former function superseded every active progressed row but rebuilt only
-- unlocked allocations. This replacement narrows both sides to the same mutable
-- population, so locked/exported/released history can never disappear.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recalculate_invoice_adjustment_consumption_v1(
  p_supplier_invoice_id uuid
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  locked_goods_total_gbp numeric,
  locked_discount_total_gbp numeric,
  locked_delivery_total_gbp numeric,
  active_progressed_base_gbp numeric,
  active_discount_consumed_gbp numeric,
  active_delivery_consumed_gbp numeric,
  active_adjusted_goods_basis_gbp numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_basis_id uuid;
  v_staff_id uuid;
  v_operator_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: recalculate invoice adjustment consumption requires auth.uid()';
  END IF;

  SELECT id
    INTO v_staff_id
  FROM public.staff
  WHERE auth_user_id = auth.uid()
    AND active = true
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT id
    INTO v_operator_id
  FROM public.operators
  WHERE auth_user_id = auth.uid()
    AND active = true
  ORDER BY created_at DESC
  LIMIT 1;

  v_basis_id := public.ensure_invoice_adjustment_basis_v1(p_supplier_invoice_id);

  UPDATE public.invoice_adjustment_consumption_ledger l
     SET active = false,
         outcome = 'superseded',
         superseded_at = now()
   WHERE l.supplier_invoice_id = p_supplier_invoice_id
     AND l.outcome = 'progressed_allocated'
     AND l.active = true
     AND EXISTS (
       SELECT 1
       FROM public.order_tracking_line_allocations otla
       WHERE otla.id = l.source_allocation_id
         AND otla.locked_for_export_pack_at IS NULL
         AND otla.allocation_status <> 'locked_for_export_pack'
         AND NOT EXISTS (
           SELECT 1
           FROM public.customer_sales_release_lines csrl
           WHERE csrl.tracking_line_allocation_id = otla.id
             AND csrl.release_status = 'active'
         )
     );

  WITH basis AS (
    SELECT *
    FROM public.invoice_adjustment_basis
    WHERE id = v_basis_id
  ), src AS (
    SELECT
      otla.id AS source_allocation_id,
      otla.supplier_invoice_line_id,
      otla.tracking_submission_id,
      p.shipment_batch_id,
      otla.qty_allocated,
      bl.original_qty,
      bl.original_line_value_gbp,
      b.locked_goods_total_gbp,
      b.locked_discount_total_gbp,
      b.locked_delivery_total_gbp,
      CASE
        WHEN bl.original_qty > 0
          THEN ROUND(bl.original_line_value_gbp * otla.qty_allocated / bl.original_qty, 2)
        ELSE COALESCE(otla.base_value_gbp, 0)
      END AS base_value_consumed
    FROM public.order_tracking_line_allocations otla
    JOIN public.invoice_adjustment_basis_lines bl
      ON bl.supplier_invoice_line_id = otla.supplier_invoice_line_id
    JOIN basis b
      ON b.id = bl.invoice_adjustment_basis_id
    LEFT JOIN public.shipper_shipment_batch_packages p
      ON p.tracking_submission_id = otla.tracking_submission_id
     AND p.active = true
    WHERE bl.supplier_invoice_id = p_supplier_invoice_id
      AND otla.locked_for_export_pack_at IS NULL
      AND otla.allocation_status <> 'locked_for_export_pack'
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_sales_release_lines csrl
        WHERE csrl.tracking_line_allocation_id = otla.id
          AND csrl.release_status = 'active'
      )
  ), calc AS (
    SELECT
      src.*,
      CASE
        WHEN src.locked_goods_total_gbp > 0
          THEN ROUND(src.locked_discount_total_gbp * src.base_value_consumed / src.locked_goods_total_gbp, 2)
        ELSE 0
      END AS discount_consumed,
      CASE
        WHEN src.locked_goods_total_gbp > 0
          THEN ROUND(src.locked_delivery_total_gbp * src.base_value_consumed / src.locked_goods_total_gbp, 2)
        ELSE 0
      END AS delivery_consumed
    FROM src
  )
  INSERT INTO public.invoice_adjustment_consumption_ledger (
    invoice_adjustment_basis_id,
    supplier_invoice_id,
    supplier_invoice_line_id,
    source_allocation_id,
    tracking_submission_id,
    shipment_batch_id,
    qty_consumed,
    base_value_consumed_gbp,
    discount_consumed_gbp,
    delivery_consumed_gbp,
    chargeable_adjusted_goods_basis_gbp,
    outcome,
    reason,
    created_by_staff_id,
    created_by_operator_id
  )
  SELECT
    v_basis_id,
    p_supplier_invoice_id,
    c.supplier_invoice_line_id,
    c.source_allocation_id,
    c.tracking_submission_id,
    c.shipment_batch_id,
    c.qty_allocated,
    c.base_value_consumed,
    c.discount_consumed,
    c.delivery_consumed,
    c.base_value_consumed - c.discount_consumed + c.delivery_consumed,
    'progressed_allocated',
    'Progressed allocation recalculated from locked physical invoice basis.',
    v_staff_id,
    CASE WHEN v_staff_id IS NULL THEN v_operator_id ELSE NULL END
  FROM calc c;

  UPDATE public.order_tracking_line_allocations otla
     SET base_value_gbp = l.base_value_consumed_gbp,
         discount_share_gbp = l.discount_consumed_gbp,
         retailer_delivery_share_gbp = l.delivery_consumed_gbp,
         adjusted_net_value_gbp = l.chargeable_adjusted_goods_basis_gbp,
         updated_at = now()
  FROM public.invoice_adjustment_consumption_ledger l
  WHERE l.source_allocation_id = otla.id
    AND l.supplier_invoice_id = p_supplier_invoice_id
    AND l.outcome = 'progressed_allocated'
    AND l.active = true
    AND otla.locked_for_export_pack_at IS NULL
    AND otla.allocation_status <> 'locked_for_export_pack'
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines csrl
      WHERE csrl.tracking_line_allocation_id = otla.id
        AND csrl.release_status = 'active'
    );

  RETURN QUERY
  SELECT
    b.supplier_invoice_id,
    b.locked_goods_total_gbp,
    b.locked_discount_total_gbp,
    b.locked_delivery_total_gbp,
    COALESCE(SUM(l.base_value_consumed_gbp)
      FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0),
    COALESCE(SUM(l.discount_consumed_gbp)
      FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0),
    COALESCE(SUM(l.delivery_consumed_gbp)
      FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0),
    COALESCE(SUM(l.chargeable_adjusted_goods_basis_gbp)
      FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0)
  FROM public.invoice_adjustment_basis b
  LEFT JOIN public.invoice_adjustment_consumption_ledger l
    ON l.invoice_adjustment_basis_id = b.id
  WHERE b.id = v_basis_id
  GROUP BY
    b.supplier_invoice_id,
    b.locked_goods_total_gbp,
    b.locked_discount_total_gbp,
    b.locked_delivery_total_gbp;
END;
$$;

REVOKE ALL ON FUNCTION public.recalculate_invoice_adjustment_consumption_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.recalculate_invoice_adjustment_consumption_v1(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Late authoritative classification bridge.
--
-- Normal operator/staff resolution actions already create the resolution row in
-- one database transaction. This trigger refreshes an existing mutable basis in
-- that same transaction. Failure therefore rolls back the classification rather
-- than leaving a half-corrected allocation.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_invoice_adjustment_after_nonphysical_resolution_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.active = true
     AND NEW.resolution_type = 'non_physical_financial'
     AND EXISTS (
       SELECT 1
       FROM public.invoice_adjustment_basis b
       WHERE b.supplier_invoice_id = NEW.supplier_invoice_id
         AND b.basis_status = 'locked'
     )
  THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION
        'Authenticated operator/staff context required to refresh an existing invoice adjustment basis after non-physical classification.';
    END IF;

    PERFORM 1
    FROM public.recalculate_invoice_adjustment_consumption_v1(NEW.supplier_invoice_id);
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_invoice_adjustment_after_nonphysical_resolution_v1() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_refresh_invoice_adjustment_after_nonphysical_resolution_v1
  ON public.supplier_invoice_line_resolutions;

CREATE TRIGGER trg_refresh_invoice_adjustment_after_nonphysical_resolution_v1
AFTER INSERT OR UPDATE OF active, resolution_type, supplier_invoice_line_id
ON public.supplier_invoice_line_resolutions
FOR EACH ROW
WHEN (NEW.active = true AND NEW.resolution_type = 'non_physical_financial')
EXECUTE FUNCTION public.refresh_invoice_adjustment_after_nonphysical_resolution_v1();

-- -----------------------------------------------------------------------------
-- 4. Guarded one-time repair for existing active supplier invoices.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _iab_physical_basis_affected ON COMMIT DROP AS
SELECT DISTINCT
  b.id AS basis_id,
  b.supplier_invoice_id
FROM public.invoice_adjustment_basis b
JOIN public.supplier_invoices si
  ON si.id = b.supplier_invoice_id
JOIN public.invoice_adjustment_basis_lines bl
  ON bl.invoice_adjustment_basis_id = b.id
JOIN public.supplier_invoice_line_resolutions r
  ON r.supplier_invoice_line_id = bl.supplier_invoice_line_id
 AND r.resolution_type = 'non_physical_financial'
 AND r.active = true
WHERE b.basis_status = 'locked'
  AND COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  );

CREATE TEMP TABLE _iab_physical_basis_allocation_before ON COMMIT DROP AS
SELECT
  a.basis_id,
  otla.id AS allocation_id,
  to_jsonb(otla)
    - ARRAY[
      'base_value_gbp',
      'discount_share_gbp',
      'retailer_delivery_share_gbp',
      'adjusted_net_value_gbp',
      'updated_at'
    ]::text[] AS immutable_payload
FROM _iab_physical_basis_affected a
JOIN public.supplier_invoice_lines sil
  ON sil.supplier_invoice_id = a.supplier_invoice_id
JOIN public.order_tracking_line_allocations otla
  ON otla.supplier_invoice_line_id = sil.id;

DO $$
DECLARE
  v_row record;
  v_goods_total numeric;
BEGIN
  FOR v_row IN
    SELECT basis_id, supplier_invoice_id
    FROM _iab_physical_basis_affected
    ORDER BY supplier_invoice_id
  LOOP
    PERFORM 1
    FROM public.invoice_adjustment_basis b
    WHERE b.id = v_row.basis_id
    FOR UPDATE;

    IF EXISTS (
      SELECT 1
      FROM public.order_tracking_line_allocations otla
      JOIN public.supplier_invoice_lines sil
        ON sil.id = otla.supplier_invoice_line_id
      WHERE sil.supplier_invoice_id = v_row.supplier_invoice_id
        AND (
          otla.locked_for_export_pack_at IS NOT NULL
          OR otla.allocation_status = 'locked_for_export_pack'
          OR EXISTS (
            SELECT 1
            FROM public.customer_sales_release_lines csrl
            WHERE csrl.tracking_line_allocation_id = otla.id
              AND csrl.release_status = 'active'
          )
        )
    ) THEN
      RAISE EXCEPTION
        'Existing basis % is contaminated but immutable through export/customer release; migration made no changes.',
        v_row.supplier_invoice_id;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.invoice_adjustment_consumption_ledger l
      WHERE l.supplier_invoice_id = v_row.supplier_invoice_id
        AND l.active = true
        AND l.outcome IN ('refunded_nil_charge','replacement_child','written_off_nil_charge')
    ) THEN
      RAISE EXCEPTION
        'Existing basis % is contaminated and has an active terminal consumption outcome; migration made no changes.',
        v_row.supplier_invoice_id;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.invoice_adjustment_basis_lines bl
      JOIN public.order_tracking_line_allocations otla
        ON otla.supplier_invoice_line_id = bl.supplier_invoice_line_id
      WHERE bl.invoice_adjustment_basis_id = v_row.basis_id
        AND EXISTS (
          SELECT 1
          FROM public.supplier_invoice_line_resolutions r
          WHERE r.supplier_invoice_line_id = bl.supplier_invoice_line_id
            AND r.resolution_type = 'non_physical_financial'
            AND r.active = true
        )
    ) THEN
      RAISE EXCEPTION
        'Existing basis % has a tracking allocation on a resolved non-physical line; migration made no changes.',
        v_row.supplier_invoice_id;
    END IF;

    DELETE FROM public.invoice_adjustment_basis_lines bl
    WHERE bl.invoice_adjustment_basis_id = v_row.basis_id
      AND EXISTS (
        SELECT 1
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_line_id = bl.supplier_invoice_line_id
          AND r.resolution_type = 'non_physical_financial'
          AND r.active = true
      );

    SELECT COALESCE(SUM(bl.original_line_value_gbp), 0)
      INTO v_goods_total
    FROM public.invoice_adjustment_basis_lines bl
    WHERE bl.invoice_adjustment_basis_id = v_row.basis_id;

    IF v_goods_total <= 0 THEN
      RAISE EXCEPTION
        'Existing basis % has no positive physical-goods value after correction.',
        v_row.supplier_invoice_id;
    END IF;

    UPDATE public.invoice_adjustment_basis b
       SET locked_goods_total_gbp = v_goods_total,
           notes = CONCAT_WS(
             E'\n',
             NULLIF(BTRIM(COALESCE(b.notes, '')), ''),
             'Physical-basis correction: explicitly resolved non-physical financial lines excluded from the goods denominator.'
           ),
           updated_at = now()
     WHERE b.id = v_row.basis_id;

    UPDATE public.invoice_adjustment_basis_lines bl
       SET line_share_ratio = ROUND(bl.original_line_value_gbp / v_goods_total, 8)
     WHERE bl.invoice_adjustment_basis_id = v_row.basis_id;

    UPDATE public.invoice_adjustment_consumption_ledger l
       SET active = false,
           outcome = 'superseded',
           superseded_at = now()
     WHERE l.supplier_invoice_id = v_row.supplier_invoice_id
       AND l.outcome = 'progressed_allocated'
       AND l.active = true;

    WITH basis AS (
      SELECT *
      FROM public.invoice_adjustment_basis
      WHERE id = v_row.basis_id
    ), src AS (
      SELECT
        otla.id AS source_allocation_id,
        otla.supplier_invoice_line_id,
        otla.tracking_submission_id,
        p.shipment_batch_id,
        otla.qty_allocated,
        bl.original_qty,
        bl.original_line_value_gbp,
        b.locked_goods_total_gbp,
        b.locked_discount_total_gbp,
        b.locked_delivery_total_gbp,
        CASE
          WHEN bl.original_qty > 0
            THEN ROUND(bl.original_line_value_gbp * otla.qty_allocated / bl.original_qty, 2)
          ELSE COALESCE(otla.base_value_gbp, 0)
        END AS base_value_consumed
      FROM public.order_tracking_line_allocations otla
      JOIN public.invoice_adjustment_basis_lines bl
        ON bl.supplier_invoice_line_id = otla.supplier_invoice_line_id
      JOIN basis b
        ON b.id = bl.invoice_adjustment_basis_id
      LEFT JOIN public.shipper_shipment_batch_packages p
        ON p.tracking_submission_id = otla.tracking_submission_id
       AND p.active = true
      WHERE bl.supplier_invoice_id = v_row.supplier_invoice_id
    ), calc AS (
      SELECT
        src.*,
        CASE
          WHEN src.locked_goods_total_gbp > 0
            THEN ROUND(src.locked_discount_total_gbp * src.base_value_consumed / src.locked_goods_total_gbp, 2)
          ELSE 0
        END AS discount_consumed,
        CASE
          WHEN src.locked_goods_total_gbp > 0
            THEN ROUND(src.locked_delivery_total_gbp * src.base_value_consumed / src.locked_goods_total_gbp, 2)
          ELSE 0
        END AS delivery_consumed
      FROM src
    )
    INSERT INTO public.invoice_adjustment_consumption_ledger (
      invoice_adjustment_basis_id,
      supplier_invoice_id,
      supplier_invoice_line_id,
      source_allocation_id,
      tracking_submission_id,
      shipment_batch_id,
      qty_consumed,
      base_value_consumed_gbp,
      discount_consumed_gbp,
      delivery_consumed_gbp,
      chargeable_adjusted_goods_basis_gbp,
      outcome,
      reason,
      created_by_staff_id,
      created_by_operator_id
    )
    SELECT
      v_row.basis_id,
      v_row.supplier_invoice_id,
      c.supplier_invoice_line_id,
      c.source_allocation_id,
      c.tracking_submission_id,
      c.shipment_batch_id,
      c.qty_allocated,
      c.base_value_consumed,
      c.discount_consumed,
      c.delivery_consumed,
      c.base_value_consumed - c.discount_consumed + c.delivery_consumed,
      'progressed_allocated',
      'Progressed allocation rebuilt by guarded physical-basis migration.',
      otla.allocated_by_staff_id,
      otla.allocated_by_operator_id
    FROM calc c
    JOIN public.order_tracking_line_allocations otla
      ON otla.id = c.source_allocation_id;

    UPDATE public.order_tracking_line_allocations otla
       SET base_value_gbp = l.base_value_consumed_gbp,
           discount_share_gbp = l.discount_consumed_gbp,
           retailer_delivery_share_gbp = l.delivery_consumed_gbp,
           adjusted_net_value_gbp = l.chargeable_adjusted_goods_basis_gbp,
           updated_at = now()
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.source_allocation_id = otla.id
      AND l.supplier_invoice_id = v_row.supplier_invoice_id
      AND l.outcome = 'progressed_allocated'
      AND l.active = true;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 5. Transactional non-impact and result assertions.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_invoice_id uuid;
  v_basis_total numeric;
  v_delivery_total numeric;
  v_adjusted_total numeric;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM _iab_physical_basis_allocation_before b
    JOIN public.order_tracking_line_allocations otla
      ON otla.id = b.allocation_id
    WHERE (
      to_jsonb(otla)
        - ARRAY[
          'base_value_gbp',
          'discount_share_gbp',
          'retailer_delivery_share_gbp',
          'adjusted_net_value_gbp',
          'updated_at'
        ]::text[]
    ) IS DISTINCT FROM b.immutable_payload
  ) THEN
    RAISE EXCEPTION 'Physical-basis repair changed a non-financial tracking-allocation field.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_basis b
    JOIN public.supplier_invoices si
      ON si.id = b.supplier_invoice_id
    JOIN public.invoice_adjustment_basis_lines bl
      ON bl.invoice_adjustment_basis_id = b.id
    JOIN public.supplier_invoice_line_resolutions r
      ON r.supplier_invoice_line_id = bl.supplier_invoice_line_id
     AND r.resolution_type = 'non_physical_financial'
     AND r.active = true
    WHERE b.basis_status = 'locked'
      AND COALESCE(si.review_status, 'pending_review') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  ) THEN
    RAISE EXCEPTION 'An active supplier invoice adjustment basis still contains a resolved non-physical line.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM _iab_physical_basis_affected a
    JOIN public.invoice_adjustment_basis b
      ON b.id = a.basis_id
    WHERE ROUND(b.locked_goods_total_gbp, 2) IS DISTINCT FROM (
      SELECT ROUND(COALESCE(SUM(bl.original_line_value_gbp), 0), 2)
      FROM public.invoice_adjustment_basis_lines bl
      WHERE bl.invoice_adjustment_basis_id = b.id
    )
  ) THEN
    RAISE EXCEPTION 'A repaired basis total does not equal its remaining physical basis lines.';
  END IF;

  -- Known live regression runs only when the exact invoice/evidence exists.
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
        'Known invoice physical-basis regression failed: basis %, delivery %, adjusted %',
        v_basis_total,
        v_delivery_total,
        v_adjusted_total;
    END IF;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
