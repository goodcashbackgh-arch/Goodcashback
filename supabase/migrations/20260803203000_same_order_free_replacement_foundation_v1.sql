-- Governed by:
-- docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md
-- docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md
--
-- Additive foundation only.
-- Mini Builds 1-4 are not altered.
-- No child order is created by this migration.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_md5 text;
BEGIN
  IF to_regclass('public.orders') IS NULL THEN v_missing := array_append(v_missing, 'orders'); END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN v_missing := array_append(v_missing, 'supplier_invoice_lines'); END IF;
  IF to_regclass('public.order_tracking_submissions') IS NULL THEN v_missing := array_append(v_missing, 'order_tracking_submissions'); END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN v_missing := array_append(v_missing, 'order_tracking_line_allocations'); END IF;
  IF to_regclass('public.physical_exception_remedy_allocations') IS NULL THEN v_missing := array_append(v_missing, 'physical_exception_remedy_allocations'); END IF;
  IF to_regclass('public.physical_receipt_reviews') IS NULL THEN v_missing := array_append(v_missing, 'physical_receipt_reviews'); END IF;
  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL THEN v_missing := array_append(v_missing, 'shipper_package_receipt_line_dispositions'); END IF;
  IF to_regclass('public.disputes') IS NULL THEN v_missing := array_append(v_missing, 'disputes'); END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN v_missing := array_append(v_missing, 'dispute_lines'); END IF;
  IF to_regclass('public.staff') IS NULL THEN v_missing := array_append(v_missing, 'staff'); END IF;
  IF to_regclass('public.operators') IS NULL THEN v_missing := array_append(v_missing, 'operators'); END IF;
  IF to_regclass('public.operator_importers') IS NULL THEN v_missing := array_append(v_missing, 'operator_importers'); END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Same-order replacement foundation missing prerequisites: %', array_to_string(v_missing, ', ');
  END IF;

  IF to_regclass('public.physical_replacement_same_order_routes') IS NOT NULL
     OR to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Same-order replacement foundation target already exists; inspect before applying.';
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'f82d15d2de1199f9ab841d8c1ad44738' THEN
    RAISE EXCEPTION 'Mini Build guard fingerprint changed: physical_remedy_allocation_guard_v2 = %', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '3c5067f31d4f2112207e02d1f307e233' THEN
    RAISE EXCEPTION 'Mini Build guard fingerprint changed: physical_remedy_sequence_guard_v1 = %', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'eaaf737e29580feb56272c55e6f1f679' THEN
    RAISE EXCEPTION 'Mini Build guard fingerprint changed: physical_receipt_review_guard_v1 = %', v_md5;
  END IF;
END
$preflight$;

CREATE TABLE public.physical_replacement_same_order_routes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  physical_remedy_allocation_id uuid NOT NULL UNIQUE
    REFERENCES public.physical_exception_remedy_allocations(id) ON DELETE RESTRICT,
  physical_receipt_review_id uuid NOT NULL
    REFERENCES public.physical_receipt_reviews(id) ON DELETE RESTRICT,
  dispute_id uuid NOT NULL
    REFERENCES public.disputes(id) ON DELETE RESTRICT,
  dispute_line_id uuid NOT NULL UNIQUE
    REFERENCES public.dispute_lines(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL
    REFERENCES public.orders(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL
    REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  source_tracking_line_allocation_id uuid NOT NULL
    REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  source_receipt_line_disposition_id uuid NOT NULL
    REFERENCES public.shipper_package_receipt_line_dispositions(id) ON DELETE RESTRICT,
  replacement_qty numeric(12,3) NOT NULL CHECK (replacement_qty > 0),
  transferred_base_value_gbp numeric(14,2) NOT NULL CHECK (transferred_base_value_gbp >= 0),
  transferred_discount_share_gbp numeric(14,2) NOT NULL CHECK (transferred_discount_share_gbp >= 0),
  transferred_retailer_delivery_share_gbp numeric(14,2) NOT NULL CHECK (transferred_retailer_delivery_share_gbp >= 0),
  transferred_adjusted_net_value_gbp numeric(14,2) NOT NULL CHECK (transferred_adjusted_net_value_gbp > 0),
  route_status text NOT NULL DEFAULT 'approved_waiting_tracking'
    CHECK (route_status IN ('approved_waiting_tracking','tracking_allocated','cancelled')),
  successor_tracking_submission_id uuid
    REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  successor_tracking_line_allocation_id uuid UNIQUE
    REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  accepted_by_staff_id uuid NOT NULL
    REFERENCES public.staff(id) ON DELETE RESTRICT,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  tracking_allocated_by_operator_id uuid
    REFERENCES public.operators(id) ON DELETE RESTRICT,
  tracking_allocated_by_staff_id uuid
    REFERENCES public.staff(id) ON DELETE RESTRICT,
  tracking_allocated_at timestamptz,
  cancelled_by_staff_id uuid
    REFERENCES public.staff(id) ON DELETE RESTRICT,
  cancelled_at timestamptz,
  cancellation_reason text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT same_order_route_whole_unit_qty_chk
    CHECK (trunc(replacement_qty) = replacement_qty),
  CONSTRAINT same_order_route_tracking_shape_chk CHECK (
    (
      route_status = 'approved_waiting_tracking'
      AND successor_tracking_submission_id IS NULL
      AND successor_tracking_line_allocation_id IS NULL
      AND tracking_allocated_by_operator_id IS NULL
      AND tracking_allocated_by_staff_id IS NULL
      AND tracking_allocated_at IS NULL
    )
    OR
    (
      route_status = 'tracking_allocated'
      AND successor_tracking_submission_id IS NOT NULL
      AND successor_tracking_line_allocation_id IS NOT NULL
      AND tracking_allocated_at IS NOT NULL
      AND num_nonnulls(tracking_allocated_by_operator_id, tracking_allocated_by_staff_id) = 1
    )
    OR
    (
      route_status = 'cancelled'
      AND cancelled_by_staff_id IS NOT NULL
      AND cancelled_at IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(cancellation_reason, '')), '') IS NOT NULL
    )
  )
);

COMMENT ON TABLE public.physical_replacement_same_order_routes IS
'Additive exact same-original-order free-replacement route. Does not create or require a replacement child order and does not modify Mini Builds 1-4.';

CREATE INDEX idx_same_order_replacement_order_status
  ON public.physical_replacement_same_order_routes(order_id, route_status, created_at);
CREATE INDEX idx_same_order_replacement_source_allocation
  ON public.physical_replacement_same_order_routes(source_tracking_line_allocation_id, route_status);
CREATE INDEX idx_same_order_replacement_supplier_line
  ON public.physical_replacement_same_order_routes(supplier_invoice_line_id, route_status);
CREATE INDEX idx_same_order_replacement_successor_tracking
  ON public.physical_replacement_same_order_routes(successor_tracking_submission_id)
  WHERE successor_tracking_submission_id IS NOT NULL;

ALTER TABLE public.physical_replacement_same_order_routes ENABLE ROW LEVEL SECURITY;

CREATE POLICY same_order_replacement_staff_read_v1
ON public.physical_replacement_same_order_routes
FOR SELECT TO authenticated
USING (public.is_active_staff());

CREATE POLICY same_order_replacement_operator_read_v1
ON public.physical_replacement_same_order_routes
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.operator_importers oi
      ON oi.importer_id = o.importer_id
     AND oi.revoked_at IS NULL
    JOIN public.operators op
      ON op.id = oi.operator_id
    WHERE o.id = physical_replacement_same_order_routes.order_id
      AND op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
  )
);

CREATE FUNCTION public.tracking_allocation_effective_entitlement_v1(
  p_order_id uuid DEFAULT NULL,
  p_supplier_invoice_line_id uuid DEFAULT NULL
)
RETURNS TABLE (
  allocation_id uuid,
  order_id uuid,
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid,
  raw_qty_allocated numeric,
  transferred_out_qty numeric,
  effective_qty_allocated numeric,
  raw_base_value_gbp numeric,
  transferred_out_base_value_gbp numeric,
  effective_base_value_gbp numeric,
  raw_discount_share_gbp numeric,
  transferred_out_discount_share_gbp numeric,
  effective_discount_share_gbp numeric,
  raw_retailer_delivery_share_gbp numeric,
  transferred_out_retailer_delivery_share_gbp numeric,
  effective_retailer_delivery_share_gbp numeric,
  raw_adjusted_net_value_gbp numeric,
  transferred_out_adjusted_net_value_gbp numeric,
  effective_adjusted_net_value_gbp numeric,
  is_same_order_successor boolean,
  source_allocation_id uuid,
  replacement_route_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH route_slices AS (
    SELECT
      r.source_tracking_line_allocation_id,
      SUM(r.replacement_qty)::numeric AS transferred_qty,
      SUM(r.transferred_base_value_gbp)::numeric AS transferred_base,
      SUM(r.transferred_discount_share_gbp)::numeric AS transferred_discount,
      SUM(r.transferred_retailer_delivery_share_gbp)::numeric AS transferred_delivery,
      SUM(r.transferred_adjusted_net_value_gbp)::numeric AS transferred_adjusted
    FROM public.physical_replacement_same_order_routes r
    WHERE r.route_status = 'tracking_allocated'
      AND r.successor_tracking_line_allocation_id IS NOT NULL
    GROUP BY r.source_tracking_line_allocation_id
  ), successor_identity AS (
    SELECT
      r.successor_tracking_line_allocation_id AS allocation_id,
      r.source_tracking_line_allocation_id AS source_allocation_id,
      r.id AS replacement_route_id
    FROM public.physical_replacement_same_order_routes r
    WHERE r.route_status = 'tracking_allocated'
      AND r.successor_tracking_line_allocation_id IS NOT NULL
  )
  SELECT
    a.id AS allocation_id,
    a.order_id,
    a.supplier_invoice_line_id,
    a.tracking_submission_id,
    a.qty_allocated::numeric AS raw_qty_allocated,
    COALESCE(s.transferred_qty, 0)::numeric AS transferred_out_qty,
    (a.qty_allocated - COALESCE(s.transferred_qty, 0))::numeric AS effective_qty_allocated,
    a.base_value_gbp::numeric AS raw_base_value_gbp,
    COALESCE(s.transferred_base, 0)::numeric AS transferred_out_base_value_gbp,
    (a.base_value_gbp - COALESCE(s.transferred_base, 0))::numeric AS effective_base_value_gbp,
    a.discount_share_gbp::numeric AS raw_discount_share_gbp,
    COALESCE(s.transferred_discount, 0)::numeric AS transferred_out_discount_share_gbp,
    (a.discount_share_gbp - COALESCE(s.transferred_discount, 0))::numeric AS effective_discount_share_gbp,
    a.retailer_delivery_share_gbp::numeric AS raw_retailer_delivery_share_gbp,
    COALESCE(s.transferred_delivery, 0)::numeric AS transferred_out_retailer_delivery_share_gbp,
    (a.retailer_delivery_share_gbp - COALESCE(s.transferred_delivery, 0))::numeric AS effective_retailer_delivery_share_gbp,
    a.adjusted_net_value_gbp::numeric AS raw_adjusted_net_value_gbp,
    COALESCE(s.transferred_adjusted, 0)::numeric AS transferred_out_adjusted_net_value_gbp,
    (a.adjusted_net_value_gbp - COALESCE(s.transferred_adjusted, 0))::numeric AS effective_adjusted_net_value_gbp,
    (si.allocation_id IS NOT NULL) AS is_same_order_successor,
    si.source_allocation_id,
    si.replacement_route_id
  FROM public.order_tracking_line_allocations a
  LEFT JOIN route_slices s
    ON s.source_tracking_line_allocation_id = a.id
  LEFT JOIN successor_identity si
    ON si.allocation_id = a.id
  WHERE (p_order_id IS NULL OR a.order_id = p_order_id)
    AND (p_supplier_invoice_line_id IS NULL OR a.supplier_invoice_line_id = p_supplier_invoice_line_id)
$function$;

COMMENT ON FUNCTION public.tracking_allocation_effective_entitlement_v1(uuid,uuid) IS
'Current commercial entitlement projection: raw allocation less exact committed same-order replacement transfer. Raw package/receipt history remains unchanged.';

REVOKE ALL ON FUNCTION public.tracking_allocation_effective_entitlement_v1(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tracking_allocation_effective_entitlement_v1(uuid,uuid) TO authenticated, service_role;

DO $postflight$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'f82d15d2de1199f9ab841d8c1ad44738' THEN
    RAISE EXCEPTION 'Mini Build guard changed during migration: physical_remedy_allocation_guard_v2 = %', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '3c5067f31d4f2112207e02d1f307e233' THEN
    RAISE EXCEPTION 'Mini Build guard changed during migration: physical_remedy_sequence_guard_v1 = %', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'eaaf737e29580feb56272c55e6f1f679' THEN
    RAISE EXCEPTION 'Mini Build guard changed during migration: physical_receipt_review_guard_v1 = %', v_md5;
  END IF;
END
$postflight$;

COMMIT;
