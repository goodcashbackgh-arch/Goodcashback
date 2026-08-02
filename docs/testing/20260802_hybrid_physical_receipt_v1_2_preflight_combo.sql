-- Hybrid Physical Receipt v1.2 — one-result live preflight combo
-- Governed by HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md.
-- Read-only. Returns one JSON object so the entire result can be copied back in one go.

BEGIN;
SET LOCAL TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '0';

WITH target_functions(signature) AS (
  VALUES
    ('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'),
    ('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)'),
    ('public.staff_accept_replacement_outcome_v1(uuid,uuid,text)'),
    ('public.create_replacement_child_order_v2(uuid,uuid,uuid,text)'),
    ('public.operator_submit_return_collection_tracking(uuid,uuid,text,date,text,boolean,text,text,text,text)'),
    ('public.staff_review_return_collection_tracking(uuid,text,text)'),
    ('public.shipper_return_tasks_v1()'),
    ('public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)')
),
function_snapshot AS (
  SELECT
    tf.signature,
    to_regprocedure(tf.signature) IS NOT NULL AS exists,
    CASE WHEN to_regprocedure(tf.signature) IS NOT NULL THEN pg_get_userbyid(p.proowner) END AS owner_name,
    CASE WHEN to_regprocedure(tf.signature) IS NOT NULL THEN p.prosecdef END AS security_definer,
    CASE WHEN to_regprocedure(tf.signature) IS NOT NULL THEN p.proconfig END AS proconfig,
    CASE WHEN to_regprocedure(tf.signature) IS NOT NULL THEN p.proacl END AS acl,
    CASE WHEN to_regprocedure(tf.signature) IS NOT NULL THEN md5(pg_get_functiondef(p.oid)) END AS function_md5,
    CASE WHEN to_regprocedure(tf.signature) IS NOT NULL THEN pg_get_functiondef(p.oid) END AS function_definition
  FROM target_functions tf
  LEFT JOIN pg_proc p ON p.oid = to_regprocedure(tf.signature)
),
target_tables(table_name) AS (
  VALUES
    ('physical_exception_remedy_allocations'),
    ('order_tracking_line_allocations'),
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
  ORDER BY c.table_name, c.ordinal_position
),
index_snapshot AS (
  SELECT
    i.tablename AS table_name,
    i.indexname,
    i.indexdef
  FROM pg_indexes i
  JOIN target_tables t ON t.table_name = i.tablename
  WHERE i.schemaname = 'public'
  ORDER BY i.tablename, i.indexname
),
trigger_snapshot AS (
  SELECT
    event_object_table AS table_name,
    trigger_name,
    event_manipulation,
    action_timing,
    action_statement
  FROM information_schema.triggers
  WHERE trigger_schema = 'public'
    AND event_object_table IN (SELECT table_name FROM target_tables)
  ORDER BY event_object_table, trigger_name, event_manipulation
),
pending_duplicates AS (
  SELECT
    return_tracking_submission_id,
    count(*)::integer AS pending_count,
    array_agg(id ORDER BY submitted_at NULLS LAST, id) AS confirmation_ids
  FROM public.shipper_return_task_confirmations
  WHERE review_status = 'pending_review'
  GROUP BY return_tracking_submission_id
  HAVING count(*) > 1
),
exact_chain AS (
  SELECT
    o.id AS order_id,
    o.order_ref,
    r.id AS review_id,
    pra.id AS remedy_allocation_id,
    pra.status AS remedy_status,
    pra.approved_remedy_type,
    pra.approved_remedy_qty,
    pra.commercial_value_gbp AS customer_commercial_value_gbp,
    pra.replacement_child_order_id AS remedy_child_order_id,
    otla.id AS tracking_allocation_id,
    otla.qty_allocated,
    otla.adjusted_net_value_gbp,
    sil.id AS supplier_invoice_line_id,
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
  FROM public.orders o
  JOIN public.physical_receipt_reviews r
    ON r.order_id = o.id
  JOIN public.physical_exception_remedy_allocations pra
    ON pra.physical_receipt_review_id = r.id
  LEFT JOIN public.order_tracking_line_allocations otla
    ON otla.id = pra.order_tracking_line_allocation_id
  LEFT JOIN public.supplier_invoice_lines sil
    ON sil.id = otla.supplier_invoice_line_id
  LEFT JOIN public.dispute_lines dl
    ON dl.id = pra.dispute_line_id
  LEFT JOIN public.disputes d
    ON d.id = dl.dispute_id
  WHERE o.id = '8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid
    AND r.id = '1987393f-47ba-4460-96f6-598e0e52792d'::uuid
    AND pra.id = '9e7f6c25-e920-4c90-a16a-0ffb6381a3d6'::uuid
),
role_snapshot AS (
  SELECT jsonb_build_object(
    'anon', jsonb_build_object(
      'staff_v2_execute', has_function_privilege('anon', 'public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)', 'EXECUTE'),
      'shipper_v1_reader_execute', has_function_privilege('anon', 'public.shipper_return_tasks_v1()', 'EXECUTE'),
      'shipper_v1_submit_execute', has_function_privilege('anon', 'public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)', 'EXECUTE')
    ),
    'authenticated', jsonb_build_object(
      'staff_v2_execute', has_function_privilege('authenticated', 'public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)', 'EXECUTE'),
      'shipper_v1_reader_execute', has_function_privilege('authenticated', 'public.shipper_return_tasks_v1()', 'EXECUTE'),
      'shipper_v1_submit_execute', has_function_privilege('authenticated', 'public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)', 'EXECUTE')
    )
  ) AS payload
)
SELECT jsonb_pretty(jsonb_build_object(
  'captured_at_utc', timezone('utc', now()),
  'database', current_database(),
  'current_user', current_user,
  'server_version', current_setting('server_version'),
  'functions', COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.signature) FROM function_snapshot f), '[]'::jsonb),
  'role_execute_snapshot', (SELECT payload FROM role_snapshot),
  'columns', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.table_name, c.ordinal_position) FROM column_snapshot c), '[]'::jsonb),
  'indexes', COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.table_name, i.indexname) FROM index_snapshot i), '[]'::jsonb),
  'triggers', COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.table_name, t.trigger_name, t.event_manipulation) FROM trigger_snapshot t), '[]'::jsonb),
  'duplicate_pending_shipper_confirmations', COALESCE((SELECT jsonb_agg(to_jsonb(p)) FROM pending_duplicates p), '[]'::jsonb),
  'exact_gbp60_chain', COALESCE((SELECT jsonb_agg(to_jsonb(e)) FROM exact_chain e), '[]'::jsonb)
)) AS hybrid_physical_receipt_v1_2_preflight_combo;

ROLLBACK;
