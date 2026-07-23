BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.shipper_package_original_contents_preview_v1(
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
    RAISE EXCEPTION 'Unauthenticated user: original package contents preview requires auth.uid()';
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
    ots.id,
    o.id,
    o.order_ref::text,
    r.name::text,
    c.name::text,
    ots.tracking_ref::text,
    sil.id,
    COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text,
    a.qty_allocated::numeric,
    a.allocation_status::text
  FROM public.order_tracking_line_allocations a
  JOIN public.order_tracking_submissions ots
    ON ots.id = a.tracking_submission_id
   AND ots.superseded_at IS NULL
  JOIN public.orders o
    ON o.id = a.order_id
   AND o.id = ots.order_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
  WHERE o.shipper_id = v_shipper_id
    AND COALESCE(a.qty_allocated, 0) > 0
    AND (p_tracking_submission_id IS NULL OR ots.id = p_tracking_submission_id)
  ORDER BY o.order_ref NULLS LAST, ots.tracking_date NULLS LAST, sil.line_order NULLS LAST, sil.description;
END;
$$;

COMMENT ON FUNCTION public.shipper_package_original_contents_preview_v1(uuid) IS
'Read-only original tracking allocation truth. Does not apply hold, return, refund or shipment-membership filtering.';

REVOKE ALL ON FUNCTION public.shipper_package_original_contents_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_package_original_contents_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
