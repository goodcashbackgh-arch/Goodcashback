-- Read-only diagnostic for the Day3 correction eligibility wrapper snapshot.
-- No business writes. Safe to run in Supabase SQL editor.

BEGIN;
SET LOCAL statement_timeout = '0';
SET LOCAL lock_timeout = '15s';

SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);

WITH wrapper AS (
  SELECT public.customer_order_correction_eligibility_v1(
    '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid
  ) AS result
), expected AS (
  SELECT
    o.id,
    o.importer_id,
    o.total_qty_declared,
    ROUND(o.order_total_gbp_declared::numeric, 2) AS current_amount,
    COUNT(os.id) FILTER (WHERE os.note = 'Original order screenshot')::integer AS original_screenshot_count,
    f.applied_credit_gbp AS raw_applied_credit_gbp,
    f.funded_total_gbp AS raw_funded_total_gbp,
    f.markup_applied_gbp AS raw_markup_applied_gbp,
    ROUND(COALESCE(f.applied_credit_gbp, 0)::numeric, 2) AS expected_applied_credit_gbp,
    ROUND(COALESCE(f.funded_total_gbp, 0)::numeric, 2) AS expected_funded_total_gbp,
    ROUND(COALESCE(f.markup_applied_gbp, 0)::numeric, 2) AS expected_markup_applied_gbp
  FROM public.orders o
  JOIN public.order_funding_position_vw f ON f.order_id = o.id
  LEFT JOIN public.order_screenshots os ON os.order_id = o.id
  WHERE o.id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid
  GROUP BY o.id, o.importer_id, o.total_qty_declared, o.order_total_gbp_declared,
           f.applied_credit_gbp, f.funded_total_gbp, f.markup_applied_gbp
)
SELECT
  w.result AS wrapper_result,
  e.importer_id AS expected_importer_id,
  e.total_qty_declared AS expected_qty,
  e.current_amount AS expected_amount,
  e.original_screenshot_count AS expected_screenshot_count,
  e.raw_applied_credit_gbp,
  e.raw_funded_total_gbp,
  e.raw_markup_applied_gbp,
  e.expected_applied_credit_gbp,
  e.expected_funded_total_gbp,
  e.expected_markup_applied_gbp,
  ROUND((w.result->>'applied_credit_gbp')::numeric, 2) AS wrapper_applied_credit_gbp,
  ROUND((w.result->>'funded_total_gbp')::numeric, 2) AS wrapper_funded_total_gbp,
  ROUND((w.result->>'markup_applied_gbp')::numeric, 2) AS wrapper_markup_applied_gbp
FROM wrapper w
CROSS JOIN expected e;

ROLLBACK;
