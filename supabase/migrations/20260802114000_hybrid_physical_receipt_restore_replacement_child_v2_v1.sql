BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.create_replacement_child_order_v2(uuid,uuid,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Replacement-child v2 already exists; inspect before replacing.';
  END IF;
END
$$;

CREATE FUNCTION public.create_replacement_child_order_v2(
  p_parent_order_id uuid,
  p_dispute_line_id uuid,
  p_staff_id uuid,
  p_notes text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_parent public.orders%ROWTYPE;
  v_dispute_id uuid;
  v_child_id uuid;
  v_sequence integer;
  v_qty integer;
  v_amount numeric;
  v_parent_has_funding_anomaly boolean := false;
  v_physical_remedy_id uuid;
  v_physical_remedy public.physical_exception_remedy_allocations%ROWTYPE;
  v_review_order_id uuid;
BEGIN
  SELECT * INTO v_parent FROM public.orders WHERE id = p_parent_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Parent order % not found', p_parent_order_id; END IF;
  IF v_parent.order_type = 'replacement_child' THEN RAISE EXCEPTION 'Cannot create replacement of a replacement in Phase 1'; END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.escalation_events ee
    JOIN public.escalation_rules er ON er.id = ee.rule_id
    WHERE ee.entity_type = 'order'
      AND ee.entity_id = p_parent_order_id
      AND ee.resolved_at IS NULL
      AND er.rule_code = 'FUND_LATE_MATCH'
  ) INTO v_parent_has_funding_anomaly;

  IF v_parent.funded_at IS NULL AND NOT v_parent_has_funding_anomaly THEN
    RAISE EXCEPTION 'Parent order % must be platform-funded or explicitly in the funding anomaly queue before replacement can be created', p_parent_order_id;
  END IF;

  SELECT dl.dispute_id,
         GREATEST(COALESCE(dl.qty_impact, 1), 1),
         COALESCE(dl.amount_impact_gbp, 0),
         dl.physical_remedy_allocation_id
  INTO v_dispute_id, v_qty, v_amount, v_physical_remedy_id
  FROM public.dispute_lines dl
  JOIN public.disputes d ON d.id = dl.dispute_id AND d.order_id = p_parent_order_id
  WHERE dl.id = p_dispute_line_id
  FOR UPDATE OF dl;

  IF v_dispute_id IS NULL THEN
    RAISE EXCEPTION 'Dispute line % not found or not linked to parent order %', p_dispute_line_id, p_parent_order_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.replacement_source_dispute_line_id = p_dispute_line_id
  ) THEN
    RAISE EXCEPTION 'Replacement child order already exists for dispute line %', p_dispute_line_id;
  END IF;

  IF v_physical_remedy_id IS NOT NULL THEN
    SELECT remedy.* INTO v_physical_remedy
    FROM public.physical_exception_remedy_allocations remedy
    WHERE remedy.id = v_physical_remedy_id
    FOR UPDATE;

    SELECT review_row.order_id INTO v_review_order_id
    FROM public.physical_receipt_reviews review_row
    WHERE review_row.id = v_physical_remedy.physical_receipt_review_id;

    IF v_physical_remedy.id IS NULL
       OR v_physical_remedy.dispute_line_id IS DISTINCT FROM p_dispute_line_id
       OR v_physical_remedy.approved_remedy_type IS DISTINCT FROM 'replacement'
       OR v_physical_remedy.approved_remedy_qty IS NULL
       OR v_physical_remedy.approved_remedy_qty <= 0
       OR TRUNC(v_physical_remedy.approved_remedy_qty) <> v_physical_remedy.approved_remedy_qty
       OR v_physical_remedy.supplier_cost_mode NOT IN ('free_replacement','charged_repurchase','pending_supplier_evidence')
       OR v_physical_remedy.status NOT IN ('approved','linked_to_exception')
       OR v_physical_remedy.replacement_child_order_id IS NOT NULL
       OR v_review_order_id IS DISTINCT FROM p_parent_order_id
    THEN
      RAISE EXCEPTION 'Physical replacement remedy % is not an approved, exact and unconsumed replacement authority for dispute line %', v_physical_remedy_id, p_dispute_line_id;
    END IF;

    v_qty := v_physical_remedy.approved_remedy_qty::integer;
    v_amount := COALESCE(v_physical_remedy.customer_commercial_value_gbp, v_amount, 0);
  END IF;

  SELECT COUNT(*) + 1 INTO v_sequence
  FROM public.orders o
  WHERE o.parent_order_id = p_parent_order_id;

  INSERT INTO public.orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, parent_order_id, order_type, order_total_gbp_declared,
    total_qty_declared, quote_fx_rate, quote_card_markup_pct, quote_fx_rate_locked,
    quote_card_markup_pct_locked, quote_rate_date_locked, quote_rate_locked_at,
    status, sop_version, replacement_source_dispute_line_id, funded_at, created_at, updated_at
  ) VALUES (
    v_parent.order_ref || '-R' || v_sequence, NULL, v_parent.importer_id,
    v_parent.operator_id, v_parent.shipper_id, v_parent.retailer_id,
    v_parent.destination_hub_id, p_parent_order_id, 'replacement_child',
    v_amount, v_qty, v_parent.quote_fx_rate, v_parent.quote_card_markup_pct,
    v_parent.quote_fx_rate_locked, v_parent.quote_card_markup_pct_locked,
    v_parent.quote_rate_date_locked, v_parent.quote_rate_locked_at,
    'evidence_collecting', v_parent.sop_version, p_dispute_line_id,
    NULL, NOW(), NOW()
  ) RETURNING id INTO v_child_id;

  INSERT INTO public.order_category_lines (
    order_id, markup_category_id, qty, amount_inc_vat_gbp,
    markup_pct_applied, markup_gbp_calculated, created_at
  )
  SELECT v_child_id, ocl.markup_category_id, v_qty, v_amount,
         ocl.markup_pct_applied, COALESCE(ocl.markup_gbp_calculated, 0), NOW()
  FROM public.order_category_lines ocl
  WHERE ocl.order_id = p_parent_order_id
  ORDER BY ocl.id
  LIMIT 1;

  IF v_physical_remedy_id IS NOT NULL THEN
    UPDATE public.physical_exception_remedy_allocations
    SET replacement_child_order_id = v_child_id,
        status = 'in_progress',
        updated_at = NOW()
    WHERE id = v_physical_remedy_id;
  END IF;

  UPDATE public.disputes
  SET replacement_child_order_id = v_child_id,
      resolved_at = COALESCE(resolved_at, NOW())
  WHERE id = v_dispute_id;

  UPDATE public.dispute_lines
  SET resolved_via_child_order_id = v_child_id,
      conversation_status = 'resolved_replacement',
      resolution_method = 'replacement',
      resolved_at = COALESCE(resolved_at, NOW())
  WHERE id = p_dispute_line_id;

  PERFORM public.raise_escalation(
    'REPLACEMENT_CHILD', 'order', v_child_id,
    jsonb_build_object(
      'parent_order_id', p_parent_order_id,
      'dispute_line_id', p_dispute_line_id,
      'physical_remedy_allocation_id', v_physical_remedy_id,
      'approved_replacement_qty', v_qty,
      'notes', p_notes,
      'staff_id', p_staff_id
    )
  );

  RETURN v_child_id;
END;
$function$;

COMMENT ON FUNCTION public.create_replacement_child_order_v2(uuid,uuid,uuid,text) IS
'Versioned hardened physical replacement-child authority preserving exact approved physical-remedy provenance. The existing v1 authority is unchanged.';

REVOKE ALL ON FUNCTION public.create_replacement_child_order_v2(uuid,uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_replacement_child_order_v2(uuid,uuid,uuid,text) TO authenticated, service_role;

COMMIT;
