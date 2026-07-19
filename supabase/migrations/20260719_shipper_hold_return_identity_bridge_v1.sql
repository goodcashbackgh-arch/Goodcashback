BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.shipper_customer_hold_set_aside_v2()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shipper_customer_hold_set_aside_v2()';
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_customer_hold_set_aside_v3()
RETURNS TABLE (
  hold_request_id uuid,
  order_id uuid,
  order_ref text,
  tracking_submission_id uuid,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  line_description text,
  line_qty numeric,
  line_amount_inc_vat_gbp numeric,
  reason text,
  hold_scope text,
  hold_status text,
  set_aside_instruction text,
  converted_dispute_id uuid
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    v2.hold_request_id,
    v2.order_id,
    v2.order_ref,
    v2.tracking_submission_id,
    v2.tracking_ref,
    v2.supplier_invoice_line_id,
    v2.line_description,
    v2.line_qty,
    v2.line_amount_inc_vat_gbp,
    v2.reason,
    v2.hold_scope,
    v2.hold_status,
    v2.set_aside_instruction,
    h.converted_dispute_id
  FROM public.shipper_customer_hold_set_aside_v2() v2
  JOIN public.customer_pre_shipment_hold_requests h
    ON h.id = v2.hold_request_id;
$$;

REVOKE ALL ON FUNCTION public.shipper_customer_hold_set_aside_v3() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_customer_hold_set_aside_v3() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
