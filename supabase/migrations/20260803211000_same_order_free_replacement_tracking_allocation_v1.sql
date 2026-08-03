-- Governed by HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1 + v1_1.
-- Additive successor allocation only. No closure adapter and no child order.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)') IS NULL
     OR to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)') IS NULL
  THEN RAISE EXCEPTION 'Same-order acceptance/foundation must be installed first.'; END IF;
  IF to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Tracking allocation authority already exists; inspect before applying.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.operator_allocate_same_order_replacement_tracking_v1(
  p_order_id uuid,
  p_tracking_submission_id uuid,
  p_route_ids uuid[],
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_operator public.operators%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_tracking_order_id uuid;
  v_input_count integer;
  v_distinct_count integer;
  v_valid_count integer;
  v_route public.physical_replacement_same_order_routes%ROWTYPE;
  v_allocation_id uuid;
  v_created jsonb := '[]'::jsonb;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT op.* INTO v_operator
  FROM public.operators op
  WHERE op.auth_user_id=auth.uid() AND COALESCE(op.active,true)
  ORDER BY op.id LIMIT 1;
  IF v_operator.id IS NULL THEN RAISE EXCEPTION 'Active operator account not found.'; END IF;

  SELECT o.* INTO v_order FROM public.orders o WHERE o.id=p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.operator_importers oi
    WHERE oi.operator_id=v_operator.id AND oi.importer_id=v_order.importer_id AND oi.revoked_at IS NULL
  ) THEN RAISE EXCEPTION 'Operator is not authorised for this order.'; END IF;

  SELECT ots.order_id INTO v_tracking_order_id
  FROM public.order_tracking_submissions ots
  WHERE ots.id=p_tracking_submission_id AND ots.superseded_at IS NULL
  FOR UPDATE;
  IF v_tracking_order_id IS DISTINCT FROM p_order_id THEN
    RAISE EXCEPTION 'Tracking submission is missing, superseded or belongs to another order.';
  END IF;

  v_input_count := COALESCE(array_length(p_route_ids,1),0);
  SELECT COUNT(DISTINCT x)::integer INTO v_distinct_count
  FROM unnest(COALESCE(p_route_ids,ARRAY[]::uuid[])) x;
  IF v_input_count=0 THEN RAISE EXCEPTION 'At least one route is required.'; END IF;
  IF v_input_count<>v_distinct_count THEN RAISE EXCEPTION 'Duplicate route IDs are not allowed.'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_order_id::text));

  PERFORM 1 FROM public.physical_replacement_same_order_routes r
  WHERE r.id=ANY(p_route_ids) ORDER BY r.id FOR UPDATE;

  SELECT COUNT(*)::integer INTO v_valid_count
  FROM public.physical_replacement_same_order_routes r
  WHERE r.id=ANY(p_route_ids)
    AND r.order_id=p_order_id
    AND r.route_status='approved_waiting_tracking'
    AND r.successor_tracking_submission_id IS NULL
    AND r.successor_tracking_line_allocation_id IS NULL;
  IF v_valid_count<>v_input_count THEN
    RAISE EXCEPTION 'Every route must exist once, belong to the order and await tracking allocation.';
  END IF;

  PERFORM 1 FROM public.order_tracking_line_allocations a
  WHERE a.id IN (
    SELECT r.source_tracking_line_allocation_id
    FROM public.physical_replacement_same_order_routes r
    WHERE r.id=ANY(p_route_ids)
  ) ORDER BY a.id FOR UPDATE;

  CREATE TEMP TABLE pg_temp.same_order_before_position ON COMMIT DROP AS
  SELECT e.supplier_invoice_line_id,
         SUM(e.effective_qty_allocated) qty,
         SUM(e.effective_base_value_gbp) base,
         SUM(e.effective_discount_share_gbp) discount,
         SUM(e.effective_retailer_delivery_share_gbp) delivery,
         SUM(e.effective_adjusted_net_value_gbp) adjusted
  FROM public.tracking_allocation_effective_entitlement_v1(p_order_id,NULL) e
  WHERE e.supplier_invoice_line_id IN (
    SELECT r.supplier_invoice_line_id FROM public.physical_replacement_same_order_routes r WHERE r.id=ANY(p_route_ids)
  )
  GROUP BY e.supplier_invoice_line_id;

  FOR v_route IN
    SELECT r.* FROM public.physical_replacement_same_order_routes r
    WHERE r.id=ANY(p_route_ids) ORDER BY r.id
  LOOP
    IF v_route.replacement_qty<=0
       OR v_route.transferred_adjusted_net_value_gbp<=0
       OR abs((v_route.transferred_base_value_gbp-v_route.transferred_discount_share_gbp+v_route.transferred_retailer_delivery_share_gbp)-v_route.transferred_adjusted_net_value_gbp)>0.01
    THEN RAISE EXCEPTION 'Route % has invalid transferred entitlement.',v_route.id; END IF;

    INSERT INTO public.order_tracking_line_allocations(
      order_id,supplier_invoice_line_id,tracking_submission_id,qty_allocated,
      base_value_gbp,discount_share_gbp,retailer_delivery_share_gbp,adjusted_net_value_gbp,
      allocation_status,allocation_basis,notes,allocated_by_operator_id,created_at,updated_at
    ) VALUES (
      p_order_id,v_route.supplier_invoice_line_id,p_tracking_submission_id,v_route.replacement_qty,
      v_route.transferred_base_value_gbp,v_route.transferred_discount_share_gbp,
      v_route.transferred_retailer_delivery_share_gbp,v_route.transferred_adjusted_net_value_gbp,
      'allocated','operator_declaration',
      concat_ws(' ','Same-order free replacement successor for route',v_route.id::text||'.',NULLIF(BTRIM(COALESCE(p_note,'')),'')),
      v_operator.id,v_now,v_now
    ) RETURNING id INTO v_allocation_id;

    UPDATE public.physical_replacement_same_order_routes
    SET route_status='tracking_allocated',
        successor_tracking_submission_id=p_tracking_submission_id,
        successor_tracking_line_allocation_id=v_allocation_id,
        tracking_allocated_by_operator_id=v_operator.id,
        tracking_allocated_by_staff_id=NULL,
        tracking_allocated_at=v_now,
        updated_at=v_now
    WHERE id=v_route.id;

    v_created := v_created || jsonb_build_array(jsonb_build_object(
      'route_id',v_route.id,
      'successor_tracking_line_allocation_id',v_allocation_id,
      'supplier_invoice_line_id',v_route.supplier_invoice_line_id,
      'replacement_qty',v_route.replacement_qty));
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.tracking_allocation_effective_entitlement_v1(p_order_id,NULL) e
    WHERE e.effective_qty_allocated < -0.0005
       OR e.effective_base_value_gbp < -0.005
       OR e.effective_discount_share_gbp < -0.005
       OR e.effective_retailer_delivery_share_gbp < -0.005
       OR e.effective_adjusted_net_value_gbp < -0.005
  ) THEN RAISE EXCEPTION 'Negative effective entitlement produced.'; END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.same_order_before_position b
    LEFT JOIN (
      SELECT e.supplier_invoice_line_id,
             SUM(e.effective_qty_allocated) qty,
             SUM(e.effective_base_value_gbp) base,
             SUM(e.effective_discount_share_gbp) discount,
             SUM(e.effective_retailer_delivery_share_gbp) delivery,
             SUM(e.effective_adjusted_net_value_gbp) adjusted
      FROM public.tracking_allocation_effective_entitlement_v1(p_order_id,NULL) e
      GROUP BY e.supplier_invoice_line_id
    ) a USING (supplier_invoice_line_id)
    WHERE abs(COALESCE(a.qty,0)-b.qty)>0.0005
       OR abs(COALESCE(a.base,0)-b.base)>0.005
       OR abs(COALESCE(a.discount,0)-b.discount)>0.005
       OR abs(COALESCE(a.delivery,0)-b.delivery)>0.005
       OR abs(COALESCE(a.adjusted,0)-b.adjusted)>0.005
  ) THEN RAISE EXCEPTION 'Successor allocation changed effective line quantity/value.'; END IF;

  PERFORM public.raise_escalation('SAME_ORDER_REPLACEMENT_TRACKING_ALLOCATED','order',p_order_id,
    jsonb_build_object('tracking_submission_id',p_tracking_submission_id,'route_ids',to_jsonb(p_route_ids),
      'created_allocations',v_created,'operator_id',v_operator.id,'note',p_note));

  RETURN jsonb_build_object('ok',true,'order_id',p_order_id,
    'tracking_submission_id',p_tracking_submission_id,'created_allocations',v_created);
END;
$function$;

REVOKE ALL ON FUNCTION public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text) TO authenticated, service_role;

COMMIT;
