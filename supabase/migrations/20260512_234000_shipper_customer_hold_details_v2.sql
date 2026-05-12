BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_customer_hold_set_aside_v2()
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
  set_aside_instruction text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper hold visibility requires auth.uid()';
  END IF;

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    h.id,
    o.id,
    o.order_ref::text,
    h.tracking_submission_id,
    ots.tracking_ref::text,
    h.supplier_invoice_line_id,
    sil.description::text,
    sil.qty::numeric,
    sil.amount_inc_vat_gbp::numeric,
    h.reason,
    h.requested_scope::text,
    h.status::text,
    CASE
      WHEN h.requested_scope = 'order' THEN 'ORDER-LEVEL CUSTOMER HOLD — WATCH FOR ANY PACKAGE FOR THIS ORDER. DO NOT CONSOLIDATE OR ADD TO SHIPMENT UNTIL SUPERVISOR CLEARS.'
      WHEN h.requested_scope = 'tracking' THEN 'PACKAGE/TRACKING CUSTOMER HOLD — SET ASIDE THIS PACKAGE. DO NOT ADD TO SHIPMENT UNTIL SUPERVISOR CLEARS.'
      WHEN h.requested_scope = 'line' THEN 'ITEM-LINE CUSTOMER HOLD — SET ASIDE AFFECTED ITEM(S) IF IDENTIFIABLE. DO NOT SHIP HELD ITEM(S) UNTIL SUPERVISOR CLEARS.'
      ELSE 'CUSTOMER HOLD — SET ASIDE / DO NOT SHIP UNTIL SUPERVISOR CLEARS'
    END::text
  FROM public.customer_pre_shipment_hold_requests h
  JOIN public.orders o ON o.id = h.order_id
  LEFT JOIN public.order_tracking_submissions ots ON ots.id = h.tracking_submission_id
  LEFT JOIN public.supplier_invoice_lines sil ON sil.id = h.supplier_invoice_line_id
  WHERE o.shipper_id = v_shipper_id
    AND h.status = 'supervisor_approved'
  ORDER BY o.order_ref NULLS LAST, h.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_customer_hold_set_aside_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_customer_hold_set_aside_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
