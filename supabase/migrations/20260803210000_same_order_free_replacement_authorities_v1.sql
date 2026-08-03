-- Governed by:
-- docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md
-- docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md
--
-- Additive authorities only. Mini Builds 1-4 remain unchanged.
-- No child order, supplier invoice, DVA, AP, Sage, VAT, settlement or closure adapter is created.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_md5 text;
BEGIN
  IF to_regclass('public.physical_replacement_same_order_routes') IS NULL THEN
    v_missing := array_append(v_missing, 'physical_replacement_same_order_routes');
  END IF;
  IF to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'tracking_allocation_effective_entitlement_v1(uuid,uuid)');
  END IF;
  IF to_regclass('public.dispute_messages') IS NULL THEN
    v_missing := array_append(v_missing, 'dispute_messages');
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    v_missing := array_append(v_missing, 'supplier_invoices');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Same-order replacement authorities missing prerequisites: %', array_to_string(v_missing, ', ');
  END IF;

  IF to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)') IS NOT NULL
     OR to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Same-order replacement authority target already exists; inspect before applying.';
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'f82d15d2de1199f9ab841d8c1ad44738' THEN
    RAISE EXCEPTION 'Protected Mini Build fingerprint drift: physical_remedy_allocation_guard_v2 = %', v_md5;
  END IF;
  SELECT md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '3c5067f31d4f2112207e02d1f307e233' THEN
    RAISE EXCEPTION 'Protected Mini Build fingerprint drift: physical_remedy_sequence_guard_v1 = %', v_md5;
  END IF;
  SELECT md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'eaaf737e29580feb56272c55e6f1f679' THEN
    RAISE EXCEPTION 'Protected Mini Build fingerprint drift: physical_receipt_review_guard_v1 = %', v_md5;
  END IF;
END
$preflight$;

CREATE FUNCTION public.staff_accept_same_order_free_replacement_v1(
  p_dispute_id uuid,
  p_staff_id uuid,
  p_confirmed_supplier_cost_mode text,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_staff public.staff%ROWTYPE;
  v_dispute public.disputes%ROWTYPE;
  v_line public.dispute_lines%ROWTYPE;
  v_remedy public.physical_exception_remedy_allocations%ROWTYPE;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_disposition public.shipper_package_receipt_line_dispositions%ROWTYPE;
  v_source public.order_tracking_line_allocations%ROWTYPE;
  v_supplier_line public.supplier_invoice_lines%ROWTYPE;
  v_route_id uuid;
  v_active_line_count integer;
  v_now timestamptz := clock_timestamp();
  v_note text := NULLIF(BTRIM(COALESCE(p_notes, '')), '');
  v_total_route_qty numeric;
  v_total_base numeric;
  v_total_discount numeric;
  v_total_delivery numeric;
  v_total_adjusted numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: same-order replacement acceptance requires auth.uid().';
  END IF;

  SELECT s.* INTO v_staff
  FROM public.staff s
  WHERE s.id = p_staff_id
    AND s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
    AND s.role_type IN ('admin','supervisor')
  FOR UPDATE;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Only the authenticated active admin/supervisor may accept a same-order free replacement.';
  END IF;

  IF lower(BTRIM(COALESCE(p_confirmed_supplier_cost_mode, ''))) <> 'free_replacement' THEN
    RAISE EXCEPTION 'Same-order routing requires explicit supplier_cost_mode = free_replacement.';
  END IF;

  SELECT d.* INTO v_dispute
  FROM public.disputes d
  WHERE d.id = p_dispute_id
  FOR UPDATE;

  IF v_dispute.id IS NULL THEN RAISE EXCEPTION 'Dispute % not found.', p_dispute_id; END IF;
  IF v_dispute.desired_outcome IS DISTINCT FROM 'replacement' THEN
    RAISE EXCEPTION 'Dispute % is not a replacement dispute.', p_dispute_id;
  END IF;
  IF v_dispute.status NOT IN ('raised','under_review') OR v_dispute.resolved_at IS NOT NULL THEN
    RAISE EXCEPTION 'Dispute % is not open for final replacement acceptance. Current status: %.', p_dispute_id, v_dispute.status;
  END IF;
  IF v_dispute.replacement_child_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'Dispute % already has a replacement child order and must remain on the legacy route.', p_dispute_id;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_dispute.order_id::text));

  SELECT COUNT(*)::integer INTO v_active_line_count
  FROM public.dispute_lines dl
  WHERE dl.dispute_id = p_dispute_id
    AND dl.resolved_at IS NULL;

  IF v_active_line_count <> 1 THEN
    RAISE EXCEPTION 'Same-order acceptance requires exactly one active remedy-linked dispute line per dispute; found %.', v_active_line_count;
  END IF;

  SELECT dl.* INTO v_line
  FROM public.dispute_lines dl
  WHERE dl.dispute_id = p_dispute_id
    AND dl.resolved_at IS NULL
  FOR UPDATE;

  IF v_line.physical_remedy_allocation_id IS NULL
     OR v_line.conversation_status IS DISTINCT FROM 'retailer_response_received'
     OR v_line.resolved_via_child_order_id IS NOT NULL
  THEN
    RAISE EXCEPTION 'Active dispute line is not an unresolved retailer-accepted physical replacement line.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.dispute_messages dm
    WHERE dm.dispute_id = p_dispute_id
      AND dm.message_type = 'retailer_reply'
      AND dm.counterparty = 'retailer'
  ) THEN
    RAISE EXCEPTION 'At least one retailer reply is required before same-order replacement acceptance.';
  END IF;

  SELECT r.* INTO v_remedy
  FROM public.physical_exception_remedy_allocations r
  WHERE r.id = v_line.physical_remedy_allocation_id
  FOR UPDATE;

  IF v_remedy.id IS NULL
     OR v_remedy.dispute_line_id IS DISTINCT FROM v_line.id
     OR v_remedy.approved_remedy_type IS DISTINCT FROM 'replacement'
     OR COALESCE(v_remedy.approved_remedy_qty, 0) <= 0
     OR trunc(v_remedy.approved_remedy_qty) <> v_remedy.approved_remedy_qty
     OR v_remedy.status NOT IN ('approved','linked_to_exception')
     OR v_remedy.replacement_child_order_id IS NOT NULL
     OR v_remedy.replacement_child_tracking_allocation_id IS NOT NULL
     OR COALESCE(v_remedy.customer_commercial_value_gbp, 0) <= 0
  THEN
    RAISE EXCEPTION 'Physical remedy is not an exact, approved and unconsumed replacement authority.';
  END IF;

  SELECT pr.* INTO v_review
  FROM public.physical_receipt_reviews pr
  WHERE pr.id = v_remedy.physical_receipt_review_id
  FOR UPDATE;

  SELECT d.* INTO v_disposition
  FROM public.shipper_package_receipt_line_dispositions d
  WHERE d.id = v_remedy.receipt_line_disposition_id
  FOR UPDATE;

  SELECT a.* INTO v_source
  FROM public.order_tracking_line_allocations a
  WHERE a.id = v_remedy.tracking_line_allocation_id
  FOR UPDATE;

  SELECT sil.* INTO v_supplier_line
  FROM public.supplier_invoice_lines sil
  WHERE sil.id = v_remedy.supplier_invoice_line_id
  FOR UPDATE;

  IF v_review.id IS NULL OR v_review.order_id IS DISTINCT FROM v_dispute.order_id THEN
    RAISE EXCEPTION 'Physical review/order identity does not match the dispute.';
  END IF;
  IF v_disposition.id IS NULL
     OR v_disposition.disposition_type NOT IN ('missing','damaged','wrong')
     OR v_disposition.tracking_line_allocation_id IS DISTINCT FROM v_source.id
     OR v_disposition.supplier_invoice_line_id IS DISTINCT FROM v_supplier_line.id
     OR COALESCE(v_disposition.affected_qty, 0) + 0.0005 < v_remedy.approved_remedy_qty
  THEN
    RAISE EXCEPTION 'Source disposition does not prove the approved replacement quantity and identity.';
  END IF;
  IF v_source.id IS NULL
     OR v_source.order_id IS DISTINCT FROM v_dispute.order_id
     OR v_source.supplier_invoice_line_id IS DISTINCT FROM v_supplier_line.id
     OR v_source.qty_allocated + 0.0005 < v_remedy.approved_remedy_qty
     OR v_source.adjusted_net_value_gbp <= 0
  THEN
    RAISE EXCEPTION 'Source tracking allocation is not a positive matching commercial entitlement.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.supplier_invoices si
    WHERE si.id = v_supplier_line.supplier_invoice_id
      AND si.order_id = v_dispute.order_id
  ) THEN
    RAISE EXCEPTION 'Supplier invoice line does not belong to the original order.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.physical_replacement_same_order_routes r
    WHERE r.physical_remedy_allocation_id = v_remedy.id
       OR r.dispute_line_id = v_line.id
  ) THEN
    RAISE EXCEPTION 'The physical remedy or dispute line already has a same-order replacement route.';
  END IF;

  PERFORM 1
  FROM public.physical_replacement_same_order_routes r
  WHERE r.source_tracking_line_allocation_id = v_source.id
    AND r.route_status <> 'cancelled'
  ORDER BY r.id
  FOR UPDATE;

  SELECT COALESCE(SUM(r.replacement_qty), 0)
  INTO v_total_route_qty
  FROM public.physical_replacement_same_order_routes r
  WHERE r.source_tracking_line_allocation_id = v_source.id
    AND r.route_status <> 'cancelled';

  IF v_total_route_qty + v_remedy.approved_remedy_qty > v_source.qty_allocated + 0.0005 THEN
    RAISE EXCEPTION 'Replacement transfer would exceed the source allocation quantity.';
  END IF;

  INSERT INTO public.physical_replacement_same_order_routes (
    physical_remedy_allocation_id,
    physical_receipt_review_id,
    dispute_id,
    dispute_line_id,
    order_id,
    supplier_invoice_line_id,
    source_tracking_line_allocation_id,
    source_receipt_line_disposition_id,
    replacement_qty,
    transferred_base_value_gbp,
    transferred_discount_share_gbp,
    transferred_retailer_delivery_share_gbp,
    transferred_adjusted_net_value_gbp,
    route_status,
    accepted_by_staff_id,
    accepted_at,
    notes,
    created_at,
    updated_at
  ) VALUES (
    v_remedy.id,
    v_review.id,
    v_dispute.id,
    v_line.id,
    v_dispute.order_id,
    v_supplier_line.id,
    v_source.id,
    v_disposition.id,
    v_remedy.approved_remedy_qty,
    round(v_source.base_value_gbp * v_remedy.approved_remedy_qty / v_source.qty_allocated, 2),
    round(v_source.discount_share_gbp * v_remedy.approved_remedy_qty / v_source.qty_allocated, 2),
    round(v_source.retailer_delivery_share_gbp * v_remedy.approved_remedy_qty / v_source.qty_allocated, 2),
    v_remedy.customer_commercial_value_gbp,
    'approved_waiting_tracking',
    v_staff.id,
    v_now,
    v_note,
    v_now,
    v_now
  )
  RETURNING id INTO v_route_id;

  -- Recalculate every still-unallocated slice against the exact locked source.
  -- Already allocated slices are immutable; the final waiting slice receives any
  -- component penny residual when all source quantity is transferred.
  WITH locked_routes AS (
    SELECT
      r.id,
      r.replacement_qty,
      r.route_status,
      row_number() OVER (ORDER BY r.id) AS seq,
      count(*) OVER () AS route_count,
      sum(r.replacement_qty) OVER () AS total_qty
    FROM public.physical_replacement_same_order_routes r
    WHERE r.source_tracking_line_allocation_id = v_source.id
      AND r.route_status <> 'cancelled'
  ), calculated AS (
    SELECT
      lr.id,
      CASE WHEN lr.seq = lr.route_count AND abs(lr.total_qty - v_source.qty_allocated) <= 0.0005
        THEN v_source.base_value_gbp - COALESCE((SELECT SUM(x.transferred_base_value_gbp) FROM public.physical_replacement_same_order_routes x WHERE x.source_tracking_line_allocation_id = v_source.id AND x.route_status <> 'cancelled' AND x.id <> lr.id), 0)
        ELSE round(v_source.base_value_gbp * lr.replacement_qty / v_source.qty_allocated, 2) END AS base_value,
      CASE WHEN lr.seq = lr.route_count AND abs(lr.total_qty - v_source.qty_allocated) <= 0.0005
        THEN v_source.discount_share_gbp - COALESCE((SELECT SUM(x.transferred_discount_share_gbp) FROM public.physical_replacement_same_order_routes x WHERE x.source_tracking_line_allocation_id = v_source.id AND x.route_status <> 'cancelled' AND x.id <> lr.id), 0)
        ELSE round(v_source.discount_share_gbp * lr.replacement_qty / v_source.qty_allocated, 2) END AS discount_value,
      CASE WHEN lr.seq = lr.route_count AND abs(lr.total_qty - v_source.qty_allocated) <= 0.0005
        THEN v_source.retailer_delivery_share_gbp - COALESCE((SELECT SUM(x.transferred_retailer_delivery_share_gbp) FROM public.physical_replacement_same_order_routes x WHERE x.source_tracking_line_allocation_id = v_source.id AND x.route_status <> 'cancelled' AND x.id <> lr.id), 0)
        ELSE round(v_source.retailer_delivery_share_gbp * lr.replacement_qty / v_source.qty_allocated, 2) END AS delivery_value
    FROM locked_routes lr
    WHERE lr.route_status = 'approved_waiting_tracking'
  )
  UPDATE public.physical_replacement_same_order_routes r
  SET transferred_base_value_gbp = c.base_value,
      transferred_discount_share_gbp = c.discount_value,
      transferred_retailer_delivery_share_gbp = c.delivery_value,
      updated_at = v_now
  FROM calculated c
  WHERE r.id = c.id;

  SELECT
    COALESCE(SUM(r.replacement_qty), 0),
    COALESCE(SUM(r.transferred_base_value_gbp), 0),
    COALESCE(SUM(r.transferred_discount_share_gbp), 0),
    COALESCE(SUM(r.transferred_retailer_delivery_share_gbp), 0),
    COALESCE(SUM(r.transferred_adjusted_net_value_gbp), 0)
  INTO v_total_route_qty, v_total_base, v_total_discount, v_total_delivery, v_total_adjusted
  FROM public.physical_replacement_same_order_routes r
  WHERE r.source_tracking_line_allocation_id = v_source.id
    AND r.route_status <> 'cancelled';

  IF v_total_route_qty > v_source.qty_allocated + 0.0005
     OR v_total_base > v_source.base_value_gbp + 0.005
     OR v_total_discount > v_source.discount_share_gbp + 0.005
     OR v_total_delivery > v_source.retailer_delivery_share_gbp + 0.005
     OR v_total_adjusted > v_source.adjusted_net_value_gbp + 0.005
  THEN
    RAISE EXCEPTION 'Same-order transferred quantity/value exceeds the locked source allocation.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.physical_replacement_same_order_routes r
    WHERE r.source_tracking_line_allocation_id = v_source.id
      AND r.route_status <> 'cancelled'
      AND (
        r.transferred_adjusted_net_value_gbp <= 0
        OR abs((r.transferred_base_value_gbp - r.transferred_discount_share_gbp + r.transferred_retailer_delivery_share_gbp) - r.transferred_adjusted_net_value_gbp) > 0.01
      )
  ) THEN
    RAISE EXCEPTION 'Transferred value components do not reconcile to the exact customer commercial value.';
  END IF;

  UPDATE public.physical_exception_remedy_allocations
  SET supplier_cost_mode = 'free_replacement',
      status = 'in_progress',
      updated_at = v_now
  WHERE id = v_remedy.id;

  IF v_dispute.status = 'raised' THEN
    UPDATE public.disputes SET status = 'under_review' WHERE id = v_dispute.id;
  END IF;
  UPDATE public.disputes SET status = 'approved_replacement' WHERE id = v_dispute.id;

  UPDATE public.dispute_lines
  SET conversation_status = 'resolved_replacement',
      resolution_method = 'replacement',
      resolved_at = v_now,
      resolved_via_child_order_id = NULL
  WHERE id = v_line.id;

  UPDATE public.disputes
  SET status = 'replaced',
      replacement_child_order_id = NULL,
      resolved_at = v_now
  WHERE id = v_dispute.id;

  PERFORM public.raise_escalation(
    'SAME_ORDER_FREE_REPLACEMENT',
    'order',
    v_dispute.order_id,
    jsonb_build_object(
      'route_id', v_route_id,
      'dispute_id', v_dispute.id,
      'dispute_line_id', v_line.id,
      'physical_remedy_allocation_id', v_remedy.id,
      'source_tracking_line_allocation_id', v_source.id,
      'supplier_invoice_line_id', v_supplier_line.id,
      'replacement_qty', v_remedy.approved_remedy_qty,
      'supplier_cost_mode', 'free_replacement',
      'replacement_child_order_id', NULL,
      'staff_id', v_staff.id,
      'notes', v_note
    )
  );

  RETURN v_route_id;
END;
$function$;

COMMENT ON FUNCTION public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) IS
'Controlled supervisor/admin acceptance of one exact free physical replacement on the original order. Never creates or invokes a replacement child.';

REVOKE ALL ON FUNCTION public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) TO authenticated, service_role;

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
  v_locked_count integer;
  v_now timestamptz := clock_timestamp();
  v_note text := NULLIF(BTRIM(COALESCE(p_note, '')), '');
  v_route record;
  v_allocation_id uuid;
  v_created jsonb := '[]'::jsonb;
  v_before_qty numeric;
  v_before_base numeric;
  v_before_discount numeric;
  v_before_delivery numeric;
  v_before_adjusted numeric;
  v_after_qty numeric;
  v_after_base numeric;
  v_after_discount numeric;
  v_after_delivery numeric;
  v_after_adjusted numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: same-order tracking allocation requires auth.uid().';
  END IF;

  SELECT op.* INTO v_operator
  FROM public.operators op
  WHERE op.auth_user_id = auth.uid()
    AND COALESCE(op.active, true) = true
  ORDER BY op.id
  LIMIT 1;

  IF v_operator.id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found.';
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order % not found.', p_order_id; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator.id
      AND oi.importer_id = v_order.importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised for order %.', p_order_id;
  END IF;

  SELECT ots.order_id INTO v_tracking_order_id
  FROM public.order_tracking_submissions ots
  WHERE ots.id = p_tracking_submission_id
    AND ots.superseded_at IS NULL
  FOR UPDATE;

  IF v_tracking_order_id IS DISTINCT FROM p_order_id THEN
    RAISE EXCEPTION 'Tracking submission is missing, superseded or belongs to another order.';
  END IF;

  v_input_count := COALESCE(array_length(p_route_ids, 1), 0);
  SELECT COUNT(DISTINCT x)::integer INTO v_distinct_count FROM unnest(COALESCE(p_route_ids, ARRAY[]::uuid[])) x;
  IF v_input_count = 0 THEN RAISE EXCEPTION 'At least one same-order replacement route is required.'; END IF;
  IF v_input_count <> v_distinct_count THEN RAISE EXCEPTION 'Duplicate route IDs are not allowed.'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_order_id::text));

  PERFORM 1
  FROM public.physical_replacement_same_order_routes r
  WHERE r.id = ANY(p_route_ids)
  ORDER BY r.id
  FOR UPDATE;

  SELECT COUNT(*)::integer INTO v_locked_count
  FROM public.physical_replacement_same_order_routes r
  WHERE r.id = ANY(p_route_ids)
    AND r.order_id = p_order_id
    AND r.route_status = 'approved_waiting_tracking'
    AND r.successor_tracking_submission_id IS NULL
    AND r.successor_tracking_line_allocation_id IS NULL;

  IF v_locked_count <> v_input_count THEN
    RAISE EXCEPTION 'Every route must exist once, belong to the order and await tracking allocation.';
  END IF;

  PERFORM 1
  FROM public.order_tracking_line_allocations a
  WHERE a.id IN (
    SELECT r.source_tracking_line_allocation_id
    FROM public.physical_replacement_same_order_routes r
    WHERE r.id = ANY(p_route_ids)
  )
  ORDER BY a.id
  FOR UPDATE;

  CREATE TEMP TABLE pg_temp.same_order_before_position (
    supplier_invoice_line_id uuid PRIMARY KEY,
    qty numeric,
    base numeric,
    discount numeric,
    delivery numeric,
    adjusted numeric
  ) ON COMMIT DROP;

  INSERT INTO pg_temp.same_order_before_position
  SELECT
    e.supplier_invoice_line_id,
    SUM(e.effective_qty_allocated),
    SUM(e.effective_base_value_gbp),
    SUM(e.effective_discount_share_gbp),
    SUM(e.effective_retailer_delivery_share_gbp),
    SUM(e.effective_adjusted_net_value_gbp)
  FROM public.tracking_allocation_effective_entitlement_v1(p_order_id, NULL) e
  WHERE e.supplier_invoice_line_id IN (
    SELECT r.supplier_invoice_line_id
    FROM public.physical_replacement_same_order_routes r
    WHERE r.id = ANY(p_route_ids)
  )
  GROUP BY e.supplier_invoice_line_id;

  FOR v_route IN
    SELECT r.*
    FROM public.physical_replacement_same_order_routes r
    WHERE r.id = ANY(p_route_ids)
    ORDER BY r.id
  LOOP
    IF v_route.replacement_qty <= 0
       OR v_route.transferred_adjusted_net_value_gbp <= 0
       OR abs((v_route.transferred_base_value_gbp - v_route.transferred_discount_share_gbp + v_route.transferred_retailer_delivery_share_gbp) - v_route.transferred_adjusted_net_value_gbp) > 0.01
    THEN
      RAISE EXCEPTION 'Route % has invalid or unreconciled transferred entitlement.', v_route.id;
    END IF;

    INSERT INTO public.order_tracking_line_allocations (
      order_id,
      supplier_invoice_line_id,
      tracking_submission_id,
      qty_allocated,
      base_value_gbp,
      discount_share_gbp,
      retailer_delivery_share_gbp,
      adjusted_net_value_gbp,
      allocation_status,
      allocation_basis,
      notes,
      allocated_by_operator_id,
      created_at,
      updated_at
    ) VALUES (
      p_order_id,
      v_route.supplier_invoice_line_id,
      p_tracking_submission_id,
      v_route.replacement_qty,
      v_route.transferred_base_value_gbp,
      v_route.transferred_discount_share_gbp,
      v_route.transferred_retailer_delivery_share_gbp,
      v_route.transferred_adjusted_net_value_gbp,
      'allocated',
      'operator_declaration',
      concat_ws(' ', 'Same-order free replacement successor for route', v_route.id::text || '.', v_note),
      v_operator.id,
      v_now,
      v_now
    ) RETURNING id INTO v_allocation_id;

    UPDATE public.physical_replacement_same_order_routes
    SET route_status = 'tracking_allocated',
        successor_tracking_submission_id = p_tracking_submission_id,
        successor_tracking_line_allocation_id = v_allocation_id,
        tracking_allocated_by_operator_id = v_operator.id,
        tracking_allocated_by_staff_id = NULL,
        tracking_allocated_at = v_now,
        updated_at = v_now
    WHERE id = v_route.id;

    v_created := v_created || jsonb_build_array(jsonb_build_object(
      'route_id', v_route.id,
      'successor_tracking_line_allocation_id', v_allocation_id,
      'supplier_invoice_line_id', v_route.supplier_invoice_line_id,
      'replacement_qty', v_route.replacement_qty
    ));
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM public.tracking_allocation_effective_entitlement_v1(p_order_id, NULL) e
    WHERE e.effective_qty_allocated < -0.0005
       OR e.effective_base_value_gbp < -0.005
       OR e.effective_discount_share_gbp < -0.005
       OR e.effective_retailer_delivery_share_gbp < -0.005
       OR e.effective_adjusted_net_value_gbp < -0.005
  ) THEN
    RAISE EXCEPTION 'Successor allocation produced negative effective entitlement.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.same_order_before_position b
    LEFT JOIN (
      SELECT
        e.supplier_invoice_line_id,
        SUM(e.effective_qty_allocated) AS qty,
        SUM(e.effective_base_value_gbp) AS base,
        SUM(e.effective_discount_share_gbp) AS discount,
        SUM(e.effective_retailer_delivery_share_gbp) AS delivery,
        SUM(e.effective_adjusted_net_value_gbp) AS adjusted
      FROM public.tracking_allocation_effective_entitlement_v1(p_order_id, NULL) e
      GROUP BY e.supplier_invoice_line_id
    ) a ON a.supplier_invoice_line_id = b.supplier_invoice_line_id
    WHERE abs(COALESCE(a.qty, 0) - b.qty) > 0.0005
       OR abs(COALESCE(a.base, 0) - b.base) > 0.005
       OR abs(COALESCE(a.discount, 0) - b.discount) > 0.005
       OR abs(COALESCE(a.delivery, 0) - b.delivery) > 0.005
       OR abs(COALESCE(a.adjusted, 0) - b.adjusted) > 0.005
  ) THEN
    RAISE EXCEPTION 'Successor allocation changed the original effective quantity or value entitlement.';
  END IF;

  PERFORM public.raise_escalation(
    'SAME_ORDER_REPLACEMENT_TRACKING_ALLOCATED',
    'order',
    p_order_id,
    jsonb_build_object(
      'tracking_submission_id', p_tracking_submission_id,
      'route_ids', to_jsonb(p_route_ids),
      'created_allocations', v_created,
      'operator_id', v_operator.id,
      'note', v_note
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'tracking_submission_id', p_tracking_submission_id,
    'created_allocations', v_created
  );
END;
$function$;

COMMENT ON FUNCTION public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text) IS
'Atomic multi-route successor allocation on one existing original-order tracking submission. Preserves effective quantity and value and creates no child order.';

REVOKE ALL ON FUNCTION public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text) TO authenticated, service_role;

DO $postflight$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'f82d15d2de1199f9ab841d8c1ad44738' THEN
    RAISE EXCEPTION 'Protected Mini Build changed: physical_remedy_allocation_guard_v2 = %', v_md5;
  END IF;
  SELECT md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '3c5067f31d4f2112207e02d1f307e233' THEN
    RAISE EXCEPTION 'Protected Mini Build changed: physical_remedy_sequence_guard_v1 = %', v_md5;
  END IF;
  SELECT md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'eaaf737e29580feb56272c55e6f1f679' THEN
    RAISE EXCEPTION 'Protected Mini Build changed: physical_receipt_review_guard_v1 = %', v_md5;
  END IF;

  IF position('staff_accept_replacement_outcome_v1' in pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure)) > 0
     OR position('create_replacement_child_order' in pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure)) > 0
  THEN
    RAISE EXCEPTION 'Same-order acceptance contains forbidden child-order authority invocation.';
  END IF;
END
$postflight$;

COMMIT;
