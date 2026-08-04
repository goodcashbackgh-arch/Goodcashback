-- Read-only diagnostic. No writes.
-- Captures the exact live shipper review-state functions that reference the rejected Phase 1A timing columns.

WITH funcs AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.proacl AS acl,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid IN (
    'public.shipper_tracking_review_state_v1(uuid,uuid)'::regprocedure,
    'public.shipper_dashboard_tracking_review_states_v1()'::regprocedure
  )
)
SELECT jsonb_build_object(
  'functions', jsonb_agg(
    jsonb_build_object(
      'identity', identity,
      'definition_md5', definition_md5,
      'owner', owner,
      'security_definer', security_definer,
      'acl', acl,
      'contains_review_eligible_at', position('review_eligible_at' in definition) > 0,
      'contains_review_expires_at', position('review_expires_at' in definition) > 0,
      'definition', definition
    ) ORDER BY identity
  )
) AS phase1a_shipper_state_reference_diagnostic
FROM funcs;
