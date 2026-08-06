BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Read-only preflight for:
-- docs/governing-pack/architecture/
-- INDEPENDENT_SHIPMENT_BATCH_CUSTOMER_DRAFT_LIFECYCLE_CORRECTION_ADDENDUM_v1.md
--
-- Purpose:
--   * freeze the current installed resolver, creator, queue and index baseline;
--   * confirm the existing J040826 invoice and ledger remain correct;
--   * prove J040826v1 is blocked only by the old parent-order draft design;
--   * identify every uniqueness/concurrency control that must be replaced;
--   * perform no persistent operational-row DML.

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

  PERFORM set_config(
    'request.jwt.claim.sub',
    v_auth_user_id::text,
    true
  );
END;
$auth_context$;

DO $preflight$
DECLARE
  v_j040826_batch uuid;
  v_j040826v1_batch uuid;
  v_parent_order uuid :=
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid;
  v_target_invoice uuid :=
    'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid;
  v_count integer;
BEGIN
  IF to_regprocedure(
       'public.internal_customer_sales_release_sources_v1(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'
     ) IS NULL
     OR to_regprocedure(
       'public.internal_customer_invoice_release_queue_v1()'
     ) IS NULL
     OR to_regprocedure(
       'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'
     ) IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: required customer-release objects are missing';
  END IF;

  SELECT batch.id
  INTO v_j040826_batch
  FROM public.shipper_shipment_batches batch
  WHERE batch.booking_ref = 'J040826'
  ORDER BY batch.created_at DESC, batch.id DESC
  LIMIT 1;

  SELECT batch.id
  INTO v_j040826v1_batch
  FROM public.shipper_shipment_batches batch
  WHERE batch.booking_ref = 'J040826v1'
  ORDER BY batch.created_at DESC, batch.id DESC
  LIMIT 1;

  IF v_j040826_batch IS DISTINCT FROM
       '1d8ed4af-4d35-4b2d-9913-9bae1a20a717'::uuid
     OR v_j040826v1_batch IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: target shipment batches are missing or changed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice
    WHERE invoice.id = v_target_invoice
      AND invoice.order_id = v_parent_order
      AND invoice.invoice_type = 'supplementary'
      AND invoice.sage_status = 'draft'
      AND invoice.amount_gbp = 10
  ) THEN
    RAISE EXCEPTION 'FAIL: existing J040826 £10 draft changed';
  END IF;

  SELECT count(*)
  INTO v_count
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.sales_invoice_id = v_target_invoice
    AND release_line.release_status = 'active';

  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'FAIL: existing J040826 draft active membership count is %, expected 1',
      v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id = v_target_invoice
      AND release_line.source_shipment_batch_id = v_j040826_batch
      AND release_line.tracking_line_allocation_id =
          '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      AND release_line.release_status = 'active'
      AND release_line.released_qty = 1
      AND release_line.goods_amount_gbp = 10
      AND release_line.shipping_amount_gbp = 0
      AND release_line.customer_charge_amount_gbp = 10
      AND release_line.membership_fingerprint =
          'f9f4041d776bd6f5dc632323a0eff373'
  ) THEN
    RAISE EXCEPTION 'FAIL: existing J040826 exact membership changed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.source_shipment_batch_id = v_j040826v1_batch
      AND release_line.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'FAIL: J040826v1 already has an active release membership';
  END IF;

  SELECT count(*)
  INTO v_count
  FROM (
    SELECT release_line.membership_fingerprint
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.membership_fingerprint
    HAVING count(*) > 1
  ) duplicate_fingerprint;

  IF v_count > 0 THEN
    RAISE EXCEPTION
      'FAIL: % duplicate active membership fingerprints exist',
      v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes index_row
    WHERE index_row.schemaname = 'public'
      AND index_row.indexname =
          'uq_sales_invoices_active_release_draft_v1'
      AND lower(index_row.indexdef) LIKE '%unique%'
      AND lower(index_row.indexdef) LIKE '%sales_invoices%'
      AND lower(index_row.indexdef) LIKE '%order_id%'
      AND lower(index_row.indexdef) LIKE '%sage_status%'
      AND lower(index_row.indexdef) LIKE '%draft%'
  ) THEN
    RAISE EXCEPTION
      'FAIL: expected one-active-draft-per-order index is missing or changed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes index_row
    WHERE index_row.schemaname = 'public'
      AND index_row.indexname = 'uq_sales_invoices_nonvoid_main_v1'
  ) THEN
    RAISE EXCEPTION 'FAIL: one-nonvoid-main index is missing';
  END IF;
END;
$preflight$;

ROLLBACK;

WITH target_batches AS (
  SELECT
    batch.id,
    batch.booking_ref
  FROM public.shipper_shipment_batches batch
  WHERE batch.booking_ref IN ('J040826', 'J040826v1')
), resolver_rows AS (
  SELECT
    target.booking_ref,
    target.id AS shipment_batch_id,
    source_row.tracking_line_allocation_id,
    source_row.customer_charge_amount_gbp,
    source_row.proposed_invoice_type,
    source_row.sales_invoice_state,
    source_row.blocker
  FROM target_batches target
  CROSS JOIN LATERAL
    public.internal_customer_sales_release_sources_v1(target.id) source_row
), queue_rows AS (
  SELECT queue_row.*
  FROM public.internal_customer_invoice_release_queue_v1() queue_row
  WHERE queue_row.shipment_batch_id IN (
    SELECT target.id FROM target_batches target
  )
), index_rows AS (
  SELECT
    index_row.indexname,
    index_row.indexdef
  FROM pg_indexes index_row
  WHERE index_row.schemaname = 'public'
    AND index_row.indexname IN (
      'uq_sales_invoices_active_release_draft_v1',
      'uq_sales_invoices_nonvoid_main_v1',
      'uq_csrl_invoice_membership',
      'idx_csrl_batch_active',
      'idx_csrl_parent_active'
    )
), function_rows AS (
  SELECT *
  FROM (VALUES
    (
      'resolver',
      md5(pg_get_functiondef(
        'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
      ))
    ),
    (
      'draft_creator',
      md5(pg_get_functiondef(
        'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
      ))
    ),
    (
      'queue',
      md5(pg_get_functiondef(
        'public.internal_customer_invoice_release_queue_v1()'::regprocedure
      ))
    ),
    (
      'readiness_preview',
      md5(pg_get_functiondef(
        'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
      ))
    ),
    (
      'remaining_preview',
      md5(pg_get_functiondef(
        'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'::regprocedure
      ))
    ),
    (
      'release_guard',
      md5(pg_get_functiondef(
        'public.customer_sales_release_guard_v1()'::regprocedure
      ))
    ),
    (
      'financial_guard',
      md5(pg_get_functiondef(
        'public.customer_sales_release_financial_guard_v1()'::regprocedure
      ))
    ),
    (
      'total_guard',
      md5(pg_get_functiondef(
        'public.customer_sales_release_total_guard_v1()'::regprocedure
      ))
    ),
    (
      'exact_clean_helper',
      md5(pg_get_functiondef(
        'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'::regprocedure
      ))
    )
  ) fingerprint(name, md5)
), target_invoice AS (
  SELECT
    invoice.id,
    invoice.order_id,
    invoice.invoice_type,
    invoice.sage_status,
    invoice.amount_gbp,
    invoice.created_at,
    invoice.line_items_json #> '{draft_control,shipment_batch_ids}'
      AS shipment_batch_ids
  FROM public.sales_invoices invoice
  WHERE invoice.id =
        'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
), target_memberships AS (
  SELECT
    release_line.id,
    release_line.sales_invoice_id,
    release_line.source_shipment_batch_id,
    batch.booking_ref,
    release_line.tracking_line_allocation_id,
    release_line.released_qty,
    release_line.goods_amount_gbp,
    release_line.shipping_amount_gbp,
    release_line.customer_charge_amount_gbp,
    release_line.release_status,
    release_line.membership_fingerprint
  FROM public.customer_sales_release_lines release_line
  LEFT JOIN public.shipper_shipment_batches batch
    ON batch.id = release_line.source_shipment_batch_id
  WHERE release_line.sales_invoice_id =
        'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
), parent_drafts AS (
  SELECT
    invoice.id,
    invoice.invoice_type,
    invoice.sage_status,
    invoice.amount_gbp,
    invoice.created_at,
    COALESCE(
      jsonb_agg(DISTINCT jsonb_build_object(
        'shipment_batch_id', release_line.source_shipment_batch_id,
        'booking_ref', batch.booking_ref,
        'release_status', release_line.release_status
      )) FILTER (WHERE release_line.id IS NOT NULL),
      '[]'::jsonb
    ) AS release_memberships
  FROM public.sales_invoices invoice
  LEFT JOIN public.customer_sales_release_lines release_line
    ON release_line.sales_invoice_id = invoice.id
  LEFT JOIN public.shipper_shipment_batches batch
    ON batch.id = release_line.source_shipment_batch_id
  WHERE invoice.order_id =
        '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
    AND invoice.invoice_type IN ('main', 'supplementary')
    AND invoice.sage_status = 'draft'
  GROUP BY
    invoice.id,
    invoice.invoice_type,
    invoice.sage_status,
    invoice.amount_gbp,
    invoice.created_at
)
SELECT jsonb_build_object(
  'preflight',
    'independent_shipment_batch_draft_lifecycle_db_preflight_v1',
  'status', 'passed',
  'note',
    'Use the returned current fingerprints, index definitions and target resolver rows as the exact governed baseline. No production migration should be written from historical definitions.',
  'current_fingerprints', (
    SELECT jsonb_object_agg(function_row.name, function_row.md5)
    FROM function_rows function_row
  ),
  'current_indexes', (
    SELECT jsonb_agg(
      jsonb_build_object(
        'index_name', index_row.indexname,
        'index_definition', index_row.indexdef
      )
      ORDER BY index_row.indexname
    )
    FROM index_rows index_row
  ),
  'target_resolver_rows', (
    SELECT jsonb_agg(
      jsonb_build_object(
        'booking_ref', resolver_row.booking_ref,
        'shipment_batch_id', resolver_row.shipment_batch_id,
        'tracking_line_allocation_id',
          resolver_row.tracking_line_allocation_id,
        'customer_charge_amount_gbp',
          resolver_row.customer_charge_amount_gbp,
        'proposed_invoice_type', resolver_row.proposed_invoice_type,
        'sales_invoice_state', resolver_row.sales_invoice_state,
        'blocker', resolver_row.blocker
      )
      ORDER BY resolver_row.booking_ref,
               resolver_row.tracking_line_allocation_id
    )
    FROM resolver_rows resolver_row
  ),
  'target_queue_rows', (
    SELECT jsonb_agg(to_jsonb(queue_row) ORDER BY queue_row.booking_ref)
    FROM queue_rows queue_row
  ),
  'target_invoice', (
    SELECT to_jsonb(invoice_row)
    FROM target_invoice invoice_row
  ),
  'target_memberships', (
    SELECT jsonb_agg(
      to_jsonb(membership_row)
      ORDER BY membership_row.id
    )
    FROM target_memberships membership_row
  ),
  'active_parent_drafts', (
    SELECT jsonb_agg(
      to_jsonb(parent_draft)
      ORDER BY parent_draft.created_at, parent_draft.id
    )
    FROM parent_drafts parent_draft
  ),
  'duplicate_active_membership_fingerprint_count', (
    SELECT count(*)
    FROM (
      SELECT release_line.membership_fingerprint
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.release_status = 'active'
      GROUP BY release_line.membership_fingerprint
      HAVING count(*) > 1
    ) duplicate_fingerprint
  ),
  'persistent_rows_changed', false
) AS result;
