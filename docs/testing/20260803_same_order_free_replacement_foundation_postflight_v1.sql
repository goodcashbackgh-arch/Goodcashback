-- One-run postflight for the additive same-order free-replacement foundation.
-- Run only after applying migration 20260803203000_same_order_free_replacement_foundation_v1.sql.
-- Read-only. One JSON result.

BEGIN;
SET LOCAL TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

WITH
protected(signature, expected_md5) AS (
  VALUES
    ('public.physical_remedy_allocation_guard_v2()'::text, 'f82d15d2de1199f9ab841d8c1ad44738'::text),
    ('public.physical_remedy_sequence_guard_v1()'::text, '3c5067f31d4f2112207e02d1f307e233'::text),
    ('public.physical_receipt_review_guard_v1()'::text, 'eaaf737e29580feb56272c55e6f1f679'::text),
    ('public.create_replacement_child_order_v2(uuid,uuid,uuid,text)'::text, '03b481778c539cfe0d00ddf5ceb3e474'::text),
    ('public.order_has_open_child_exceptions_v2(uuid)'::text, '5738715ff7877344b10c1fb81e59f8db'::text),
    ('public.staff_accept_replacement_outcome_v1(uuid,uuid,text)'::text, '311c1fa3b5b7b8ce04bcd72379caf299'::text),
    ('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::text, '32ecb4c4bb7f4809e88a35241a8cf4d5'::text),
    ('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)'::text, '63822bed13e02b23cd412d1ae3e5d915'::text)
),
fingerprint_check AS (
  SELECT
    p.signature,
    p.expected_md5,
    CASE WHEN to_regprocedure(p.signature) IS NULL THEN NULL
         ELSE md5(pg_get_functiondef(to_regprocedure(p.signature))) END AS actual_md5,
    to_regprocedure(p.signature) IS NOT NULL AS exists_yn,
    CASE WHEN to_regprocedure(p.signature) IS NULL THEN false
         ELSE md5(pg_get_functiondef(to_regprocedure(p.signature))) = p.expected_md5 END AS unchanged_yn
  FROM protected p
),
foundation_objects AS (
  SELECT jsonb_build_object(
    'route_table_exists', to_regclass('public.physical_replacement_same_order_routes') IS NOT NULL,
    'resolver_exists', to_regprocedure('public.tracking_allocation_effective_entitlement_v1(uuid,uuid)') IS NOT NULL,
    'route_table_rls_enabled', COALESCE((
      SELECT c.relrowsecurity
      FROM pg_class c
      WHERE c.oid = to_regclass('public.physical_replacement_same_order_routes')
    ), false),
    'route_rows', COALESCE((SELECT count(*) FROM public.physical_replacement_same_order_routes), 0)
  ) AS value
),
child_count AS (
  SELECT count(*)::integer AS legacy_child_count
  FROM public.orders
  WHERE order_type = 'replacement_child'
),
route_child_violation AS (
  SELECT count(*)::integer AS violation_count
  FROM public.physical_replacement_same_order_routes r
  JOIN public.physical_exception_remedy_allocations pra
    ON pra.id = r.physical_remedy_allocation_id
  WHERE pra.replacement_child_order_id IS NOT NULL
     OR pra.replacement_child_tracking_allocation_id IS NOT NULL
),
route_integrity AS (
  SELECT
    count(*)::integer AS route_count,
    count(*) FILTER (WHERE route_status = 'approved_waiting_tracking')::integer AS waiting_count,
    count(*) FILTER (WHERE route_status = 'tracking_allocated')::integer AS allocated_count,
    count(*) FILTER (WHERE route_status = 'cancelled')::integer AS cancelled_count,
    count(*) FILTER (
      WHERE route_status = 'tracking_allocated'
        AND (
          successor_tracking_submission_id IS NULL
          OR successor_tracking_line_allocation_id IS NULL
          OR tracking_allocated_at IS NULL
        )
    )::integer AS malformed_allocated_count
  FROM public.physical_replacement_same_order_routes
),
effective_negative_check AS (
  SELECT count(*)::integer AS negative_effective_rows
  FROM public.tracking_allocation_effective_entitlement_v1(NULL, NULL) e
  WHERE e.effective_qty_allocated < 0
     OR e.effective_base_value_gbp < 0
     OR e.effective_discount_share_gbp < 0
     OR e.effective_retailer_delivery_share_gbp < 0
     OR e.effective_adjusted_net_value_gbp < 0
),
effective_line_totals AS (
  SELECT
    e.order_id,
    e.supplier_invoice_line_id,
    sum(e.effective_qty_allocated)::numeric AS effective_qty,
    count(*)::integer AS allocation_count
  FROM public.tracking_allocation_effective_entitlement_v1(NULL, NULL) e
  GROUP BY e.order_id, e.supplier_invoice_line_id
),
quantity_overallocation AS (
  SELECT
    t.order_id,
    t.supplier_invoice_line_id,
    COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS authoritative_qty,
    t.effective_qty,
    t.allocation_count
  FROM effective_line_totals t
  JOIN public.supplier_invoice_lines sil ON sil.id = t.supplier_invoice_line_id
  WHERE t.effective_qty > COALESCE(sil.qty_confirmed, sil.qty, 0) + 0.0001
),
trigger_snapshot AS (
  SELECT
    t.tgrelid::regclass::text AS table_name,
    t.tgname,
    t.tgfoid::regprocedure::text AS trigger_function
  FROM pg_trigger t
  WHERE NOT t.tgisinternal
    AND t.tgrelid IN (
      'public.physical_exception_remedy_allocations'::regclass,
      'public.physical_receipt_reviews'::regclass,
      'public.shipper_package_receipt_line_dispositions'::regclass
    )
  ORDER BY table_name, t.tgname
)
SELECT jsonb_build_object(
  'foundation_objects', (SELECT value FROM foundation_objects),
  'protected_fingerprints', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM fingerprint_check x), '[]'::jsonb),
  'protected_triggers', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM trigger_snapshot x), '[]'::jsonb),
  'legacy_child_count', (SELECT legacy_child_count FROM child_count),
  'new_route_child_link_violations', (SELECT violation_count FROM route_child_violation),
  'route_integrity', (SELECT to_jsonb(x) FROM route_integrity x),
  'negative_effective_entitlement_rows', (SELECT negative_effective_rows FROM effective_negative_check),
  'effective_quantity_overallocation', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM quantity_overallocation x), '[]'::jsonb)
) AS foundation_postflight;

ROLLBACK;
