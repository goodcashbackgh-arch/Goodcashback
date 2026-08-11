BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/governing-pack/backend/Delivery_Allocation_Lock_Timing_Clarification_v1.md
-- section "Governing amendment v1.3 — bulk assignment wrapper only".
-- This migration adds one bulk-only allocation authority and changes no existing authority.

DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.orders') IS NULL THEN v_missing := array_append(v_missing, 'orders'); END IF;
  IF to_regclass('public.operators') IS NULL THEN v_missing := array_append(v_missing, 'operators'); END IF;
  IF to_regclass('public.staff') IS NULL THEN v_missing := array_append(v_missing, 'staff'); END IF;
  IF to_regclass('public.operator_importers') IS NULL THEN v_missing := array_append(v_missing, 'operator_importers'); END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN v_missing := array_append(v_missing, 'supplier_invoices'); END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN v_missing := array_append(v_missing, 'supplier_invoice_lines'); END IF;
  IF to_regclass('public.supplier_invoice_line_resolutions') IS NULL THEN v_missing := array_append(v_missing, 'supplier_invoice_line_resolutions'); END IF;
  IF to_regclass('public.order_tracking_submissions') IS NULL THEN v_missing := array_append(v_missing, 'order_tracking_submissions'); END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN v_missing := array_append(v_missing, 'order_tracking_line_allocations'); END IF;

  IF to_regprocedure('public.recalculate_invoice_adjustment_consumption_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'recalculate_invoice_adjustment_consumption_v1(uuid)');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Delivery allocation bulk prerequisites missing: %', array_to_string(v_missing, ', ');
  END IF;

  IF to_regprocedure('public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'delivery_allocate_tracking_lines_bulk_v1 already exists. Inspect target rather than replacing an unknown definition.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.delivery_allocate_tracking_lines_bulk_v1(
  p_order_id uuid,
  p_actor_mode text,
  p_tracking_submission_id uuid,
  p_line_ids uuid[],
  p_confirm_same_package boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_actor_mode text := lower(btrim(COALESCE(p_actor_mode, '')));
  v_operator_id uuid;
  v_staff_id uuid;
  v_staff_role text;
  v_order_importer_id uuid;
  v_tracking_order_id uuid;
  v_line_count integer;
  v_distinct_count integer;
  v_total_qty numeric := 0;
  v_created jsonb := '[]'::jsonb;
  v_row record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: delivery allocation requires auth.uid().';
  END IF;
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required.';
  END IF;
  IF p_tracking_submission_id IS NULL THEN
    RAISE EXCEPTION 'Select a tracking ref/package.';
  END IF;
  IF p_confirm_same_package IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Confirm that the selected items are in this tracking package.';
  END IF;
  IF v_actor_mode NOT IN ('operator', 'staff') THEN
    RAISE EXCEPTION 'Unsupported delivery allocation actor mode.';
  END IF;
  IF p_line_ids IS NULL OR cardinality(p_line_ids) = 0 THEN
    RAISE EXCEPTION 'Select at least one item.';
  END IF;
  IF array_position(p_line_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'Selected supplier invoice line identity is invalid.';
  END IF;

  SELECT COUNT(*)::integer, COUNT(DISTINCT line_id)::integer
  INTO v_line_count, v_distinct_count
  FROM unnest(p_line_ids) AS selected(line_id);

  IF v_line_count <> v_distinct_count THEN
    RAISE EXCEPTION 'Duplicate supplier invoice line selections are not allowed.';
  END IF;

  SELECT o.importer_id
  INTO v_order_importer_id
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;

  IF v_actor_mode = 'operator' THEN
    SELECT op.id
    INTO v_operator_id
    FROM public.operators op
    WHERE op.auth_user_id = v_auth_uid
      AND op.active = true
    ORDER BY op.id
    LIMIT 1;

    IF v_operator_id IS NULL THEN
      RAISE EXCEPTION 'Active operator account not found.';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.operator_importers oi
      WHERE oi.operator_id = v_operator_id
        AND oi.importer_id = v_order_importer_id
        AND oi.revoked_at IS NULL
    ) THEN
      RAISE EXCEPTION 'You are not authorised for this order.';
    END IF;
  ELSE
    SELECT s.id, s.role_type::text
    INTO v_staff_id, v_staff_role
    FROM public.staff s
    WHERE s.auth_user_id = v_auth_uid
      AND s.active = true
    ORDER BY s.id
    LIMIT 1;

    IF v_staff_id IS NULL OR v_staff_role NOT IN ('admin', 'supervisor') THEN
      RAISE EXCEPTION 'Only supervisor/admin staff can use the internal allocation workspace.';
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_order_id::text));

  SELECT ots.order_id
  INTO v_tracking_order_id
  FROM public.order_tracking_submissions ots
  WHERE ots.id = p_tracking_submission_id
  FOR UPDATE;

  IF v_tracking_order_id IS NULL OR v_tracking_order_id IS DISTINCT FROM p_order_id THEN
    RAISE EXCEPTION 'Tracking ref not found for this order.';
  END IF;

  CREATE TEMP TABLE delivery_allocation_bulk_items_v1 (
    supplier_invoice_line_id uuid PRIMARY KEY,
    supplier_invoice_id uuid NOT NULL,
    qty_to_allocate numeric NOT NULL,
    base_value_gbp numeric NOT NULL
  ) ON COMMIT DROP;

  PERFORM 1
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  WHERE sil.id = ANY(p_line_ids)
    AND si.order_id = p_order_id
  ORDER BY sil.id
  FOR UPDATE OF sil;

  PERFORM 1
  FROM public.order_tracking_line_allocations a
  WHERE a.supplier_invoice_line_id = ANY(p_line_ids)
  ORDER BY a.id
  FOR UPDATE;

  FOR v_row IN
    SELECT
      sil.id AS supplier_invoice_line_id,
      sil.supplier_invoice_id,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS line_qty,
      ROUND(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)::numeric, 2) AS line_amount,
      sil.eligible_for_invoice_yn::text AS eligible_for_invoice_yn
    FROM public.supplier_invoice_lines sil
    JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
    WHERE sil.id = ANY(p_line_ids)
      AND si.order_id = p_order_id
    ORDER BY sil.id
  LOOP
    IF lower(btrim(COALESCE(v_row.eligible_for_invoice_yn, ''))) NOT IN ('y', 'yes', 'true', '1') THEN
      RAISE EXCEPTION 'Only progressed lines can be allocated to tracking refs.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_line_id = v_row.supplier_invoice_line_id
        AND r.resolution_type = 'non_physical_financial'
        AND r.active = true
    ) THEN
      RAISE EXCEPTION 'Non-physical financial lines cannot be allocated to tracking refs.';
    END IF;

    IF v_row.line_qty <= 0 OR v_row.line_amount < 0 THEN
      RAISE EXCEPTION 'Line quantity/value is not valid for allocation.';
    END IF;

    DECLARE
      v_already_allocated numeric := 0;
      v_remaining numeric := 0;
      v_base numeric := 0;
    BEGIN
      SELECT COALESCE(SUM(a.qty_allocated), 0)::numeric
      INTO v_already_allocated
      FROM public.order_tracking_line_allocations a
      WHERE a.supplier_invoice_line_id = v_row.supplier_invoice_line_id;

      v_remaining := v_row.line_qty - v_already_allocated;

      IF v_remaining <= 0.0001 THEN
        RAISE EXCEPTION 'One of the selected items no longer has remaining quantity. Nothing was saved.';
      END IF;

      v_base := ROUND((v_row.line_amount / v_row.line_qty) * v_remaining, 2);

      INSERT INTO pg_temp.delivery_allocation_bulk_items_v1(
        supplier_invoice_line_id,
        supplier_invoice_id,
        qty_to_allocate,
        base_value_gbp
      ) VALUES (
        v_row.supplier_invoice_line_id,
        v_row.supplier_invoice_id,
        v_remaining,
        v_base
      );
    END;
  END LOOP;

  IF (SELECT COUNT(*) FROM pg_temp.delivery_allocation_bulk_items_v1) <> v_line_count THEN
    RAISE EXCEPTION 'One or more selected supplier invoice lines does not belong to this order. Nothing was saved.';
  END IF;

  FOR v_row IN
    INSERT INTO public.order_tracking_line_allocations(
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
      evidence_url,
      notes,
      allocated_by_operator_id,
      allocated_by_staff_id
    )
    SELECT
      p_order_id,
      item.supplier_invoice_line_id,
      p_tracking_submission_id,
      item.qty_to_allocate,
      item.base_value_gbp,
      0,
      0,
      item.base_value_gbp,
      'allocated',
      CASE WHEN v_actor_mode = 'staff' THEN 'supervisor_estimate' ELSE 'operator_declaration' END,
      NULL,
      NULL,
      CASE WHEN v_actor_mode = 'operator' THEN v_operator_id ELSE NULL END,
      CASE WHEN v_actor_mode = 'staff' THEN v_staff_id ELSE NULL END
    FROM pg_temp.delivery_allocation_bulk_items_v1 item
    ORDER BY item.supplier_invoice_line_id
    RETURNING id, supplier_invoice_line_id, qty_allocated
  LOOP
    v_total_qty := v_total_qty + v_row.qty_allocated;
    v_created := v_created || jsonb_build_array(
      jsonb_build_object(
        'allocation_id', v_row.id,
        'supplier_invoice_line_id', v_row.supplier_invoice_line_id,
        'qty_allocated', v_row.qty_allocated
      )
    );
  END LOOP;

  FOR v_row IN
    SELECT DISTINCT supplier_invoice_id
    FROM pg_temp.delivery_allocation_bulk_items_v1
    ORDER BY supplier_invoice_id
  LOOP
    PERFORM public.recalculate_invoice_adjustment_consumption_v1(v_row.supplier_invoice_id);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'tracking_submission_id', p_tracking_submission_id,
    'allocation_count', v_line_count,
    'total_qty_allocated', v_total_qty,
    'created_allocations', v_created
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean) TO authenticated;

DO $postflight$
BEGIN
  IF to_regprocedure('public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)') IS NULL THEN
    RAISE EXCEPTION 'delivery_allocate_tracking_lines_bulk_v1 failed postflight installation check.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';
COMMIT;
