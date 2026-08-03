-- Read-only probe for the exact legacy replacement child case.
-- Determines whether child-order tracking provenance already exists and which
-- live routines can finalize supplier cost mode and complete the physical remedy.

WITH target AS (
  SELECT
    '83a2a969-56b2-4b33-99f9-aa3d68bc89d9'::uuid AS child_order_id,
    '9e7f6c25-e920-4c90-a16a-0ffb6381a3d6'::uuid AS remedy_allocation_id
), child_order AS (
  SELECT jsonb_build_object(
    'id',o.id,
    'order_ref',o.order_ref,
    'status',o.status,
    'order_type',o.order_type,
    'parent_order_id',o.parent_order_id,
    'replacement_source_dispute_line_id',o.replacement_source_dispute_line_id,
    'funded_at',o.funded_at,
    'created_at',o.created_at,
    'updated_at',o.updated_at
  ) AS value
  FROM target t
  LEFT JOIN public.orders o ON o.id=t.child_order_id
), child_tracking_allocations AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',a.id,
    'order_id',a.order_id,
    'tracking_submission_id',a.tracking_submission_id,
    'supplier_invoice_line_id',a.supplier_invoice_line_id,
    'qty_allocated',a.qty_allocated,
    'adjusted_net_value_gbp',a.adjusted_net_value_gbp,
    'created_at',a.created_at,
    'updated_at',a.updated_at
  ) ORDER BY a.created_at,a.id),'[]'::jsonb) AS value,
  COUNT(*) AS allocation_count
  FROM target t
  LEFT JOIN public.order_tracking_line_allocations a ON a.order_id=t.child_order_id
), remedy AS (
  SELECT jsonb_build_object(
    'id',r.id,
    'status',r.status,
    'approved_remedy_type',r.approved_remedy_type,
    'approved_remedy_qty',r.approved_remedy_qty,
    'supplier_cost_mode',r.supplier_cost_mode,
    'replacement_child_order_id',r.replacement_child_order_id,
    'replacement_child_tracking_allocation_id',r.replacement_child_tracking_allocation_id,
    'dispute_line_id',r.dispute_line_id,
    'updated_at',r.updated_at
  ) AS value
  FROM target t
  LEFT JOIN public.physical_exception_remedy_allocations r ON r.id=t.remedy_allocation_id
), eligible_routines AS (
  SELECT p.*
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.prokind IN ('f','p')
), completion_routines AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function_name',p.oid::regprocedure::text,
    'security_definer',p.prosecdef,
    'function_md5',md5(pg_get_functiondef(p.oid)),
    'mentions_remedy_allocation_id',pg_get_functiondef(p.oid) ILIKE '%physical_exception_remedy_allocations%',
    'mentions_replacement_child_tracking_allocation_id',pg_get_functiondef(p.oid) ILIKE '%replacement_child_tracking_allocation_id%',
    'mentions_supplier_cost_mode',pg_get_functiondef(p.oid) ILIKE '%supplier_cost_mode%',
    'mentions_completed_assignment',pg_get_functiondef(p.oid) ~* 'status\s*=\s*''completed''',
    'definition',pg_get_functiondef(p.oid)
  ) ORDER BY p.oid::regprocedure::text),'[]'::jsonb) AS value
  FROM eligible_routines p
  WHERE pg_get_functiondef(p.oid) ILIKE '%physical_exception_remedy_allocations%'
    AND (
      pg_get_functiondef(p.oid) ILIKE '%replacement_child_tracking_allocation_id%'
      OR pg_get_functiondef(p.oid) ILIKE '%supplier_cost_mode%'
      OR pg_get_functiondef(p.oid) ~* 'status\s*=\s*''completed'''
    )
)
SELECT jsonb_build_object(
  'probe','legacy_replacement_child_completion_prerequisites_v1',
  'result','READY',
  'child_order',child_order.value,
  'child_tracking_allocation_count',child_tracking_allocations.allocation_count,
  'child_tracking_allocations',child_tracking_allocations.value,
  'physical_remedy',remedy.value,
  'completion_routines',completion_routines.value,
  'classification',CASE
    WHEN child_tracking_allocations.allocation_count=0 THEN 'CHILD_TRACKING_ALLOCATION_MISSING'
    WHEN COALESCE((remedy.value->>'supplier_cost_mode'),'')='pending_supplier_evidence' THEN 'SUPPLIER_COST_CONFIRMATION_MISSING'
    WHEN remedy.value->>'replacement_child_tracking_allocation_id' IS NULL THEN 'REMEDY_CHILD_TRACKING_LINK_MISSING'
    WHEN remedy.value->>'status'='completed' THEN 'COMPLETE'
    ELSE 'READY_FOR_CONTROLLED_COMPLETION'
  END
) AS result
FROM child_order
CROSS JOIN child_tracking_allocations
CROSS JOIN remedy
CROSS JOIN completion_routines;
