BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Read-only live preflight for the independent shipment-batch draft lifecycle.
--
-- Purpose:
--   * freeze the exact current resolver, queue and creator definitions;
--   * capture the one-active-draft index definition;
--   * prove the existing J040826 draft and exact release membership;
--   * prove J040826v1 has no active membership;
--   * expose J040826v1's resolver/readiness result and every current blocker;
--   * enumerate database routines that contain the parent-order draft rule;
--   * make no persistent operational-row change.
--
-- This file is diagnostic only. It does not authorise a migration.

DO $auth_context$
DECLARE
  v_auth_user_id uuid;
BEGIN
  SELECT staff_row.auth_user_id
  INTO v_auth_user_id
  FROM public.staff staff_row
  WHERE staff_row.active = true
    AND staff_row.auth_user_id IS NOT NULL
  ORDER BY staff_row.created_at, staff_row.id
  LIMIT 1;

  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION
      'FAIL: no active staff auth context available for preflight';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::text, true);
END;
$auth_context$;

WITH
object_ids AS (
  SELECT
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
    to_regclass('public.uq_sales_invoices_active_release_draft_v1') AS active_draft_index_oid,
    to_regclass('public.uq_sales_invoices_nonvoid_main_v1') AS nonvoid_main_index_oid
),
required_objects AS (
  SELECT
    resolver_oid IS NOT NULL AS resolver_exists,
    queue_oid IS NOT NULL AS queue_exists,
    creator_oid IS NOT NULL AS creator_exists,
    readiness_oid IS NOT NULL AS readiness_exists,
    remaining_oid IS NOT NULL AS remaining_exists,
    active_draft_index_oid IS NOT NULL AS active_draft_index_exists,
    nonvoid_main_index_oid IS NOT NULL AS nonvoid_main_index_exists,
    to_regclass('public.customer_sales_release_lines') IS NOT NULL
      AS release_ledger_exists,
    to_regclass('public.sales_invoices') IS NOT NULL
      AS sales_invoices_exists,
    to_regclass('public.shipper_shipment_batches') IS NOT NULL
      AS shipment_batches_exists
  FROM object_ids
),
target_batches AS (
  SELECT
    MAX(batch.id) FILTER (WHERE batch.booking_ref = 'J040826')
      AS j040826_batch_id,
    MAX(batch.id) FILTER (WHERE batch.booking_ref = 'J040826v1')
      AS j040826v1_batch_id
  FROM public.shipper_shipment_batches batch
  WHERE batch.booking_ref IN ('J040826', 'J040826v1')
),
target_orders AS (
  SELECT
    batch.id AS shipment_batch_id,
    batch.booking_ref,
    COALESCE(
      NULLIF(order_row.order_type, 'replacement_child')::text,
      order_row.order_type
    ) AS source_order_type,
    order_row.id AS source_order_id,
    CASE
      WHEN order_row.order_type = 'replacement_child'
        AND order_row.parent_order_id IS NOT NULL
      THEN order_row.parent_order_id
      ELSE order_row.id
    END AS commercial_parent_order_id,
    order_row.order_ref
  FROM public.shipper_shipment_batches batch
  LEFT JOIN public.orders order_row
    ON order_row.id = batch.order_id
  WHERE batch.booking_ref IN ('J040826', 'J040826v1')
),
function_contracts AS (
  SELECT jsonb_build_object(
    'resolver', jsonb_build_object(
      'md5', md5(pg_get_functiondef(ids.resolver_oid)),
      'identity_arguments', pg_get_function_identity_arguments(ids.resolver_oid),
      'result', pg_get_function_result(ids.resolver_oid),
      'definition', pg_get_functiondef(ids.resolver_oid)
    ),
    'queue', jsonb_build_object(
      'md5', md5(pg_get_functiondef(ids.queue_oid)),
      'identity_arguments', pg_get_function_identity_arguments(ids.queue_oid),
      'result', pg_get_function_result(ids.queue_oid),
      'definition', pg_get_functiondef(ids.queue_oid)
    ),
    'creator', jsonb_build_object(
      'md5', md5(pg_get_functiondef(ids.creator_oid)),
      'identity_arguments', pg_get_function_identity_arguments(ids.creator_oid),
      'result', pg_get_function_result(ids.creator_oid),
      'definition', pg_get_functiondef(ids.creator_oid)
    ),
    'readiness_preview', jsonb_build_object(
      'md5', md5(pg_get_functiondef(ids.readiness_oid)),
      'identity_arguments', pg_get_function_identity_arguments(ids.readiness_oid),
      'result', pg_get_function_result(ids.readiness_oid)
    ),
    'remaining_preview', jsonb_build_object(
      'md5', md5(pg_get_functiondef(ids.remaining_oid)),
      'identity_arguments', pg_get_function_identity_arguments(ids.remaining_oid),
      'result', pg_get_function_result(ids.remaining_oid)
    )
  ) AS value
  FROM object_ids ids
),
index_contracts AS (
  SELECT jsonb_build_object(
    'active_release_draft', jsonb_build_object(
      'name', 'uq_sales_invoices_active_release_draft_v1',
      'definition', pg_get_indexdef(ids.active_draft_index_oid),
      'is_unique', COALESCE(index_row.indisunique, false),
      'is_valid', COALESCE(index_row.indisvalid, false),
      'is_ready', COALESCE(index_row.indisready, false)
    ),
    'nonvoid_main', jsonb_build_object(
      'name', 'uq_sales_invoices_nonvoid_main_v1',
      'definition', pg_get_indexdef(ids.nonvoid_main_index_oid),
      'is_unique', COALESCE(main_index.indisunique, false),
      'is_valid', COALESCE(main_index.indisvalid, false),
      'is_ready', COALESCE(main_index.indisready, false)
    )
  ) AS value
  FROM object_ids ids
  LEFT JOIN pg_index index_row
    ON index_row.indexrelid = ids.active_draft_index_oid
  LEFT JOIN pg_index main_index
    ON main_index.indexrelid = ids.nonvoid_main_index_oid
),
parent_draft_routine_consumers AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'schema', namespace_row.nspname,
        'function', procedure_row.proname,
        'identity_arguments',
          pg_get_function_identity_arguments(procedure_row.oid),
        'md5', md5(pg_get_functiondef(procedure_row.oid)),
        'contains_sales_invoice_order_match',
          lower(pg_get_functiondef(procedure_row.oid)) LIKE
            '%invoice.order_id%'
          OR lower(pg_get_functiondef(procedure_row.oid)) LIKE
            '%sales_invoices%order_id%',
        'contains_active_draft_status',
          lower(pg_get_functiondef(procedure_row.oid)) LIKE '%sage_status%draft%',
        'contains_draft_already_exists',
          lower(pg_get_functiondef(procedure_row.oid)) LIKE
            '%draft_already_exists%',
        'contains_release_ledger',
          lower(pg_get_functiondef(procedure_row.oid)) LIKE
            '%customer_sales_release_lines%'
      )
      ORDER BY namespace_row.nspname, procedure_row.proname,
        pg_get_function_identity_arguments(procedure_row.oid)
    ),
    '[]'::jsonb
  ) AS value
  FROM pg_proc procedure_row
  JOIN pg_namespace namespace_row
    ON namespace_row.oid = procedure_row.pronamespace
  WHERE namespace_row.nspname = 'public'
    AND procedure_row.prokind = 'f'
    AND (
      lower(pg_get_functiondef(procedure_row.oid)) LIKE
        '%customer_sales_release_draft_already_exists%'
      OR lower(pg_get_functiondef(procedure_row.oid)) LIKE
        '%skipped_draft_already_exists%'
      OR lower(pg_get_functiondef(procedure_row.oid)) LIKE
        '%uq_sales_invoices_active_release_draft_v1%'
      OR (
        lower(pg_get_functiondef(procedure_row.oid)) LIKE '%sales_invoices%'
        AND lower(pg_get_functiondef(procedure_row.oid)) LIKE '%sage_status%draft%'
        AND lower(pg_get_functiondef(procedure_row.oid)) LIKE '%order_id%'
      )
    )
),
index_catalog_dependencies AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'dependent_class', dependent_class.relname,
        'dependent_kind', dependent_class.relkind,
        'referenced_class', referenced_class.relname,
        'dependency_type', dependency_row.deptype
      )
      ORDER BY dependent_class.relname, referenced_class.relname
    ),
    '[]'::jsonb
  ) AS value
  FROM object_ids ids
  LEFT JOIN pg_depend dependency_row
    ON dependency_row.objid = ids.active_draft_index_oid
       OR dependency_row.refobjid = ids.active_draft_index_oid
  LEFT JOIN pg_class dependent_class
    ON dependent_class.oid = dependency_row.objid
  LEFT JOIN pg_class referenced_class
    ON referenced_class.oid = dependency_row.refobjid
  WHERE dependency_row.objid IS NOT NULL
),
target_invoice AS (
  SELECT invoice.*
  FROM public.sales_invoices invoice
  WHERE invoice.id = 'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
),
target_invoice_json AS (
  SELECT jsonb_build_object(
    'found', COUNT(*) = 1,
    'sales_invoice_id', MAX(invoice.id),
    'order_id', MAX(invoice.order_id),
    'invoice_type', MAX(invoice.invoice_type),
    'sage_status', MAX(invoice.sage_status),
    'amount_gbp', MAX(invoice.amount_gbp),
    'linked_invoice_id', MAX(invoice.linked_invoice_id),
    'created_at', MAX(invoice.created_at),
    'line_items_md5', MAX(md5(invoice.line_items_json::text)),
    'payload_shipment_batch_ids', COALESCE((
      SELECT jsonb_agg(payload_batch.value ORDER BY payload_batch.value)
      FROM target_invoice target
      CROSS JOIN LATERAL jsonb_array_elements_text(
        COALESCE(
          target.line_items_json #> '{draft_control,shipment_batch_ids}',
          '[]'::jsonb
        )
      ) payload_batch
    ), '[]'::jsonb)
  ) AS value
  FROM target_invoice invoice
),
target_memberships AS (
  SELECT jsonb_build_object(
    'active_count', COUNT(*) FILTER (
      WHERE release_line.release_status = 'active'
    ),
    'rows', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'release_line_id', release_line.id,
          'sales_invoice_id', release_line.sales_invoice_id,
          'source_shipment_batch_id', release_line.source_shipment_batch_id,
          'booking_ref', shipment_batch.booking_ref,
          'tracking_line_allocation_id',
            release_line.tracking_line_allocation_id,
          'released_qty', release_line.released_qty,
          'goods_amount_gbp', release_line.goods_amount_gbp,
          'shipping_amount_gbp', release_line.shipping_amount_gbp,
          'customer_charge_amount_gbp',
            release_line.customer_charge_amount_gbp,
          'release_status', release_line.release_status,
          'membership_fingerprint', release_line.membership_fingerprint,
          'created_at', release_line.created_at
        )
        ORDER BY release_line.created_at, release_line.id
      ) FILTER (WHERE release_line.id IS NOT NULL),
      '[]'::jsonb
    ),
    'j040826_active_membership_count', COUNT(*) FILTER (
      WHERE release_line.release_status = 'active'
        AND shipment_batch.booking_ref = 'J040826'
    ),
    'j040826v1_active_membership_count', COUNT(*) FILTER (
      WHERE release_line.release_status = 'active'
        AND shipment_batch.booking_ref = 'J040826v1'
    )
  ) AS value
  FROM public.customer_sales_release_lines release_line
  LEFT JOIN public.shipper_shipment_batches shipment_batch
    ON shipment_batch.id = release_line.source_shipment_batch_id
  WHERE release_line.sales_invoice_id =
    'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
),
resolver_rows AS (
  SELECT
    target.booking_ref,
    target.shipment_batch_id,
    resolver.*
  FROM target_orders target
  CROSS JOIN LATERAL
    public.internal_customer_sales_release_sources_v1(
      target.shipment_batch_id
    ) resolver
),
resolver_summary AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'booking_ref', booking_ref,
        'shipment_batch_id', shipment_batch_id,
        'row_count', row_count,
        'positive_release_row_count', positive_release_row_count,
        'total_release_qty', total_release_qty,
        'total_customer_charge_gbp', total_customer_charge_gbp,
        'blockers', blockers
      )
      ORDER BY booking_ref
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
      )::integer AS positive_release_row_count,
      COALESCE(SUM(qty_to_release), 0) AS total_release_qty,
      COALESCE(SUM(total_line_amount_gbp), 0) AS total_customer_charge_gbp,
      COALESCE(
        jsonb_agg(DISTINCT blocker ORDER BY blocker)
          FILTER (WHERE blocker IS NOT NULL),
        '[]'::jsonb
      ) AS blockers
    FROM resolver_rows
    GROUP BY booking_ref, shipment_batch_id
  ) summary
),
readiness_rows AS (
  SELECT
    target.booking_ref,
    target.shipment_batch_id,
    preview.*
  FROM target_orders target
  CROSS JOIN LATERAL
    public.internal_shipping_customer_invoice_readiness_preview_v1(
      target.shipment_batch_id
    ) preview
),
readiness_summary AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'booking_ref', booking_ref,
        'shipment_batch_id', shipment_batch_id,
        'row_count', row_count,
        'ready_row_count', ready_row_count,
        'blocked_row_count', blocked_row_count,
        'proposed_amount_gbp', proposed_amount_gbp,
        'proposed_goods_amount_gbp', proposed_goods_amount_gbp,
        'proposed_shipping_amount_gbp', proposed_shipping_amount_gbp,
        'blockers', blockers
      )
      ORDER BY booking_ref
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
      )::integer AS ready_row_count,
      COUNT(*) FILTER (WHERE blocker IS NOT NULL)::integer
        AS blocked_row_count,
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
  ) summary
),
queue_summary AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'booking_ref', queue_row.booking_ref,
        'shipment_batch_id', queue_row.shipment_batch_id,
        'readiness_status', queue_row.readiness_status,
        'queue_action', queue_row.queue_action,
        'created_draft_count', queue_row.created_draft_count,
        'posted_invoice_count', queue_row.posted_invoice_count,
        'proposed_amount_gbp', queue_row.proposed_amount_gbp,
        'line_count', queue_row.line_count,
        'ready_line_count', queue_row.ready_line_count,
        'blocker_count', queue_row.blocker_count,
        'blockers', queue_row.blockers
      )
      ORDER BY queue_row.booking_ref
    ),
    '[]'::jsonb
  ) AS value
  FROM public.internal_customer_invoice_release_queue_v1() queue_row
  WHERE queue_row.booking_ref IN ('J040826', 'J040826v1')
),
commercial_parent_summary AS (
  SELECT jsonb_build_object(
    'rows', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'booking_ref', target.booking_ref,
          'shipment_batch_id', target.shipment_batch_id,
          'source_order_id', target.source_order_id,
          'source_order_type', target.source_order_type,
          'commercial_parent_order_id', target.commercial_parent_order_id,
          'order_ref', target.order_ref
        )
        ORDER BY target.booking_ref
      ),
      '[]'::jsonb
    ),
    'same_commercial_parent',
      COUNT(DISTINCT target.commercial_parent_order_id) = 1
  ) AS value
  FROM target_orders target
),
active_parent_drafts AS (
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'sales_invoice_id', invoice.id,
        'order_id', invoice.order_id,
        'invoice_type', invoice.invoice_type,
        'sage_status', invoice.sage_status,
        'amount_gbp', invoice.amount_gbp,
        'linked_invoice_id', invoice.linked_invoice_id,
        'created_at', invoice.created_at,
        'active_membership_batches', COALESCE((
          SELECT jsonb_agg(
            DISTINCT jsonb_build_object(
              'shipment_batch_id', release_line.source_shipment_batch_id,
              'booking_ref', shipment_batch.booking_ref
            )
          )
          FROM public.customer_sales_release_lines release_line
          LEFT JOIN public.shipper_shipment_batches shipment_batch
            ON shipment_batch.id = release_line.source_shipment_batch_id
          WHERE release_line.sales_invoice_id = invoice.id
            AND release_line.release_status = 'active'
        ), '[]'::jsonb)
      )
      ORDER BY invoice.created_at, invoice.id
    ),
    '[]'::jsonb
  ) AS value
  FROM public.sales_invoices invoice
  WHERE invoice.order_id IN (
    SELECT DISTINCT commercial_parent_order_id
    FROM target_orders
  )
    AND invoice.invoice_type IN ('main', 'supplementary')
    AND invoice.sage_status = 'draft'
),
active_membership_collisions AS (
  SELECT jsonb_build_object(
    'duplicate_membership_fingerprint_groups', COUNT(*),
    'rows', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'membership_fingerprint', collision.membership_fingerprint,
          'active_count', collision.active_count,
          'invoice_ids', collision.invoice_ids,
          'shipment_batch_ids', collision.shipment_batch_ids
        )
        ORDER BY collision.membership_fingerprint
      ),
      '[]'::jsonb
    )
  ) AS value
  FROM (
    SELECT
      release_line.membership_fingerprint,
      COUNT(*)::integer AS active_count,
      jsonb_agg(release_line.sales_invoice_id ORDER BY release_line.sales_invoice_id)
        AS invoice_ids,
      jsonb_agg(
        release_line.source_shipment_batch_id
        ORDER BY release_line.source_shipment_batch_id
      ) AS shipment_batch_ids
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.membership_fingerprint
    HAVING COUNT(*) > 1
  ) collision
),
result AS (
  SELECT jsonb_build_object(
    'preflight',
      'independent_shipment_batch_draft_lifecycle_db_preflight_v2',
    'status', CASE
      WHEN required.resolver_exists
       AND required.queue_exists
       AND required.creator_exists
       AND required.readiness_exists
       AND required.remaining_exists
       AND required.active_draft_index_exists
       AND required.nonvoid_main_index_exists
       AND required.release_ledger_exists
       AND required.sales_invoices_exists
       AND required.shipment_batches_exists
       AND batches.j040826_batch_id IS NOT NULL
       AND batches.j040826v1_batch_id IS NOT NULL
      THEN 'passed'
      ELSE 'failed_missing_prerequisite'
    END,
    'objects', to_jsonb(required),
    'target_batches', jsonb_build_object(
      'j040826', batches.j040826_batch_id,
      'j040826v1', batches.j040826v1_batch_id
    ),
    'commercial_parent', parent.value,
    'function_contracts', contracts.value,
    'index_contracts', indexes.value,
    'parent_draft_routine_consumers', consumers.value,
    'active_draft_index_catalog_dependencies', dependencies.value,
    'target_invoice', invoice_json.value,
    'target_invoice_memberships', memberships.value,
    'active_parent_drafts', parent_drafts.value,
    'resolver_results', resolver.value,
    'readiness_results', readiness.value,
    'queue_results', queue_rows.value,
    'active_membership_collisions', collisions.value,
    'operational_rows_changed', false,
    'interpretation', jsonb_build_object(
      'required_next_decision',
        'Use the exact live definitions and results above to decide whether the resolver gate, creator grouping/reuse rule and one-active-draft index are the complete original parent-order blocking chain. Do not write a migration until every listed consumer is reviewed.',
      'working_state_to_preserve', jsonb_build_array(
        'existing J040826 £10 draft',
        'existing exact J040826 active release membership',
        'exact-clean receipt compatibility',
        'exact shipment-batch queue draft/posted counts',
        'Mini-build 1 supplier identity',
        'Mini-build 2 tracking and package identity',
        'Mini-build 3 quantity/value guards and Sage route',
        'Mini-build 4 review/hold/exception controls'
      )
    )
  ) AS value
  FROM required_objects required
  CROSS JOIN target_batches batches
  CROSS JOIN commercial_parent_summary parent
  CROSS JOIN function_contracts contracts
  CROSS JOIN index_contracts indexes
  CROSS JOIN parent_draft_routine_consumers consumers
  CROSS JOIN index_catalog_dependencies dependencies
  CROSS JOIN target_invoice_json invoice_json
  CROSS JOIN target_memberships memberships
  CROSS JOIN active_parent_drafts parent_drafts
  CROSS JOIN resolver_summary resolver
  CROSS JOIN readiness_summary readiness
  CROSS JOIN queue_summary queue_rows
  CROSS JOIN active_membership_collisions collisions
)
SELECT value AS result
FROM result;

ROLLBACK;
