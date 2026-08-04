-- Read-only verification that the two Mini Build 4 guards are restored.

WITH guard_state AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.proacl AS acl,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid IN (
    'public.customer_review_cycle_component_guard_v1()'::regprocedure,
    'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure
  )
), expected(identity, expected_md5) AS (
  VALUES
    ('customer_review_cycle_component_guard_v1()', 'c7b7727836dd6c49fdbcd415fb68d88a'),
    ('customer_review_cycle_membership_immutable_guard_v1()', 'f08154042118c35eb4428af24623ae90')
)
SELECT jsonb_build_object(
  'restored', NOT EXISTS (
    SELECT 1
    FROM expected e
    LEFT JOIN guard_state g ON g.identity = e.identity
    WHERE g.identity IS NULL OR g.definition_md5 IS DISTINCT FROM e.expected_md5
  ),
  'guards', COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'identity', e.identity,
        'expected_md5', e.expected_md5,
        'actual_md5', g.definition_md5,
        'matches', g.definition_md5 = e.expected_md5,
        'owner', g.owner,
        'security_definer', g.security_definer,
        'acl', g.acl,
        'uses_original_fingerprint_version',
          CASE
            WHEN e.identity = 'customer_review_cycle_component_guard_v1()'
            THEN position('customer_review_membership_v2' in g.definition) > 0
            ELSE NULL
          END,
        'references_new_timing_columns',
          position('review_eligible_at' in g.definition) > 0
          OR position('review_expires_at' in g.definition) > 0
      )
      ORDER BY e.identity
    )
    FROM expected e
    LEFT JOIN guard_state g ON g.identity = e.identity
  ), '[]'::jsonb)
) AS mini4_guard_restoration_check;
