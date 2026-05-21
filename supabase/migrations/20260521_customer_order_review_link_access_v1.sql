BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;
  IF to_regclass('public.operator_importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_importers';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.customer_active_order_review_link_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  customer_review_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_importer_id uuid;
  v_token text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT o.importer_id
    INTO v_importer_id
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators op
    JOIN public.operator_importers oi
      ON oi.operator_id = op.id
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
      AND oi.revoked_at IS NULL
      AND oi.importer_id = v_importer_id
  ) THEN
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;

  SELECT l.secure_token
    INTO v_token
  FROM public.customer_order_review_links l
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  ORDER BY l.created_at DESC
  LIMIT 1;

  IF v_token IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    p_order_id,
    ('/customer/orders/' || v_token || '/review')::text;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_active_order_review_link_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_active_order_review_link_v1(uuid) TO authenticated;

COMMIT;
