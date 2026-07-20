BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.customer_active_order_review_link_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_active_order_review_link_v1(uuid)';
  END IF;

  IF to_regprocedure('public.customer_order_has_review_ready_lines_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_has_review_ready_lines_v1(uuid)';
  END IF;

  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.customer_dashboard_review_cards_v1()
RETURNS TABLE (
  order_id uuid,
  customer_review_path text,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_review_path text;
  v_expires_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  FOR v_order_id IN
    SELECT DISTINCT o.id
    FROM public.orders o
    JOIN public.operator_importers oi
      ON oi.importer_id = o.importer_id
     AND oi.revoked_at IS NULL
    JOIN public.operators op
      ON op.id = oi.operator_id
     AND op.auth_user_id = auth.uid()
     AND COALESCE(op.active, true) = true
    WHERE public.customer_order_has_review_ready_lines_v1(o.id)
  LOOP
    v_review_path := NULL;
    v_expires_at := NULL;

    SELECT active_link.customer_review_path
      INTO v_review_path
    FROM public.customer_active_order_review_link_v1(v_order_id) active_link
    LIMIT 1;

    IF v_review_path IS NULL THEN
      CONTINUE;
    END IF;

    SELECT l.expires_at
      INTO v_expires_at
    FROM public.customer_order_review_links l
    WHERE l.order_id = v_order_id
      AND l.is_active = true
      AND l.expires_at IS NOT NULL
      AND l.expires_at > now()
    ORDER BY l.created_at DESC
    LIMIT 1;

    IF v_expires_at IS NULL THEN
      CONTINUE;
    END IF;

    order_id := v_order_id;
    customer_review_path := v_review_path;
    expires_at := v_expires_at;
    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.customer_dashboard_review_cards_v1() IS
'Returns active customer review cards for the signed-in operator by reusing customer_active_order_review_link_v1(uuid). It exposes only the existing review path and existing expires_at deadline; it does not create a separate review, hold, receipt, shipment, or expiry workflow.';

REVOKE ALL ON FUNCTION public.customer_dashboard_review_cards_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_dashboard_review_cards_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
