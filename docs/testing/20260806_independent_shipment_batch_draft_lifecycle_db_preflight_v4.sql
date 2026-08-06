BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Read-only live preflight.
-- No operational INSERT, UPDATE or DELETE.

DO $auth_context$
DECLARE
  v_auth_user_id uuid;
BEGIN
  SELECT s.auth_user_id
  INTO v_auth_user_id
  FROM public.staff s
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY s.created_at, s.id
  LIMIT 1;

  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff auth context available';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::text, true);
END;
$auth_context$;

WITH
ids AS (
  SELECT
    (
      SELECT b.id
      FROM public.shipper_shipment_batches b
      WHERE b.booking_ref = 'J040826'
      ORDER BY b.created_at DESC, b.id DESC
      LIMIT 1
    ) AS j040826_batch_id,
    (
      SELECT b.id
      FROM public.shipper_shipment_batches b
      WHERE b.booking_ref = 'J040826v1'
      ORDER BY b.created_at DESC, b.id DESC
      LIMIT 1
    ) AS j040826v1_batch_id,
    to_regprocedure(
      'public.internal_customer_sales_release_sources_v1(uuid)'
    ) AS resolver_oid,
    to_regprocedure(
      'public.internal_customer_invoice_release_queue_v1()'
    ) AS queue_oid,
    to_regprocedure(
      'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'
    ) AS creator_oid,
    to_regprocedure(
      'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'
    ) AS readiness_oid,
    to_regprocedure(
      'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'
    ) AS remaining_oid,
    to_regclass(
      'public.uq_sales_invoices_active_release_draft_v1'
    ) AS active_draft_index_oid,
    to_regclass(
      'public.uq_sales_invoices_nonvoid_main_v1'
    ) AS nonvoid_main_index_oid
),
objects AS (
  SELECT jsonb_build_object(
    'resolver_exists', resolver_oid IS NOT NULL,
    'queue_exists', queue_oid IS NOT NULL,
    'creator_exists', creator_oid IS NOT NULL,
    'readiness_exists', readiness_oid IS NOT NULL,
    'remaining_exists', remaining_oid IS NOT NULL,
    'active_draft_index_exists', active_draft_index_oid IS NOT NULL,
    'nonvoid_main_index_exists', nonvoid_main_index_oid IS NOT NULL,
    'release_ledger_exists',
      to_regclass('public.customer_sales_release_lines') IS NOT NULL,
    'sales_invoices_exists',
      to_regclass('public.sales_invoices') IS NOT NULL,
    'j040826_batch_found', j040826_batch_id IS NOT NULL,
    'j040826v1_batch_found', j040826v1_batch_id IS NOT NULL
  ) AS value
  FROM ids
),
function_contracts AS (
  SELECT jsonb_build_object(
    'resolver', jsonb_build_object(
      'md5', md5(pg_get_functiondef(resolver_oid)),
      'identity_arguments', pg_get_function_identity_arguments(resolver_oid),
      'result', pg_get_function_result(resolver_oid),
      'definition', pg_get_functiondef(resolver_oid)
    ),
    'queue', jsonb_build_object(
      'md5', md5(pg_get_functiondef(queue_oid)),
      'identity_arguments', pg_get_function_identity_arguments(queue_oid),
      'result', pg_get_function_result(queue_oid),
      'definition', pg_get_functiondef(queue_oid)
    ),
    'creator', jsonb_build_object(
      'md5', md5(pg_get_functiondef(creator_oid)),
      'identity_arguments', pg_get_function_identity_arguments(creator_oid),
      'result', pg_get_function_result(creator_oid),
      'definition', pg_get_functiondef(creator_oid)
    ),
    'readiness_preview_md5', md5(pg_get_functiondef(readiness_oid)),
    'remaining_preview_md5', md5(pg_get_functiondef(remaining_oid))
  ) AS value
  FROM ids
),
index_contracts AS (
  SELECT jsonb_build_object(
    'active_release_draft', jsonb_build_object(
      'definition', pg_get_indexdef(active_draft_index_oid),
      'is_unique', active_idx.indisunique,
      'is_valid', active_idx.indisvalid,
      'is_ready', active_idx.indisready
    ),
    'nonvoid_main', jsonb_build_object(
      'definition', pg_get_indexdef(nonvoid_main_index_oid),
      'is_unique', main_idx.indisunique,
      'is_valid', main_idx.indisvalid,
      'is_ready', main_idx.indisready
    )
  ) AS value
  FROM ids
  LEFT JOIN pg_index active_idx
    ON active_idx.indexrelid = active_draft_index_oid
  LEFT JOIN pg_index main_idx
    ON main_idx.indexrelid = nonvoid_main_index_oid
),
target_orders AS (
  SELECT
    b.id AS shipment_batch_id,
    b.booking_ref,
    o.id AS source_order_id,
    o.order_ref,
    o.order_type,
    CASE
      WHEN o.order_type = 'replacement_child'
        AND o.parent_order_id IS NOT NULL
      THEN o.parent_order_id
      ELSE o.id
    END AS commercial_parent_order_id
  FROM public.shipper_shipment_batches b
  JOIN public.orders o ON o.id = b.order_id
  CROSS JOIN ids
  WHERE b.id IN (ids.j040826_batch_id, ids.j040826v1_batch_id)
),
commercial_parent AS (
  SELECT jsonb_build_object(
    'same_commercial_parent',
      COUNT(DISTINCT commercial_parent_order_id) = 1,
    'rows', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'booking_ref', booking_ref,
          'shipment_batch_id', shipment_batch_id,
          'source_order_id', source_order_id,
          'order_ref', order_ref,
          'order_type', order_type,
          'commercial_parent_order_id', commercial_parent_order_id
        ) ORDER BY booking_ref
      ),
      '[]'::jsonb
    )
  ) AS value
  FROM target_orders
),
target_invoice AS (
  SELECT si.*
  FROM public.sales_invoices si
  WHERE si.id = 'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
),
target_invoice_json AS (
  SELECT COALESCE(
    (
      SELECT jsonb_build_object(
        'found', true,
        'sales_invoice_id', si.id,
        'order_id', si.order_id,
        'invoice_type', si.invoice_type,
        'sage_status', si.sage_status,
        'amount_gbp', si.amount_gbp,
        'linked_invoice_id', si.linked_invoice_id,
        'created_at', si.created_at,
        'line_items_md5', md5(si.line_items_json::text),
        'payload_shipment_batch_ids', COALESCE(
          (
            SELECT jsonb_agg(x.value ORDER BY x.value)
            FROM jsonb_array_elements_text(
              COALESCE(
                si.line_items_json #> '{draft_control,shipment_batch_ids}',
                '[]'::jsonb
              )
            ) x
          ),
          '[]'::jsonb
        )
      )
      FROM target_invoice si
    ),
    jsonb_build_object('found', false)
  ) AS value
),
target_memberships AS (
  SELECT jsonb_build_object(
    'active_count', COUNT(*) FILTER (
      WHERE l.release_status = 'active'
    ),
    'j040826_active_membership_count', COUNT(*) FILTER (
      WHERE l.release_status = 'active'
        AND b.booking_ref = 'J040826'
    ),
    'j040826v1_active_membership_count', COUNT(*) FILTER (
      WHERE l.release_status = 'active'
        AND b.booking_ref = 'J040826v1'
    ),
    'rows', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'release_line_id', l.id,
          'sales_invoice_id', l.sales_invoice_id,
          'source_shipment_batch_id', l.source_shipment_batch_id,
          'booking_ref', b.booking_ref,
          'tracking_line_allocation_id', l.tracking_line_allocation_id,
          'released_qty', l.released_qty,
          'goods_amount_gbp', l.goods_amount_gbp,
          'shipping_amount_gbp', l.shipping_amount_gbp,
          'customer_charge_amount_gbp', l.customer_charge_amount_gbp,
          'release_status', l.release_status,
          'membership_fingerprint', l.membership_fingerprint
        ) ORDER BY l.created_at, l.id
      ) FILTER (WHERE l.id IS NOT NULL),
      '[]'::jsonb
    )
  ) AS value
  FROM public.customer_sales_release_lines l
  LEFT JOIN public.shipper_shipment_batches b
    ON b.id = l.source_shipment_batch_id
  WHERE l.sales_invoice_id =
    'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
),
resolver_rows AS (
  SELECT
    t.booking_ref,
    t.shipment_batch_id,
    r.*
  FROM target_orders t
  CROSS JOIN LATERAL
    public.internal_customer_sales_release_sources_v1(
      t.shipment_batch_id
    ) r
),
resolver_summary AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'booking_ref', booking_ref,
        'shipment_batch_id', shipment_batch_id,
        'row_count', row_count,
        'positive_unblocked_rows', positive_unblocked_rows,
        'release_qty', release_qty,
        'customer_charge_gbp', customer_charge_gbp,
        'blockers', blockers
      ) ORDER BY booking_ref
    ),
    '[]'::jsonb
  ) AS value
  FROM (
    SELECT
      booking_ref,
      shipment_batch_id,
      COUNT(*)::integer AS row_count,
      COUNT(*) FILTER (
        WHERE COALESCE(qty_to_release, 0) > 0
          AND blocker IS NULL
      )::integer AS positive_unblocked_rows,
      COALESCE(SUM(qty_to_release), 0) AS release_qty,
      COALESCE(SUM(total_line_amount_gbp), 0) AS customer_charge_gbp,
      COALESCE(
        jsonb_agg(DISTINCT blocker ORDER BY blocker)
          FILTER (WHERE blocker IS NOT NULL),
        '[]'::jsonb
      ) AS blockers
    FROM resolver_rows
    GROUP BY booking_ref, shipment_batch_id
  ) x
),
readiness_rows AS (
  SELECT
    t.booking_ref,
    t.shipment_batch_id,
    p.*
  FROM target_orders t
  CROSS JOIN LATERAL
    public.internal_shipping_customer_invoice_readiness_preview_v1(
      t.shipment_batch_id
    ) p
),
readiness_summary AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'booking_ref', booking_ref,
        'shipment_batch_id', shipment_batch_id,
        'row_count', row_count,
        'ready_rows', ready_rows,
        'blocked_rows', blocked_rows,
        'proposed_amount_gbp', proposed_amount_gbp,
        'proposed_goods_amount_gbp', proposed_goods_amount_gbp,
        'proposed_shipping_amount_gbp', proposed_shipping_amount_gbp,
        'blockers', blockers
      ) ORDER BY booking_ref
    ),
    '[]'::jsonb
  ) AS value
  FROM (
    SELECT
      booking_ref,
      shipment_batch_id,
      COUNT(*)::integer AS row_count,
      COUNT(*) FILTER (
        WHERE blocker IS NULL
          AND ROUND(COALESCE(total_line_amount_gbp, 0), 2) > 0
      )::integer AS ready_rows,
      COUNT(*) FILTER (WHERE blocker IS NOT NULL)::integer AS blocked_rows,
      MAX(proposed_amount_gbp) AS proposed_amount_gbp,
      MAX(proposed_goods_amount_gbp) AS proposed_goods_amount_gbp,
      MAX(proposed_shipping_amount_gbp) AS proposed_shipping_amount_gbp,
      COALESCE(
        jsonb_agg(DISTINCT blocker ORDER BY blocker)
          FILTER (WHERE blocker IS NOT NULL),
        '[]'::jsonb
      ) AS blockers
    FROM readiness_rows
    GROUP BY booking_ref, shipment_batch_id
  ) x
),
queue_summary AS (
  SELECT COALESCE(
    jsonb_agg(
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
    ),
    '[]'::jsonb
  ) AS value
  FROM public.internal_customer_invoice_release_queue_v1() q
  WHERE q.booking_ref IN ('J040826', 'J040826v1')
),
active_parent_drafts AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'sales_invoice_id', si.id,
        'order_id', si.order_id,
        'invoice_type', si.invoice_type,
        'sage_status', si.sage_status,
        'amount_gbp', si.amount_gbp,
        'linked_invoice_id', si.linked_invoice_id,
        'active_membership_batches', COALESCE(
          (
            SELECT jsonb_agg(
              jsonb_build_object(
                'shipment_batch_id', l.source_shipment_batch_id,
                'booking_ref', b.booking_ref
              ) ORDER BY b.booking_ref, l.source_shipment_batch_id
            )
            FROM public.customer_sales_release_lines l
            LEFT JOIN public.shipper_shipment_batches b
              ON b.id = l.source_shipment_batch_id
            WHERE l.sales_invoice_id = si.id
              AND l.release_status = 'active'
          ),
          '[]'::jsonb
        )
      ) ORDER BY si.created_at, si.id
    ),
    '[]'::jsonb
  ) AS value
  FROM public.sales_invoices si
  WHERE si.order_id IN (
    SELECT DISTINCT commercial_parent_order_id
    FROM target_orders
  )
    AND si.invoice_type IN ('main', 'supplementary')
    AND si.sage_status = 'draft'
),
routine_consumers AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'schema', n.nspname,
        'function', p.proname,
        'identity_arguments', pg_get_function_identity_arguments(p.oid),
        'md5', md5(pg_get_functiondef(p.oid)),
        'contains_draft_already_exists',
          lower(pg_get_functiondef(p.oid)) LIKE '%draft_already_exists%',
        'contains_sales_invoice_order_match',
          lower(pg_get_functiondef(p.oid)) LIKE '%sales_invoices%order_id%',
        'contains_release_ledger',
          lower(pg_get_functiondef(p.oid)) LIKE '%customer_sales_release_lines%'
      ) ORDER BY n.nspname, p.proname,
        pg_get_function_identity_arguments(p.oid)
    ),
    '[]'::jsonb
  ) AS value
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
    AND (
      lower(pg_get_functiondef(p.oid)) LIKE
        '%customer_sales_release_draft_already_exists%'
      OR lower(pg_get_functiondef(p.oid)) LIKE
        '%skipped_draft_already_exists%'
      OR (
        lower(pg_get_functiondef(p.oid)) LIKE '%sales_invoices%'
        AND lower(pg_get_functiondef(p.oid)) LIKE '%sage_status%draft%'
        AND lower(pg_get_functiondef(p.oid)) LIKE '%order_id%'
      )
    )
),
membership_collisions AS (
  SELECT jsonb_build_object(
    'duplicate_active_fingerprint_groups', COUNT(*),
    'rows', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'membership_fingerprint', membership_fingerprint,
          'active_count', active_count,
          'sales_invoice_ids', sales_invoice_ids,
          'shipment_batch_ids', shipment_batch_ids
        ) ORDER BY membership_fingerprint
      ),
      '[]'::jsonb
    )
  ) AS value
  FROM (
    SELECT
      l.membership_fingerprint,
      COUNT(*)::integer AS active_count,
      jsonb_agg(l.sales_invoice_id::text ORDER BY l.sales_invoice_id::text)
        AS sales_invoice_ids,
      jsonb_agg(
        l.source_shipment_batch_id::text
        ORDER BY l.source_shipment_batch_id::text
      ) AS shipment_batch_ids
    FROM public.customer_sales_release_lines l
    WHERE l.release_status = 'active'
    GROUP BY l.membership_fingerprint
    HAVING COUNT(*) > 1
  ) x
)
SELECT jsonb_build_object(
  'preflight',
    'independent_shipment_batch_draft_lifecycle_db_preflight_v4',
  'status', 'passed',
  'objects', objects.value,
  'target_batches', jsonb_build_object(
    'j040826', ids.j040826_batch_id,
    'j040826v1', ids.j040826v1_batch_id
  ),
  'commercial_parent', commercial_parent.value,
  'function_contracts', function_contracts.value,
  'index_contracts', index_contracts.value,
  'target_invoice', target_invoice_json.value,
  'target_invoice_memberships', target_memberships.value,
  'active_parent_drafts', active_parent_drafts.value,
  'resolver_results', resolver_summary.value,
  'readiness_results', readiness_summary.value,
  'queue_results', queue_summary.value,
  'parent_draft_routine_consumers', routine_consumers.value,
  'active_membership_collisions', membership_collisions.value,
  'operational_rows_changed', false,
  'required_next_decision',
    'Review the exact live resolver gate, creator grouping/reuse rule, active-draft index and every listed consumer before authoring any migration.'
) AS result
FROM ids
CROSS JOIN objects
CROSS JOIN function_contracts
CROSS JOIN index_contracts
CROSS JOIN commercial_parent
CROSS JOIN target_invoice_json
CROSS JOIN target_memberships
CROSS JOIN active_parent_drafts
CROSS JOIN resolver_summary
CROSS JOIN readiness_summary
CROSS JOIN queue_summary
CROSS JOIN routine_consumers
CROSS JOIN membership_collisions;

ROLLBACK;
