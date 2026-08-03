-- Corrected read-only combo for same-order free replacement preflight.
-- Returns only the exact outputs needed for implementation.

BEGIN;
SET LOCAL TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- RESULT 1: protected Mini Build fingerprints.
WITH protected(signature) AS (
  VALUES
    ('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::text),
    ('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)'::text),
    ('public.physical_remedy_allocation_guard_v2()'::text),
    ('public.physical_remedy_sequence_guard_v1()'::text),
    ('public.physical_receipt_review_guard_v1()'::text),
    ('public.order_has_open_child_exceptions_v2(uuid)'::text),
    ('public.create_replacement_child_order_v2(uuid,uuid,uuid,text)'::text),
    ('public.staff_accept_replacement_outcome_v1(uuid,uuid,text)'::text)
)
SELECT
  'protected_fingerprints' AS result_set,
  p.signature,
  to_regprocedure(p.signature) IS NOT NULL AS exists_yn,
  CASE WHEN to_regprocedure(p.signature) IS NOT NULL
       THEN md5(pg_get_functiondef(to_regprocedure(p.signature))) END AS definition_md5
FROM protected p
ORDER BY p.signature;

-- RESULT 2: protected trigger bindings.
SELECT
  'protected_triggers' AS result_set,
  t.tgrelid::regclass::text AS table_name,
  t.tgname,
  t.tgfoid::regprocedure::text AS trigger_function,
  pg_get_triggerdef(t.oid, true) AS trigger_definition
FROM pg_trigger t
WHERE NOT t.tgisinternal
  AND t.tgrelid IN (
    'public.physical_exception_remedy_allocations'::regclass,
    'public.physical_receipt_reviews'::regclass,
    'public.shipper_package_receipt_line_dispositions'::regclass
  )
ORDER BY table_name, t.tgname;

-- RESULT 3: exact function call graph for blockers, recompute and raw allocation quantity.
WITH f AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    lower(pg_get_functiondef(p.oid)) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
)
SELECT
  'function_call_graph' AS result_set,
  signature,
  position('order_has_open_child_exceptions(' in definition) > 0 AS calls_child_blocker_v1,
  position('order_has_open_child_exceptions_v2(' in definition) > 0 AS calls_child_blocker_v2,
  position('recompute_order_status(' in definition) > 0 AS calls_recompute,
  position('order_tracking_line_allocations' in definition) > 0 AS reads_allocations,
  position('qty_allocated' in definition) > 0 AS reads_qty
FROM f
WHERE position('order_has_open_child_exceptions(' in definition) > 0
   OR position('order_has_open_child_exceptions_v2(' in definition) > 0
   OR position('recompute_order_status(' in definition) > 0
   OR (
     position('order_tracking_line_allocations' in definition) > 0
     AND position('qty_allocated' in definition) > 0
   )
ORDER BY signature;

-- RESULT 4: views that consume allocation quantity.
SELECT
  'raw_allocation_views' AS result_set,
  v.viewname,
  md5(v.definition) AS definition_md5
FROM pg_views v
WHERE v.schemaname = 'public'
  AND position('order_tracking_line_allocations' in lower(v.definition)) > 0
  AND position('qty_allocated' in lower(v.definition)) > 0
ORDER BY v.viewname;

-- RESULT 5: open physical replacement remedies without a child.
SELECT
  'open_replacement_remedies' AS result_set,
  r.id AS remedy_id,
  review_row.order_id,
  d.id AS dispute_id,
  dl.id AS dispute_line_id,
  r.tracking_line_allocation_id AS source_tracking_allocation_id,
  r.supplier_invoice_line_id,
  r.approved_remedy_qty,
  r.customer_commercial_value_gbp,
  r.supplier_cost_mode,
  r.status AS remedy_status,
  disp.disposition_type,
  disp.quantity AS affected_disposition_qty
FROM public.physical_exception_remedy_allocations r
JOIN public.physical_receipt_reviews review_row
  ON review_row.id = r.physical_receipt_review_id
JOIN public.shipper_package_receipt_line_dispositions disp
  ON disp.id = r.receipt_line_disposition_id
LEFT JOIN public.dispute_lines dl ON dl.id = r.dispute_line_id
LEFT JOIN public.disputes d ON d.id = dl.dispute_id
WHERE r.approved_remedy_type = 'replacement'
  AND r.replacement_child_order_id IS NULL
ORDER BY r.created_at DESC, r.id;

-- RESULT 6: legacy replacement children inventory.
SELECT
  'legacy_replacement_children' AS result_set,
  o.id AS child_order_id,
  o.order_ref AS child_order_ref,
  o.status AS child_status,
  o.parent_order_id,
  parent.order_ref AS parent_order_ref,
  o.replacement_source_dispute_line_id
FROM public.orders o
LEFT JOIN public.orders parent ON parent.id = o.parent_order_id
WHERE o.order_type = 'replacement_child'
ORDER BY o.created_at DESC, o.id;

-- RESULT 7: corrected quantity-only over-allocation check.
SELECT
  'quantity_overallocation' AS result_set,
  si.order_id,
  sil.id AS supplier_invoice_line_id,
  COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS authoritative_line_qty,
  COALESCE(SUM(otla.qty_allocated), 0)::numeric AS raw_allocated_qty,
  COUNT(otla.id)::integer AS allocation_count
FROM public.supplier_invoices si
JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
LEFT JOIN public.order_tracking_line_allocations otla
  ON otla.order_id = si.order_id
 AND otla.supplier_invoice_line_id = sil.id
GROUP BY si.order_id, sil.id, sil.qty_confirmed, sil.qty
HAVING COALESCE(SUM(otla.qty_allocated), 0)
       > COALESCE(sil.qty_confirmed, sil.qty, 0) + 0.0001
ORDER BY si.order_id, sil.id;

ROLLBACK;
