BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/governing-pack/backend/Delivery_Allocation_Lock_Timing_Clarification_v1.md
-- section "Governing amendment v1.1 — atomic bulk allocation and exact-provenance rework".
-- Surgical boundary: add three narrow authorities only. Do not replace existing
-- replacement, receipt, shipment, customer-sales, Sage, VAT or export authorities.

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
  IF to_regclass('public.shipper_package_receipts') IS NULL THEN v_missing := array_append(v_missing, 'shipper_package_receipts'); END IF;
  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL THEN v_missing := array_append(v_missing, 'shipper_package_receipt_line_dispositions'); END IF;
  IF to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL THEN v_missing := array_append(v_missing, 'shipper_shipment_batch_line_memberships'); END IF;
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL THEN v_missing := array_append(v_missing, 'customer_review_cycle_memberships'); END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL THEN v_missing := array_append(v_missing, 'customer_sales_release_lines'); END IF;
  IF to_regclass('public.physical_exception_remedy_allocations') IS NULL THEN v_missing := array_append(v_missing, 'physical_exception_remedy_allocations'); END IF;
  IF to_regclass('public.physical_replacement_same_order_routes') IS NULL THEN v_missing := array_append(v_missing, 'physical_replacement_same_order_routes'); END IF;

  IF to_regprocedure('public.recalculate_invoice_adjustment_consumption_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'recalculate_invoice_adjustment_consumption_v1(uuid)');
  END IF;
  IF to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)') IS NULL THEN
    v_missing := array_append(v_missing, 'operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Delivery allocation atomic bulk prerequisites missing: %', array_to_string(v_missing, ', ');
  END IF;

  IF to_regprocedure('public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)') IS NOT NULL
     OR to_regprocedure('public.delivery_clear_tracking_allocations_v1(uuid,text,uuid)') IS NOT NULL
     OR to_regprocedure('public.delivery_allocation_control_state_v1(uuid,text)') IS NOT NULL
  THEN
    RAISE EXCEPTION 'One or more delivery allocation v1 authorities already exist. Inspect target rather than replacing an unknown definition.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.delivery_allocate_tracking_lines_v1(
  p_order_id uuid,
  p_actor_mode text,
  p_request_kind text,
  p_tracking_submission_id uuid,
  p_items jsonb,
  p_content_state text DEFAULT 'confirmed',
  p_allocation_basis text DEFAULT 'operator_declaration',
  p_evidence_url text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_confirm_same_package boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_actor_mode text := lower(btrim(COALESCE(p_actor_mode, '')));
  v_request_kind text := lower(btrim(COALESCE(p_request_kind, '')));
  v_content_state text := lower(btrim(COALESCE(p_content_state, 'confirmed')));
  v_allocation_basis text := lower(btrim(COALESCE(p_allocation_basis, 'operator_declaration')));
  v_operator_id uuid;
  v_staff_id uuid;
  v_staff_role text;
  v_order_importer_id uuid;
  v_tracking_order_id uuid;
  v_tracking_superseded_at timestamptz;
  v_allocation_status text;
  v_item_count integer;
  v_distinct_count integer;
  v_created jsonb := '[]'::jsonb;
  v_total_qty numeric := 0;
  v_row record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: delivery allocation requires auth.uid().';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required.';
  END IF;

  IF v_actor_mode NOT IN ('operator','staff') THEN
    RAISE EXCEPTION 'Unsupported delivery allocation actor mode.';
  END IF;

  IF v_request_kind NOT IN ('single','bulk') THEN
    RAISE EXCEPTION 'Unsupported delivery allocation request kind.';
  END IF;

  IF jsonb_typeof(COALESCE(p_items, 'null'::jsonb)) <> 'array'
     OR jsonb_array_length(p_items) = 0
  THEN
    RAISE EXCEPTION 'At least one allocation item is required.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE jsonb_typeof(item) <> 'object'
       OR EXISTS (
         SELECT 1
         FROM jsonb_object_keys(item) key
         WHERE key NOT IN ('supplier_invoice_line_id','quantity_mode','qty')
       )
  ) THEN
    RAISE EXCEPTION 'Allocation item payload contains an unsupported field or shape.';
  END IF;

  SELECT COUNT(*)::integer,
         COUNT(DISTINCT x.supplier_invoice_line_id)::integer
  INTO v_item_count, v_distinct_count
  FROM jsonb_to_recordset(p_items) AS x(
    supplier_invoice_line_id uuid,
    quantity_mode text,
    qty numeric
  );

  IF v_item_count <> v_distinct_count THEN
    RAISE EXCEPTION 'Duplicate supplier invoice line selections are not allowed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_items) AS x(
      supplier_invoice_line_id uuid,
      quantity_mode text,
      qty numeric
    )
    WHERE x.supplier_invoice_line_id IS NULL
       OR lower(btrim(COALESCE(x.quantity_mode, ''))) NOT IN ('exact','remaining')
       OR (
         lower(btrim(COALESCE(x.quantity_mode, ''))) = 'exact'
         AND (x.qty IS NULL OR x.qty <= 0)
       )
       OR (
         lower(btrim(COALESCE(x.quantity_mode, ''))) = 'remaining'
         AND x.qty IS NOT NULL
       )
  ) THEN
    RAISE EXCEPTION 'One or more allocation items has an invalid identity, quantity mode or quantity.';
  END IF;

  IF v_request_kind = 'single' AND v_item_count <> 1 THEN
    RAISE EXCEPTION 'Single allocation requires exactly one item.';
  END IF;

  IF v_request_kind = 'bulk' THEN
    IF p_tracking_submission_id IS NULL THEN
      RAISE EXCEPTION 'Bulk allocation requires one tracking ref/package.';
    END IF;
    IF p_confirm_same_package IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'Confirm that the selected items are in this tracking package.';
    END IF;
    IF v_content_state <> 'confirmed' THEN
      RAISE EXCEPTION 'Bulk allocation supports confirmed package contents only.';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_to_recordset(p_items) AS x(
        supplier_invoice_line_id uuid,
        quantity_mode text,
        qty numeric
      )
      WHERE lower(btrim(COALESCE(x.quantity_mode, ''))) <> 'remaining'
    ) THEN
      RAISE EXCEPTION 'Bulk allocation must use the current remaining quantity for every selected item.';
    END IF;
  END IF;

  IF v_content_state NOT IN ('confirmed','unknown_contents','needs_operator_evidence','supervisor_accepted_estimate') THEN
    RAISE EXCEPTION 'Unsupported contents evidence state.';
  END IF;

  IF v_allocation_basis NOT IN (
    'operator_declaration',
    'retailer_dispatch_email',
    'retailer_app',
    'packing_slip',
    'retailer_delivery_note',
    'supervisor_estimate',
    'unknown'
  ) THEN
    RAISE EXCEPTION 'Unsupported allocation basis.';
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
      AND COALESCE(op.active, true) = true
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

    IF v_content_state = 'supervisor_accepted_estimate' OR v_allocation_basis = 'supervisor_estimate' THEN
      RAISE EXCEPTION 'Supervisor estimate allocation requires supervisor/admin staff.';
    END IF;
  ELSE
    SELECT s.id, s.role_type::text
    INTO v_staff_id, v_staff_role
    FROM public.staff s
    WHERE s.auth_user_id = v_auth_uid
      AND COALESCE(s.active, true) = true
    ORDER BY s.id
    LIMIT 1;

    IF v_staff_id IS NULL OR v_staff_role NOT IN ('admin','supervisor') THEN
      RAISE EXCEPTION 'Only supervisor/admin staff can use the internal allocation workspace.';
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_order_id::text));

  IF p_tracking_submission_id IS NOT NULL THEN
    SELECT ots.order_id, ots.superseded_at
    INTO v_tracking_order_id, v_tracking_superseded_at
    FROM public.order_tracking_submissions ots
    WHERE ots.id = p_tracking_submission_id
    FOR UPDATE;

    IF v_tracking_order_id IS NULL
       OR v_tracking_order_id IS DISTINCT FROM p_order_id
       OR v_tracking_superseded_at IS NOT NULL
    THEN
      RAISE EXCEPTION 'Tracking ref/package is missing, superseded or belongs to another order.';
    END IF;

    -- Exact package-set mutation gate. Header-only legacy activity is not enough.
    IF EXISTS (
      SELECT 1
      FROM public.shipper_package_receipts r
      WHERE r.tracking_submission_id = p_tracking_submission_id
        AND r.receipt_model_version = 2
        AND r.receipt_state = 'finalised'
        AND r.finalised_at IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'This tracking package has already been captured by an exact shipper receipt and cannot accept ordinary allocation changes.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.tracking_submission_id = p_tracking_submission_id
    ) THEN
      RAISE EXCEPTION 'This tracking package has already been captured in an exact shipment snapshot and cannot accept ordinary allocation changes.';
    END IF;
  END IF;

  v_allocation_status := CASE
    WHEN v_content_state = 'unknown_contents' THEN 'unknown_contents'
    WHEN v_content_state = 'needs_operator_evidence' THEN 'needs_operator_evidence'
    WHEN v_actor_mode = 'staff' AND v_content_state = 'supervisor_accepted_estimate' THEN 'supervisor_accepted_estimate'
    ELSE 'allocated'
  END;

  IF v_allocation_status NOT IN ('unknown_contents','needs_operator_evidence')
     AND p_tracking_submission_id IS NULL
  THEN
    RAISE EXCEPTION 'Select a tracking ref/package, or mark the contents as unknown/needs evidence.';
  END IF;

  DROP TABLE IF EXISTS pg_temp.delivery_allocation_items_v1;
  CREATE TEMP TABLE pg_temp.delivery_allocation_items_v1 (
    supplier_invoice_line_id uuid PRIMARY KEY,
    supplier_invoice_id uuid NOT NULL,
    qty_to_allocate numeric NOT NULL,
    base_value_gbp numeric NOT NULL
  ) ON COMMIT DROP;

  -- Deterministic supplier-line locks.
  PERFORM 1
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  WHERE sil.id IN (
    SELECT x.supplier_invoice_line_id
    FROM jsonb_to_recordset(p_items) AS x(
      supplier_invoice_line_id uuid,
      quantity_mode text,
      qty numeric
    )
  )
    AND si.order_id = p_order_id
  ORDER BY sil.id
  FOR UPDATE OF sil;

  -- Deterministic existing-allocation locks. Replacement successor rows are
  -- retained for provenance but excluded from ordinary source-quantity consumption.
  PERFORM 1
  FROM public.order_tracking_line_allocations a
  WHERE a.supplier_invoice_line_id IN (
    SELECT x.supplier_invoice_line_id
    FROM jsonb_to_recordset(p_items) AS x(
      supplier_invoice_line_id uuid,
      quantity_mode text,
      qty numeric
    )
  )
  ORDER BY a.id
  FOR UPDATE;

  FOR v_row IN
    SELECT
      x.supplier_invoice_line_id,
      lower(btrim(COALESCE(x.quantity_mode, ''))) AS quantity_mode,
      x.qty AS requested_qty,
      sil.supplier_invoice_id,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS effective_qty,
      COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)::numeric AS effective_amount,
      sil.eligible_for_invoice_yn::text AS eligible_for_invoice_yn,
      si.review_status::text AS review_status
    FROM jsonb_to_recordset(p_items) AS x(
      supplier_invoice_line_id uuid,
      quantity_mode text,
      qty numeric
    )
    JOIN public.supplier_invoice_lines sil
      ON sil.id = x.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = p_order_id
    ORDER BY x.supplier_invoice_line_id
  LOOP
    IF lower(btrim(COALESCE(v_row.eligible_for_invoice_yn, ''))) NOT IN ('y','yes','true','1') THEN
      RAISE EXCEPTION 'Only progressed lines can be allocated to tracking refs.';
    END IF;

    IF COALESCE(v_row.review_status, '') IN ('rejected_resubmit_required','duplicate_blocked','superseded') THEN
      RAISE EXCEPTION 'A selected supplier invoice line belongs to a retired invoice.';
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

    IF v_row.effective_qty <= 0 OR v_row.effective_amount < 0 THEN
      RAISE EXCEPTION 'Line quantity/value is not valid for allocation.';
    END IF;

    DECLARE
      v_already_allocated numeric := 0;
      v_remaining numeric := 0;
      v_qty numeric := 0;
      v_base numeric := 0;
    BEGIN
      SELECT COALESCE(SUM(a.qty_allocated), 0)::numeric
      INTO v_already_allocated
      FROM public.order_tracking_line_allocations a
      WHERE a.supplier_invoice_line_id = v_row.supplier_invoice_line_id
        AND NOT EXISTS (
          SELECT 1
          FROM public.physical_replacement_same_order_routes rr
          WHERE rr.successor_tracking_line_allocation_id = a.id
        );

      v_remaining := v_row.effective_qty - v_already_allocated;

      IF v_remaining <= 0.0001 THEN
        RAISE EXCEPTION 'One of the selected items no longer has remaining quantity. Nothing was saved.';
      END IF;

      v_qty := CASE
        WHEN v_row.quantity_mode = 'remaining' THEN v_remaining
        ELSE v_row.requested_qty
      END;

      IF v_qty IS NULL OR v_qty <= 0 OR v_qty > v_remaining + 0.0001 THEN
        RAISE EXCEPTION 'Allocation would exceed the current progressed-line remaining quantity. Nothing was saved.';
      END IF;

      v_base := ROUND((v_row.effective_amount * v_qty / v_row.effective_qty)::numeric, 2);

      INSERT INTO pg_temp.delivery_allocation_items_v1(
        supplier_invoice_line_id,
        supplier_invoice_id,
        qty_to_allocate,
        base_value_gbp
      ) VALUES (
        v_row.supplier_invoice_line_id,
        v_row.supplier_invoice_id,
        v_qty,
        v_base
      );
    END;
  END LOOP;

  IF (SELECT COUNT(*) FROM pg_temp.delivery_allocation_items_v1) <> v_item_count THEN
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
      allocated_by_staff_id,
      supervisor_accepted_by_staff_id,
      supervisor_accepted_at
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
      v_allocation_status,
      v_allocation_basis,
      NULLIF(btrim(COALESCE(p_evidence_url, '')), ''),
      NULLIF(btrim(COALESCE(p_notes, '')), ''),
      CASE WHEN v_actor_mode = 'operator' THEN v_operator_id ELSE NULL END,
      CASE WHEN v_actor_mode = 'staff' THEN v_staff_id ELSE NULL END,
      CASE WHEN v_actor_mode = 'staff' AND v_allocation_status = 'supervisor_accepted_estimate' THEN v_staff_id ELSE NULL END,
      CASE WHEN v_actor_mode = 'staff' AND v_allocation_status = 'supervisor_accepted_estimate' THEN clock_timestamp() ELSE NULL END
    FROM pg_temp.delivery_allocation_items_v1 item
    ORDER BY item.supplier_invoice_line_id
    RETURNING id, supplier_invoice_line_id, qty_allocated
  LOOP
    v_total_qty := v_total_qty + v_row.qty_allocated;
    v_created := v_created || jsonb_build_array(jsonb_build_object(
      'allocation_id', v_row.id,
      'supplier_invoice_line_id', v_row.supplier_invoice_line_id,
      'qty_allocated', v_row.qty_allocated
    ));
  END LOOP;

  FOR v_row IN
    SELECT DISTINCT supplier_invoice_id
    FROM pg_temp.delivery_allocation_items_v1
    ORDER BY supplier_invoice_id
  LOOP
    PERFORM public.recalculate_invoice_adjustment_consumption_v1(v_row.supplier_invoice_id);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'request_kind', v_request_kind,
    'tracking_submission_id', p_tracking_submission_id,
    'allocation_count', v_item_count,
    'total_qty_allocated', v_total_qty,
    'created_allocations', v_created
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.delivery_clear_tracking_allocations_v1(
  p_order_id uuid,
  p_actor_mode text,
  p_supplier_invoice_line_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_actor_mode text := lower(btrim(COALESCE(p_actor_mode, '')));
  v_operator_id uuid;
  v_staff_id uuid;
  v_staff_role text;
  v_order_importer_id uuid;
  v_supplier_invoice_id uuid;
  v_deleted_count integer := 0;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: delivery allocation rework requires auth.uid().'; END IF;
  IF p_order_id IS NULL OR p_supplier_invoice_line_id IS NULL THEN RAISE EXCEPTION 'Order and supplier invoice line are required.'; END IF;
  IF v_actor_mode NOT IN ('operator','staff') THEN RAISE EXCEPTION 'Unsupported delivery allocation actor mode.'; END IF;

  SELECT o.importer_id INTO v_order_importer_id
  FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF v_order_importer_id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;

  IF v_actor_mode = 'operator' THEN
    SELECT op.id INTO v_operator_id
    FROM public.operators op
    WHERE op.auth_user_id = v_auth_uid AND COALESCE(op.active, true) = true
    ORDER BY op.id LIMIT 1;
    IF v_operator_id IS NULL THEN RAISE EXCEPTION 'Active operator account not found.'; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.operator_importers oi
      WHERE oi.operator_id = v_operator_id
        AND oi.importer_id = v_order_importer_id
        AND oi.revoked_at IS NULL
    ) THEN RAISE EXCEPTION 'You are not authorised for this order.'; END IF;
  ELSE
    SELECT s.id, s.role_type::text INTO v_staff_id, v_staff_role
    FROM public.staff s
    WHERE s.auth_user_id = v_auth_uid AND COALESCE(s.active, true) = true
    ORDER BY s.id LIMIT 1;
    IF v_staff_id IS NULL OR v_staff_role NOT IN ('admin','supervisor') THEN
      RAISE EXCEPTION 'Only supervisor/admin staff can use the internal allocation workspace.';
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_order_id::text));

  SELECT sil.supplier_invoice_id INTO v_supplier_invoice_id
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  WHERE sil.id = p_supplier_invoice_line_id
    AND si.order_id = p_order_id
  FOR UPDATE OF sil;

  IF v_supplier_invoice_id IS NULL THEN RAISE EXCEPTION 'Supplier invoice line not found for this order.'; END IF;

  PERFORM 1
  FROM public.order_tracking_line_allocations a
  WHERE a.order_id = p_order_id
    AND a.supplier_invoice_line_id = p_supplier_invoice_line_id
  ORDER BY a.id
  FOR UPDATE;

  WITH editable AS (
    SELECT a.id
    FROM public.order_tracking_line_allocations a
    WHERE a.order_id = p_order_id
      AND a.supplier_invoice_line_id = p_supplier_invoice_line_id
      AND a.locked_for_export_pack_at IS NULL
      AND a.allocation_status <> 'locked_for_export_pack'
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_package_receipt_line_dispositions d
        WHERE d.tracking_line_allocation_id = a.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
        WHERE m.tracking_line_allocation_id = a.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.customer_review_cycle_memberships crm
        WHERE crm.tracking_line_allocation_id = a.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.customer_sales_release_lines csr
        WHERE csr.tracking_line_allocation_id = a.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.physical_exception_remedy_allocations r
        WHERE r.tracking_line_allocation_id = a.id
           OR r.replacement_child_tracking_allocation_id = a.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.physical_replacement_same_order_routes rr
        WHERE rr.source_tracking_line_allocation_id = a.id
           OR rr.successor_tracking_line_allocation_id = a.id
      )
  )
  DELETE FROM public.order_tracking_line_allocations a
  USING editable e
  WHERE a.id = e.id;

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  IF v_deleted_count = 0 THEN
    RAISE EXCEPTION 'No editable allocations remain for this item because downstream provenance already exists or there is nothing to clear.';
  END IF;

  PERFORM public.recalculate_invoice_adjustment_consumption_v1(v_supplier_invoice_id);

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'supplier_invoice_line_id', p_supplier_invoice_line_id,
    'deleted_allocation_count', v_deleted_count
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.delivery_allocation_control_state_v1(
  p_order_id uuid,
  p_actor_mode text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_actor_mode text := lower(btrim(COALESCE(p_actor_mode, '')));
  v_operator_id uuid;
  v_staff_role text;
  v_order_importer_id uuid;
  v_tracking jsonb;
  v_allocations jsonb;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: delivery allocation control state requires auth.uid().'; END IF;
  IF p_order_id IS NULL THEN RAISE EXCEPTION 'Order is required.'; END IF;
  IF v_actor_mode NOT IN ('operator','staff') THEN RAISE EXCEPTION 'Unsupported delivery allocation actor mode.'; END IF;

  SELECT o.importer_id INTO v_order_importer_id
  FROM public.orders o WHERE o.id = p_order_id;
  IF v_order_importer_id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;

  IF v_actor_mode = 'operator' THEN
    SELECT op.id INTO v_operator_id
    FROM public.operators op
    WHERE op.auth_user_id = v_auth_uid AND COALESCE(op.active, true) = true
    ORDER BY op.id LIMIT 1;
    IF v_operator_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.operator_importers oi
      WHERE oi.operator_id = v_operator_id
        AND oi.importer_id = v_order_importer_id
        AND oi.revoked_at IS NULL
    ) THEN RAISE EXCEPTION 'You are not authorised for this order.'; END IF;
  ELSE
    SELECT s.role_type::text INTO v_staff_role
    FROM public.staff s
    WHERE s.auth_user_id = v_auth_uid AND COALESCE(s.active, true) = true
    ORDER BY s.id LIMIT 1;
    IF v_staff_role NOT IN ('admin','supervisor') THEN
      RAISE EXCEPTION 'Only supervisor/admin staff can use the internal allocation workspace.';
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'tracking_submission_id', ots.id,
      'accepts_new_allocations', CASE
        WHEN EXISTS (
          SELECT 1 FROM public.shipper_package_receipts r
          WHERE r.tracking_submission_id = ots.id
            AND r.receipt_model_version = 2
            AND r.receipt_state = 'finalised'
            AND r.finalised_at IS NOT NULL
        ) THEN false
        WHEN EXISTS (
          SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
          WHERE m.tracking_submission_id = ots.id
        ) THEN false
        ELSE true
      END,
      'blocker', CASE
        WHEN EXISTS (
          SELECT 1 FROM public.shipper_package_receipts r
          WHERE r.tracking_submission_id = ots.id
            AND r.receipt_model_version = 2
            AND r.receipt_state = 'finalised'
            AND r.finalised_at IS NOT NULL
        ) THEN 'exact_physical_receipt'
        WHEN EXISTS (
          SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
          WHERE m.tracking_submission_id = ots.id
        ) THEN 'exact_shipment_snapshot'
        ELSE NULL
      END
    ) ORDER BY ots.submitted_at, ots.id
  ), '[]'::jsonb)
  INTO v_tracking
  FROM public.order_tracking_submissions ots
  WHERE ots.order_id = p_order_id
    AND ots.superseded_at IS NULL;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'allocation_id', a.id,
      'can_simple_clear', CASE
        WHEN a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status = 'locked_for_export_pack' THEN false
        WHEN EXISTS (SELECT 1 FROM public.shipper_package_receipt_line_dispositions d WHERE d.tracking_line_allocation_id = a.id) THEN false
        WHEN EXISTS (SELECT 1 FROM public.shipper_shipment_batch_line_memberships m WHERE m.tracking_line_allocation_id = a.id) THEN false
        WHEN EXISTS (SELECT 1 FROM public.customer_review_cycle_memberships crm WHERE crm.tracking_line_allocation_id = a.id) THEN false
        WHEN EXISTS (SELECT 1 FROM public.customer_sales_release_lines csr WHERE csr.tracking_line_allocation_id = a.id) THEN false
        WHEN EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations r WHERE r.tracking_line_allocation_id = a.id OR r.replacement_child_tracking_allocation_id = a.id) THEN false
        WHEN EXISTS (SELECT 1 FROM public.physical_replacement_same_order_routes rr WHERE rr.source_tracking_line_allocation_id = a.id OR rr.successor_tracking_line_allocation_id = a.id) THEN false
        ELSE true
      END,
      'blocker', CASE
        WHEN a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status = 'locked_for_export_pack' THEN 'export_accounting_lock'
        WHEN EXISTS (SELECT 1 FROM public.shipper_package_receipt_line_dispositions d WHERE d.tracking_line_allocation_id = a.id) THEN 'exact_physical_receipt'
        WHEN EXISTS (SELECT 1 FROM public.shipper_shipment_batch_line_memberships m WHERE m.tracking_line_allocation_id = a.id) THEN 'exact_shipment_snapshot'
        WHEN EXISTS (SELECT 1 FROM public.customer_review_cycle_memberships crm WHERE crm.tracking_line_allocation_id = a.id) THEN 'customer_review_provenance'
        WHEN EXISTS (SELECT 1 FROM public.customer_sales_release_lines csr WHERE csr.tracking_line_allocation_id = a.id) THEN 'customer_sales_release'
        WHEN EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations r WHERE r.tracking_line_allocation_id = a.id OR r.replacement_child_tracking_allocation_id = a.id) THEN 'physical_remedy_provenance'
        WHEN EXISTS (SELECT 1 FROM public.physical_replacement_same_order_routes rr WHERE rr.source_tracking_line_allocation_id = a.id OR rr.successor_tracking_line_allocation_id = a.id) THEN 'replacement_provenance'
        ELSE NULL
      END
    ) ORDER BY a.created_at, a.id
  ), '[]'::jsonb)
  INTO v_allocations
  FROM public.order_tracking_line_allocations a
  WHERE a.order_id = p_order_id;

  RETURN jsonb_build_object(
    'tracking_packages', v_tracking,
    'allocations', v_allocations
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delivery_clear_tracking_allocations_v1(uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delivery_allocation_control_state_v1(uuid,text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delivery_clear_tracking_allocations_v1(uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delivery_allocation_control_state_v1(uuid,text) TO authenticated;

DO $postflight$
BEGIN
  IF to_regprocedure('public.delivery_allocate_tracking_lines_v1(uuid,text,text,uuid,jsonb,text,text,text,text,boolean)') IS NULL
     OR to_regprocedure('public.delivery_clear_tracking_allocations_v1(uuid,text,uuid)') IS NULL
     OR to_regprocedure('public.delivery_allocation_control_state_v1(uuid,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Delivery allocation v1 authorities failed postflight installation check.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
