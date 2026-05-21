BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.customer_line_has_active_hold_conflict_v1(
  p_order_id uuid,
  p_tracking_submission_id uuid,
  p_supplier_invoice_line_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = p_order_id
      AND h.status IN ('requested','supervisor_approved')
      AND (
        h.requested_scope = 'order'
        OR (h.requested_scope = 'tracking' AND h.tracking_submission_id = p_tracking_submission_id)
        OR (h.requested_scope = 'line' AND h.supplier_invoice_line_id = p_supplier_invoice_line_id)
      )
  );
$$;

REVOKE ALL ON FUNCTION public.customer_line_has_active_hold_conflict_v1(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_line_has_active_hold_conflict_v1(uuid, uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_sales_invoice_has_active_hold_conflict_v1(
  p_order_id uuid,
  p_line_items_json jsonb
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = p_order_id
      AND h.status IN ('requested','supervisor_approved')
      AND (
        h.requested_scope = 'order'
        OR (
          h.requested_scope = 'tracking'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(COALESCE(p_line_items_json, '[]'::jsonb)) item
            WHERE item->>'source_tracking_submission_id' = h.tracking_submission_id::text
          )
        )
        OR (
          h.requested_scope = 'line'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(COALESCE(p_line_items_json, '[]'::jsonb)) item
            WHERE item->>'source_supplier_invoice_line_id' = h.supplier_invoice_line_id::text
          )
        )
      )
  );
$$;

REVOKE ALL ON FUNCTION public.customer_sales_invoice_has_active_hold_conflict_v1(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_sales_invoice_has_active_hold_conflict_v1(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_block_sales_invoice_when_hold_active_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.invoice_type::text, '') IN ('main','supplementary')
     AND COALESCE(NEW.sage_status::text, '') IN ('draft','posted')
     AND public.customer_sales_invoice_has_active_hold_conflict_v1(NEW.order_id, NEW.line_items_json)
  THEN
    RAISE EXCEPTION 'Cannot create or post customer sales invoice: invoice includes unresolved customer held line/package/order for order %.', NEW.order_id;
  END IF;

  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
