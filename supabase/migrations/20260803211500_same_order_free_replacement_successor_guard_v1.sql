-- Sidecar-only integrity guard for same-order successor allocation identity.
-- Does not alter Mini Builds 1-4 or order_tracking_line_allocations.

BEGIN;

CREATE FUNCTION public.same_order_replacement_successor_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_source public.order_tracking_line_allocations%ROWTYPE;
  v_successor public.order_tracking_line_allocations%ROWTYPE;
BEGIN
  IF NEW.route_status='tracking_allocated' THEN
    SELECT a.* INTO v_source
    FROM public.order_tracking_line_allocations a
    WHERE a.id=NEW.source_tracking_line_allocation_id;

    SELECT a.* INTO v_successor
    FROM public.order_tracking_line_allocations a
    WHERE a.id=NEW.successor_tracking_line_allocation_id;

    IF v_source.id IS NULL OR v_successor.id IS NULL THEN
      RAISE EXCEPTION 'Same-order route source/successor allocation is missing.';
    END IF;
    IF NEW.successor_tracking_submission_id IS DISTINCT FROM v_successor.tracking_submission_id THEN
      RAISE EXCEPTION 'Route successor tracking identity does not match the successor allocation.';
    END IF;
    IF v_source.tracking_submission_id IS NOT NULL
       AND v_successor.tracking_submission_id IS NOT DISTINCT FROM v_source.tracking_submission_id
    THEN
      RAISE EXCEPTION 'A same-order replacement successor must use a new tracking submission, not the failed source tracking submission.';
    END IF;
    IF v_successor.order_id IS DISTINCT FROM NEW.order_id
       OR v_successor.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
       OR v_successor.qty_allocated IS DISTINCT FROM NEW.replacement_qty
       OR v_successor.base_value_gbp IS DISTINCT FROM NEW.transferred_base_value_gbp
       OR v_successor.discount_share_gbp IS DISTINCT FROM NEW.transferred_discount_share_gbp
       OR v_successor.retailer_delivery_share_gbp IS DISTINCT FROM NEW.transferred_retailer_delivery_share_gbp
       OR v_successor.adjusted_net_value_gbp IS DISTINCT FROM NEW.transferred_adjusted_net_value_gbp
    THEN
      RAISE EXCEPTION 'Successor allocation does not exactly reproduce the transferred route entitlement.';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_same_order_replacement_successor_guard_v1
BEFORE INSERT OR UPDATE ON public.physical_replacement_same_order_routes
FOR EACH ROW EXECUTE FUNCTION public.same_order_replacement_successor_guard_v1();

REVOKE ALL ON FUNCTION public.same_order_replacement_successor_guard_v1() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.same_order_replacement_successor_guard_v1() TO service_role;

COMMIT;
