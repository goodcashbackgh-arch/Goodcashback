BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/governing-pack/architecture/SHIPPER_INCOMING_TRAFFIC_ADDENDUM_v1.md
--
-- Additive read-only reader only. Existing shipper, tracking, allocation,
-- receipt and shipment functions are intentionally untouched.

CREATE FUNCTION public.shipper_incoming_traffic_v1()
RETURNS TABLE (
  order_id uuid,
  order_date timestamptz,
  importer_id uuid,
  importer_name text,
  retailer_id uuid,
  retailer_name text,
  order_ref text,
  total_qty_declared integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper incoming traffic requires auth.uid()';
  END IF;

  SELECT su.shipper_id
    INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    o.id AS order_id,
    o.created_at AS order_date,
    o.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    o.retailer_id,
    r.name::text AS retailer_name,
    o.order_ref::text AS order_ref,
    o.total_qty_declared
  FROM public.orders o
  LEFT JOIN public.importers i
    ON i.id = o.importer_id
  LEFT JOIN public.retailers r
    ON r.id = o.retailer_id
  WHERE o.shipper_id = v_shipper_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.order_tracking_line_allocations otla
      JOIN public.supplier_invoice_lines sil
        ON sil.id = otla.supplier_invoice_line_id
      JOIN public.order_tracking_submissions ots
        ON ots.id = otla.tracking_submission_id
       AND ots.order_id = otla.order_id
       AND ots.superseded_at IS NULL
      WHERE otla.order_id = o.id
        AND otla.tracking_submission_id IS NOT NULL
    )
  ORDER BY o.created_at DESC, o.id DESC;
END;
$function$;

ALTER FUNCTION public.shipper_incoming_traffic_v1()
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.shipper_incoming_traffic_v1()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.shipper_incoming_traffic_v1()
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
