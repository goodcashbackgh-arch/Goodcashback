BEGIN;

CREATE OR REPLACE FUNCTION public.staff_accept_replacement_outcome_v1(
  p_dispute_id uuid,
  p_staff_id uuid,
  p_notes text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispute public.disputes%ROWTYPE;
  v_parent public.orders%ROWTYPE;
  v_active_line_count integer;
  v_physical_line_count integer;
  v_non_manual_line_count integer;
  v_first_line_id uuid;
  v_child_id uuid;
  v_sequence integer;
  v_legacy_qty integer;
  v_legacy_amount numeric;
  v_parent_has_funding_anomaly boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.id = p_staff_id
      AND s.auth_user_id = auth.uid()
      AND COALESCE(s.active, true) = true
  ) THEN
    RAISE EXCEPTION 'Active staff authority not found';
  END IF;

  SELECT * INTO v_dispute
  FROM public.disputes
  WHERE id = p_dispute_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Dispute % not found', p_dispute_id; END IF;
  IF v_dispute.desired_outcome IS DISTINCT FROM 'replacement' THEN
    RAISE EXCEPTION 'Dispute % is not a replacement dispute', p_dispute_id;
  END IF;
  IF v_dispute.replacement_child_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'Replacement child order already exists for dispute %', p_dispute_id;
  END IF;
  IF v_dispute.status NOT IN ('raised','under_review') THEN
    RAISE EXCEPTION 'Replacement final acceptance requires dispute status raised or under_review. Current status: %', v_dispute.status;
  END IF;

  SELECT * INTO v_parent
  FROM public.orders
  WHERE id = v_dispute.order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Parent order % not found', v_dispute.order_id; END IF;
  IF v_parent.order_type = 'replacement_child' THEN
    RAISE EXCEPTION 'Cannot create replacement of a replacement in Phase 1';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.escalation_events ee
    JOIN public.escalation_rules er ON er.id = ee.rule_id
    WHERE ee.entity_type = 'order'
      AND ee.entity_id = v_parent.id
      AND ee.resolved_at IS NULL
      AND er.rule_code = 'FUND_LATE_MATCH'
  ) INTO v_parent_has_funding_anomaly;

  IF v_parent.funded_at IS NULL AND NOT v_parent_has_funding_anomaly THEN
    RAISE EXCEPTION 'Parent order % must be platform-funded or explicitly in the funding anomaly queue before replacement can be created', v_parent.id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.dispute_messages dm
    WHERE dm.dispute_id = p_dispute_id
      AND dm.message_type = 'retailer_reply'
      AND dm.counterparty = 'retailer'
  ) THEN
    RAISE EXCEPTION 'At least one retailer reply is required before accepting final outcome';
  END IF;

  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE dl.physical_remedy_allocation_id IS NOT NULL),
    COUNT(*) FILTER (WHERE sil.line_source IS DISTINCT FROM 'manually_added'),
    MIN(dl.id::text)::uuid,
    COALESCE(SUM(ABS(dl.qty_impact)), 0)::integer,
    COALESCE(SUM(ABS(dl.amount_impact_gbp)), 0)::numeric
  INTO
    v_active_line_count,
    v_physical_line_count,
    v_non_manual_line_count,
    v_first_line_id,
    v_legacy_qty,
    v_legacy_amount
  FROM public.dispute_lines dl
  JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
  WHERE dl.dispute_id = p_dispute_id
    AND dl.resolved_at IS NULL
    AND dl.conversation_status = 'retailer_response_received';

  IF v_active_line_count = 0 THEN
    RAISE EXCEPTION 'No active retailer-accepted replacement dispute lines found';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    WHERE dl.dispute_id = p_dispute_id
      AND dl.resolved_at IS NULL
      AND dl.conversation_status IS DISTINCT FROM 'retailer_response_received'
  ) THEN
    RAISE EXCEPTION 'Every active dispute line must have an accepted retailer outcome before final replacement acceptance';
  END IF;

  IF v_physical_line_count > 0 AND v_physical_line_count <> v_active_line_count THEN
    RAISE EXCEPTION 'Physical and legacy replacement lines cannot be mixed in one final acceptance';
  END IF;

  IF v_physical_line_count > 0 AND v_active_line_count <> 1 THEN
    RAISE EXCEPTION 'A physical replacement requires exactly one approved remedy-linked dispute line';
  END IF;

  IF v_dispute.status = 'raised' THEN
    UPDATE public.disputes SET status = 'under_review' WHERE id = p_dispute_id;
  END IF;

  UPDATE public.disputes SET status = 'approved_replacement' WHERE id = p_dispute_id;

  IF v_physical_line_count = 1 THEN
    v_child_id := public.create_replacement_child_order_v2(
      v_parent.id,
      v_first_line_id,
      p_staff_id,
      p_notes
    );
  ELSE
    IF v_non_manual_line_count > 0 THEN
      RAISE EXCEPTION 'Legacy replacement child creation requires manual missing-item lines';
    END IF;
    IF v_legacy_qty <= 0 THEN RAISE EXCEPTION 'Legacy replacement child creation requires a positive quantity'; END IF;
    IF v_legacy_amount <= 0 THEN RAISE EXCEPTION 'Legacy replacement child creation requires a positive value'; END IF;

    SELECT COUNT(*) + 1 INTO v_sequence
    FROM public.orders o
    WHERE o.parent_order_id = v_parent.id;

    INSERT INTO public.orders (
      order_ref, payment_auth_id, importer_id, operator_id, shipper_id,
      retailer_id, destination_hub_id, parent_order_id, order_type,
      order_total_gbp_declared, total_qty_declared, quote_fx_rate,
      quote_card_markup_pct, quote_fx_rate_locked, quote_card_markup_pct_locked,
      quote_rate_date_locked, quote_rate_locked_at, status, sop_version,
      replacement_source_dispute_line_id, funded_at, created_at, updated_at
    ) VALUES (
      v_parent.order_ref || '-R' || v_sequence,
      NULL, v_parent.importer_id, v_parent.operator_id, v_parent.shipper_id,
      v_parent.retailer_id, v_parent.destination_hub_id, v_parent.id,
      'replacement_child', v_legacy_amount, v_legacy_qty,
      v_parent.quote_fx_rate, v_parent.quote_card_markup_pct,
      v_parent.quote_fx_rate_locked, v_parent.quote_card_markup_pct_locked,
      v_parent.quote_rate_date_locked, v_parent.quote_rate_locked_at,
      'evidence_collecting', v_parent.sop_version, NULL, NULL, NOW(), NOW()
    ) RETURNING id INTO v_child_id;

    INSERT INTO public.order_category_lines (
      order_id, markup_category_id, qty, amount_inc_vat_gbp,
      markup_pct_applied, markup_gbp_calculated, created_at
    )
    SELECT v_child_id, ocl.markup_category_id, v_legacy_qty, v_legacy_amount,
           ocl.markup_pct_applied, COALESCE(ocl.markup_gbp_calculated, 0), NOW()
    FROM public.order_category_lines ocl
    WHERE ocl.order_id = v_parent.id
    ORDER BY ocl.id
    LIMIT 1;

    UPDATE public.dispute_lines
    SET resolved_via_child_order_id = v_child_id,
        conversation_status = 'resolved_replacement',
        resolution_method = 'replacement',
        resolved_at = COALESCE(resolved_at, NOW())
    WHERE dispute_id = p_dispute_id
      AND resolved_at IS NULL;

    PERFORM public.raise_escalation(
      'REPLACEMENT_CHILD', 'order', v_child_id,
      jsonb_build_object(
        'parent_order_id', v_parent.id,
        'dispute_id', p_dispute_id,
        'legacy_source_dispute_line_ids', (
          SELECT jsonb_agg(dl.id ORDER BY dl.id)
          FROM public.dispute_lines dl
          WHERE dl.dispute_id = p_dispute_id
            AND dl.resolved_via_child_order_id = v_child_id
        ),
        'approved_replacement_qty', v_legacy_qty,
        'notes', p_notes,
        'staff_id', p_staff_id
      )
    );
  END IF;

  UPDATE public.disputes
  SET status = 'replaced',
      replacement_child_order_id = v_child_id,
      resolved_at = COALESCE(resolved_at, NOW())
  WHERE id = p_dispute_id;

  RETURN v_child_id;
END;
$function$;

COMMENT ON FUNCTION public.staff_accept_replacement_outcome_v1(uuid,uuid,text) IS
'Atomic replacement acceptance. UUID source-line selection uses text ordering because PostgreSQL does not provide min(uuid).';

REVOKE ALL ON FUNCTION public.staff_accept_replacement_outcome_v1(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_accept_replacement_outcome_v1(uuid,uuid,text) TO authenticated, service_role;

COMMIT;
