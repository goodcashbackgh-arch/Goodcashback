BEGIN;

WITH totals AS (
  SELECT
    b.id,
    count(r.id)::integer AS n,
    COALESCE(sum(r.amount_gbp), 0)::numeric(18,2) AS total
  FROM public.cash_posting_batches b
  LEFT JOIN public.cash_posting_batch_rows r
    ON r.batch_id = b.id
   AND r.active = true
  WHERE b.active = true
  GROUP BY b.id
)
UPDATE public.cash_posting_batches b
SET
  row_count = totals.n,
  total_amount_gbp = totals.total,
  batch_status = CASE WHEN totals.n = 0 THEN 'cancelled' ELSE b.batch_status END,
  updated_at = now()
FROM totals
WHERE b.id = totals.id
  AND (
    b.row_count IS DISTINCT FROM totals.n
    OR b.total_amount_gbp IS DISTINCT FROM totals.total
  );

NOTIFY pgrst, 'reload schema';

COMMIT;
