-- Read-only live preflight for the exact-routing / same-order replacement intersection.
-- No DDL, DML, function calls with writes, temporary objects or persistent changes.

WITH required_objects(name, present) AS (
  VALUES
    ('physical_replacement_same_order_routes', to_regclass('public.physical_replacement_same_order_routes') IS NOT NULL),
    ('tracking_allocation_effective_entitlement_v1(uuid,uuid)', to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)') IS NOT NULL),
    ('staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)', to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)') IS NOT NULL),
    ('operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)', to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)') IS NOT NULL),
    ('physical_receipt_reviews', to_regclass('public.physical_receipt_reviews') IS NOT NULL),
    ('physical_exception_remedy_allocations', to_regclass('public.physical_exception_remedy_allocations') IS NOT NULL),
    ('order_tracking_line_allocations', to_regclass('public.order_tracking_line_allocations') IS NOT NULL),
    ('shipper_package_receipts', to_regclass('public.shipper_package_receipts') IS NOT NULL),
    ('shipper_package_receipt_line_dispositions', to_regclass('public.shipper_package_receipt_line_dispositions') IS NOT NULL)
),
required_columns(table_name, column_name) AS (
  VALUES
    ('physical_replacement_same_order_routes','id'),
    ('physical_replacement_same_order_routes','physical_remedy_allocation_id'),
    ('physical_replacement_same_order_routes','physical_receipt_review_id'),
    ('physical_replacement_same_order_routes','order_id'),
    ('physical_replacement_same_order_routes','supplier_invoice_line_id'),
    ('physical_replacement_same_order_routes','source_tracking_line_allocation_id'),
    ('physical_replacement_same_order_routes','replacement_qty'),
    ('physical_replacement_same_order_routes','transferred_adjusted_net_value_gbp'),
    ('physical_replacement_same_order_routes','route_status'),
    ('physical_replacement_same_order_routes','successor_tracking_submission_id'),
    ('physical_replacement_same_order_routes','successor_tracking_line_allocation_id')
),
column_results AS (
  SELECT
    rc.table_name,
    rc.column_name,
    EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = rc.table_name
        AND c.column_name = rc.column_name
    ) AS present
  FROM required_columns rc
),
route_status_check AS (
  SELECT
    COALESCE(array_agg(DISTINCT r.route_status ORDER BY r.route_status), ARRAY[]::text[]) AS installed_values,
    COUNT(*) FILTER (WHERE r.route_status NOT IN ('approved_waiting_tracking','tracking_allocated','cancelled')) AS invalid_count
  FROM public.physical_replacement_same_order_routes r
),
route_shape_check AS (
  SELECT
    COUNT(*) AS route_count,
    COUNT(*) FILTER (
      WHERE route_status = 'approved_waiting_tracking'
        AND (successor_tracking_submission_id IS NOT NULL OR successor_tracking_line_allocation_id IS NOT NULL)
    ) AS waiting_with_successor_count,
    COUNT(*) FILTER (
      WHERE route_status = 'tracking_allocated'
        AND (successor_tracking_submission_id IS NULL OR successor_tracking_line_allocation_id IS NULL)
    ) AS allocated_missing_successor_count,
    COUNT(*) FILTER (
      WHERE replacement_qty <= 0 OR replacement_qty <> trunc(replacement_qty)
    ) AS invalid_quantity_count,
    COUNT(*) FILTER (
      WHERE transferred_adjusted_net_value_gbp <= 0
    ) AS invalid_value_count
  FROM public.physical_replacement_same_order_routes
),
provenance_check AS (
  SELECT
    COUNT(*) FILTER (WHERE pra.id IS NULL) AS missing_remedy_count,
    COUNT(*) FILTER (WHERE prr.id IS NULL) AS missing_review_count,
    COUNT(*) FILTER (WHERE src.id IS NULL) AS missing_source_allocation_count,
    COUNT(*) FILTER (WHERE sil.id IS NULL) AS missing_supplier_line_count,
    COUNT(*) FILTER (
      WHERE succ.id IS NOT NULL
        AND (succ.order_id IS DISTINCT FROM r.order_id
          OR succ.supplier_invoice_line_id IS DISTINCT FROM r.supplier_invoice_line_id)
    ) AS successor_cross_order_or_line_count,
    COUNT(*) FILTER (
      WHERE succ.id IS NOT NULL
        AND (succ.qty_allocated IS DISTINCT FROM r.replacement_qty
          OR succ.adjusted_net_value_gbp IS DISTINCT FROM r.transferred_adjusted_net_value_gbp)
    ) AS successor_quantity_or_value_mismatch_count
  FROM public.physical_replacement_same_order_routes r
  LEFT JOIN public.physical_exception_remedy_allocations pra ON pra.id = r.physical_remedy_allocation_id
  LEFT JOIN public.physical_receipt_reviews prr ON prr.id = r.physical_receipt_review_id
  LEFT JOIN public.order_tracking_line_allocations src ON src.id = r.source_tracking_line_allocation_id
  LEFT JOIN public.supplier_invoice_lines sil ON sil.id = r.supplier_invoice_line_id
  LEFT JOIN public.order_tracking_line_allocations succ ON succ.id = r.successor_tracking_line_allocation_id
),
effective_check AS (
  SELECT
    COUNT(*) AS allocation_count,
    COUNT(*) FILTER (WHERE effective_qty_allocated < 0) AS negative_effective_qty_count,
    COUNT(*) FILTER (WHERE effective_adjusted_net_value_gbp < 0) AS negative_effective_value_count,
    COUNT(*) FILTER (
      WHERE transferred_out_qty > raw_qty_allocated
         OR transferred_out_adjusted_net_value_gbp > raw_adjusted_net_value_gbp
    ) AS over_superseded_count,
    COUNT(*) FILTER (
      WHERE is_same_order_successor
        AND (source_allocation_id IS NULL OR replacement_route_id IS NULL)
    ) AS successor_missing_route_identity_count
  FROM public.tracking_allocation_effective_entitlement_v1(NULL, NULL)
),
function_contracts AS (
  SELECT
    p.oid::regprocedure::text AS function_identity,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.provolatile,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    COALESCE(array_to_json(p.proacl), '[]'::json) AS acl
  FROM pg_proc p
  WHERE p.oid IN (
    to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)'),
    to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'),
    to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)')
  )
),
trigger_inventory AS (
  SELECT
    c.relname AS table_name,
    t.tgname AS trigger_name,
    p.oid::regprocedure::text AS trigger_function,
    t.tgenabled
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE n.nspname = 'public'
    AND NOT t.tgisinternal
    AND c.relname IN (
      'physical_replacement_same_order_routes',
      'physical_receipt_reviews',
      'physical_exception_remedy_allocations',
      'shipper_package_receipts',
      'order_tracking_line_allocations'
    )
)
SELECT jsonb_build_object(
  'overall_ready',
    NOT EXISTS (SELECT 1 FROM required_objects WHERE NOT present)
    AND NOT EXISTS (SELECT 1 FROM column_results WHERE NOT present)
    AND (SELECT invalid_count = 0 FROM route_status_check)
    AND (SELECT waiting_with_successor_count = 0
              AND allocated_missing_successor_count = 0
              AND invalid_quantity_count = 0
              AND invalid_value_count = 0
         FROM route_shape_check)
    AND (SELECT missing_remedy_count = 0
              AND missing_review_count = 0
              AND missing_source_allocation_count = 0
              AND missing_supplier_line_count = 0
              AND successor_cross_order_or_line_count = 0
              AND successor_quantity_or_value_mismatch_count = 0
         FROM provenance_check)
    AND (SELECT negative_effective_qty_count = 0
              AND negative_effective_value_count = 0
              AND over_superseded_count = 0
              AND successor_missing_route_identity_count = 0
         FROM effective_check),
  'required_objects', (SELECT jsonb_agg(to_jsonb(required_objects) ORDER BY name) FROM required_objects),
  'required_columns', (SELECT jsonb_agg(to_jsonb(column_results) ORDER BY table_name, column_name) FROM column_results),
  'route_statuses', (SELECT to_jsonb(route_status_check) FROM route_status_check),
  'route_shape', (SELECT to_jsonb(route_shape_check) FROM route_shape_check),
  'provenance', (SELECT to_jsonb(provenance_check) FROM provenance_check),
  'effective_entitlement', (SELECT to_jsonb(effective_check) FROM effective_check),
  'function_contracts', COALESCE((SELECT jsonb_agg(to_jsonb(function_contracts) ORDER BY function_identity) FROM function_contracts), '[]'::jsonb),
  'trigger_inventory', COALESCE((SELECT jsonb_agg(to_jsonb(trigger_inventory) ORDER BY table_name, trigger_name) FROM trigger_inventory), '[]'::jsonb)
) AS exact_routing_same_order_integration_preflight;
