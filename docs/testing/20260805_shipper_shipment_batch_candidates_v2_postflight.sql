WITH function_check AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    p.prosecdef AS security_definer,
    p.proconfig AS function_config,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  WHERE p.oid = 'public.shipper_shipment_batch_candidates_v2()'::regprocedure
), protected AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md