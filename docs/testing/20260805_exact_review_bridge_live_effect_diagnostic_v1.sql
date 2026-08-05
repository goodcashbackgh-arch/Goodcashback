BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Rollback-only diagnostic. No persistent changes.
-- Determines why the bridge reports one inserted row while no membership remains visible.

CREATE TEMP TABLE pg_temp.exact_bridge_diag_result (
  inserted_count integer
) ON COMMIT DROP;

INSERT INTO pg_temp.exact_bridge_diag_result(inserted_count)
SELECT public.internal_bridge_exact_customer_review_candidates_v1(
  '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
  NULL
);

WITH candidates AS (
  SELECT c.*
  FROM public.internal_customer_review_cycle_candidates_v2(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
  ) c
), links AS (
  SELECT l.*
  FROM public.customer_order_review_links l
  WHERE l.order_id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
  ORDER BY l.created_at, l.id
), memberships AS (
  SELECT m.*
  FROM public.customer_review_cycle_memberships m
  WHERE m.order_id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
  ORDER BY m.created_at, m.id
), table_triggers AS (
  SELECT
    c.relname AS table_name,
    t.tgname,
    t.tgenabled,
    t.tgtype,
    t.tgconstraint,
    pg_get_triggerdef(t.oid, true) AS trigger_definition,
    p.oid::regprocedure::text AS trigger_function,
    md5(pg_get_functiondef(p.oid)) AS trigger_function_md5,
    pg_get_functiondef(p.oid) AS trigger_function_definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE n.nspname = 'public'
    AND c.relname IN (
      'customer_order_review_links',
      'customer_review_cycle_memberships'
    )
    AND NOT t.tgisinternal
  ORDER BY c.relname, t.tgname
), rules AS (
  SELECT
    schemaname,
    tablename,
    rulename,
    definition
  FROM pg_rules
  WHERE schemaname = 'public'
    AND tablename IN (
      'customer_order_review_links',
      'customer_review_cycle_memberships'
    )
  ORDER BY tablename, rulename
)
SELECT jsonb_build_object(
  'bridge_inserted_count', (
    SELECT inserted_count FROM pg_temp.exact_bridge_diag_result
  ),
  'candidate_rows', COALESCE((
    SELECT jsonb_agg(to_jsonb(candidates) ORDER BY tracking_line_allocation_id)
    FROM candidates
  ), '[]'::jsonb),
  'review_links_after_call', COALESCE((
    SELECT jsonb_agg(to_jsonb(links) ORDER BY created_at, id)
    FROM links
  ), '[]'::jsonb),
  'memberships_after_call', COALESCE((
    SELECT jsonb_agg(to_jsonb(memberships) ORDER BY created_at, id)
    FROM memberships
  ), '[]'::jsonb),
  'noninternal_triggers', COALESCE((
    SELECT jsonb_agg(to_jsonb(table_triggers) ORDER BY table_name, tgname)
    FROM table_triggers
  ), '[]'::jsonb),
  'table_rules', COALESCE((
    SELECT jsonb_agg(to_jsonb(rules) ORDER BY tablename, rulename)
    FROM rules
  ), '[]'::jsonb),
  'transaction_timestamp', transaction_timestamp(),
  'statement_timestamp', statement_timestamp(),
  'clock_timestamp', clock_timestamp()
) AS exact_review_bridge_live_effect_diagnostic;

ROLLBACK;
