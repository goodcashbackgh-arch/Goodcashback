-- Read-only postflight for 20260803220000_physical_outcome_lane_foundation_v1.sql.

WITH expected_relations(name) AS (
  VALUES
    ('physical_receipt_outcome_lanes'),
    ('physical_receipt_outcome_lane_items'),
    ('physical_receipt_outcome_lane_updates'),
    ('physical_receipt_outcome_lane_update_items'),
    ('physical_receipt_outcome_refund_evidence_links'),
    ('physical_receipt_outcome_return_tracking_links')
), relation_state AS (
  SELECT
    e.name,
    c.oid IS NOT NULL AS installed,
    COALESCE(c.relrowsecurity,false) AS rls_enabled
  FROM expected_relations e
  LEFT JOIN pg_namespace n ON n.nspname='public'
  LEFT JOIN pg_class c ON c.relnamespace=n.oid AND c.relname=e.name AND c.relkind IN ('r','p')
), function_state AS (
  SELECT jsonb_build_object(
    'materialize_physical_receipt_outcome_lanes_v1', jsonb_build_object(
      'installed', to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NOT NULL,
      'md5', CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN NULL
                  ELSE md5(pg_get_functiondef('public.materialize_physical_receipt_outcome_lanes_v1(uuid)'::regprocedure)) END,
      'security_definer', CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN NULL
                               ELSE (SELECT prosecdef FROM pg_proc WHERE oid='public.materialize_physical_receipt_outcome_lanes_v1(uuid)'::regprocedure) END,
      'search_path', CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN NULL
                          ELSE (SELECT proconfig FROM pg_proc WHERE oid='public.materialize_physical_receipt_outcome_lanes_v1(uuid)'::regprocedure) END,
      'authenticated_execute', CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN false
                                    ELSE has_function_privilege('authenticated','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE') END,
      'anon_execute', CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN false
                           ELSE has_function_privilege('anon','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE') END
    ),
    'operator_record_physical_outcome_lane_update_v1', jsonb_build_object(
      'installed', to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NOT NULL,
      'md5', CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL THEN NULL
                  ELSE md5(pg_get_functiondef('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)'::regprocedure)) END,
      'security_definer', CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL THEN NULL
                               ELSE (SELECT prosecdef FROM pg_proc WHERE oid='public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)'::regprocedure) END,
      'search_path', CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL THEN NULL
                          ELSE (SELECT proconfig FROM pg_proc WHERE oid='public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)'::regprocedure) END,
      'authenticated_execute', CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL THEN false
                                    ELSE has_function_privilege('authenticated','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE') END,
      'anon_execute', CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL THEN false
                           ELSE has_function_privilege('anon','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE') END
    )
  ) AS functions
), required_constraints AS (
  SELECT jsonb_object_agg(e.name, COALESCE(x.constraints,'[]'::jsonb)) AS constraints
  FROM expected_relations e
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
      'name',con.conname,
      'type',con.contype,
      'definition',pg_get_constraintdef(con.oid,true)
    ) ORDER BY con.conname) AS constraints
    FROM pg_constraint con
    JOIN pg_class c ON c.oid=con.conrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname=e.name
  ) x ON true
  GROUP BY true
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN EXISTS(SELECT 1 FROM relation_state WHERE NOT installed) THEN 'missing_lane_relation' END,
    CASE WHEN EXISTS(SELECT 1 FROM relation_state WHERE installed AND NOT rls_enabled) THEN 'lane_relation_without_rls' END,
    CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN 'materialize_function_missing' END,
    CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL THEN 'grouped_update_function_missing' END,
    CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NOT NULL
           AND NOT has_function_privilege('authenticated','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE') THEN 'materialize_authenticated_execute_missing' END,
    CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NOT NULL
           AND NOT has_function_privilege('authenticated','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE') THEN 'grouped_update_authenticated_execute_missing' END,
    CASE WHEN to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NOT NULL
           AND has_function_privilege('anon','public.materialize_physical_receipt_outcome_lanes_v1(uuid)','EXECUTE') THEN 'materialize_anon_execute_present' END,
    CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NOT NULL
           AND has_function_privilege('anon','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE') THEN 'grouped_update_anon_execute_present' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN 'remedy_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233' THEN 'remedy_sequence_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679' THEN 'review_guard_drift' END
  ],NULL) AS blockers
)
SELECT jsonb_build_object(
  'postflight','physical_outcome_lane_foundation_v1',
  'result',CASE WHEN COALESCE(array_length(blockers,1),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  'blockers',blockers,
  'relations',(SELECT jsonb_agg(jsonb_build_object('name',name,'installed',installed,'rls_enabled',rls_enabled) ORDER BY name) FROM relation_state),
  'functions',(SELECT functions FROM function_state),
  'constraints',(SELECT constraints FROM required_constraints),
  'protected_guard_fingerprints',jsonb_build_object(
    'physical_remedy_allocation_guard_v2',md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
    'physical_remedy_sequence_guard_v1',md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)),
    'physical_receipt_review_guard_v1',md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))
  )
) AS result
FROM blockers;
