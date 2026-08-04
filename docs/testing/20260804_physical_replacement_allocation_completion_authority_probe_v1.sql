-- Read-only live dependency probe for physical replacement allocation completion.
-- Identifies triggers and ordinary functions/procedures that reference the allocation table,
-- especially logic that can move replacement allocations into a terminal completed state.

WITH trigger_rows AS (
  SELECT jsonb_agg(jsonb_build_object(
    'trigger_name',t.tgname,
    'table_name',c.relname,
    'enabled',t.tgenabled,
    'function_name',p.oid::regprocedure::text,
    'function_md5',md5(pg_get_functiondef(p.oid)),
    'function_definition',pg_get_functiondef(p.oid)
  ) ORDER BY t.tgname) AS value
  FROM pg_trigger t
  JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN pg_proc p ON p.oid=t.tgfoid
  WHERE NOT t.tgisinternal
    AND n.nspname='public'
    AND c.relname='physical_exception_remedy_allocations'
), eligible_routines AS (
  SELECT p.*
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.prokind IN ('f','p')
), function_rows AS (
  SELECT jsonb_agg(jsonb_build_object(
    'function_name',p.oid::regprocedure::text,
    'security_definer',p.prosecdef,
    'function_md5',md5(pg_get_functiondef(p.oid)),
    'mentions_completed',pg_get_functiondef(p.oid) ILIKE '%completed%',
    'mentions_in_progress',pg_get_functiondef(p.oid) ILIKE '%in_progress%',
    'mentions_replacement_child_order_id',pg_get_functiondef(p.oid) ILIKE '%replacement_child_order_id%',
    'definition',pg_get_functiondef(p.oid)
  ) ORDER BY p.oid::regprocedure::text) AS value
  FROM eligible_routines p
  WHERE pg_get_functiondef(p.oid) ILIKE '%physical_exception_remedy_allocations%'
), exact_allocation AS (
  SELECT jsonb_build_object(
    'id',r.id,
    'status',r.status,
    'approved_remedy_type',r.approved_remedy_type,
    'approved_remedy_qty',r.approved_remedy_qty,
    'replacement_child_order_id',r.replacement_child_order_id,
    'replacement_child_tracking_allocation_id',r.replacement_child_tracking_allocation_id,
    'dispute_line_id',r.dispute_line_id,
    'updated_at',r.updated_at
  ) AS value
  FROM public.physical_exception_remedy_allocations r
  WHERE r.id='9e7f6c25-e920-4c90-a16a-0ffb6381a3d6'::uuid
)
SELECT jsonb_build_object(
  'probe','physical_replacement_allocation_completion_authority_v1',
  'result','READY',
  'allocation',exact_allocation.value,
  'table_triggers',COALESCE(trigger_rows.value,'[]'::jsonb),
  'referencing_functions',COALESCE(function_rows.value,'[]'::jsonb)
) AS result
FROM trigger_rows
CROSS JOIN function_rows
CROSS JOIN exact_allocation;
