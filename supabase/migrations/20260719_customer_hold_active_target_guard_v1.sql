BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_tracking_line_allocations';
  END IF;
END $$;

WITH ranked AS (
  SELECT h.id,
         first_value(h.id) OVER (
           PARTITION BY h.order_id
           ORDER BY CASE h.status WHEN 'supervisor_approved' THEN 1 ELSE 2 END,
                    h.reviewed_at NULLS LAST,
                    h.created_at,
                    h.id
         ) AS retained_id,
         row_number() OVER (
           PARTITION BY h.order_id
           ORDER BY CASE h.status WHEN 'supervisor_approved' THEN 1 ELSE 2 END,
                    h.reviewed_at NULLS LAST,
                    h.created_at,
                    h.id
         ) AS rn
  FROM public.customer_pre_shipment_hold_requests h
  WHERE h.requested_scope = 'order'
    AND h.status IN ('requested', 'supervisor_approved')
)
UPDATE public.customer_pre_shipment_hold_requests h
SET status = 'superseded',
    superseded_by_hold_request_id = r.retained_id,
    resolved_at = COALESCE(h.resolved_at, now()),
    updated_at = now(),
    supervisor_review_note = concat_ws(' ', NULLIF(h.supervisor_review_note, ''), 'Automatically superseded as a duplicate active order hold.')
FROM ranked r
WHERE r.id = h.id
  AND r.rn > 1;

WITH ranked AS (
  SELECT h.id,
         first_value(h.id) OVER (
           PARTITION BY h.tracking_submission_id
           ORDER BY CASE h.status WHEN 'supervisor_approved' THEN 1 ELSE 2 END,
                    h.reviewed_at NULLS LAST,
                    h.created_at,
                    h.id
         ) AS retained_id,
         row_number() OVER (
           PARTITION BY h.tracking_submission_id
           ORDER BY CASE h.status WHEN 'supervisor_approved' THEN 1 ELSE 2 END,
                    h.reviewed_at NULLS LAST,
                    h.created_at,
                    h.id
         ) AS rn
  FROM public.customer_pre_shipment_hold_requests h
  WHERE h.requested_scope = 'tracking'
    AND h.tracking_submission_id IS NOT NULL
    AND h.status IN ('requested', 'supervisor_approved')
)
UPDATE public.customer_pre_shipment_hold_requests h
SET status = 'superseded',
    superseded_by_hold_request_id = r.retained_id,
    resolved_at = COALESCE(h.resolved_at, now()),
    updated_at = now(),
    supervisor_review_note = concat_ws(' ', NULLIF(h.supervisor_review_note, ''), 'Automatically superseded as a duplicate active package hold.')
FROM ranked r
WHERE r.id = h.id
  AND r.rn > 1;

WITH ranked AS (
  SELECT h.id,
         first_value(h.id) OVER (
           PARTITION BY h.supplier_invoice_line_id
           ORDER BY CASE h.status WHEN 'supervisor_approved' THEN 1 ELSE 2 END,
                    h.reviewed_at NULLS LAST,
                    h.created_at,
                    h.id
         ) AS retained_id,
         row_number() OVER (
           PARTITION BY h.supplier_invoice_line_id
           ORDER BY CASE h.status WHEN 'supervisor_approved' THEN 1 ELSE 2 END,
                    h.reviewed_at NULLS LAST,
                    h.created_at,
                    h.id
         ) AS rn
  FROM public.customer_pre_shipment_hold_requests h
  WHERE h.requested_scope = 'line'
    AND h.supplier_invoice_line_id IS NOT NULL
    AND h.status IN ('requested', 'supervisor_approved')
)
UPDATE public.customer_pre_shipment_hold_requests h
SET status = 'superseded',
    superseded_by_hold_request_id = r.retained_id,
    resolved_at = COALESCE(h.resolved_at, now()),
    updated_at = now(),
    supervisor_review_note = concat_ws(' ', NULLIF(h.supervisor_review_note, ''), 'Automatically superseded as a duplicate active item hold.')
FROM ranked r
WHERE r.id = h.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_hold_active_order_target_v1
  ON public.customer_pre_shipment_hold_requests(order_id)
  WHERE requested_scope = 'order'
    AND status IN ('requested', 'supervisor_approved');

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_hold_active_package_target_v1
  ON public.customer_pre_shipment_hold_requests(tracking_submission_id)
  WHERE requested_scope = 'tracking'
    AND tracking_submission_id IS NOT NULL
    AND status IN ('requested', 'supervisor_approved');

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_hold_active_line_target_v1
  ON public.customer_pre_shipment_hold_requests(supplier_invoice_line_id)
  WHERE requested_scope = 'line'
    AND supplier_invoice_line_id IS NOT NULL
    AND status IN ('requested', 'supervisor_approved');

CREATE OR REPLACE FUNCTION public.customer_hold_enforce_active_target_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status NOT IN ('requested', 'supervisor_approved') THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.order_id::text));

  IF NEW.requested_scope = 'order'
     AND EXISTS (
       SELECT 1
       FROM public.customer_pre_shipment_hold_requests h
       WHERE h.order_id = NEW.order_id
         AND h.status IN ('requested', 'supervisor_approved')
         AND h.id IS DISTINCT FROM NEW.id
         AND h.id IS DISTINCT FROM NEW.narrowed_from_hold_request_id
     )
  THEN
    RAISE EXCEPTION 'This order already has an active hold. Resolve or narrow it before requesting a whole-order hold.';
  END IF;

  IF NEW.requested_scope <> 'order'
     AND EXISTS (
       SELECT 1
       FROM public.customer_pre_shipment_hold_requests h
       WHERE h.order_id = NEW.order_id
         AND h.requested_scope = 'order'
         AND h.status IN ('requested', 'supervisor_approved')
         AND h.id IS DISTINCT FROM NEW.id
         AND h.id IS DISTINCT FROM NEW.narrowed_from_hold_request_id
     )
  THEN
    RAISE EXCEPTION 'This target is already covered by an active whole-order hold.';
  END IF;

  IF NEW.requested_scope = 'tracking'
     AND EXISTS (
       SELECT 1
       FROM public.customer_pre_shipment_hold_requests h
       WHERE h.requested_scope = 'tracking'
         AND h.tracking_submission_id = NEW.tracking_submission_id
         AND h.status IN ('requested', 'supervisor_approved')
         AND h.id IS DISTINCT FROM NEW.id
         AND h.id IS DISTINCT FROM NEW.narrowed_from_hold_request_id
     )
  THEN
    RAISE EXCEPTION 'This package already has an active hold request.';
  END IF;

  IF NEW.requested_scope = 'tracking'
     AND EXISTS (
       SELECT 1
       FROM public.customer_pre_shipment_hold_requests h
       JOIN public.order_tracking_line_allocations otla
         ON otla.order_id = NEW.order_id
        AND otla.tracking_submission_id = NEW.tracking_submission_id
        AND otla.supplier_invoice_line_id = h.supplier_invoice_line_id
        AND COALESCE(otla.qty_allocated, 0) > 0
       WHERE h.order_id = NEW.order_id
         AND h.requested_scope = 'line'
         AND h.status IN ('requested', 'supervisor_approved')
         AND h.id IS DISTINCT FROM NEW.id
         AND h.id IS DISTINCT FROM NEW.narrowed_from_hold_request_id
     )
  THEN
    RAISE EXCEPTION 'One or more items in this package already has an active hold. Resolve those item holds first.';
  END IF;

  IF NEW.requested_scope = 'line'
     AND EXISTS (
       SELECT 1
       FROM public.customer_pre_shipment_hold_requests h
       WHERE h.requested_scope = 'line'
         AND h.supplier_invoice_line_id = NEW.supplier_invoice_line_id
         AND h.status IN ('requested', 'supervisor_approved')
         AND h.id IS DISTINCT FROM NEW.id
         AND h.id IS DISTINCT FROM NEW.narrowed_from_hold_request_id
     )
  THEN
    RAISE EXCEPTION 'This item already has an active hold request.';
  END IF;

  IF NEW.requested_scope = 'line'
     AND EXISTS (
       SELECT 1
       FROM public.customer_pre_shipment_hold_requests h
       JOIN public.order_tracking_line_allocations otla
         ON otla.order_id = NEW.order_id
        AND otla.tracking_submission_id = h.tracking_submission_id
        AND otla.supplier_invoice_line_id = NEW.supplier_invoice_line_id
        AND COALESCE(otla.qty_allocated, 0) > 0
       WHERE h.order_id = NEW.order_id
         AND h.requested_scope = 'tracking'
         AND h.status IN ('requested', 'supervisor_approved')
         AND h.id IS DISTINCT FROM NEW.id
         AND h.id IS DISTINCT FROM NEW.narrowed_from_hold_request_id
     )
  THEN
    RAISE EXCEPTION 'This item is already covered by an active package hold.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_hold_enforce_active_target_v1
  ON public.customer_pre_shipment_hold_requests;

CREATE TRIGGER trg_customer_hold_enforce_active_target_v1
BEFORE INSERT OR UPDATE OF
  order_id,
  requested_scope,
  tracking_submission_id,
  supplier_invoice_line_id,
  status,
  narrowed_from_hold_request_id
ON public.customer_pre_shipment_hold_requests
FOR EACH ROW
EXECUTE FUNCTION public.customer_hold_enforce_active_target_v1();

NOTIFY pgrst, 'reload schema';

COMMIT;
