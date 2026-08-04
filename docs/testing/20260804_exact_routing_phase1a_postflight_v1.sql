-- Read-only postflight for Phase 1A membership timing.

WITH column_state AS (
  SELECT
    column_name,
    data_type,
    is_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'customer_review_cycle_memberships'
    AND column_name IN ('review_eligible_at','review_expires_at')
), constraint_state AS (
  SELECT
    conname,
    pg_get_constraintdef(oid, true) AS definition
  FROM pg_constraint
  WHERE conrelid = 'public.customer_review_cycle_memberships'::regclass
    AND conname = 'customer_review_cycle_membership_timing_pair_v1'
), index_state AS (
  SELECT indexname, indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'customer_review_cycle_memberships'
    AND indexname = 'customer_review_cycle_membership_active_expiry_v1'
), data_state AS (
  SELECT
    COUNT(*)::integer AS membership_count,
    COUNT(*) FILTER (
      WHERE (review_eligible_at IS NULL) <> (review_expires_at IS NULL)
         OR (review_eligible_at IS NOT NULL AND review_expires_at <= review_eligible_at)
    )::integer AS bad_timing_pair_count,
    COUNT(*) FILTER (
      WHERE l.expires_at IS NOT NULL
        AND (
          m.review_eligible_at IS DISTINCT FROM m.receipt_recorded_at
          OR m.review_expires_at IS DISTINCT FROM l.expires_at
        )
    )::integer AS timed_backfill_mismatch_count,
    COUNT(*) FILTER (
      WHERE l.expires_at IS NULL
        AND (m.review_eligible_at IS NOT NULL OR m.review_expires_at IS NOT NULL)
    )::integer AS legacy_untimed_nonnull_count
  FROM public.customer_review_cycle_memberships m
  JOIN public.customer_order_review_links l ON l.id = m.review_link_id
), function_state AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.proacl AS acl
  FROM pg_proc p
  WHERE p.oid IN (
    'public.customer_review_cycle_component_guard_v1()'::regprocedure,
    'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure
  )
)
SELECT jsonb_build_object(
  'phase1a_ready',
    (SELECT COUNT(*) = 2 FROM column_state)
    AND EXISTS (SELECT 1 FROM constraint_state)
    AND EXISTS (SELECT 1 FROM index_state)
    AND (SELECT bad_timing_pair_count = 0 AND timed_backfill_mismatch_count = 0 AND legacy_untimed_nonnull_count = 0 FROM data_state),
  'columns', COALESCE((SELECT jsonb_agg(to_jsonb(column_state) ORDER BY column_name) FROM column_state), '[]'::jsonb),
  'constraint', COALESCE((SELECT jsonb_agg(to_jsonb(constraint_state)) FROM constraint_state), '[]'::jsonb),
  'index', COALESCE((SELECT jsonb_agg(to_jsonb(index_state)) FROM index_state), '[]'::jsonb),
  'data_state', (SELECT to_jsonb(data_state) FROM data_state),
  'function_state', COALESCE((SELECT jsonb_agg(to_jsonb(function_state) ORDER BY identity) FROM function_state), '[]'::jsonb)
) AS exact_routing_phase1a_postflight;
