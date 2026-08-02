-- Hybrid Physical Receipt v1.2 — one-result live preflight combo
-- Governed by HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md.
-- Read-only. Returns one JSON object so the entire result can be copied back in one go.

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
),
exact_chain AS (
  SELECT
    o.id AS order_id,
    o.order_ref,
    review_row.id AS review_id,
    remedy.id AS remedy_allocation_id,
    remedy.status AS remedy_status,
    remedy.approved_remedy_type,
    remedy.approved_remedy_qty,
    remedy.customer_commercial_value_gbp,
    remedy.replacement_child_order_id AS remedy_child_order_id,
    allocation.id AS tracking_allocation_id,
    allocation.qty_allocated,
    allocation.adjusted_net_value_gbp,
    remedy.supplier_invoice_line_id,
    dl.id AS dispute_line_id,
    dl.qty_impact,
    dl.amount_impact_gbp AS dispute_line_amount_gbp,
    dl.resolved_at AS dispute_line_resolved_at,
    dl.resolved_via_child_order_id,
    d.id AS dispute_id,
    d.desired_outcome,
    d.status AS dispute_status,
    d.amount_impact_gbp AS dispute_amount_gbp,
    d.resolved_at AS dispute_resolved_at,
    d.replacement_child_order_id AS dispute_child_order_id
  FROM public.physical_exception_remedy_allocations remedy
  JOIN public.physical_receipt_reviews review_row
    ON review_row.id = remedy.physical_receipt_review_id
  JOIN public.orders o
    ON o.id = review_row.order_id
  JOIN public.order_tracking_line_allocations allocation
    ON allocation.id = remedy.tracking_line_allocation_id
  LEFT JOIN public.dispute_lines dl
    ON dl.id = remedy.dispute_line_id
  LEFT JOIN public.disputes d
    ON d.id = dl.dispute_id
  WHERE o.id = '8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid
    AND review_row.id = '1987393f-47ba-4460-96f6-598e0e52792d'::uuid
    AND remedy.id = '9e7f6c25-e920-4c90-a16a-0ffb6381a3d6'::uuid
    AND allocation.id = '5dbd95c5-c0d0-489d-973d-fab4c9083160'::uuid
    AND remedy.supplier_invoice_line_id = '0985538e-e9bb-42f2-8e3c-8cf11063705e'::uuid
    AND dl.id = '126ed01a-09b4-47e4-a2db-c52e7480d814'::uuid
    AND d.id = 'd7b32314-603e-49bf-83d1-1a01e2e4d29f'::uuid
),
role_snapshot AS (
  SELECT
    snapshot.signature,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute
  FROM function_snapshot snapshot
  JOIN pg_proc p ON p.oid::regprocedure::text = snapshot.signature
)
SELECT jsonb_pretty(jsonb_build_object(
  'captured_at_utc', timezone('utc', now()),
  'database', current_database(),
  'current_user', current_user,
  'server_version', current_setting('server_version'),
  'missing_functions', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.function_name) FROM missing_functions m), '[]'::jsonb),
  'functions', COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.signature) FROM function_snapshot f), '[]'::jsonb),
  'role_execute_snapshot', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.signature) FROM role_snapshot r), '[]'::jsonb),
  'columns', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.table_name, c.ordinal_position) FROM column_snapshot c), '[]'::jsonb),
  'indexes', COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.table_name, i.indexname) FROM index_snapshot i), '[]'::jsonb),
  'triggers', COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.relation_name, t.trigger_name) FROM trigger_snapshot t), '[]'::jsonb),
  'pending_shipper_confirmation_state', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.return_tracking_submission_id) FROM pending_state p), '[]'::jsonb),
  'duplicate_pending_shipper_confirmations', COALESCE((SELECT jsonb_agg(to_jsonb(p)) FROM pending_state p WHERE p.pending_count > 1), '[]'::jsonb),
  'exact_gbp60_chain', COALESCE((SELECT jsonb_agg(to_jsonb(e)) FROM exact_chain e), '[]'::jsonb)
)) AS hybrid_physical_receipt_v1_2_preflight_combo;

ROLLBACK;
