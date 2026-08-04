-- Read-only corrected preflight for removing the rejected Phase 1A schema additions.
-- No writes.
-- v1 produced false positives because function return-column names included review_expires_at.
-- This version checks actual references to the membership-table columns.

WITH target_columns AS (
  SELECT a.attrelid, a.attnum, a.attname
  FROM pg_attribute a
  WHERE a.attrelid = 'public.customer_review_cycle_memberships'::regclass
    AND a.attname IN ('review_eligible_at', 'review_expires_at')
    AND NOT a.attisdropped
), dependent_objects AS (
  SELECT DISTINCT
    d.classid::regclass::text AS dependent_catalog,
    d.objid,
    d.objsubid,
    d.deptype,
    pg_describe_object(d.classid, d.objid, d.objsubid) AS dependent_object
  FROM pg_depend d
  JOIN target_columns c
    ON d.refobjid = c.attrelid
   AND d.refobjsubid = c.attnum
  WHERE NOT (
    d.classid = 'pg_constraint'::regclass
    AND d.objid = COALESCE((
      SELECT con.oid
      FROM pg_constraint con
      WHERE con.conrelid = 'public.customer_review_cycle_memberships'::regclass
        AND con.conname = 'customer_review_cycle_membership_timing_pair_v1'
    ), 0)
  )
  AND NOT (
    d.classid = 'pg_class'::regclass
    AND d.objid = COALESCE(
      to_regclass('public.customer_review_cycle_membership_active_expiry_v1')::oid,
      0
    )
  )
), actual_function_references AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND (
      position('membership.review_eligible_at' in pg_get_functiondef(p.oid)) > 0
      OR position('membership.review_expires_at' in pg_get_functiondef(p.oid)) > 0
      OR position('customer_review_cycle_memberships.review_eligible_at' in pg_get_functiondef(p.oid)) > 0
      OR position('customer_review_cycle_memberships.review_expires_at' in pg_get_functiondef(p.oid)) > 0
    )
), actual_view_references AS (
  SELECT schemaname, viewname
  FROM pg_views
  WHERE schemaname = 'public'
    AND (
      position('customer_review_cycle_memberships.review_eligible_at' in definition) > 0
      OR position('customer_review_cycle_memberships.review_expires_at' in definition) > 0
    )
), data_state AS (
  SELECT
    count(*)::integer AS row_count,
    count(*) FILTER (
      WHERE review_eligible_at IS NOT NULL
         OR review_expires_at IS NOT NULL
    )::integer AS populated_row_count,
    count(*) FILTER (
      WHERE review_eligible_at IS DISTINCT FROM receipt_recorded_at
    )::integer AS eligible_mismatch_count,
    count(*) FILTER (
      WHERE review_expires_at IS DISTINCT FROM link_row.expires_at
    )::integer AS expiry_mismatch_count
  FROM public.customer_review_cycle_memberships membership
  JOIN public.customer_order_review_links link_row
    ON link_row.id = membership.review_link_id
)
SELECT jsonb_build_object(
  'cleanup_safe',
    EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'customer_review_cycle_memberships'
        AND column_name = 'review_eligible_at'
    )
    AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'customer_review_cycle_memberships'
        AND column_name = 'review_expires_at'
    )
    AND NOT EXISTS (SELECT 1 FROM dependent_objects)
    AND NOT EXISTS (SELECT 1 FROM actual_function_references)
    AND NOT EXISTS (SELECT 1 FROM actual_view_references)
    AND (SELECT eligible_mismatch_count = 0 AND expiry_mismatch_count = 0 FROM data_state),
  'data_state', (SELECT to_jsonb(data_state) FROM data_state),
  'unexpected_dependencies', COALESCE((
    SELECT jsonb_agg(to_jsonb(dependent_objects) ORDER BY dependent_object)
    FROM dependent_objects
  ), '[]'::jsonb),
  'actual_function_references', COALESCE((
    SELECT jsonb_agg(to_jsonb(actual_function_references) ORDER BY identity)
    FROM actual_function_references
  ), '[]'::jsonb),
  'actual_view_references', COALESCE((
    SELECT jsonb_agg(to_jsonb(actual_view_references) ORDER BY schemaname, viewname)
    FROM actual_view_references
  ), '[]'::jsonb),
  'mini4_guard_md5', jsonb_build_object(
    'component', md5(pg_get_functiondef(
      'public.customer_review_cycle_component_guard_v1()'::regprocedure
    )),
    'immutable', md5(pg_get_functiondef(
      'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure
    ))
  )
) AS phase1a_dormant_schema_cleanup_preflight_v2;
