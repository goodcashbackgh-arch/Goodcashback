-- Same-order free replacement routing: read-only repository/live-schema preflight.
--
-- Governing authority:
-- docs/governing-pack/architecture/
-- HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md
-- HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md
--
-- This script writes no application data and installs no objects.
-- It proves the exact schema, function, trigger and caller baseline before any build.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';
SET LOCAL TRANSACTION READ ONLY;

DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.orders') IS NULL THEN v_missing := array_append(v_missing, 'orders'); END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN v_missing := array_append(v_missing, 'supplier_invoices'); END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN v_missing := array_append(v_missing, 'supplier_invoice_lines'); END IF;
  IF to_regclass('public.order_tracking_submissions') IS NULL THEN v_missing := array_append(v_missing, 'order_tracking_submissions'); END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN v_missing := array_append(v_missing, 'order_tracking_line_allocations'); END IF;
  IF to_regclass('public.shipper_package_receipts') IS NULL THEN v_missing := array_append(v_missing, 'shipper_package_receipts'); END IF;
  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL THEN v_missing := array_append(v_missing, 'shipper_package_receipt_line_dispositions'); END IF;
  IF to_regclass('public.physical_receipt_reviews') IS NULL THEN v_missing := array_append(v_missing, 'physical_receipt_reviews'); END IF;
  IF to_regclass('public.physical_exception_remedy_allocations') IS NULL THEN v_missing := array_append(v_missing, 'physical_exception_remedy_allocations'); END IF;
  IF to_regclass('public.disputes') IS NULL THEN v_missing := array_append(v_missing, 'disputes'); END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN v_missing := array_append(v_missing, 'dispute_lines'); END IF;
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL THEN v_missing := array_append(v_missing, 'customer_review_cycle_memberships'); END IF;
  IF to_regclass('public.customer_hold_review_memberships') IS NULL THEN v_missing := array_append(v_missing, 'customer_hold_review_memberships'); END IF;
  IF to_regclass('public.shipper_shipment_batch_packages') IS NULL THEN v_missing := array_append(v_missing, 'shipper_shipment_batch_packages'); END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL THEN v_missing := array_append(v_missing, 'customer_sales_release_lines'); END IF;

  IF to_regprocedure('public.recompute_order_status(uuid)') IS NULL THEN v_missing := array_append(v_missing, 'recompute_order_status(uuid)'); END IF;
  IF to_regprocedure('public.order_has_open_child_exceptions(uuid)') IS NULL THEN v_missing := array_append(v_missing, 'order_has_open_child_exceptions(uuid)'); END IF;
  IF to_regprocedure('public.order_has_open_child_exceptions_v2(uuid)') IS NULL THEN v_missing := array_append(v_missing, 'order_has_open_child_exceptions_v2(uuid)'); END IF;
  IF to_regprocedure('public.staff_accept_replacement_outcome_v1(uuid,uuid,text)') IS NULL THEN v_missing := array_append(v_missing, 'staff_accept_replacement_outcome_v1(uuid,uuid,text)'); END IF;
  IF to_regprocedure('public.create_replacement_child_order_v2(uuid,uuid,uuid,text)') IS NULL THEN v_missing := array_append(v_missing, 'create_replacement_child_order_v2(uuid,uuid,uuid,text)'); END IF;
  IF to_regprocedure('public.physical_remedy_allocation_guard_v2()') IS NULL THEN v_missing := array_append(v_missing, 'physical_remedy_allocation_guard_v2()'); END IF;
  IF to_regprocedure('public.physical_remedy_sequence_guard_v1()') IS NULL THEN v_missing := array_append(v_missing, 'physical_remedy_sequence_guard_v1()'); END IF;
  IF to_regprocedure('public.physical_receipt_review_guard_v1()') IS NULL THEN v_missing := array_append(v_missing, 'physical_receipt_review_guard_v1()'); END IF;
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN v_missing := array_append(v_missing, 'order_audience_status_v1(uuid)'); END IF;
  IF to_regprocedure('public.recalculate_invoice_adjustment_consumption_v1(uuid)') IS NULL THEN v_missing := array_append(v_missing, 'recalculate_invoice_adjustment_consumption_v1(uuid)'); END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Same-order replacement preflight missing objects: %', array_to_string(v_missing, ', ');
  END IF;
END
$preflight$;

-- 1. Exact columns and constraints of the allocation and physical-remedy sources.
SELECT
  c.table_name,
  c.ordinal_position,
  c.column_name,
  c.data_type,
  c.udt_name,
  c.is_nullable,
  c.column_default
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.table_name IN (
    'order_tracking_line_allocations',
    'physical_exception_remedy_allocations',
    'shipper_package_receipt_line_dispositions',
    'physical_receipt_reviews',
    'disputes',
    'dispute_lines'
  )
ORDER BY c.table_name, c.ordinal_position;

SELECT
  con.conrelid::regclass::text AS table_name,
  con.conname,
  con.contype,
  pg_get_constraintdef(con.oid, true) AS definition
FROM pg_constraint con
WHERE con.conrelid IN (
  'public.order_tracking_line_allocations'::regclass,
  'public.physical_exception_remedy_allocations'::regclass,
  'public.shipper_package_receipt_line_dispositions'::regclass,
  'public.physical_receipt_reviews'::regclass
)
ORDER BY table_name, con.conname;

-- 2. Fingerprints of every protected Mini Build authority named by the spec.
WITH protected(signature) AS (
  VALUES
    ('public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,text,text,text)'::text),
    ('public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)'::text),
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
  protected.signature,
  to_regprocedure(protected.signature) IS NOT NULL AS exists_yn,
  CASE
    WHEN to_regprocedure(protected.signature) IS NULL THEN NULL
    ELSE md5(pg_get_functiondef(to_regprocedure(protected.signature)))
  END AS definition_md5,
  p.prosecdef AS security_definer,
  p.proowner::regrole::text AS owner,
  p.proacl,
  p.proconfig
FROM protected
LEFT JOIN pg_proc p ON p.oid = to_regprocedure(protected.signature)
ORDER BY protected.signature;

-- 3. Trigger bindings on protected physical tables.
SELECT
  t.tgrelid::regclass::text AS table_name,
  t.tgname,
  t.tgfoid::regprocedure::text AS trigger_function,
  pg_get_triggerdef(t.oid, true) AS trigger_definition
FROM pg_trigger t
WHERE NOT t.tgisinternal
  AND t.tgrelid IN (
    'public.physical_exception_remedy_allocations'::regclass,
    'public.physical_receipt_reviews'::regclass,
    'public.shipper_package_receipt_line_dispositions'::regclass,
    'public.order_tracking_line_allocations'::regclass,
    'public.order_tracking_submissions'::regclass,
    'public.orders'::regclass
  )
ORDER BY table_name, t.tgname;

-- 4. Exact function-source call graph for closure and allocation consumers.
WITH functions AS (
  SELECT
    p.oid,
    n.nspname,
    p.proname,
    p.oid::regprocedure::text AS signature,
    lower(pg_get_functiondef(p.oid)) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
)
SELECT
  signature,
  (position('order_has_open_child_exceptions(' in definition) > 0) AS calls_child_blocker_v1,
  (position('order_has_open_child_exceptions_v2(' in definition) > 0) AS calls_child_blocker_v2,
  (position('recompute_order_status(' in definition) > 0) AS calls_recompute,
  (position('order_tracking_line_allocations' in definition) > 0) AS reads_tracking_allocations,
  (position('qty_allocated' in definition) > 0) AS reads_allocation_quantity,
  (position('physical_exception_remedy_allocations' in definition) > 0) AS reads_physical_remedies,
  (position('replacement_child_order_id' in definition) > 0) AS reads_child_identity
FROM functions
WHERE position('order_has_open_child_exceptions(' in definition) > 0
   OR position('order_has_open_child_exceptions_v2(' in definition) > 0
   OR position('recompute_order_status(' in definition) > 0
   OR (
     position('order_tracking_line_allocations' in definition) > 0
     AND position('qty_allocated' in definition) > 0
   )
ORDER BY signature;

-- 5. Views that consume raw tracking allocation quantity.
SELECT
  v.schemaname,
  v.viewname,
  (position('order_tracking_line_allocations' in lower(v.definition)) > 0) AS reads_allocations,
  (position('qty_allocated' in lower(v.definition)) > 0) AS reads_qty,
  (position('replacement_child_order_id' in lower(v.definition)) > 0) AS reads_child_identity,
  md5(v.definition) AS definition_md5
FROM pg_views v
WHERE v.schemaname = 'public'
  AND position('order_tracking_line_allocations' in lower(v.definition)) > 0
ORDER BY v.viewname;

-- 6. Current new-case candidates and legacy-child inventory.
SELECT
  o.id AS child_order_id,
  o.order_ref AS child_order_ref,
  o.status AS child_status,
  o.parent_order_id,
  parent.order_ref AS parent_order_ref,
  o.replacement_source_dispute_line_id,
  d.id AS dispute_id,
  d.status AS dispute_status,
  r.id AS remedy_id,
  r.status AS remedy_status,
  r.supplier_cost_mode,
  r.replacement_child_order_id,
  r.replacement_child_tracking_allocation_id
FROM public.orders o
LEFT JOIN public.orders parent ON parent.id = o.parent_order_id
LEFT JOIN public.dispute_lines dl ON dl.id = o.replacement_source_dispute_line_id
LEFT JOIN public.disputes d ON d.id = dl.dispute_id
LEFT JOIN public.physical_exception_remedy_allocations r
  ON r.dispute_line_id = dl.id
WHERE o.order_type = 'replacement_child'
ORDER BY o.created_at DESC, o.id;

SELECT
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
  r.replacement_child_order_id,
  r.replacement_child_tracking_allocation_id,
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

-- 7. Existing raw/effective-risk sample by supplier line.
SELECT
  si.order_id,
  sil.id AS supplier_invoice_line_id,
  COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS authoritative_line_qty,
  COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)::numeric AS authoritative_line_amount_gbp,
  COALESCE(SUM(otla.qty_allocated), 0)::numeric AS raw_allocated_qty,
  COALESCE(SUM(otla.adjusted_net_value_gbp), 0)::numeric AS raw_allocated_value_gbp,
  COUNT(otla.id)::integer AS allocation_count
FROM public.supplier_invoices si
JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
LEFT JOIN public.order_tracking_line_allocations otla
  ON otla.order_id = si.order_id
 AND otla.supplier_invoice_line_id = sil.id
GROUP BY si.order_id, sil.id, sil.qty_confirmed, sil.qty, sil.amount_confirmed, sil.amount_inc_vat_gbp
HAVING COALESCE(SUM(otla.qty_allocated), 0) > COALESCE(sil.qty_confirmed, sil.qty, 0)
    OR COALESCE(SUM(otla.adjusted_net_value_gbp), 0) > COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)
ORDER BY si.order_id, sil.id;

ROLLBACK;
