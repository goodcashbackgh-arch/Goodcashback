-- Final read-only governed DB check before exact-routing build.
-- Scope is limited to the contracts required by the governing addendum.
-- No DDL, DML, temporary objects or persistent changes.

WITH function_targets(identity) AS (
  VALUES
    ('public.customer_review_cycle_candidates_v1(uuid)'),
    ('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'),
    ('public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'),
    ('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'),
    ('public.shipper_shipment_batch_candidates_v1()'),
    ('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'),
    ('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)')
), function_contracts AS (
  SELECT
    ft.identity,
    to_regprocedure(ft.identity) IS NOT NULL AS present,
    CASE WHEN to_regprocedure(ft.identity) IS NOT NULL THEN pg_get_userbyid(p.proowner) END AS owner,
    CASE WHEN to_regprocedure(ft.identity) IS NOT NULL THEN p.prosecdef END AS security_definer,
    CASE WHEN to_regprocedure(ft.identity) IS NOT NULL THEN p.provolatile END AS volatility,
    CASE WHEN to_regprocedure(ft.identity) IS NOT NULL THEN p.proconfig END AS proconfig,
    CASE WHEN to_regprocedure(ft.identity) IS NOT NULL THEN p.proacl END AS acl,
    CASE WHEN to_regprocedure(ft.identity) IS NOT NULL THEN md5(pg_get_functiondef(p.oid)) END AS definition_md5,
    CASE WHEN to_regprocedure(ft.identity) IS NOT NULL THEN pg_get_functiondef(p.oid) END AS definition
  FROM function_targets ft
  LEFT JOIN pg_proc p ON p.oid = to_regprocedure(ft.identity)
), membership_columns AS (
  SELECT
    ordinal_position,
    column_name,
    data_type,
    udt_name,
    is_nullable,
    column_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'customer_review_cycle_memberships'
  ORDER BY ordinal_position
), membership_constraints AS (
  SELECT
    conname,
    contype,
    pg_get_constraintdef(oid, true) AS definition
  FROM pg_constraint
  WHERE conrelid = 'public.customer_review_cycle_memberships'::regclass
  ORDER BY conname
), membership_indexes AS (
  SELECT indexname, indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'customer_review_cycle_memberships'
  ORDER BY indexname
), review_link_contract AS (
  SELECT
    ordinal_position,
    column_name,
    data_type,
    udt_name,
    is_nullable,
    column_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'customer_order_review_links'
  ORDER BY ordinal_position
), supervisor_function_candidates AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_functiondef(p.oid) AS definition,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.proacl AS acl
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname LIKE 'staff_decide_physical_receipt_review%'
  ORDER BY p.oid::regprocedure::text
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
      'physical_exception_remedy_allocations',
      'customer_review_cycle_memberships',
      'customer_order_review_links',
      'order_tracking_line_allocations'
    )
  ORDER BY c.relname, t.tgname
), dependency_edges AS (
  SELECT DISTINCT
    caller.oid::regprocedure::text AS caller,
    callee.oid::regprocedure::text AS callee
  FROM pg_depend d
  JOIN pg_proc caller ON caller.oid = d.objid
  JOIN pg_proc callee ON callee.oid = d.refobjid
  WHERE d.classid = 'pg_proc'::regclass
    AND d.refclassid = 'pg_proc'::regclass
    AND (
      caller.oid IN (
        to_regprocedure('public.customer_review_cycle_candidates_v1(uuid)'),
        to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'),
        to_regprocedure('public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'),
        to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'),
        to_regprocedure('public.shipper_shipment_batch_candidates_v1()'),
        to_regprocedure('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)')
      )
      OR callee.oid IN (
        to_regprocedure('public.customer_review_cycle_candidates_v1(uuid)'),
        to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'),
        to_regprocedure('public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'),
        to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'),
        to_regprocedure('public.shipper_shipment_batch_candidates_v1()'),
        to_regprocedure('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)')
      )
    )
  ORDER BY caller, callee
), exact_examples AS (
  SELECT
    p.order_id,
    p.tracking_submission_id,
    p.tracking_line_allocation_id,
    p.supplier_invoice_line_id,
    p.allocated_qty,
    p.physical_clean_qty,
    p.physical_exception_qty,
    p.reviewed_qty,
    p.review_available_qty,
    p.shipment_available_qty,
    p.remedy_assigned_qty,
    p.position_valid_yn,
    p.position_blocker,
    p.source_receipt_id,
    p.source_receipt_model,
    e.raw_qty_allocated,
    e.transferred_out_qty,
    e.effective_qty_allocated,
    e.raw_adjusted_net_value_gbp,
    e.transferred_out_adjusted_net_value_gbp,
    e.effective_adjusted_net_value_gbp,
    e.is_same_order_successor,
    e.source_allocation_id,
    e.replacement_route_id
  FROM public.internal_tracking_allocation_fulfilment_position_v1(NULL,NULL,NULL) p
  LEFT JOIN public.tracking_allocation_effective_entitlement_v1(NULL,NULL) e
    ON e.allocation_id = p.tracking_line_allocation_id
  WHERE p.source_receipt_model = 'v2_exact'
  ORDER BY p.source_receipt_id DESC NULLS LAST, p.tracking_line_allocation_id
  LIMIT 50
), current_membership_examples AS (
  SELECT
    m.id,
    m.review_link_id,
    m.order_id,
    m.tracking_line_allocation_id,
    m.review_qty,
    m.receipt_recorded_at,
    m.membership_status,
    m.membership_fingerprint,
    m.created_at,
    l.expires_at AS review_link_expires_at,
    l.is_active AS review_link_is_active
  FROM public.customer_review_cycle_memberships m
  JOIN public.customer_order_review_links l ON l.id = m.review_link_id
  ORDER BY m.created_at DESC
  LIMIT 50
), security_contract AS (
  SELECT
    c.relname AS relation_name,
    pg_get_userbyid(c.relowner) AS owner,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced,
    c.relacl AS acl
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN (
      'customer_review_cycle_memberships',
      'customer_order_review_links',
      'physical_receipt_reviews',
      'physical_exception_remedy_allocations',
      'shipper_package_receipts',
      'physical_replacement_same_order_routes'
    )
  ORDER BY c.relname
)
SELECT jsonb_build_object(
  'all_named_functions_present', NOT EXISTS (SELECT 1 FROM function_contracts WHERE NOT present),
  'function_contracts', COALESCE((SELECT jsonb_agg(to_jsonb(function_contracts) ORDER BY identity) FROM function_contracts), '[]'::jsonb),
  'supervisor_function_candidates', COALESCE((SELECT jsonb_agg(to_jsonb(supervisor_function_candidates) ORDER BY identity) FROM supervisor_function_candidates), '[]'::jsonb),
  'membership_columns', COALESCE((SELECT jsonb_agg(to_jsonb(membership_columns) ORDER BY ordinal_position) FROM membership_columns), '[]'::jsonb),
  'membership_constraints', COALESCE((SELECT jsonb_agg(to_jsonb(membership_constraints) ORDER BY conname) FROM membership_constraints), '[]'::jsonb),
  'membership_indexes', COALESCE((SELECT jsonb_agg(to_jsonb(membership_indexes) ORDER BY indexname) FROM membership_indexes), '[]'::jsonb),
  'review_link_contract', COALESCE((SELECT jsonb_agg(to_jsonb(review_link_contract) ORDER BY ordinal_position) FROM review_link_contract), '[]'::jsonb),
  'relevant_triggers', COALESCE((SELECT jsonb_agg(to_jsonb(relevant_triggers) ORDER BY table_name, trigger_name) FROM relevant_triggers), '[]'::jsonb),
  'dependency_edges', COALESCE((SELECT jsonb_agg(to_jsonb(dependency_edges) ORDER BY caller, callee) FROM dependency_edges), '[]'::jsonb),
  'exact_examples', COALESCE((SELECT jsonb_agg(to_jsonb(exact_examples)) FROM exact_examples), '[]'::jsonb),
  'current_membership_examples', COALESCE((SELECT jsonb_agg(to_jsonb(current_membership_examples)) FROM current_membership_examples), '[]'::jsonb),
  'security_contract', COALESCE((SELECT jsonb_agg(to_jsonb(security_contract) ORDER BY relation_name) FROM security_contract), '[]'::jsonb)
) AS exact_routing_final_governed_db_check;
