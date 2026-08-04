-- Live preflight for grouped supervisor lane decision authority.
-- Read-only: inventories installed refund/replacement authorities and exact schemas.

WITH candidate_functions AS (
  SELECT
    n.nspname AS schema_name,
    p.proname AS function_name,
    p.oid::regprocedure::text AS signature,
    p.prosecdef AS security_definer,
    p.proconfig AS config,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND (
      p.proname ILIKE '%same_order%replacement%'
      OR p.proname ILIKE '%physical%replacement%route%'
      OR p.proname ILIKE '%refund%settlement%'
      OR p.proname ILIKE '%refund%approve%'
      OR p.proname ILIKE '%refund%decision%'
      OR p.proname ILIKE '%supervisor%dispute%'
      OR p.proname ILIKE '%staff%dispute%'
      OR p.proname ILIKE '%remedy%decision%'
    )
), target_columns AS (
  SELECT
    c.table_name,
    jsonb_agg(jsonb_build_object(
      'column_name',c.column_name,
      'data_type',c.data_type,
      'udt_name',c.udt_name,
      'nullable',c.is_nullable,
      'default',c.column_default
    ) ORDER BY c.ordinal_position) AS columns
  FROM information_schema.columns c
  WHERE c.table_schema='public'
    AND c.table_name IN (
      'physical_exception_remedy_allocations',
      'disputes',
      'dispute_lines',
      'dispute_refund_evidence_submissions',
      'dispute_return_tracking_submissions',
      'physical_receipt_outcome_lanes',
      'physical_receipt_outcome_lane_items'
    )
  GROUP BY c.table_name
), target_constraints AS (
  SELECT
    con.conrelid::regclass::text AS table_name,
    jsonb_agg(jsonb_build_object(
      'name',con.conname,
      'type',con.contype,
      'definition',pg_get_constraintdef(con.oid,true)
    ) ORDER BY con.conname) AS constraints
  FROM pg_constraint con
  WHERE con.conrelid IN (
    'public.physical_exception_remedy_allocations'::regclass,
    'public.disputes'::regclass,
    'public.dispute_lines'::regclass,
    'public.dispute_refund_evidence_submissions'::regclass,
    'public.dispute_return_tracking_submissions'::regclass,
    'public.physical_receipt_outcome_lanes'::regclass,
    'public.physical_receipt_outcome_lane_items'::regclass
  )
  GROUP BY con.conrelid
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN to_regclass('public.physical_receipt_outcome_lanes') IS NULL THEN 'outcome_lanes_missing' END,
    CASE WHEN to_regclass('public.physical_receipt_outcome_lane_items') IS NULL THEN 'outcome_lane_items_missing' END,
    CASE WHEN to_regclass('public.physical_exception_remedy_allocations') IS NULL THEN 'remedy_allocations_missing' END,
    CASE WHEN to_regclass('public.disputes') IS NULL THEN 'disputes_missing' END,
    CASE WHEN to_regclass('public.dispute_lines') IS NULL THEN 'dispute_lines_missing' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM candidate_functions WHERE function_name ILIKE '%replacement%') THEN 'replacement_authority_not_identified' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM candidate_functions WHERE function_name ILIKE '%refund%') THEN 'refund_authority_not_identified' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN 'remedy_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233' THEN 'remedy_sequence_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679' THEN 'review_guard_drift' END
  ],NULL) AS blockers
)
SELECT jsonb_build_object(
  'preflight','physical_outcome_lane_supervisor_authority_v1',
  'result',CASE WHEN COALESCE(array_length(blockers,1),0)=0 THEN 'READY' ELSE 'BLOCKED' END,
  'blockers',blockers,
  'candidate_functions',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'signature',signature,
      'security_definer',security_definer,
      'config',config,
      'definition_md5',definition_md5
    ) ORDER BY signature)
    FROM candidate_functions
  ),'[]'::jsonb),
  'table_columns',COALESCE((SELECT jsonb_object_agg(table_name,columns) FROM target_columns),'{}'::jsonb),
  'table_constraints',COALESCE((SELECT jsonb_object_agg(table_name,constraints) FROM target_constraints),'{}'::jsonb),
  'protected_guard_fingerprints',jsonb_build_object(
    'physical_remedy_allocation_guard_v2',md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
    'physical_remedy_sequence_guard_v1',md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)),
    'physical_receipt_review_guard_v1',md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))
  )
) AS result
FROM blockers;
