-- =============================================================================
-- 20260510_shipper_package_contents_preview_v1.sql
-- Multi Tenant Platform Build — shipper package contents preview
--
-- Governing source:
--   docs/governing-pack/backend/Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md
--
-- Purpose:
--   Let authenticated shipper users see practical package contents only:
--   item description + allocated quantity. No values, VAT, margin, DVA/card,
--   Sage coding, or adjusted net amounts are exposed.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.shipper_package_contents_preview_v1(
  p_tracking_submission_id uuid DEFAULT NULL
)
RETURNS TABLE (
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  allocation_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: package contents preview requires auth.uid()';
  END IF;

  SELECT su.shipper_id
    INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    ots.id AS tracking_submission_id,
    o.id AS order_id,
    o.order_ref::text AS order_ref,
    r.name::text AS retailer_name,
    c.name::text AS courier_name,
    ots.tracking_ref::text AS tracking_ref,
    sil.id AS supplier_invoice_line_id,
    COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
    otla.qty_allocated,
    otla.allocation_status::text
  FROM public.order_tracking_submissions ots
  JOIN public.orders o ON o.id = ots.order_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  JOIN public.order_tracking_line_allocations otla
    ON otla.tracking_submission_id = ots.id
  JOIN public.supplier_invoice_lines sil
    ON sil.id = otla.supplier_invoice_line_id
  WHERE o.shipper_id = v_shipper_id
    AND ots.superseded_at IS NULL
    AND (p_tracking_submission_id IS NULL OR ots.id = p_tracking_submission_id)
  ORDER BY o.order_ref NULLS LAST, ots.tracking_date NULLS LAST, sil.line_order NULLS LAST, sil.description;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_package_contents_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_package_contents_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
