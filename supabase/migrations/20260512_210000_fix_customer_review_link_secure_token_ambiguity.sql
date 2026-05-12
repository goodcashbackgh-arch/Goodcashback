BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_create_customer_order_review_link_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  secure_token text,
  customer_review_path text,
  customer_review_url text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_token text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer order review link requires auth.uid()';
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required to create customer review link.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = p_order_id) THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  SELECT l.secure_token INTO v_token
  FROM public.customer_order_review_links l
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  ORDER BY l.created_at DESC
  LIMIT 1;

  IF v_token IS NULL THEN
    INSERT INTO public.customer_order_review_links AS corl (order_id, created_by_staff_id)
    VALUES (p_order_id, v_staff_id)
    RETURNING corl.secure_token INTO v_token;
  END IF;

  RETURN QUERY
  SELECT
    p_order_id AS order_id,
    v_token AS secure_token,
    ('/customer/orders/' || v_token || '/review')::text AS customer_review_path,
    ('/customer/orders/' || v_token || '/review')::text AS customer_review_url;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_customer_order_review_link_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_create_customer_order_review_link_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
