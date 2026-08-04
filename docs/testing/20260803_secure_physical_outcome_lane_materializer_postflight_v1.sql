-- Read-only postflight for 20260803223000_secure_physical_outcome_lane_materializer_v1.sql.

WITH f AS (
  SELECT
    p.oid,
    p.prosecdef,
    p.proconfig,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid = to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)')
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN NOT EXISTS (SELECT 1 FROM f) THEN 'function_missing' END,
    CASE WHEN EXISTS (SELECT 1 FROM f WHERE NOT prosecdef) THEN 'not_security_definer' END,
    CASE WHEN EXISTS (SELECT 1 FROM f WHERE NOT ('search_path=public, pg_temp' = ANY(proconfig))) THEN 'unsafe_search_path' END,
    CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NOT NULL
           AND NOT has_function_privilege('authenticated','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE')
      THEN 'authenticated_execute_missing' END,
    CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NOT NULL
           AND has_function_privilege('anon','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE')
      THEN 'anon_execute_present' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM f
      WHERE definition NOT LIKE '%s.role_type IN (''admin'',''supervisor'')%'
    ) THEN 'staff_role_check_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM f
      WHERE definition NOT LIKE '%oi.importer_id=v_review.importer_id%'
         OR definition NOT LIKE '%oi.revoked_at IS NULL%'
    ) THEN 'operator_importer_check_missing' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN 'remedy_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233' THEN 'remedy_sequence_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679' THEN 'review_guard_drift' END
  ],NULL) AS blockers
)
SELECT jsonb_build_object(
  'postflight','secure_physical_outcome_lane_materializer_v1',
  'result',CASE WHEN COALESCE(array_length(blockers,1),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  'blockers',blockers,
  'function',(
    SELECT jsonb_build_object(
      'installed',true,
      'md5',md5(definition),
      'security_definer',prosecdef,
      'search_path',proconfig,
      'authenticated_execute',has_function_privilege('authenticated','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE'),
      'anon_execute',has_function_privilege('anon','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE'),
      'contains_staff_role_check',definition LIKE '%s.role_type IN (''admin'',''supervisor'')%',
      'contains_operator_importer_check',definition LIKE '%oi.importer_id=v_review.importer_id%' AND definition LIKE '%oi.revoked_at IS NULL%'
    ) FROM f
  ),
  'protected_guard_fingerprints',jsonb_build_object(
    'physical_remedy_allocation_guard_v2',md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
    'physical_remedy_sequence_guard_v1',md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)),
    'physical_receipt_review_guard_v1',md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))
  )
) AS result
FROM blockers;
