BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shipper_package_receipts';
  END IF;
  IF to_regclass('public.shipper_shipment_batch_packages') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shipper_shipment_batch_packages';
  END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_tracking_line_allocations';
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
END $$;

-- Review eligibility now begins at the existing latest received-clean timestamp.
-- It ends automatically 24 hours later and never depends on shipment membership.
CREATE OR REPLACE FUNCTION public.customer_review_ready_line_ids_v1(p_order_id uuid)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH tracking_scope AS (
    SELECT
      ots.id AS tracking_submission_id,
      ots.order_id,
      latest_receipt.receipt_status,
      latest_receipt.recorded_at
    FROM public.order_tracking_submissions ots
    JOIN LATERAL (
      SELECT spr.receipt_status, spr.recorded_at
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = ots.id
      ORDER BY spr.created_at DESC, spr.id DESC
      LIMIT 1
    ) latest_receipt ON true
    WHERE ots.order_id = p_order_id
      AND ots.superseded_at IS NULL
      AND latest_receipt.receipt_status = 'received_clean'
      AND now() >= latest_receipt.recorded_at
      AND now() < latest_receipt.recorded_at + interval '24 hours'
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages sbp
        WHERE sbp.tracking_submission_id = ots.id
          AND sbp.active = true
      )
  )
  SELECT DISTINCT
    otla.supplier_invoice_line_id,
    ts.tracking_submission_id
  FROM tracking_scope ts
  JOIN public.order_tracking_line_allocations otla
    ON otla.order_id = ts.order_id
   AND otla.tracking_submission_id = ts.tracking_submission_id
   AND otla.supplier_invoice_line_id IS NOT NULL
   AND COALESCE(otla.qty_allocated, 0) > 0
  JOIN public.supplier_invoice_lines sil
    ON sil.id = otla.supplier_invoice_line_id
  JOIN public.supplier_invoices si
    ON si.id = sil.supplier_invoice_id
   AND si.order_id = ts.order_id
  WHERE COALESCE(si.review_status, '') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  );
$$;

REVOKE ALL ON FUNCTION public.customer_review_ready_line_ids_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_review_ready_line_ids_v1(uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.customer_order_has_review_ready_lines_v1(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customer_review_ready_line_ids_v1(p_order_id)
  );
$$;

REVOKE ALL ON FUNCTION public.customer_order_has_review_ready_lines_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_order_has_review_ready_lines_v1(uuid) TO authenticated;

-- Reuse the existing review link. Its expiry is derived from the latest open
-- clean-receipt window, so no cron or background expiry process is required.
CREATE OR REPLACE FUNCTION public.customer_active_order_review_link_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  customer_review_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_importer_id uuid;
  v_token text;
  v_deadline timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT o.importer_id
    INTO v_importer_id
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators op
    JOIN public.operator_importers oi
      ON oi.operator_id = op.id
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
      AND oi.revoked_at IS NULL
      AND oi.importer_id = v_importer_id
  ) THEN
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;

  SELECT MAX(latest_receipt.recorded_at + interval '24 hours')
    INTO v_deadline
  FROM public.order_tracking_submissions ots
  JOIN LATERAL (
    SELECT spr.receipt_status, spr.recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = ots.id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1
  ) latest_receipt ON true
  WHERE ots.order_id = p_order_id
    AND ots.superseded_at IS NULL
    AND latest_receipt.receipt_status = 'received_clean'
    AND now() >= latest_receipt.recorded_at
    AND now() < latest_receipt.recorded_at + interval '24 hours'
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_packages sbp
      WHERE sbp.tracking_submission_id = ots.id
        AND sbp.active = true
    );

  UPDATE public.customer_order_review_links l
  SET is_active = false
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NOT NULL AND l.expires_at <= now());

  IF v_deadline IS NULL
     OR NOT public.customer_order_has_review_ready_lines_v1(p_order_id)
     OR EXISTS (
       SELECT 1
       FROM public.sales_invoices si
       WHERE si.order_id = p_order_id
         AND COALESCE(si.invoice_type::text, '') IN ('main', 'supplementary')
         AND COALESCE(si.sage_status::text, '') IN ('draft', 'posted')
     )
  THEN
    RETURN;
  END IF;

  SELECT l.secure_token
    INTO v_token
  FROM public.customer_order_review_links l
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  ORDER BY l.created_at DESC
  LIMIT 1;

  IF v_token IS NULL THEN
    INSERT INTO public.customer_order_review_links (
      order_id,
      is_active,
      expires_at
    ) VALUES (
      p_order_id,
      true,
      v_deadline
    )
    RETURNING secure_token INTO v_token;
  ELSE
    UPDATE public.customer_order_review_links l
    SET expires_at = v_deadline
    WHERE l.order_id = p_order_id
      AND l.secure_token = v_token;
  END IF;

  RETURN QUERY
  SELECT p_order_id, ('/customer/orders/' || v_token || '/review')::text;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_active_order_review_link_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_active_order_review_link_v1(uuid) TO authenticated;

-- New customer requests must still be inside the exact package's open window.
-- Existing approved holds may continue to be narrowed/resolved after expiry.
CREATE OR REPLACE FUNCTION public.customer_hold_enforce_open_review_window_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tracking_id uuid;
  v_tracking_count integer;
BEGIN
  IF NEW.status <> 'requested'
     OR NEW.narrowed_from_hold_request_id IS NOT NULL
  THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.order_id::text));

  IF NEW.requested_scope = 'order' THEN
    IF NOT public.customer_order_has_review_ready_lines_v1(NEW.order_id) THEN
      RAISE EXCEPTION 'The 24-hour customer review window has closed or the package is already in a shipment.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.requested_scope = 'tracking' THEN
    PERFORM pg_advisory_xact_lock(hashtext(NEW.tracking_submission_id::text));
    IF NOT EXISTS (
      SELECT 1
      FROM public.customer_review_ready_line_ids_v1(NEW.order_id) rl
      WHERE rl.tracking_submission_id = NEW.tracking_submission_id
    ) THEN
      RAISE EXCEPTION 'The 24-hour customer review window for this package has closed or the package is already in a shipment.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.requested_scope = 'line' THEN
    SELECT MIN(rl.tracking_submission_id), COUNT(DISTINCT rl.tracking_submission_id)::integer
      INTO v_tracking_id, v_tracking_count
    FROM public.customer_review_ready_line_ids_v1(NEW.order_id) rl
    WHERE rl.supplier_invoice_line_id = NEW.supplier_invoice_line_id
      AND (
        NEW.tracking_submission_id IS NULL
        OR rl.tracking_submission_id = NEW.tracking_submission_id
      );

    IF COALESCE(v_tracking_count, 0) = 0 THEN
      RAISE EXCEPTION 'The 24-hour customer review window for this item has closed or its package is already in a shipment.';
    END IF;

    IF NEW.tracking_submission_id IS NULL AND v_tracking_count > 1 THEN
      RAISE EXCEPTION 'This item is allocated across more than one package. Select the package to hold.';
    END IF;

    NEW.tracking_submission_id := COALESCE(NEW.tracking_submission_id, v_tracking_id);
    PERFORM pg_advisory_xact_lock(hashtext(NEW.tracking_submission_id::text));
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_hold_enforce_open_review_window_v1
  ON public.customer_pre_shipment_hold_requests;

CREATE TRIGGER trg_customer_hold_enforce_open_review_window_v1
BEFORE INSERT ON public.customer_pre_shipment_hold_requests
FOR EACH ROW
EXECUTE FUNCTION public.customer_hold_enforce_open_review_window_v1();

-- Candidate list: no package appears until its 24-hour review window has ended,
-- and requested/approved holds continue to block the applicable scope.
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
    COALESCE(alloc.allocated_qty, 0::numeric),
    COALESCE(alloc.allocated_net_value_gbp, 0::numeric),
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
  LEFT JOIN LATERAL (
    SELECT
      SUM(COALESCE(otla.qty_allocated, 0)) AS allocated_qty,
      SUM(COALESCE(otla.adjusted_net_value_gbp, 0)) AS allocated_net_value_gbp
    FROM public.order_tracking_line_allocations otla
    WHERE otla.order_id = o.id
      AND otla.tracking_submission_id = ots.id
  ) alloc ON true
  JOIN LATERAL (
    SELECT spr.receipt_status, spr.recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = ots.id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1
  ) latest_receipt ON true
  LEFT JOIN public.shipper_shipment_batch_packages existing_link
    ON existing_link.tracking_submission_id = ots.id
   AND existing_link.active = true
  WHERE o.shipper_id = v_shipper_id
    AND latest_receipt.receipt_status = 'received_clean'
    AND now() >= latest_receipt.recorded_at + interval '24 hours'
    AND existing_link.id IS NULL
    AND COALESCE(alloc.allocated_qty, 0) > 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = o.id
        AND h.status IN ('requested', 'supervisor_approved')
        AND (
          h.requested_scope = 'order'
          OR (h.requested_scope = 'tracking' AND h.tracking_submission_id = ots.id)
          OR (
            h.requested_scope = 'line'
            AND EXISTS (
              SELECT 1
              FROM public.order_tracking_line_allocations hold_alloc
              WHERE hold_alloc.order_id = o.id
                AND hold_alloc.tracking_submission_id = ots.id
                AND hold_alloc.supplier_invoice_line_id = h.supplier_invoice_line_id
                AND COALESCE(hold_alloc.qty_allocated, 0) > 0
            )
          )
        )
    )
  ORDER BY i.company_name NULLS LAST, o.created_at DESC, ots.tracking_date DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_candidates_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_candidates_v1() TO authenticated;

-- Defensive server check mirrors the candidate query and serialises against
-- simultaneous hold requests. UI filtering alone is never the control.
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
  v_tracking_id uuid;
  v_order_id uuid;
  v_order_shipper_id uuid;
  v_order_importer_id uuid;
  v_latest_receipt_status text;
  v_latest_receipt_recorded_at timestamptz;
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

    SELECT spr.receipt_status, spr.recorded_at
      INTO v_latest_receipt_status, v_latest_receipt_recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = v_tracking_id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1;

    IF v_latest_receipt_status IS DISTINCT FROM 'received_clean' THEN
      RAISE EXCEPTION 'Only latest received-clean packages can be selected for shipment batch.';
    END IF;
    IF now() < v_latest_receipt_recorded_at + interval '24 hours' THEN
      RAISE EXCEPTION 'This package is inside the 24-hour customer review window and cannot yet be added to a shipment.';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_packages sbp
      WHERE sbp.tracking_submission_id = v_tracking_id
        AND sbp.active = true
    ) THEN
      RAISE EXCEPTION 'This package is already in an active shipment batch.';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = v_order_id
        AND h.status IN ('requested', 'supervisor_approved')
        AND (
          h.requested_scope = 'order'
          OR (h.requested_scope = 'tracking' AND h.tracking_submission_id = v_tracking_id)
          OR (
            h.requested_scope = 'line'
            AND EXISTS (
              SELECT 1
              FROM public.order_tracking_line_allocations hold_alloc
              WHERE hold_alloc.order_id = v_order_id
                AND hold_alloc.tracking_submission_id = v_tracking_id
                AND hold_alloc.supplier_invoice_line_id = h.supplier_invoice_line_id
                AND COALESCE(hold_alloc.qty_allocated, 0) > 0
            )
          )
        )
    ) THEN
      RAISE EXCEPTION 'This order/package/item is under customer hold or awaiting supervisor clearance and cannot be added to a shipment batch.';
    END IF;
  END LOOP;

  INSERT INTO public.shipper_shipment_batches (
    shipper_id,
    importer_id,
    created_by_shipper_user_id,
    booking_ref,
    shipment_cutoff_at,
    dispatched_at,
    box_count,
    container_ref,
    bol_ref,
    notes
  ) VALUES (
    v_shipper_id,
    p_importer_id,
    v_shipper_user_id,
    btrim(p_booking_ref),
    p_shipment_cutoff_at,
    p_dispatched_at,
    p_box_count,
    NULLIF(btrim(COALESCE(p_container_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_bol_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_notes, '')), '')
  ) RETURNING id INTO v_batch_id;

  FOREACH v_tracking_id IN ARRAY p_tracking_submission_ids LOOP
    SELECT ots.order_id, o.importer_id
      INTO v_order_id, v_order_importer_id
    FROM public.order_tracking_submissions ots
    JOIN public.orders o ON o.id = ots.order_id
    WHERE ots.id = v_tracking_id
      AND ots.superseded_at IS NULL;

    INSERT INTO public.shipper_shipment_batch_packages (
      shipment_batch_id,
      tracking_submission_id,
      order_id,
      shipper_id,
      importer_id,
      selected_by_shipper_user_id
    ) VALUES (
      v_batch_id,
      v_tracking_id,
      v_order_id,
      v_shipper_id,
      v_order_importer_id,
      v_shipper_user_id
    );
  END LOOP;

  RETURN v_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
