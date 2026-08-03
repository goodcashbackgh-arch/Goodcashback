-- Governed by HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1 + v1_1.
-- Additive only. Mini Builds 1-4 and all child-order authorities remain unchanged.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
DECLARE v_md5 text;
BEGIN
  IF to_regclass('public.physical_replacement_same_order_routes') IS NULL
     OR to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Same-order foundation is not installed.';
  END IF;
  IF to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Acceptance authority already exists; inspect before applying.';
  END IF;
  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) INTO v_md5;
  IF v_md5 <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN RAISE EXCEPTION 'Mini Build fingerprint drift.'; END IF;
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
  v_now timestamptz := clock_timestamp();
  v_qty numeric;
  v_base numeric;
  v_discount numeric;
  v_delivery numeric;
  v_adjusted numeric;
  v_existing_qty numeric;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT s.* INTO v_staff
  FROM public.staff s
  WHERE s.id = p_staff_id
    AND s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true)
    AND s.role_type IN ('admin','supervisor')
  FOR UPDATE;
  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active supervisor/admin authority not found.'; END IF;

  IF lower(BTRIM(COALESCE(p_confirmed_supplier_cost_mode,''))) <> 'free_replacement' THEN
    RAISE EXCEPTION 'Explicit free_replacement confirmation is required.';
  END IF;

  SELECT d.* INTO v_dispute FROM public.disputes d WHERE d.id = p_dispute_id FOR UPDATE;
  IF v_dispute.id IS NULL THEN RAISE EXCEPTION 'Dispute not found.'; END IF;
  IF v_dispute.desired_outcome IS DISTINCT FROM 'replacement'
     OR v_dispute.status NOT IN ('raised','under_review')
     OR v_dispute.resolved_at IS NOT NULL
     OR v_dispute.replacement_child_order_id IS NOT NULL
  THEN
    RAISE EXCEPTION 'Dispute is not an open child-free replacement dispute.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_dispute.order_id::text));

  IF (SELECT COUNT(*) FROM public.dispute_lines dl WHERE dl.dispute_id=p_dispute_id AND dl.resolved_at IS NULL) <> 1 THEN
    RAISE EXCEPTION 'Exactly one active physical remedy-linked dispute line is required.';
  END IF;

  SELECT dl.* INTO v_line
  FROM public.dispute_lines dl
  WHERE dl.dispute_id=p_dispute_id AND dl.resolved_at IS NULL
  FOR UPDATE;

  IF v_line.physical_remedy_allocation_id IS NULL
     OR v_line.conversation_status IS DISTINCT FROM 'retailer_response_received'
     OR v_line.resolved_via_child_order_id IS NOT NULL
  THEN RAISE EXCEPTION 'Dispute line is not retailer-accepted and child-free.'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.dispute_messages dm
    WHERE dm.dispute_id=p_dispute_id
      AND dm.message_type='retailer_reply'
      AND dm.counterparty='retailer'
  ) THEN RAISE EXCEPTION 'Retailer reply is required.'; END IF;

  SELECT r.* INTO v_remedy
  FROM public.physical_exception_remedy_allocations r
  WHERE r.id=v_line.physical_remedy_allocation_id
  FOR UPDATE;

  IF v_remedy.id IS NULL
     OR v_remedy.dispute_line_id IS DISTINCT FROM v_line.id
     OR v_remedy.approved_remedy_type IS DISTINCT FROM 'replacement'
     OR COALESCE(v_remedy.approved_remedy_qty,0) <= 0
     OR trunc(v_remedy.approved_remedy_qty) <> v_remedy.approved_remedy_qty
     OR v_remedy.status NOT IN ('approved','linked_to_exception')
     OR v_remedy.replacement_child_order_id IS NOT NULL
     OR v_remedy.replacement_child_tracking_allocation_id IS NOT NULL
  THEN RAISE EXCEPTION 'Physical remedy is not an exact unconsumed replacement authority.'; END IF;

  SELECT pr.* INTO v_review FROM public.physical_receipt_reviews pr WHERE pr.id=v_remedy.physical_receipt_review_id FOR UPDATE;
  SELECT d.* INTO v_disposition FROM public.shipper_package_receipt_line_dispositions d WHERE d.id=v_remedy.receipt_line_disposition_id FOR UPDATE;
  SELECT a.* INTO v_source FROM public.order_tracking_line_allocations a WHERE a.id=v_remedy.tracking_line_allocation_id FOR UPDATE;
  SELECT sil.* INTO v_supplier_line FROM public.supplier_invoice_lines sil WHERE sil.id=v_remedy.supplier_invoice_line_id FOR UPDATE;

  v_qty := v_remedy.approved_remedy_qty;

  IF v_review.id IS NULL OR v_review.order_id IS DISTINCT FROM v_dispute.order_id THEN
    RAISE EXCEPTION 'Review/order identity mismatch.';
  END IF;
  IF v_disposition.id IS NULL
     OR v_disposition.receipt_id IS DISTINCT FROM v_review.receipt_id
     OR v_disposition.disposition_type NOT IN ('missing','damaged','wrong')
     OR v_disposition.tracking_line_allocation_id IS DISTINCT FROM v_source.id
     OR v_disposition.supplier_invoice_line_id IS DISTINCT FROM v_supplier_line.id
     OR v_disposition.quantity + 0.0005 < v_qty
  THEN RAISE EXCEPTION 'Disposition does not prove the replacement quantity and identity.'; END IF;
  IF v_source.id IS NULL
     OR v_source.order_id IS DISTINCT FROM v_dispute.order_id
     OR v_source.supplier_invoice_line_id IS DISTINCT FROM v_supplier_line.id
     OR v_source.qty_allocated + 0.0005 < v_qty
     OR v_source.adjusted_net_value_gbp <= 0
  THEN RAISE EXCEPTION 'Source allocation does not prove positive matching entitlement.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.supplier_invoices si
    WHERE si.id=v_supplier_line.supplier_invoice_id AND si.order_id=v_dispute.order_id
  ) THEN RAISE EXCEPTION 'Supplier line does not belong to the original order.'; END IF;

  PERFORM 1 FROM public.physical_replacement_same_order_routes r
  WHERE r.source_tracking_line_allocation_id=v_source.id AND r.route_status<>'cancelled'
  ORDER BY r.id FOR UPDATE;

  SELECT COALESCE(SUM(r.replacement_qty),0) INTO v_existing_qty
  FROM public.physical_replacement_same_order_routes r
  WHERE r.source_tracking_line_allocation_id=v_source.id AND r.route_status<>'cancelled';
  IF v_existing_qty + v_qty > v_source.qty_allocated + 0.0005 THEN
    RAISE EXCEPTION 'Replacement transfer exceeds source quantity.';
  END IF;

  v_base := round(v_source.base_value_gbp * v_qty / v_source.qty_allocated,2);
  v_discount := round(v_source.discount_share_gbp * v_qty / v_source.qty_allocated,2);
  v_delivery := round(v_source.retailer_delivery_share_gbp * v_qty / v_source.qty_allocated,2);
  v_adjusted := v_base - v_discount + v_delivery;

  IF v_adjusted <= 0 OR COALESCE(v_remedy.customer_commercial_value_gbp,0) <= 0
     OR abs(v_adjusted-v_remedy.customer_commercial_value_gbp) > 0.01
  THEN RAISE EXCEPTION 'Transferred value does not reconcile to approved customer commercial value.'; END IF;

  INSERT INTO public.physical_replacement_same_order_routes(
    physical_remedy_allocation_id, physical_receipt_review_id, dispute_id, dispute_line_id,
    order_id, supplier_invoice_line_id, source_tracking_line_allocation_id,
    source_receipt_line_disposition_id, replacement_qty,
    transferred_base_value_gbp, transferred_discount_share_gbp,
    transferred_retailer_delivery_share_gbp, transferred_adjusted_net_value_gbp,
    route_status, accepted_by_staff_id, accepted_at, notes, created_at, updated_at
  ) VALUES (
    v_remedy.id,v_review.id,v_dispute.id,v_line.id,v_dispute.order_id,v_supplier_line.id,
    v_source.id,v_disposition.id,v_qty,v_base,v_discount,v_delivery,v_adjusted,
    'approved_waiting_tracking',v_staff.id,v_now,NULLIF(BTRIM(COALESCE(p_notes,'')),''),v_now,v_now
  ) RETURNING id INTO v_route_id;

  UPDATE public.physical_exception_remedy_allocations
  SET supplier_cost_mode='free_replacement',updated_at=v_now
  WHERE id=v_remedy.id;

  IF v_dispute.status='raised' THEN UPDATE public.disputes SET status='under_review' WHERE id=v_dispute.id; END IF;
  UPDATE public.disputes SET status='approved_replacement' WHERE id=v_dispute.id;
  UPDATE public.dispute_lines
  SET conversation_status='resolved_replacement',resolution_method='replacement',resolved_at=v_now,resolved_via_child_order_id=NULL
  WHERE id=v_line.id;
  UPDATE public.disputes
  SET status='replaced',resolved_at=v_now,replacement_child_order_id=NULL
  WHERE id=v_dispute.id;

  PERFORM public.raise_escalation('SAME_ORDER_FREE_REPLACEMENT','order',v_dispute.order_id,
    jsonb_build_object('route_id',v_route_id,'dispute_id',v_dispute.id,'dispute_line_id',v_line.id,
      'physical_remedy_allocation_id',v_remedy.id,'source_tracking_line_allocation_id',v_source.id,
      'supplier_invoice_line_id',v_supplier_line.id,'replacement_qty',v_qty,
      'replacement_child_order_id',NULL,'staff_id',v_staff.id,'notes',p_notes));

  RETURN v_route_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) TO authenticated, service_role;

DO $postflight$
BEGIN
  IF position('staff_accept_replacement_outcome_v1' in pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure))>0
     OR position('create_replacement_child_order' in pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure))>0
     OR position('status=''in_progress''' in pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure))>0
  THEN RAISE EXCEPTION 'Forbidden child-order or child-only remedy lifecycle invocation found.'; END IF;
END
$postflight$;

COMMIT;
