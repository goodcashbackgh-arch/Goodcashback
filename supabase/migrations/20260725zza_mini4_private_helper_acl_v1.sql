BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Apply immediately after the Mini 4 foundation so private candidate and
-- deadline provenance is never directly exposed while later migrations run.

DO $prerequisites$
BEGIN
  IF to_regprocedure('public.customer_review_cycle_candidates_v1(uuid)') IS NULL
     OR to_regprocedure(
       'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Mini 4 private helper prerequisites are missing.';
  END IF;
END
$prerequisites$;

REVOKE ALL ON FUNCTION public.customer_review_cycle_candidates_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_review_cycle_candidates_v1(uuid)
  TO service_role;

REVOKE ALL ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  TO service_role;

DO $proof$
BEGIN
  IF has_function_privilege(
       'authenticated',
       'public.customer_review_cycle_candidates_v1(uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)',
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'Mini 4 private helper execution leaked to authenticated.';
  END IF;
END
$proof$;

COMMIT;
