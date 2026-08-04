-- Phase 1 read-only preflight for exact routing.
-- Captures the live contracts needed before any migration is written.
-- No DDL, DML, temporary objects or persistent changes.

WITH target_functions AS (
  SELECT unnest(ARRAY[
    'public.customer_review_cycle_candidates_v1(uuid)'::text,
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::text,
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::text,
    'public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'::text,
    'public.shipper_shipment_batch_candidates_v1()'::text,
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::text
  ]) AS identity
), function_contracts AS (
  SELECT
    tf.identity,
    to_regprocedure(tf.identity) IS NOT NULL AS present,
    CASE WHEN to_regprocedure(tf.identity) IS NOT NULL THEN pg_get_userbyid(p.proowner) END AS owner,
    CASE WHEN to_regprocedure(tf.identity) IS NOT NULL THEN p.prosecdef END AS security_definer,
    CASE WHEN to_regprocedure(tf.identity) IS NOT NULL THEN p.provolatile END AS volatility,
    CASE WHEN to_regprocedure(tf.identity) IS NOT NULL THEN p.proconfig END AS proconfig,
    CASE WHEN to_regprocedure(tf.identity) IS NOT NULL THEN p.proacl END AS acl,
    CASE WHEN to_regprocedure(tf.identity) IS NOT NULL THEN md5(pg_get_functiondef(p.oid)) END AS definition_md5,
    CASE WHEN to_regprocedure(tf.identity) IS NOT NULL THEN pg_get_functiondef(p.oid) END AS definition
  FROM target_functions tf
  LEFT JOIN pg_proc p ON p.oid = to_regprocedure(tf.identity)
), membership_columns AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'customer_review_cycle_memberships'
  ORDER BY c.ordinal_position
), membership_constraints AS (
  SELECT
    con.conname,
    con.contype,
    pg_get_constraintdef(con.oid, true) AS definition
  FROM pg_constraint con
  WHERE con.conrelid = 'public.customer_review_cycle_memberships'::regclass
  ORDER BY con.conname
), membership_indexes AS (
  SELECT
    i.indexname,
    i.indexdef
  FROM pg_indexes i
  WHERE i.schemaname = 'public'
    AND i.tablename = 'customer_review_cycle_memberships'
  ORDER BY i.indexname
), relevant_triggers AS (
  SELECT
    c.relname AS table_name,
    t.tgname AS trigger_name,
    t.tgenabled,
    p.oid::regprocedure::text AS trigger_function,
    pg_get_triggerdef(t.oid, true) AS trigger_definition,
    md5(pg_get_functiondef(p.oid)) AS trigger_function_md5,
    pg_get_functiondef(p.oid) AS trigger_function_definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE n.nspname = 'public'
    AND NOT t.tgisinternal
    AND c.relname IN (
      'shipper_package_receipts',
      'physical_receipt_reviews',
      'customer_review_cycle_memberships',
      'order_tracking_line_allocations'
    )
  ORDER BY c.relname, t.tgname
), review_link_columns AS (
  SELECT
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'customer_order_review_links'
  ORDER BY c.ordinal_position
), membership_state AS (
  SELECT
    COUNT(*) AS membership_count,
    COUNT(*) FILTER (WHERE to_jsonb(m) ? 'review_eligible_at') AS rows_visible_to_json,
    MIN(m.created_at) AS earliest_created_at,
    MAX(m.created_at) AS latest_created_at
  FROM public.customer_review_cycle_memberships m
), relation_security AS (
  SELECT
    c.relname AS relation_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced,
    pg_get_userbyid(c.relowner) AS owner,
    c.relacl AS acl
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN (
      'customer_review_cycle_memberships',
      'customer_order_review_links',
      'physical_receipt_reviews',
      'shipper_package_receipts'
    )
  ORDER BY c.relname
)
SELECT jsonb_build_object(
  'all_required_functions_present', NOT EXISTS (SELECT 1 FROM function_contracts WHERE NOT present),
  'function_contracts', COALESCE((SELECT jsonb_agg(to_jsonb(function_contracts) ORDER BY identity) FROM function_contracts), '[]'::jsonb),
  'membership_columns', COALESCE((SELECT jsonb_agg(to_jsonb(membership_columns) ORDER BY ordinal_position) FROM membership_columns), '[]'::jsonb),
  'membership_constraints', COALESCE((SELECT jsonb_agg(to_jsonb(membership_constraints) ORDER BY conname) FROM membership_constraints), '[]'::jsonb),
  'membership_indexes', COALESCE((SELECT jsonb_agg(to_jsonb(membership_indexes) ORDER BY indexname) FROM membership_indexes), '[]'::jsonb),
  'review_link_columns', COALESCE((SELECT jsonb_agg(to_jsonb(review_link_columns) ORDER BY ordinal_position) FROM review_link_columns), '[]'::jsonb),
  'relevant_triggers', COALESCE((SELECT jsonb_agg(to_jsonb(relevant_triggers) ORDER BY table_name, trigger_name) FROM relevant_triggers), '[]'::jsonb),
  'membership_state', (SELECT to_jsonb(membership_state) FROM membership_state),
  'relation_security', COALESCE((SELECT jsonb_agg(to_jsonb(relation_security) ORDER BY relation_name) FROM relation_security), '[]'::jsonb)
) AS exact_routing_phase1_live_definition_preflight;
