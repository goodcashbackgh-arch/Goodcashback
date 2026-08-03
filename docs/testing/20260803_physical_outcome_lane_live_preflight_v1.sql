-- Read-only live preflight for HYBRID_PHYSICAL_RECEIPT_OUTCOME_LANE_GROUPING_ADDENDUM_v1.
-- Run as one query in Supabase SQL editor. Makes no writes.

WITH required_relations(name) AS (
  VALUES
    ('orders'),
    ('physical_receipt_reviews'),
    ('physical_exception_remedy_allocations'),
    ('disputes'),
    ('dispute_lines'),
    ('dispute_messages'),
    ('physical_receipt_review_dispute_links'),
    ('physical_replacement_same_order_routes'),
    ('order_tracking_submissions'),
    ('order_tracking_line_allocations')
), relation_state AS (
  SELECT
    name,
    to_regclass('public.' || name) IS NOT NULL AS installed
  FROM required_relations
), candidate_evidence_tables AS (
  SELECT
    c.relname AS table_name,
    obj_description(c.oid, 'pg_class') AS comment
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r','p','v','m')
    AND (
      c.relname ILIKE '%evidence%'
      OR c.relname ILIKE '%credit%note%'
      OR c.relname ILIKE '%refund%document%'
      OR c.relname ILIKE '%attachment%'
      OR c.relname ILIKE '%proof%'
      OR c.relname ILIKE '%collection%'
    )
), relevant_columns AS (
  SELECT
    table_name,
    jsonb_agg(
      jsonb_build_object(
        'column_name', column_name,
        'data_type', data_type,
        'udt_name', udt_name,
        'nullable', is_nullable,
        'default', column_default
      ) ORDER BY ordinal_position
    ) AS columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN (
      'physical_receipt_reviews',
      'physical_exception_remedy_allocations',
      'disputes',
      'dispute_lines',
      'dispute_messages',
      'physical_receipt_review_dispute_links',
      'physical_replacement_same_order_routes'
    )
  GROUP BY table_name
), relevant_constraints AS (
  SELECT
    c.relname AS table_name,
    jsonb_agg(
      jsonb_build_object(
        'constraint_name', con.conname,
        'constraint_type', con.contype,
        'definition', pg_get_constraintdef(con.oid, true)
      ) ORDER BY con.conname
    ) AS constraints
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN (
      'physical_receipt_reviews',
      'physical_exception_remedy_allocations',
      'disputes',
      'dispute_lines',
      'dispute_messages',
      'physical_receipt_review_dispute_links',
      'physical_replacement_same_order_routes'
    )
  GROUP BY c.relname
), function_state AS (
  SELECT jsonb_build_object(
    'operator_update_dispute_retailer_update', jsonb_build_object(
      'installed', to_regprocedure('public.operator_update_dispute_retailer_update(uuid,text,text)') IS NOT NULL,
      'md5', CASE WHEN to_regprocedure('public.operator_update_dispute_retailer_update(uuid,text,text)') IS NULL THEN NULL
                  ELSE md5(pg_get_functiondef('public.operator_update_dispute_retailer_update(uuid,text,text)'::regprocedure)) END,
      'definition', CASE WHEN to_regprocedure('public.operator_update_dispute_retailer_update(uuid,text,text)') IS NULL THEN NULL
                         ELSE pg_get_functiondef('public.operator_update_dispute_retailer_update(uuid,text,text)'::regprocedure) END
    ),
    'staff_decide_physical_receipt_review_v2', jsonb_build_object(
      'installed', to_regprocedure('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)') IS NOT NULL,
      'md5', CASE WHEN to_regprocedure('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)') IS NULL THEN NULL
                  ELSE md5(pg_get_functiondef('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)'::regprocedure)) END
    ),
    'staff_accept_same_order_free_replacement_v1', jsonb_build_object(
      'installed', to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)') IS NOT NULL,
      'md5', CASE WHEN to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)') IS NULL THEN NULL
                  ELSE md5(pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure)) END
    ),
    'operator_allocate_same_order_replacement_tracking_v1', jsonb_build_object(
      'installed', to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)') IS NOT NULL,
      'md5', CASE WHEN to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)') IS NULL THEN NULL
                  ELSE md5(pg_get_functiondef('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)'::regprocedure)) END
    )
  ) AS functions
), existing_lane_objects AS (
  SELECT jsonb_agg(jsonb_build_object(
    'object_name', c.relname,
    'object_type', c.relkind,
    'comment', obj_description(c.oid, 'pg_class')
  ) ORDER BY c.relname) AS objects
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname='public'
    AND (
      c.relname ILIKE '%outcome%lane%'
      OR c.relname ILIKE '%lane%item%'
      OR c.relname ILIKE '%evidence%link%'
    )
)
SELECT jsonb_build_object(
  'preflight', 'physical_outcome_lane_grouping_v1',
  'read_only', true,
  'relations', (SELECT jsonb_object_agg(name, installed) FROM relation_state),
  'existing_lane_objects', COALESCE((SELECT objects FROM existing_lane_objects), '[]'::jsonb),
  'candidate_evidence_tables', COALESCE((SELECT jsonb_agg(jsonb_build_object('table_name', table_name, 'comment', comment) ORDER BY table_name) FROM candidate_evidence_tables), '[]'::jsonb),
  'relevant_columns', COALESCE((SELECT jsonb_object_agg(table_name, columns) FROM relevant_columns), '{}'::jsonb),
  'relevant_constraints', COALESCE((SELECT jsonb_object_agg(table_name, constraints) FROM relevant_constraints), '{}'::jsonb),
  'functions', (SELECT functions FROM function_state),
  'protected_guard_fingerprints', jsonb_build_object(
    'physical_remedy_allocation_guard_v2', md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
    'physical_remedy_sequence_guard_v1', md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)),
    'physical_receipt_review_guard_v1', md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))
  )
) AS result;
