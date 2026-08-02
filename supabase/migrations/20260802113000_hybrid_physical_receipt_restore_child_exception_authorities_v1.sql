BEGIN;

DO $$
DECLARE
  v_current_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef(
    'public.order_has_open_child_exceptions(uuid)'::regprocedure
  ))
  INTO v_current_md5;

  IF v_current_md5 IS DISTINCT FROM '0c2d268a1e4a69c6665109d4a9db05e4' THEN
    RAISE EXCEPTION
      'Blocker repair stopped: installed function changed (%).',
      v_current_md5;
  END IF;

  IF to_regprocedure(
    'public.order_has_open_child_exceptions_v2(uuid)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION
      'Blocker repair stopped: v2 already exists.';
  END IF;
END
$$;

ALTER FUNCTION public.order_has_open_child_exceptions(uuid)
RENAME TO order_has_open_child_exceptions_v2;

CREATE FUNCTION public.order_has_open_child_exceptions(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.disputes d
    JOIN public.dispute_lines dl
      ON dl.dispute_id = d.id
    WHERE d.order_id = p_order_id
      AND dl.conversation_status IN (
        'child_exception_created',
        'remedy_selected',
        'refund_pending_approval',
        'retailer_draft_ready',
        'retailer_contacted',
        'retailer_response_received',
        'ai_next_draft_ready',
        'awaiting_retailer_resolution'
      )
  )
$function$;

COMMENT ON FUNCTION public.order_has_open_child_exceptions(uuid) IS
'True when an order still has child exceptions that affect value and therefore block final closure.';

COMMENT ON FUNCTION public.order_has_open_child_exceptions_v2(uuid) IS
'Versioned parent blocker for open legacy exceptions, unresolved physical remedies, unfinished replacement children and unrouted cancellations.';

REVOKE ALL
ON FUNCTION public.order_has_open_child_exceptions(uuid)
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.order_has_open_child_exceptions_v2(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.order_has_open_child_exceptions(uuid)
TO authenticated, service_role;

GRANT EXECUTE
ON FUNCTION public.order_has_open_child_exceptions_v2(uuid)
TO authenticated, service_role;

DO $$
DECLARE
  v_v1_md5 text;
  v_v2_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef(
    'public.order_has_open_child_exceptions(uuid)'::regprocedure
  ))
  INTO v_v1_md5;

  SELECT md5(pg_get_functiondef(
    'public.order_has_open_child_exceptions_v2(uuid)'::regprocedure
  ))
  INTO v_v2_md5;

  IF v_v1_md5 IS DISTINCT FROM 'c48eac531305a688aad17ccd103e2823' THEN
    RAISE EXCEPTION
      'Blocker repair postflight: restored v1 hash is %.',
      v_v1_md5;
  END IF;

  IF v_v2_md5 IS DISTINCT FROM '0c2d268a1e4a69c6665109d4a9db05e4' THEN
    RAISE EXCEPTION
      'Blocker repair postflight: preserved v2 hash is %.',
      v_v2_md5;
  END IF;
END
$$;

COMMIT;
