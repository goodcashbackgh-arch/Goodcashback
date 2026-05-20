BEGIN;

-- Accounting workbench safety patch.
-- 1) New posting batches must be lane-specific. This prevents accidental mixing
--    of customer sales AR with supplier/shipper AP from the workbench.
-- 2) Recent batch history hides cancelled/superseded batches at source, while
--    cancelled/superseded audit rows remain available in the lifecycle grid.
--
-- No Sage API call. No deletion. No column changes.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_posting_batches';
  END IF;
  IF to_regclass('public.sage_posting_batch_rows') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_posting_batch_rows';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_prevent_mixed_sage_posting_batch_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.batch_kind = 'posting_batch'
     AND COALESCE(NEW.lane, '') NOT IN ('customer_sales', 'supplier_goods_ap', 'shipper_ap') THEN
    RAISE EXCEPTION 'Choose exactly one posting lane before creating a Sage posting batch. Mixed customer/AP batches are blocked.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_mixed_sage_posting_batch_v1 ON public.sage_posting_batches;
CREATE TRIGGER trg_prevent_mixed_sage_posting_batch_v1
BEFORE INSERT OR UPDATE OF lane, batch_kind
ON public.sage_posting_batches
FOR EACH ROW
EXECUTE FUNCTION public.internal_prevent_mixed_sage_posting_batch_v1();

CREATE OR REPLACE FUNCTION public.internal_sage_posting_batch_history_v1(
  p_limit integer DEFAULT 12
)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  batch_kind text,
  batch_status text,
  status text,
  lane text,
  row_count integer,
  total_amount_gbp numeric,
  success_count integer,
  failed_count integer,
  blocked_count integer,
  included_count bigint,
  excluded_count bigint,
  posted_count bigint,
  failed_row_count bigint,
  customer_sales_count bigint,
  shipper_ap_count bigint,
  created_at timestamptz,
  created_by_staff_id uuid,
  created_by_name text,
  notes text,
  detail_href text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: posting batch history requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for posting batch history.';
  END IF;

  RETURN QUERY
  SELECT
    b.id AS batch_id,
    b.batch_ref,
    b.batch_kind,
    b.batch_status,
    b.status,
    b.lane,
    b.row_count,
    b.total_amount_gbp,
    b.success_count,
    b.failed_count,
    b.blocked_count,
    COUNT(r.id) FILTER (WHERE r.posting_status <> 'excluded') AS included_count,
    COUNT(r.id) FILTER (WHERE r.posting_status = 'excluded') AS excluded_count,
    COUNT(r.id) FILTER (WHERE r.posting_status = 'posted') AS posted_count,
    COUNT(r.id) FILTER (WHERE r.posting_status IN ('failed_retryable','failed_terminal')) AS failed_row_count,
    COUNT(r.id) FILTER (WHERE r.document_lane = 'customer_sales' AND r.posting_status <> 'excluded') AS customer_sales_count,
    COUNT(r.id) FILTER (WHERE r.document_lane IN ('shipper_ap','supplier_goods_ap') AND r.posting_status <> 'excluded') AS shipper_ap_count,
    b.created_at,
    b.created_by_staff_id,
    COALESCE(s.full_name, '—') AS created_by_name,
    b.notes,
    ('/internal/accounting-command-centre/batches/' || b.id::text) AS detail_href
  FROM public.sage_posting_batches b
  LEFT JOIN public.sage_posting_batch_rows r
    ON r.batch_id = b.id
  LEFT JOIN public.staff s
    ON s.id = b.created_by_staff_id
  WHERE COALESCE(b.status, '') <> 'cancelled'
    AND COALESCE(b.batch_status, '') <> 'superseded'
  GROUP BY
    b.id,
    b.batch_ref,
    b.batch_kind,
    b.batch_status,
    b.status,
    b.lane,
    b.row_count,
    b.total_amount_gbp,
    b.success_count,
    b.failed_count,
    b.blocked_count,
    b.created_at,
    b.created_by_staff_id,
    s.full_name,
    b.notes
  ORDER BY b.created_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 50);
END;
$$;

REVOKE ALL ON FUNCTION public.internal_prevent_mixed_sage_posting_batch_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_history_v1(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_batch_history_v1(integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
