BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.customer_hold_enforce_open_review_window_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tracking_id uuid;
  v_tracking_count integer;
  v_link_expires_at timestamptz;
BEGIN
  IF NEW.status <> 'requested'
     OR NEW.narrowed_from_hold_request_id IS NOT NULL
  THEN
    RETURN NEW;
  END IF;

  SELECT l.expires_at
    INTO v_link_expires_at
  FROM public.customer_order_review_links l
  WHERE l.id = NEW.review_link_id
    AND l.order_id = NEW.order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Customer review link is invalid or expired.';
  END IF;

  -- Existing untimed links keep the legacy early-stage hold behaviour.
  -- The new gate applies only to links created/updated with a clean-receipt deadline.
  IF v_link_expires_at IS NULL THEN
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

NOTIFY pgrst, 'reload schema';

COMMIT;
