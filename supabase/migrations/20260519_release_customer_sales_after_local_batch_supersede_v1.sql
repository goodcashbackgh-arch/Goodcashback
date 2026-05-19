BEGIN;

-- Release customer sales sources after a local/no-Sage posting batch is
-- cancelled or superseded.
--
-- Problem fixed:
--   A cancelled local batch can deactivate the frozen snapshot but leave the
--   original sales_invoices.sage_status outside the draft resolver lane. The
--   row then disappears from Actionable / Live ready not frozen even though no
--   Sage object was created.
--
-- Rule:
--   If a customer_sales batch row is cancelled/superseded/excluded locally,
--   has never posted to Sage, and no other active non-cancelled batch owns the
--   same sales invoice, reset the sales invoice to draft so it can be frozen
--   again from the current resolver.
--
-- This does not touch any row with a Sage object id or posted_at.
-- No Sage API call. No deletion.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

WITH releasable_sales AS (
  SELECT DISTINCT br.source_id AS sales_invoice_id
  FROM public.sage_posting_batch_rows br
  JOIN public.sage_posting_batches b ON b.id = br.batch_id
  LEFT JOIN public.sales_invoices si ON si.id = br.source_id
  WHERE br.document_lane = 'customer_sales'
    AND br.source_table = 'sales_invoices'
    AND br.source_id IS NOT NULL
    AND (
      br.posting_status IN ('cancelled', 'excluded')
      OR b.status = 'cancelled'
      OR b.batch_status = 'superseded'
    )
    AND COALESCE(br.sage_object_id, '') = ''
    AND br.posted_at IS NULL
    AND COALESCE(si.sage_invoice_id, '') = ''
    AND si.sage_posted_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.sage_posting_batch_rows br2
      JOIN public.sage_posting_batches b2 ON b2.id = br2.batch_id
      WHERE br2.source_table = br.source_table
        AND br2.source_id = br.source_id
        AND br2.document_lane = br.document_lane
        AND br2.id <> br.id
        AND br2.posting_status NOT IN ('excluded', 'cancelled')
        AND COALESCE(br2.sage_object_id, '') = ''
        AND br2.posted_at IS NULL
        AND COALESCE(b2.status, '') <> 'cancelled'
        AND COALESCE(b2.batch_status, '') <> 'superseded'
    )
), released AS (
  UPDATE public.sales_invoices si
  SET sage_status = 'draft'
  FROM releasable_sales rs
  WHERE si.id = rs.sales_invoice_id
    AND COALESCE(si.sage_invoice_id, '') = ''
    AND si.sage_posted_at IS NULL
    AND COALESCE(si.sage_status, '') <> 'draft'
  RETURNING si.id
)
SELECT COUNT(*) AS released_customer_sales_count FROM released;

CREATE OR REPLACE FUNCTION public.internal_release_customer_sales_after_local_batch_supersede_v1(
  p_batch_id uuid DEFAULT NULL
)
RETURNS TABLE (
  released_customer_sales_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer sales release requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for customer sales release.';
  END IF;

  WITH releasable_sales AS (
    SELECT DISTINCT br.source_id AS sales_invoice_id
    FROM public.sage_posting_batch_rows br
    JOIN public.sage_posting_batches b ON b.id = br.batch_id
    LEFT JOIN public.sales_invoices si ON si.id = br.source_id
    WHERE (p_batch_id IS NULL OR br.batch_id = p_batch_id)
      AND br.document_lane = 'customer_sales'
      AND br.source_table = 'sales_invoices'
      AND br.source_id IS NOT NULL
      AND (
        br.posting_status IN ('cancelled', 'excluded')
        OR b.status = 'cancelled'
        OR b.batch_status = 'superseded'
      )
      AND COALESCE(br.sage_object_id, '') = ''
      AND br.posted_at IS NULL
      AND COALESCE(si.sage_invoice_id, '') = ''
      AND si.sage_posted_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.sage_posting_batch_rows br2
        JOIN public.sage_posting_batches b2 ON b2.id = br2.batch_id
        WHERE br2.source_table = br.source_table
          AND br2.source_id = br.source_id
          AND br2.document_lane = br.document_lane
          AND br2.id <> br.id
          AND br2.posting_status NOT IN ('excluded', 'cancelled')
          AND COALESCE(br2.sage_object_id, '') = ''
          AND br2.posted_at IS NULL
          AND COALESCE(b2.status, '') <> 'cancelled'
          AND COALESCE(b2.batch_status, '') <> 'superseded'
      )
  ), released AS (
    UPDATE public.sales_invoices si
    SET sage_status = 'draft'
    FROM releasable_sales rs
    WHERE si.id = rs.sales_invoice_id
      AND COALESCE(si.sage_invoice_id, '') = ''
      AND si.sage_posted_at IS NULL
      AND COALESCE(si.sage_status, '') <> 'draft'
    RETURNING si.id
  )
  SELECT COUNT(*)::integer INTO v_count FROM released;

  RETURN QUERY SELECT v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_release_customer_sales_after_local_batch_supersede_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_release_customer_sales_after_local_batch_supersede_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
