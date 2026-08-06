BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Read-only diagnostic. No operational row writes.

WITH target_batches AS (
  SELECT b.id, b.booking_ref
  FROM public.shipper_shipment_batches b
  WHERE b.booking_ref IN ('J040826', 'J040826v1')
),
batch_orders AS (
  SELECT DISTINCT
    b.id AS shipment_batch_id,
    b.booking_ref,
    p.order_id AS source_order_id,
    o.order_ref,
    o.order_type,
    CASE
      WHEN o.order_type = 'replacement_child'
       AND o.parent_order_id IS NOT NULL
      THEN o.parent_order_id
      ELSE o.id
    END AS commercial_parent_order_id
  FROM target_batches b
  JOIN public.shipper_shipment_batch_packages p
    ON p.shipment_batch_id = b.id
   AND p.active = true
  JOIN public.orders o
    ON o.id = p.order_id
),
function_defs AS (
  SELECT jsonb_build_object(
    'resolver', jsonb_build_object(
      'md5', md5(pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)),
      'definition', pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)
    ),
    'queue', jsonb_build_object(
      'md5', md5(pg_get_functiondef('public.internal_customer_invoice_release_queue_v1()'::regprocedure)),
      'definition', pg_get_functiondef('public.internal_customer_invoice_release_queue_v1()'::regprocedure)
    ),
    'creator', jsonb_build_object(
      'md5', md5(pg_get_functiondef('public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure)),
      'definition', pg_get_functiondef('public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure)
    )
  ) AS value
),
indexes AS (
  SELECT jsonb_build_object(
    'active_release_draft', pg_get_indexdef('public.uq_sales_invoices_active_release_draft_v1'::regclass),
    'nonvoid_main', pg_get_indexdef('public.uq_sales_invoices_nonvoid_main_v1'::regclass)
  ) AS value
),
order_map AS (
  SELECT jsonb_build_object(
    'same_commercial_parent', COUNT(DISTINCT commercial_parent_order_id) = 1,
    'rows', jsonb_agg(
      jsonb_build_object(
        'booking_ref', booking_ref,
        'shipment_batch_id', shipment_batch_id,
        'source_order_id', source_order_id,
        'order_ref', order_ref,
        'order_type', order_type,
        'commercial_parent_order_id', commercial_parent_order_id
      ) ORDER BY booking_ref, source_order_id
    )
  ) AS value
  FROM batch_orders
),
invoice_state AS (
  SELECT jsonb_build_object(
    'sales_invoice_id', si.id,
    'order_id', si.order_id,
    'invoice_type', si.invoice_type,
    'sage_status', si.sage_status,
    'amount_gbp', si.amount_gbp,
    'linked_invoice_id', si.linked_invoice_id,
    'line_items_md5', md5(si.line_items_json::text),
    'active_memberships', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'release_line_id', l.id,
          'source_shipment_batch_id', l.source_shipment_batch_id,
          'booking_ref', b.booking_ref,
          'tracking_line_allocation_id', l.tracking_line_allocation_id,
          'released_qty', l.released_qty,
          'goods_amount_gbp', l.goods_amount_gbp,
          'shipping_amount_gbp', l.shipping_amount_gbp,
          'customer_charge_amount_gbp', l.customer_charge_amount_gbp,
          'membership_fingerprint', l.membership_fingerprint
        ) ORDER BY l.created_at, l.id
      )
      FROM public.customer_sales_release_lines l
      LEFT JOIN public.shipper_shipment_batches b
        ON b.id = l.source_shipment_batch_id
      WHERE l.sales_invoice_id = si.id
        AND l.release_status = 'active'
    ), '[]'::jsonb)
  ) AS value
  FROM public.sales_invoices si
  WHERE si.id = 'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
),
queue_rows AS (
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'booking_ref', q.booking_ref,
      'shipment_batch_id', q.shipment_batch_id,
      'readiness_status', q.readiness_status,
      'queue_action', q.queue_action,
      'created_draft_count', q.created_draft_count,
      'posted_invoice_count', q.posted_invoice_count,
      'proposed_amount_gbp', q.proposed_amount_gbp,
      'line_count', q.line_count,
      'ready_line_count', q.ready_line_count,
      'blocker_count', q.blocker_count,
      'blockers', q.blockers
    ) ORDER BY q.booking_ref
  ), '[]'::jsonb) AS value
  FROM public.internal_customer_invoice_release_queue_v1() q
  WHERE q.booking_ref IN ('J040826', 'J040826v1')
),
active_parent_drafts AS (
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'sales_invoice_id', si.id,
      'order_id', si.order_id,
      'invoice_type', si.invoice_type,
      'sage_status', si.sage_status,
      'amount_gbp', si.amount_gbp
    ) ORDER BY si.created_at, si.id
  ), '[]'::jsonb) AS value
  FROM public.sales_invoices si
  WHERE si.order_id IN (
    SELECT DISTINCT commercial_parent_order_id FROM batch_orders
  )
    AND si.invoice_type IN ('main', 'supplementary')
    AND si.sage_status = 'draft'
),
collision_check AS (
  SELECT jsonb_build_object(
    'duplicate_active_membership_fingerprint_groups', COUNT(*)
  ) AS value
  FROM (
    SELECT membership_fingerprint
    FROM public.customer_sales_release_lines
    WHERE release_status = 'active'
    GROUP BY membership_fingerprint
    HAVING COUNT(*) > 1
  ) d
)
SELECT jsonb_build_object(
  'preflight', 'independent_shipment_batch_draft_lifecycle_db_preflight_v5',
  'status', 'passed',
  'function_contracts', function_defs.value,
  'index_contracts', indexes.value,
  'shipment_batch_order_map', order_map.value,
  'target_invoice', invoice_state.value,
  'queue_results', queue_rows.value,
  'active_parent_drafts', active_parent_drafts.value,
  'active_membership_collisions', collision_check.value,
  'operational_rows_changed', false
) AS result
FROM function_defs
CROSS JOIN indexes
CROSS JOIN order_map
CROSS JOIN invoice_state
CROSS JOIN queue_rows
CROSS JOIN active_parent_drafts
CROSS JOIN collision_check;

ROLLBACK;
