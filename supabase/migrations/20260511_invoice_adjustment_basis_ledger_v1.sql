BEGIN;

CREATE TABLE IF NOT EXISTS public.invoice_adjustment_basis (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_id uuid NOT NULL UNIQUE REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  locked_goods_total_gbp numeric(14,2) NOT NULL DEFAULT 0,
  locked_discount_total_gbp numeric(14,2) NOT NULL DEFAULT 0,
  locked_delivery_total_gbp numeric(14,2) NOT NULL DEFAULT 0,
  basis_status varchar NOT NULL DEFAULT 'locked' CHECK (basis_status IN ('locked','superseded','voided')),
  locked_by_staff_id uuid REFERENCES public.staff(id),
  locked_by_operator_id uuid REFERENCES public.operators(id),
  locked_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoice_adjustment_basis_actor_check CHECK (locked_by_staff_id IS NOT NULL OR locked_by_operator_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.invoice_adjustment_basis_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_adjustment_basis_id uuid NOT NULL REFERENCES public.invoice_adjustment_basis(id) ON DELETE CASCADE,
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE CASCADE,
  original_qty numeric(12,3) NOT NULL DEFAULT 0,
  original_line_value_gbp numeric(14,2) NOT NULL DEFAULT 0,
  line_share_ratio numeric(18,8) NOT NULL DEFAULT 0,
  locked_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (invoice_adjustment_basis_id, supplier_invoice_line_id)
);

CREATE TABLE IF NOT EXISTS public.invoice_adjustment_consumption_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_adjustment_basis_id uuid NOT NULL REFERENCES public.invoice_adjustment_basis(id) ON DELETE CASCADE,
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE CASCADE,
  source_allocation_id uuid REFERENCES public.order_tracking_line_allocations(id) ON DELETE SET NULL,
  tracking_submission_id uuid REFERENCES public.order_tracking_submissions(id) ON DELETE SET NULL,
  shipment_batch_id uuid REFERENCES public.shipper_shipment_batches(id) ON DELETE SET NULL,
  qty_consumed numeric(12,3) NOT NULL DEFAULT 0,
  base_value_consumed_gbp numeric(14,2) NOT NULL DEFAULT 0,
  discount_consumed_gbp numeric(14,2) NOT NULL DEFAULT 0,
  delivery_consumed_gbp numeric(14,2) NOT NULL DEFAULT 0,
  chargeable_adjusted_goods_basis_gbp numeric(14,2) NOT NULL DEFAULT 0,
  outcome varchar NOT NULL CHECK (outcome IN ('progressed_allocated','shipped_charged','refunded_nil_charge','replacement_child','written_off_nil_charge','superseded')),
  reason text,
  active boolean NOT NULL DEFAULT true,
  created_by_staff_id uuid REFERENCES public.staff(id),
  created_by_operator_id uuid REFERENCES public.operators(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  superseded_at timestamptz,
  CONSTRAINT invoice_adjustment_consumption_reason_check CHECK (
    outcome IN ('progressed_allocated','shipped_charged','superseded') OR NULLIF(BTRIM(COALESCE(reason,'')), '') IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS idx_iab_order ON public.invoice_adjustment_basis(order_id);
CREATE INDEX IF NOT EXISTS idx_iabl_invoice ON public.invoice_adjustment_basis_lines(supplier_invoice_id);
CREATE INDEX IF NOT EXISTS idx_iacl_invoice ON public.invoice_adjustment_consumption_ledger(supplier_invoice_id, active);
CREATE INDEX IF NOT EXISTS idx_iacl_line ON public.invoice_adjustment_consumption_ledger(supplier_invoice_line_id, active);
CREATE UNIQUE INDEX IF NOT EXISTS ux_iacl_active_progressed_allocation
  ON public.invoice_adjustment_consumption_ledger(source_allocation_id)
  WHERE active = true AND source_allocation_id IS NOT NULL AND outcome = 'progressed_allocated';

ALTER TABLE public.invoice_adjustment_basis ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_adjustment_basis_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_adjustment_consumption_ledger ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='invoice_adjustment_basis' AND policyname='iab_staff_all') THEN
    CREATE POLICY iab_staff_all ON public.invoice_adjustment_basis FOR ALL TO authenticated USING (public.is_active_staff()) WITH CHECK (public.is_active_staff());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='invoice_adjustment_basis_lines' AND policyname='iabl_staff_all') THEN
    CREATE POLICY iabl_staff_all ON public.invoice_adjustment_basis_lines FOR ALL TO authenticated USING (public.is_active_staff()) WITH CHECK (public.is_active_staff());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='invoice_adjustment_consumption_ledger' AND policyname='iacl_staff_all') THEN
    CREATE POLICY iacl_staff_all ON public.invoice_adjustment_consumption_ledger FOR ALL TO authenticated USING (public.is_active_staff()) WITH CHECK (public.is_active_staff());
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.ensure_invoice_adjustment_basis_v1(p_supplier_invoice_id uuid)
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: invoice adjustment basis requires auth.uid()';
  END IF;

  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO v_operator_id FROM public.operators WHERE auth_user_id = auth.uid() AND active = true ORDER BY created_at DESC LIMIT 1;

  IF v_staff_id IS NULL AND v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active staff/operator account required for invoice adjustment basis.';
  END IF;

  SELECT si.order_id INTO v_order_id FROM public.supplier_invoices si WHERE si.id = p_supplier_invoice_id;
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

  SELECT iab.id INTO v_basis_id
  FROM public.invoice_adjustment_basis iab
  WHERE iab.supplier_invoice_id = p_supplier_invoice_id
    AND iab.basis_status = 'locked';

  IF v_basis_id IS NOT NULL THEN
    RETURN v_basis_id;
  END IF;

  SELECT COALESCE(SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)), 0)
    INTO v_goods_total
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0) > 0;

  SELECT
    COALESCE(SUM(CASE WHEN ova.adjustment_type = 'retailer_discount' THEN ova.amount_gbp ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN ova.adjustment_type = 'retailer_delivery' THEN ova.amount_gbp ELSE 0 END), 0)
  INTO v_discount_total, v_delivery_total
  FROM public.order_value_adjustments ova
  WHERE ova.supplier_invoice_id = p_supplier_invoice_id
    AND ova.approval_status IN ('approved','auto_approved');

  INSERT INTO public.invoice_adjustment_basis (
    supplier_invoice_id, order_id, locked_goods_total_gbp, locked_discount_total_gbp, locked_delivery_total_gbp,
    locked_by_staff_id, locked_by_operator_id, notes
  ) VALUES (
    p_supplier_invoice_id, v_order_id, v_goods_total, v_discount_total, v_delivery_total,
    v_staff_id, CASE WHEN v_staff_id IS NULL THEN v_operator_id ELSE NULL END,
    'Locked from supplier invoice lines and approved retailer delivery/discount adjustments.'
  ) RETURNING id INTO v_basis_id;

  INSERT INTO public.invoice_adjustment_basis_lines (
    invoice_adjustment_basis_id, supplier_invoice_id, supplier_invoice_line_id,
    original_qty, original_line_value_gbp, line_share_ratio
  )
  SELECT
    v_basis_id,
    p_supplier_invoice_id,
    sil.id,
    COALESCE(sil.qty_confirmed, sil.qty, 0),
    COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0),
    CASE WHEN v_goods_total > 0 THEN ROUND(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0) / v_goods_total, 8) ELSE 0 END
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
    AND COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0) > 0;

  RETURN v_basis_id;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_invoice_adjustment_basis_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_invoice_adjustment_basis_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.recalculate_invoice_adjustment_consumption_v1(p_supplier_invoice_id uuid)
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

  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO v_operator_id FROM public.operators WHERE auth_user_id = auth.uid() AND active = true ORDER BY created_at DESC LIMIT 1;

  v_basis_id := public.ensure_invoice_adjustment_basis_v1(p_supplier_invoice_id);

  UPDATE public.invoice_adjustment_consumption_ledger l
     SET active = false,
         outcome = 'superseded',
         superseded_at = now()
   WHERE l.supplier_invoice_id = p_supplier_invoice_id
     AND l.outcome = 'progressed_allocated'
     AND l.active = true;

  WITH basis AS (
    SELECT * FROM public.invoice_adjustment_basis WHERE id = v_basis_id
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
        WHEN bl.original_qty > 0 THEN ROUND(bl.original_line_value_gbp * otla.qty_allocated / bl.original_qty, 2)
        ELSE COALESCE(otla.base_value_gbp, 0)
      END AS base_value_consumed
    FROM public.order_tracking_line_allocations otla
    JOIN public.invoice_adjustment_basis_lines bl ON bl.supplier_invoice_line_id = otla.supplier_invoice_line_id
    JOIN basis b ON b.id = bl.invoice_adjustment_basis_id
    LEFT JOIN public.shipper_shipment_batch_packages p ON p.tracking_submission_id = otla.tracking_submission_id AND p.active = true
    WHERE bl.supplier_invoice_id = p_supplier_invoice_id
      AND otla.locked_for_export_pack_at IS NULL
  ), calc AS (
    SELECT
      src.*,
      CASE WHEN src.locked_goods_total_gbp > 0 THEN ROUND(src.locked_discount_total_gbp * src.base_value_consumed / src.locked_goods_total_gbp, 2) ELSE 0 END AS discount_consumed,
      CASE WHEN src.locked_goods_total_gbp > 0 THEN ROUND(src.locked_delivery_total_gbp * src.base_value_consumed / src.locked_goods_total_gbp, 2) ELSE 0 END AS delivery_consumed
    FROM src
  )
  INSERT INTO public.invoice_adjustment_consumption_ledger (
    invoice_adjustment_basis_id, supplier_invoice_id, supplier_invoice_line_id, source_allocation_id,
    tracking_submission_id, shipment_batch_id, qty_consumed, base_value_consumed_gbp,
    discount_consumed_gbp, delivery_consumed_gbp, chargeable_adjusted_goods_basis_gbp,
    outcome, reason, created_by_staff_id, created_by_operator_id
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
    'Progressed allocation recalculated from locked invoice basis.',
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
    AND otla.locked_for_export_pack_at IS NULL;

  RETURN QUERY
  SELECT
    b.supplier_invoice_id,
    b.locked_goods_total_gbp,
    b.locked_discount_total_gbp,
    b.locked_delivery_total_gbp,
    COALESCE(SUM(l.base_value_consumed_gbp) FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0),
    COALESCE(SUM(l.discount_consumed_gbp) FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0),
    COALESCE(SUM(l.delivery_consumed_gbp) FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0),
    COALESCE(SUM(l.chargeable_adjusted_goods_basis_gbp) FILTER (WHERE l.active AND l.outcome = 'progressed_allocated'), 0)
  FROM public.invoice_adjustment_basis b
  LEFT JOIN public.invoice_adjustment_consumption_ledger l ON l.invoice_adjustment_basis_id = b.id
  WHERE b.id = v_basis_id
  GROUP BY b.supplier_invoice_id, b.locked_goods_total_gbp, b.locked_discount_total_gbp, b.locked_delivery_total_gbp;
END;
$$;

REVOKE ALL ON FUNCTION public.recalculate_invoice_adjustment_consumption_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.recalculate_invoice_adjustment_consumption_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.close_invoice_adjustment_line_balance_v1(
  p_supplier_invoice_line_id uuid,
  p_outcome text,
  p_reason text,
  p_qty_to_close numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_basis public.invoice_adjustment_basis%ROWTYPE;
  v_line public.invoice_adjustment_basis_lines%ROWTYPE;
  v_qty numeric;
  v_base numeric;
  v_discount numeric;
  v_delivery numeric;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: close invoice adjustment balance requires auth.uid()';
  END IF;

  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true ORDER BY created_at DESC LIMIT 1;
  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required to close invoice adjustment balance.';
  END IF;

  IF p_outcome NOT IN ('refunded_nil_charge','replacement_child','written_off_nil_charge') THEN
    RAISE EXCEPTION 'Invalid line balance closure outcome: %', p_outcome;
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_reason,'')), '') IS NULL THEN
    RAISE EXCEPTION 'Reason is required to close an invoice adjustment balance.';
  END IF;

  SELECT bl.* INTO v_line
  FROM public.invoice_adjustment_basis_lines bl
  WHERE bl.supplier_invoice_line_id = p_supplier_invoice_line_id
  ORDER BY bl.locked_at DESC
  LIMIT 1;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'No locked invoice adjustment basis exists for this line.';
  END IF;

  SELECT * INTO v_basis FROM public.invoice_adjustment_basis WHERE id = v_line.invoice_adjustment_basis_id;

  v_qty := COALESCE(p_qty_to_close, v_line.original_qty) - COALESCE((
    SELECT SUM(l.qty_consumed)
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.supplier_invoice_line_id = p_supplier_invoice_line_id
      AND l.active = true
      AND l.outcome IN ('progressed_allocated','refunded_nil_charge','replacement_child','written_off_nil_charge')
  ), 0);

  IF v_qty <= 0 THEN
    RAISE EXCEPTION 'No remaining quantity exists to close for this line.';
  END IF;

  v_base := CASE WHEN v_line.original_qty > 0 THEN ROUND(v_line.original_line_value_gbp * v_qty / v_line.original_qty, 2) ELSE 0 END;
  v_discount := CASE WHEN v_basis.locked_goods_total_gbp > 0 THEN ROUND(v_basis.locked_discount_total_gbp * v_base / v_basis.locked_goods_total_gbp, 2) ELSE 0 END;
  v_delivery := CASE WHEN v_basis.locked_goods_total_gbp > 0 THEN ROUND(v_basis.locked_delivery_total_gbp * v_base / v_basis.locked_goods_total_gbp, 2) ELSE 0 END;

  INSERT INTO public.invoice_adjustment_consumption_ledger (
    invoice_adjustment_basis_id, supplier_invoice_id, supplier_invoice_line_id,
    qty_consumed, base_value_consumed_gbp, discount_consumed_gbp, delivery_consumed_gbp,
    chargeable_adjusted_goods_basis_gbp, outcome, reason, created_by_staff_id
  ) VALUES (
    v_basis.id, v_basis.supplier_invoice_id, p_supplier_invoice_line_id,
    v_qty, v_base, v_discount, v_delivery,
    CASE WHEN p_outcome = 'replacement_child' THEN v_base - v_discount + v_delivery ELSE 0 END,
    p_outcome, BTRIM(p_reason), v_staff_id
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.close_invoice_adjustment_line_balance_v1(uuid,text,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.close_invoice_adjustment_line_balance_v1(uuid,text,text,numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_invoice_adjustment_basis_position_v1(p_supplier_invoice_id uuid)
RETURNS TABLE (
  supplier_invoice_id uuid,
  supplier_invoice_line_id uuid,
  item_description text,
  original_qty numeric,
  original_line_value_gbp numeric,
  locked_goods_total_gbp numeric,
  locked_discount_total_gbp numeric,
  locked_delivery_total_gbp numeric,
  qty_consumed numeric,
  base_consumed_gbp numeric,
  discount_consumed_gbp numeric,
  delivery_consumed_gbp numeric,
  chargeable_adjusted_goods_basis_gbp numeric,
  qty_remaining numeric,
  base_remaining_gbp numeric,
  discount_remaining_gbp numeric,
  delivery_remaining_gbp numeric,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: invoice adjustment basis position requires auth.uid()';
  END IF;
  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for invoice adjustment basis position.';
  END IF;

  RETURN QUERY
  WITH b AS (
    SELECT * FROM public.invoice_adjustment_basis WHERE supplier_invoice_id = p_supplier_invoice_id AND basis_status = 'locked'
  ), consumed AS (
    SELECT
      l.supplier_invoice_line_id,
      SUM(l.qty_consumed) FILTER (WHERE l.active AND l.outcome IN ('progressed_allocated','refunded_nil_charge','replacement_child','written_off_nil_charge')) AS qty_consumed,
      SUM(l.base_value_consumed_gbp) FILTER (WHERE l.active AND l.outcome IN ('progressed_allocated','refunded_nil_charge','replacement_child','written_off_nil_charge')) AS base_consumed,
      SUM(l.discount_consumed_gbp) FILTER (WHERE l.active AND l.outcome IN ('progressed_allocated','refunded_nil_charge','replacement_child','written_off_nil_charge')) AS discount_consumed,
      SUM(l.delivery_consumed_gbp) FILTER (WHERE l.active AND l.outcome IN ('progressed_allocated','refunded_nil_charge','replacement_child','written_off_nil_charge')) AS delivery_consumed,
      SUM(l.chargeable_adjusted_goods_basis_gbp) FILTER (WHERE l.active AND l.outcome IN ('progressed_allocated','refunded_nil_charge','replacement_child','written_off_nil_charge')) AS adjusted_consumed
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.supplier_invoice_id = p_supplier_invoice_id
    GROUP BY l.supplier_invoice_line_id
  )
  SELECT
    bl.supplier_invoice_id,
    bl.supplier_invoice_line_id,
    COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text,
    bl.original_qty,
    bl.original_line_value_gbp,
    b.locked_goods_total_gbp,
    b.locked_discount_total_gbp,
    b.locked_delivery_total_gbp,
    COALESCE(c.qty_consumed, 0),
    COALESCE(c.base_consumed, 0),
    COALESCE(c.discount_consumed, 0),
    COALESCE(c.delivery_consumed, 0),
    COALESCE(c.adjusted_consumed, 0),
    GREATEST(bl.original_qty - COALESCE(c.qty_consumed, 0), 0),
    GREATEST(bl.original_line_value_gbp - COALESCE(c.base_consumed, 0), 0),
    CASE WHEN b.locked_goods_total_gbp > 0 THEN ROUND(b.locked_discount_total_gbp * GREATEST(bl.original_line_value_gbp - COALESCE(c.base_consumed, 0), 0) / b.locked_goods_total_gbp, 2) ELSE 0 END,
    CASE WHEN b.locked_goods_total_gbp > 0 THEN ROUND(b.locked_delivery_total_gbp * GREATEST(bl.original_line_value_gbp - COALESCE(c.base_consumed, 0), 0) / b.locked_goods_total_gbp, 2) ELSE 0 END,
    CASE WHEN GREATEST(bl.original_qty - COALESCE(c.qty_consumed, 0), 0) = 0 THEN 'closed' ELSE 'open_balance' END::text
  FROM b
  JOIN public.invoice_adjustment_basis_lines bl ON bl.invoice_adjustment_basis_id = b.id
  LEFT JOIN public.supplier_invoice_lines sil ON sil.id = bl.supplier_invoice_line_id
  LEFT JOIN consumed c ON c.supplier_invoice_line_id = bl.supplier_invoice_line_id
  ORDER BY sil.line_order NULLS LAST, sil.description;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_invoice_adjustment_basis_position_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_invoice_adjustment_basis_position_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
