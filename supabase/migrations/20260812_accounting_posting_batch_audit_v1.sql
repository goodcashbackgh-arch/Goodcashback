BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_sage_posting_batch_audit_v1(
  p_lane text DEFAULT 'all',
  p_status text DEFAULT 'all',
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  batch_kind text,
  status text,
  lane text,
  total_amount_gbp numeric,
  included_count bigint,
  excluded_count bigint,
  created_at timestamptz,
  created_by_name text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lane text := COALESCE(NULLIF(BTRIM(p_lane), ''), 'all');
  v_status text := COALESCE(NULLIF(BTRIM(p_status), ''), 'all');
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: posting batch audit requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for posting batch audit.';
  END IF;

  IF v_lane NOT IN ('all', 'customer_sales', 'supplier_goods_ap', 'supplier_credit_note', 'shipper_ap', 'mixed') THEN
    v_lane := 'all';
  END IF;

  IF v_status NOT IN ('all', 'draft', 'validated', 'posted', 'cancelled_or_superseded') THEN
    v_status := 'all';
  END IF;

  RETURN QUERY
  WITH row_counts AS (
    SELECT
      r.batch_id,
      COUNT(r.id) FILTER (WHERE r.posting_status <> 'excluded') AS included_count,
      COUNT(r.id) FILTER (WHERE r.posting_status = 'excluded') AS excluded_count
    FROM public.sage_posting_batch_rows r
    GROUP BY r.batch_id
  ), filtered AS (
    SELECT
      b.id AS batch_id,
      b.batch_ref,
      b.batch_kind,
      b.status,
      b.lane,
      b.total_amount_gbp,
      COALESCE(rc.included_count, 0)::bigint AS included_count,
      COALESCE(rc.excluded_count, 0)::bigint AS excluded_count,
      b.created_at,
      COALESCE(s.full_name, '—')::text AS created_by_name
    FROM public.sage_posting_batches b
    LEFT JOIN row_counts rc
      ON rc.batch_id = b.id
    LEFT JOIN public.staff s
      ON s.id = b.created_by_staff_id
    WHERE (v_lane = 'all' OR b.lane = v_lane)
      AND (
        v_status = 'all'
        OR (v_status IN ('draft', 'validated', 'posted') AND b.status = v_status)
        OR (v_status = 'cancelled_or_superseded' AND (b.status = 'cancelled' OR b.batch_status = 'superseded'))
      )
  ), counted AS (
    SELECT
      f.*,
      COUNT(*) OVER ()::bigint AS total_count
    FROM filtered f
  )
  SELECT
    c.batch_id,
    c.batch_ref,
    c.batch_kind,
    c.status,
    c.lane,
    c.total_amount_gbp,
    c.included_count,
    c.excluded_count,
    c.created_at,
    c.created_by_name,
    c.total_count
  FROM counted c
  ORDER BY c.created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_audit_v1(text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_audit_v1(text, text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_batch_audit_v1(text, text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_sage_posting_batch_audit_v1(text, text, integer, integer) IS
'Read-only paginated accounting posting-batch audit history. Adds no posting or accounting mutations.';

NOTIFY pgrst, 'reload schema';

COMMIT;
