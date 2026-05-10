-- =============================================================================
-- 20260510_shipper_package_dashboard_rpc.sql
-- Multi Tenant Platform Build — shipper package dashboard read model
--
-- Purpose:
--   Provide a SECURITY DEFINER read model for the shipper dashboard, scoped to
--   the logged-in shipper user's shipper_id. This avoids exposing internal
--   financial controls while letting shippers see expected tracking refs/packages.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.shipper_package_dashboard_v1()
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
  submitted_at timestamptz,
  is_final_delivery_yn boolean,
  tracking_evidence_url text,
  tracking_note text,
  allocated_qty numeric,
  allocated_net_value_gbp numeric,
  allocation_status_summary text
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
    RAISE EXCEPTION 'Unauthenticated user: shipper dashboard requires auth.uid()';
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
    v_shipper_user_id AS shipper_user_id,
    s.id AS shipper_id,
    s.name::text AS shipper_name,
    o.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    o.id AS order_id,
    o.order_ref::text AS order_ref,
    r.name::text AS retailer_name,
    ots.id AS tracking_submission_id,
    c.name::text AS courier_name,
    ots.tracking_ref::text AS tracking_ref,
    ots.tracking_date::text AS tracking_date,
    ots.submitted_at,
    ots.is_final_delivery_yn,
    ots.tracking_screenshot_url::text AS tracking_evidence_url,
    ots.note::text AS tracking_note,
    COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
    COALESCE(alloc.allocated_net_value_gbp, 0::numeric) AS allocated_net_value_gbp,
    COALESCE(alloc.status_summary, 'not_allocated')::text AS allocation_status_summary
  FROM public.orders o
  JOIN public.shippers s ON s.id = o.shipper_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.order_tracking_submissions ots
    ON ots.order_id = o.id
   AND ots.superseded_at IS NULL
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  LEFT JOIN LATERAL (
    SELECT
      SUM(otla.qty_allocated) AS allocated_qty,
      SUM(otla.adjusted_net_value_gbp) AS allocated_net_value_gbp,
      string_agg(DISTINCT otla.allocation_status, ', ' ORDER BY otla.allocation_status) AS status_summary
    FROM public.order_tracking_line_allocations otla
    WHERE otla.order_id = o.id
      AND otla.tracking_submission_id = ots.id
  ) alloc ON ots.id IS NOT NULL
  WHERE o.shipper_id = v_shipper_id
  ORDER BY o.created_at DESC, ots.tracking_date DESC NULLS LAST, ots.submitted_at DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_package_dashboard_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_package_dashboard_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
