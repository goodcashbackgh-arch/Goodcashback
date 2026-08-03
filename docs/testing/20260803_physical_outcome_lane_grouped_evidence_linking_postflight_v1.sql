-- Read-only postflight for grouped physical outcome lane evidence linking.

WITH functions AS (
  SELECT
    p.oid,
    p.oid::regprocedure::text AS signature,
    p.prosecdef,
    p.proconfig,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid IN (
    to_regprocedure('public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text)'),
    to_regprocedure('public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text)')
  )
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN to_regprocedure('public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text)') IS NULL THEN 'refund_link_function_missing' END,
    CASE WHEN to_regprocedure('public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text)') IS NULL THEN 'return_tracking_link_function_missing' END,
    CASE WHEN EXISTS (SELECT 1 FROM functions WHERE NOT prosecdef) THEN 'function_not_security_definer' END,
    CASE WHEN EXISTS (SELECT 1 FROM functions WHERE NOT ('search_path=public, pg_temp'=ANY(proconfig))) THEN 'unsafe_search_path' END,
    CASE WHEN to_regprocedure('public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text)') IS NOT NULL
           AND NOT has_function_privilege('authenticated','public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text)','EXECUTE')
      THEN 'refund_authenticated_execute_missing' END,
    CASE WHEN to_regprocedure('public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text)') IS NOT NULL
           AND NOT has_function_privilege('authenticated','public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text)','EXECUTE')
      THEN 'return_authenticated_execute_missing' END,
    CASE WHEN to_regprocedure('public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text)') IS NOT NULL
           AND has_function_privilege('anon','public.link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text)','EXECUTE')
      THEN 'refund_anon_execute_present' END,
    CASE WHEN to_regprocedure('public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text)') IS NOT NULL
           AND has_function_privilege('anon','public.link_physical_outcome_return_tracking_v1(uuid,uuid[],uuid,text)','EXECUTE')
      THEN 'return_anon_execute_present' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM functions
      WHERE signature LIKE 'link_physical_outcome_refund_evidence_v1%'
        AND (definition NOT LIKE '%Refund evidence submission dispute does not match every selected lane item.%'
          OR definition NOT LIKE '%ON CONFLICT(refund_evidence_submission_id,physical_remedy_allocation_id,evidence_role) DO NOTHING%'
          OR definition NOT LIKE '%v_lane.outcome_type<>''refund''%')
    ) THEN 'refund_boundary_or_idempotency_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM functions
      WHERE signature LIKE 'link_physical_outcome_return_tracking_v1%'
        AND (definition NOT LIKE '%Return tracking submission dispute does not match every selected lane item.%'
          OR definition NOT LIKE '%ON CONFLICT(return_tracking_submission_id,physical_remedy_allocation_id,evidence_role) DO NOTHING%')
    ) THEN 'return_boundary_or_idempotency_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM functions
      WHERE definition NOT LIKE '%s.role_type IN (''admin'',''supervisor'')%'
         OR definition NOT LIKE '%oi.revoked_at IS NULL%'
    ) THEN 'authorization_boundary_missing' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN 'remedy_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233' THEN 'remedy_sequence_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679' THEN 'review_guard_drift' END
  ],NULL) AS blockers
)
SELECT jsonb_build_object(
  'postflight','physical_outcome_lane_grouped_evidence_linking_v1',
  'result',CASE WHEN COALESCE(array_length(blockers,1),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  'blockers',blockers,
  'functions',(
    SELECT jsonb_agg(jsonb_build_object(
      'signature',signature,
      'md5',md5(definition),
      'security_definer',prosecdef,
      'search_path',proconfig,
      'authenticated_execute',has_function_privilege('authenticated',signature,'EXECUTE'),
      'anon_execute',has_function_privilege('anon',signature,'EXECUTE'),
      'contains_same_dispute_boundary',definition LIKE '%does not match every selected lane item.%',
      'contains_idempotent_linking',definition LIKE '%DO NOTHING%'
    ) ORDER BY signature)
    FROM functions
  ),
  'protected_guard_fingerprints',jsonb_build_object(
    'physical_remedy_allocation_guard_v2',md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
    'physical_remedy_sequence_guard_v1',md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)),
    'physical_receipt_review_guard_v1',md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))
  )
) AS result
FROM blockers;
