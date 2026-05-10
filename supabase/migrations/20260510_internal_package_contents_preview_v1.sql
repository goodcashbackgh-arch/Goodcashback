-- =============================================================================
-- 20260510_internal_package_contents_preview_v1.sql
-- Multi Tenant Platform Build — internal package contents preview
--
-- Purpose:
--   Staff/supervisor read-only package contents page. Same safe output as the
--   shipper contents view: item description + allocated quantity only. No values,
--   VAT, margin, Sage, DVA/card, adjusted net or payment data.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_package_contents_preview_v1(
  p_tracking_submission_id uuid
)
RETURNS TABLE (
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  importer_name text,
  shipper_name text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  tracking_date date,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  allocation_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal package contents requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal package contents.';
  END IF;

  IF p_tracking_submission_id IS NULL THEN
    RAISE EXCEPTION 'Tracking submission id is required.';
  END IF;

  RETURN QUERY
  SELECT
    ots.id AS tracking_submission_id,
    o.id AS order_id,
    o.order_ref::text AS order_ref,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    s.name::text AS shipper_name,
    r.name::text AS retailer_name,
    c.name::text AS courier_name,
    ots.tracking_ref::text AS tracking_ref,
    ots.tracking_date,
    sil.id AS supplier_invoice_line_id,
    COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
    otla.qty_allocated,
    otla.allocation_status::text
  FROM public.order_tracking_submissions ots
  JOIN public.orders o ON o.id = ots.order_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.shippers s ON s.id = o.shipper_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  JOIN public.order_tracking_line_allocations otla
    ON otla.tracking_submission_id = ots.id
  JOIN public.supplier_invoice_lines sil
    ON sil.id = otla.supplier_invoice_line_id
  WHERE ots.id = p_tracking_submission_id
    AND ots.superseded_at IS NULL
  ORDER BY sil.line_order NULLS LAST, sil.description;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_package_contents_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_package_contents_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
