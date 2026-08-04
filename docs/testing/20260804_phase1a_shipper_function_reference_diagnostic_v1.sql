-- Read-only diagnostic for the two live shipper functions that reference the rejected Phase 1A timing columns.
-- No writes.

WITH target_functions AS (
  SELECT
    p.oid,
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.provolatile AS volatility,
    p.proacl AS acl,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid IN (
    'public.shipper_tracking_review_state_v1(uuid,uuid)'::regprocedure,
    'public.shipper_dashboard_tracking_review_states_v1()'::regprocedure
  )
), function_details AS (
  SELECT
    identity,
    definition_md5,
    owner,
    security_definer,
    volatility,
    acl,
    position('review_eligible_at' in definition) > 0 AS uses_review_eligible_at,
    position('review_expires_at' in definition) > 0 AS uses_review_expires_at,
    definition
  FROM target_functions
), call_graph AS (
  SELECT
    caller.oid::regprocedure::text AS caller_identity,
    callee.oid::regprocedure::text AS callee_identity
  FROM pg_depend d
  JOIN pg_proc caller ON caller.oid = d.objid
  JOIN pg_proc callee ON callee.oid = d.refobjid
  WHERE d.classid = 'pg_proc'::regclass
    AND d.refclassid = 'pg_proc'::regclass
    AND (
      caller.oid IN (SELECT oid FROM target_functions)
      OR callee.oid IN (SELECT oid FROM target_functions)
    )
)
SELECT jsonb_build_object(
  'functions', COALESCE((
    SELECT jsonb_agg(to_jsonb(function_details) ORDER BY identity)
    FROM function_details
  ), '[]'::jsonb),
  'call_graph', COALESCE((
    SELECT jsonb_agg(to_jsonb(call_graph) ORDER BY caller_identity, callee_identity)
    FROM call_graph
  ), '[]'::jsonb),
  'timing_data_summary', (
    SELECT jsonb_build_object(
      'row_count', count(*)::integer,
      'populated_row_count', count(*) FILTER (
        WHERE review_eligible_at IS NOT NULL
           OR review_expires_at IS NOT NULL
      )::integer,
      'min_review_eligible_at', min(review_eligible_at),
      'max_review_eligible_at', max(review_eligible_at),
      'min_review_expires_at', min(review_expires_at),
      'max_review_expires_at', max(review_expires_at)
    )
    FROM public.customer_review_cycle_memberships
  )
) AS phase1a_shipper_function_reference_diagnostic;
