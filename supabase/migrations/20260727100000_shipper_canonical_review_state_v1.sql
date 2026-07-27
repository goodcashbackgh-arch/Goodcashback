BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_order_review_links') IS NULL
     OR to_regclass('public.customer_review_cycle_memberships') IS NULL THEN
    RAISE EXCEPTION 'Canonical customer review-cycle prerequisites are missing.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_tracking_review_state_v1(
  p_order_id uuid,
  p_tracking_submission_id uuid
)
RETURNS TABLE (
  active_review_yn boolean,
  review_link_id uuid,
  review_expires_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper tracking review state requires auth.uid()';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.orders order_row
    JOIN public.order_tracking_submissions tracking
      ON tracking.id = p_tracking_submission_id
     AND tracking.order_id = order_row.id
    JOIN public.shipper_users shipper_user
      ON shipper_user.shipper_id = order_row.shipper_id
     AND shipper_user.auth_user_id = v_auth_uid
     AND shipper_user.active = true
    WHERE order_row.id = p_order_id
  ) THEN
    RAISE EXCEPTION 'Tracking/package does not belong to this shipper.';
  END IF;

  RETURN QUERY
  SELECT
    (active_link.id IS NOT NULL) AS active_review_yn,
    active_link.id AS review_link_id,
    active_link.expires_at AS review_expires_at
  FROM (VALUES (1)) singleton(value)
  LEFT JOIN LATERAL (
    SELECT review_link.id, review_link.expires_at
    FROM public.customer_order_review_links review_link
    WHERE review_link.order_id = p_order_id
      AND review_link.is_active = true
      AND review_link.expires_at IS NOT NULL
      AND review_link.expires_at > now()
      AND EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships membership
        WHERE membership.review_link_id = review_link.id
          AND membership.order_id = p_order_id
          AND membership.tracking_submission_id = p_tracking_submission_id
          AND membership.membership_status = 'active'
      )
    ORDER BY review_link.expires_at, review_link.id
    LIMIT 1
  ) active_link ON true;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_tracking_review_state_v1(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_tracking_review_state_v1(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_candidates_v1()
RETURNS TABLE (
  shipper_user_id uuid,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  order_id uuid,
  order_ref text,
  retailer_name text,
  tracking_submission_id uuid,
  courier_name text,
  tracking_ref text,
  tracking_date text,
  allocated_qty numeric,
  allocated_net_value_gbp numeric,
  latest_receipt_status text,
  latest_receipt_recorded_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipment batch candidates require auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    v_shipper_user_id,
    s.id,
    s.name::text,
    o.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text,
    o.id,
    o.order_ref::text,
    r.name::text,
    ots.id,
    c.name::text,
    ots.tracking_ref::text,
    ots.tracking_date::text,
    eligible.allocated_qty,
    eligible.allocated_net_value_gbp,
    latest_receipt.receipt_status::text,
    latest_receipt.recorded_at
  FROM public.orders o
  JOIN public.shippers s ON s.id = o.shipper_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  JOIN public.order_tracking_submissions ots
    ON ots.order_id = o.id
   AND ots.superseded_at IS NULL
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  JOIN LATERAL (
    SELECT
      SUM(COALESCE(a.qty_allocated, 0))::numeric AS allocated_qty,
      SUM(COALESCE(a.adjusted_net_value_gbp, 0))::numeric AS allocated_net_value_gbp
    FROM public.order_tracking_line_allocations a
    WHERE a.order_id = o.id
      AND a.tracking_submission_id = ots.id
      AND COALESCE(a.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        a.order_id,
        a.tracking_submission_id,
        a.supplier_invoice_line_id
      ) IS DISTINCT FROM true
  ) eligible ON COALESCE(eligible.allocated_qty, 0) > 0
  JOIN LATERAL (
    SELECT spr.receipt_status, spr.recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = ots.id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1
  ) latest_receipt ON true
  CROSS JOIN LATERAL public.shipper_tracking_review_state_v1(o.id, ots.id) review_state
  LEFT JOIN public.shipper_shipment_batch_packages existing_link
    ON existing_link.tracking_submission_id = ots.id
   AND existing_link.active = true
  WHERE o.shipper_id = v_shipper_id
    AND latest_receipt.receipt_status = 'received_clean'
    AND NOT review_state.active_review_yn
    AND existing_link.id IS NULL
  ORDER BY i.company_name NULLS LAST, o.created_at DESC, ots.tracking_date DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_candidates_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_candidates_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_create_shipment_batch_v1(
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
AS $$
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
  v_latest_receipt_status text;
  v_eligible_count integer;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: create shipment batch requires auth.uid()';
  END IF;
  IF p_importer_id IS NULL THEN
    RAISE EXCEPTION 'Importer is required.';
  END IF;
  IF p_tracking_submission_ids IS NULL OR array_length(p_tracking_submission_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one received-clean package.';
  END IF;
  IF NULLIF(btrim(COALESCE(p_booking_ref, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Booking reference is required.';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
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
    SELECT ots.order_id, o.shipper_id, o.importer_id
      INTO v_order_id, v_order_shipper_id, v_order_importer_id
    FROM public.order_tracking_submissions ots
    JOIN public.orders o ON o.id = ots.order_id
    WHERE ots.id = v_tracking_id
      AND ots.superseded_at IS NULL;

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

    SELECT spr.receipt_status
      INTO v_latest_receipt_status
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = v_tracking_id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1;

    IF v_latest_receipt_status IS DISTINCT FROM 'received_clean' THEN
      RAISE EXCEPTION 'Only latest received-clean packages can be selected for shipment batch.';
    END IF;
    IF (
      SELECT review_state.active_review_yn
      FROM public.shipper_tracking_review_state_v1(v_order_id, v_tracking_id) review_state
    ) THEN
      RAISE EXCEPTION 'This package is inside the active customer review window and cannot yet be added to a shipment.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_packages p
      WHERE p.tracking_submission_id = v_tracking_id AND p.active = true
    ) THEN
      RAISE EXCEPTION 'This package is already in an active shipment batch.';
    END IF;

    SELECT COUNT(*)::integer
      INTO v_eligible_count
    FROM public.order_tracking_line_allocations a
    WHERE a.order_id = v_order_id
      AND a.tracking_submission_id = v_tracking_id
      AND COALESCE(a.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        a.order_id,
        a.tracking_submission_id,
        a.supplier_invoice_line_id
      ) IS DISTINCT FROM true;

    IF COALESCE(v_eligible_count, 0) = 0 THEN
      RAISE EXCEPTION 'This package has no shipment-eligible lines after active customer holds are applied.';
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
      a.tracking_submission_id,
      a.id,
      a.order_id,
      a.supplier_invoice_line_id,
      a.qty_allocated,
      COALESCE(a.adjusted_net_value_gbp, 0)
    FROM public.order_tracking_line_allocations a
    WHERE a.order_id = v_order_id
      AND a.tracking_submission_id = v_tracking_id
      AND COALESCE(a.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        a.order_id,
        a.tracking_submission_id,
        a.supplier_invoice_line_id
      ) IS DISTINCT FROM true;
  END LOOP;

  RETURN v_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) TO authenticated;
NOTIFY pgrst, 'reload schema';

COMMIT;
