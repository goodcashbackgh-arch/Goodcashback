BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Corrective replacement of the additive v2 authority only.
-- Snapshot exact routing positions before creating the active package link,
-- because the protected fulfilment authority treats that link as shipment state.
-- Does not alter v1, Mini Builds 1-4, tables, triggers or downstream authorities.

CREATE OR REPLACE FUNCTION public.shipper_create_shipment_batch_v2(
  p_importer_id uuid,
  p_tracking_submission_ids uuid[],
  p_booking_ref text,
  p_shipment_cutoff_at timestamptz DEFAULT NULL,
  p_dispatched_at timestamptz DEFAULT NULL,
  p_box_count integer DEFAULT NULL,
  p_container_ref text DEFAULT NULL,
  p_bol_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch_id uuid;
  v_package_id uuid;
  v_tracking_id uuid;
  v_order_id uuid;
  v_order_shipper_id uuid;
  v_order_importer_id uuid;
  v_ready_qty numeric;
  v_inserted_qty numeric;
  v_membership_snapshot jsonb;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: exact shipment batch creation requires auth.uid()';
  END IF;
  IF p_importer_id IS NULL THEN
    RAISE EXCEPTION 'Importer is required.';
  END IF;
  IF p_tracking_submission_ids IS NULL OR array_length(p_tracking_submission_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one shipment-ready package.';
  END IF;
  IF cardinality(p_tracking_submission_ids) <> cardinality(ARRAY(SELECT DISTINCT x FROM unnest(p_tracking_submission_ids) x)) THEN
    RAISE EXCEPTION 'Duplicate tracking/package selections are not allowed.';
  END IF;
  IF NULLIF(btrim(COALESCE(p_booking_ref, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Booking reference is required.';
  END IF;

  SELECT su.id, su.shipper_id
  INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  INSERT INTO public.shipper_shipment_batches (
    shipper_id, importer_id, created_by_shipper_user_id, booking_ref,
    shipment_cutoff_at, dispatched_at, box_count, container_ref, bol_ref, notes
  ) VALUES (
    v_shipper_id, p_importer_id, v_shipper_user_id, btrim(p_booking_ref),
    p_shipment_cutoff_at, p_dispatched_at, p_box_count,
    NULLIF(btrim(COALESCE(p_container_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_bol_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_notes, '')), '')
  ) RETURNING id INTO v_batch_id;

  FOREACH v_tracking_id IN ARRAY p_tracking_submission_ids LOOP
    v_order_id := NULL;
    v_order_shipper_id := NULL;
    v_order_importer_id := NULL;
    v_ready_qty := NULL;
    v_membership_snapshot := NULL;

    SELECT tracking.order_id, order_row.shipper_id, order_row.importer_id
    INTO v_order_id, v_order_shipper_id, v_order_importer_id
    FROM public.order_tracking_submissions tracking
    JOIN public.orders order_row ON order_row.id = tracking.order_id
    WHERE tracking.id = v_tracking_id
      AND tracking.superseded_at IS NULL;

    IF v_order_id IS NULL THEN
      RAISE EXCEPTION 'Tracking/package not found: %', v_tracking_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(v_order_id::text));
    PERFORM pg_advisory_xact_lock(hashtext(v_tracking_id::text));

    IF v_order_shipper_id IS DISTINCT FROM v_shipper_id THEN
      RAISE EXCEPTION 'Tracking/package does not belong to this shipper: %', v_tracking_id;
    END IF;
    IF v_order_importer_id IS DISTINCT FROM p_importer_id THEN
      RAISE EXCEPTION 'All selected packages must belong to the selected importer.';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_packages package_link
      WHERE package_link.tracking_submission_id = v_tracking_id
        AND package_link.active = true
    ) THEN
      RAISE EXCEPTION 'This package is already in an active shipment batch.';
    END IF;

    SELECT candidate.shipment_ready_qty
    INTO v_ready_qty
    FROM public.internal_shipper_shipment_batch_candidates_v2(
      v_shipper_id,
      v_order_id,
      v_tracking_id
    ) candidate;

    IF COALESCE(v_ready_qty, 0) <= 0 THEN
      RAISE EXCEPTION 'This package has no exact shipment-ready quantity.';
    END IF;

    -- Critical ordering: capture exact eligible memberships before the package link exists.
    SELECT jsonb_agg(
      jsonb_build_object(
        'tracking_submission_id', position.tracking_submission_id,
        'tracking_line_allocation_id', position.tracking_line_allocation_id,
        'order_id', position.order_id,
        'supplier_invoice_line_id', position.supplier_invoice_line_id,
        'qty_in_shipment', position.shipment_ready_qty,
        'adjusted_net_value_gbp', ROUND(
          COALESCE(allocation.adjusted_net_value_gbp, 0)::numeric
          * position.shipment_ready_qty
          / NULLIF(allocation.qty_allocated, 0),
          2
        )
      )
      ORDER BY position.tracking_line_allocation_id
    )
    INTO v_membership_snapshot
    FROM public.internal_tracking_allocation_fulfilment_routing_position_v2(
      v_order_id,
      v_tracking_id,
      NULL
    ) position
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = position.tracking_line_allocation_id
    WHERE position.position_valid_yn
      AND position.shipment_ready_qty > 0;

    IF v_membership_snapshot IS NULL OR jsonb_array_length(v_membership_snapshot) = 0 THEN
      RAISE EXCEPTION 'No exact shipment memberships were available to snapshot.';
    END IF;

    INSERT INTO public.shipper_shipment_batch_packages (
      shipment_batch_id, tracking_submission_id, order_id, shipper_id,
      importer_id, selected_by_shipper_user_id
    ) VALUES (
      v_batch_id, v_tracking_id, v_order_id, v_shipper_id,
      p_importer_id, v_shipper_user_id
    ) RETURNING id INTO v_package_id;

    INSERT INTO public.shipper_shipment_batch_line_memberships (
      shipment_batch_id,
      shipment_batch_package_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      order_id,
      supplier_invoice_line_id,
      qty_in_shipment,
      adjusted_net_value_gbp
    )
    SELECT
      v_batch_id,
      v_package_id,
      snapshot.tracking_submission_id,
      snapshot.tracking_line_allocation_id,
      snapshot.order_id,
      snapshot.supplier_invoice_line_id,
      snapshot.qty_in_shipment,
      snapshot.adjusted_net_value_gbp
    FROM jsonb_to_recordset(v_membership_snapshot) AS snapshot(
      tracking_submission_id uuid,
      tracking_line_allocation_id uuid,
      order_id uuid,
      supplier_invoice_line_id uuid,
      qty_in_shipment numeric,
      adjusted_net_value_gbp numeric
    );

    GET DIAGNOSTICS v_inserted_qty = ROW_COUNT;

    IF COALESCE(v_inserted_qty, 0) = 0 THEN
      RAISE EXCEPTION 'No exact shipment memberships were created.';
    END IF;

    SELECT COALESCE(SUM(membership.qty_in_shipment), 0)
    INTO v_inserted_qty
    FROM public.shipper_shipment_batch_line_memberships membership
    WHERE membership.shipment_batch_package_id = v_package_id;

    IF ABS(v_inserted_qty - v_ready_qty) > 0.0005 THEN
      RAISE EXCEPTION 'Inserted exact shipment quantity does not match candidate quantity.';
    END IF;
  END LOOP;

  RETURN v_batch_id;
END;
$function$;

ALTER FUNCTION public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)
  TO authenticated;

DO $postflight$
DECLARE
  v_live_candidate_md5 text;
  v_live_create_md5 text;
  v_package_preview_md5 text;
  v_position_md5 text;
  v_entitlement_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure))
  INTO v_live_candidate_md5;
  SELECT md5(pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure))
  INTO v_live_create_md5;
  SELECT md5(pg_get_functiondef('public.shipper_package_contents_preview_v1(uuid)'::regprocedure))
  INTO v_package_preview_md5;
  SELECT md5(pg_get_functiondef('public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::regprocedure))
  INTO v_position_md5;
  SELECT md5(pg_get_functiondef('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'::regprocedure))
  INTO v_entitlement_md5;

  IF v_live_candidate_md5 IS DISTINCT FROM '952f24084fed0dffcdebbfae988e7400'
     OR v_live_create_md5 IS DISTINCT FROM '4e4b86b0121a85523fe95c1530a41658'
     OR v_package_preview_md5 IS DISTINCT FROM 'a312af874648f50547270c2fcb7f7c6d'
     OR v_position_md5 IS DISTINCT FROM 'ae13557433f5e8500985b00266347807'
     OR v_entitlement_md5 IS DISTINCT FROM '00d5450bb95b75d2bd2150914689250f'
  THEN
    RAISE EXCEPTION 'Protected authority changed during exact shipment snapshot correction.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
