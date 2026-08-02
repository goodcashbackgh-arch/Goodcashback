-- Hybrid Physical Receipt v1.2 — cache-safe schema/function preflight combo v3
-- Read-only. The exact GBP 60 chain was already captured separately.
BEGIN;
SET LOCAL TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '0';

WITH target_function_names(function_name) AS (
  VALUES
    ('staff_decide_physical_receipt_review_v1'),
    ('staff_decide_physical_receipt_review_v2'),
    ('staff_accept_replacement_outcome_v1'),
    ('create_replacement_child_order_v2'),
    ('operator_submit_return_collection_tracking'),
    ('staff_review_return_collection_tracking'),
    ('shipper_return_tasks_v1'),
    ('shipper_submit_return_task_confirmation_v1')
),
function_snapshot AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    p.proname AS function_name,
    pg_get_userbyid(p.proowner) AS owner_name,
    p.prosecdef AS security_definer,
    p.proconfig,
    p.proacl AS acl,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    md5(pg_get_functiondef(p.oid)) AS function_md5,
    pg_get_functiondef(p.oid) AS function_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN target_function_names target ON target.function_name = p.proname
  WHERE n.nspname = 'public'
),
missing_functions AS (
  SELECT target.function_name
  FROM target_function_names target
  WHERE NOT EXISTS (
    SELECT 1 FROM function_snapshot snapshot
    WHERE snapshot.function_name = target.function_name
  )
),
target_tables(table_name) AS (
  VALUES
    ('physical_receipt_reviews'),
    ('physical_exception_remedy_allocations'),
    ('order_tracking_line_allocations'),
    ('physical_receipt_review_dispute_links'),
    ('dispute_lines'),
    ('disputes'),
    ('dispute_return_tracking_submissions'),
    ('shipper_return_task_confirmations'),
    ('shipper_package_receipt_line_dispositions')
),
column_snapshot AS (
  SELECT
    c.table_name,
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.is_nullable,
    c.column_default
  FROM information_schema.columns c
  JOIN target_tables t ON t.table_name = c.table_name
  WHERE c.table_schema = 'public'
),
index_snapshot AS (
  SELECT
    i.tablename AS table_name,
    i.indexname,
    i.indexdef
  FROM pg_indexes i
  JOIN target_tables t ON t.table_name = i.tablename
  WHERE i.schemaname = 'public'
),
trigger_snapshot AS (
  SELECT
    c.oid::regclass::text AS relation_name,
    t.tgname AS trigger_name,
    t.tgfoid::regprocedure::text AS function_identity,
    t.tgenabled,
    md5(pg_get_triggerdef(t.oid)) AS trigger_definition_md5,
    pg_get_triggerdef(t.oid) AS trigger_definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND NOT t.tgisinternal
    AND c.relname IN (SELECT table_name FROM target_tables)
),
pending_state AS (
  SELECT
    return_tracking_submission_id,
    count(*)::integer AS pending_count,
    array_agg(id ORDER BY submitted_at, id) AS confirmation_ids
  FROM public.shipper_return_task_confirmations
  WHERE review_status = 'pending_review'
  GROUP BY return_tracking_submission_id
)
SELECT jsonb_pretty(jsonb_build_object(
  'captured_at_utc', timezone('utc', now()),
  'database', current_database(),
  'current_user', current_user,
  'server_version', current_setting('server_version'),
  'missing_functions', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.function_name) FROM missing_functions m), '[]'::jsonb),
  'functions', COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.signature) FROM function_snapshot f), '[]'::jsonb),
  'columns', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.table_name, c.ordinal_position) FROM column_snapshot c), '[]'::jsonb),
  'indexes', COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.table_name, i.indexname) FROM index_snapshot i), '[]'::jsonb),
  'triggers', COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.relation_name, t.trigger_name) FROM trigger_snapshot t), '[]'::jsonb),
  'pending_shipper_confirmation_state', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.return_tracking_submission_id) FROM pending_state p), '[]'::jsonb),
  'duplicate_pending_shipper_confirmations', COALESCE((SELECT jsonb_agg(to_jsonb(p)) FROM pending_state p WHERE p.pending_count > 1), '[]'::jsonb)
)) AS hybrid_physical_receipt_v1_2_preflight_combo_v3;

ROLLBACK;
