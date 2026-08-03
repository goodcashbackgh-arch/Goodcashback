-- Read-only probe: return the live grouped refund authority definition and
-- the exact coverage-guard context. No fixture or production data is changed.

WITH fn AS (
  SELECT
    p.oid,
    md5(pg_get_functiondef(p.oid)) AS function_md5,
    pg_get_functiondef(p.oid) AS function_definition
  FROM pg_proc p
  WHERE p.oid='public.staff_decide_physical_outcome_lane