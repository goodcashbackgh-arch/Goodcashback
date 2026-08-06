BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Rollback-only authenticated post-install regression.
-- Calls the real queue under an active staff JWT context.
-- Performs no operational-row INSERT, UPDATE or DELETE.

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
      'FAIL: no active staff auth context available for regression';
  END IF;

  PERFORM set_config(
    'request.jwt.claim.sub',
    v_auth_user_id::text,
    true
  );
END;
$auth_context$;

DO $proof$
DECLARE
  v_queue_oid regprocedure :=
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure;
  v_definition text;
  v_restored_definition text;
  v_compact text;
  v_count integer;

  v_j040826_batch uuid;
  v_j040826v1_batch uuid;

  v_j040826_status text;
  v_j040826_action text;
  v_j040826_draft_count integer;
  v_j040826_posted_count integer;

  v_j040826v1_status text;
  v_j040826v1_action text;
  v_j040826v1_draft_count integer;
  v_j040826v1_posted_count integer;
  v_j040826v1_blocker_count integer;

  v_old_draft text :=
    $old$COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'draft')::integer AS draft_count$old$;
  v_old_posted text :=
    $old$COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'posted')::integer AS posted_count$old$;
  v_new_draft text :=
    $new$COUNT(DISTINCT invoice.id) FILTER (
        WHERE invoice.sage_status = 'draft'
          AND EXISTS (
            SELECT 1
            FROM public.customer_sales_release_lines release_line
            WHERE release_line.sales_invoice_id = invoice.id
              AND release_line.source_shipment_batch_id
                  = preview.shipment_batch_id
              AND release_line.release_status = 'active'
          )
      )::integer AS draft_count$new$;
  v_new_posted text :=
    $new$COUNT(DISTINCT invoice.id) FILTER (
        WHERE invoice.sage_status = 'posted'
          AND EXISTS (
            SELECT 1
            FROM public.customer_sales_release_lines release_line
            WHERE release_line.sales_invoice_id = invoice.id
              AND release_line.source_shipment_batch_id
                  = preview.shipment_batch_id
              AND release_line.release_status = 'active'
          )
      )::integer AS posted_count$new$;
BEGIN
  IF v_queue_oid IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: required queue objects are missing';
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

  SELECT
    queue_row.readiness_status,
    queue_row.queue_action,
    queue_row.created_draft_count,
    queue_row.posted_invoice_count
  INTO
    v_j040826_status,
    v_j040826_action,
    v_j040826_draft_count,
    v_j040826_posted_count
  FROM public.internal_customer_invoice_release_queue_v1() queue_row
  WHERE queue_row.shipment_batch_id = v_j040826_batch;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: J040826 is missing from the release queue';
  END IF;

  SELECT
    queue_row.readiness_status,
    queue_row.queue_action,
    queue_row.created_draft_count,
    queue_row.posted_invoice_count,
    queue_row.blocker_count
  INTO
    v_j040826v1_status,
    v_j040826v1_action,
    v_j040826v1_draft_count,
    v_j040826v1_posted_count,
    v_j040826v1_blocker_count
  FROM public.internal_customer_invoice_release_queue_v1() queue_row
  WHERE queue_row.shipment_batch_id = v_j040826v1_batch;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: J040826v1 is missing from the release queue';
  END IF;

  IF v_j040826_status IS DISTINCT FROM 'draft_exists'
     OR v_j040826_action IS DISTINCT FROM 'review_existing_draft'
     OR v_j040826_draft_count IS DISTINCT FROM 1
     OR v_j040826_posted_count IS DISTINCT FROM 0
  THEN
    RAISE EXCEPTION
      'FAIL: J040826 queue result is %, %, draft %, posted %',
      v_j040826_status,
      v_j040826_action,
      v_j040826_draft_count,
      v_j040826_posted_count;
  END IF;

  IF v_j040826v1_status IS DISTINCT FROM 'blocked'
     OR v_j040826v1_action IS DISTINCT FROM 'resolve_blockers'
     OR v_j040826v1_draft_count IS DISTINCT FROM 0
     OR v_j040826v1_posted_count IS DISTINCT FROM 0
     OR COALESCE(v_j040826v1_blocker_count, 0) <= 0
  THEN
    RAISE EXCEPTION
      'FAIL: J040826v1 queue result is %, %, draft %, posted %, blockers %',
      v_j040826v1_status,
      v_j040826v1_action,
      v_j040826v1_draft_count,
      v_j040826v1_posted_count,
      v_j040826v1_blocker_count;
  END IF;

  SELECT count(*)
  INTO v_count
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.sales_invoice_id =
        'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
    AND release_line.release_status = 'active';

  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'FAIL: target draft active membership count is %, expected 1',
      v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id =
          'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
      AND release_line.source_shipment_batch_id = v_j040826_batch
      AND release_line.tracking_line_allocation_id =
          '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      AND release_line.release_status = 'active'
      AND release_line.released_qty = 1
      AND release_line.goods_amount_gbp = 10
      AND release_line.shipping_amount_gbp = 0
      AND release_line.customer_charge_amount_gbp = 10
  ) THEN
    RAISE EXCEPTION 'FAIL: exact J040826 release membership changed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id =
          'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
      AND release_line.source_shipment_batch_id = v_j040826v1_batch
      AND release_line.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'FAIL: J040826v1 gained an active release membership';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice
    WHERE invoice.id =
          'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
      AND invoice.order_id =
          '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
      AND invoice.invoice_type = 'supplementary'
      AND invoice.sage_status = 'draft'
      AND invoice.amount_gbp = 10
  ) THEN
    RAISE EXCEPTION 'FAIL: target £10 supplementary draft changed';
  END IF;

  IF (
    SELECT count(DISTINCT payload_batch.value::uuid)
    FROM public.sales_invoices invoice
    CROSS JOIN LATERAL jsonb_array_elements_text(
      COALESCE(
        invoice.line_items_json #> '{draft_control,shipment_batch_ids}',
        '[]'::jsonb
      )
    ) payload_batch
    WHERE invoice.id =
          'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
  ) IS DISTINCT FROM 1
     OR NOT EXISTS (
       SELECT 1
       FROM public.sales_invoices invoice
       CROSS JOIN LATERAL jsonb_array_elements_text(
         COALESCE(
           invoice.line_items_json #> '{draft_control,shipment_batch_ids}',
           '[]'::jsonb
         )
       ) payload_batch
       WHERE invoice.id =
             'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
         AND payload_batch.value::uuid = v_j040826_batch
     )
  THEN
    RAISE EXCEPTION 'FAIL: target draft payload shipment membership changed';
  END IF;

  SELECT pg_get_functiondef(v_queue_oid)
  INTO v_definition;

  v_compact := regexp_replace(
    lower(v_definition),
    '[[:space:]]+',
    '',
    'g'
  );

  IF (
       length(v_compact)
       - length(replace(
           v_compact,
           'release_line.source_shipment_batch_id=preview.shipment_batch_id',
           ''
         ))
     ) / length(
       'release_line.source_shipment_batch_id=preview.shipment_batch_id'
     ) IS DISTINCT FROM 2
     OR (
       length(v_compact)
       - length(replace(
           v_compact,
           'release_line.release_status=''active''',
           ''
         ))
     ) / length(
       'release_line.release_status=''active'''
     ) IS DISTINCT FROM 2
     OR strpos(v_compact, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_compact, 'internal_shipping_customer_invoice_readiness_preview_v1') = 0
     OR strpos(v_compact, 'ready_to_create_draft') = 0
     OR strpos(v_compact, 'draft_exists') = 0
     OR strpos(v_compact, 'posted_exists') = 0
     OR strpos(v_compact, 'review_existing_draft') = 0
     OR strpos(v_compact, 'review_posted_invoice') = 0
     OR strpos(v_compact, 'resolve_blockers') = 0
  THEN
    RAISE EXCEPTION 'FAIL: queue exact-membership contract is incomplete';
  END IF;

  v_restored_definition := replace(
    v_definition,
    v_new_draft,
    v_old_draft
  );
  v_restored_definition := replace(
    v_restored_definition,
    v_new_posted,
    v_old_posted
  );

  IF md5(v_restored_definition) IS DISTINCT FROM
       '823d4488e24c335596d55351c3e752c3'
  THEN
    RAISE EXCEPTION
      'FAIL: reverse-substitution does not reproduce the governed queue baseline';
  END IF;

  IF pg_get_function_identity_arguments(v_queue_oid) IS DISTINCT FROM ''
     OR pg_get_function_arguments(v_queue_oid) IS DISTINCT FROM ''
     OR pg_get_function_result(v_queue_oid) IS DISTINCT FROM
       'TABLE(shipment_batch_id uuid, booking_ref text, importer_id uuid, importer_name text, shipper_id uuid, shipper_name text, proposed_invoice_type text, customer_action_label text, sales_invoice_state text, vat_code text, proposed_amount_gbp numeric, proposed_goods_amount_gbp numeric, proposed_shipping_amount_gbp numeric, order_count integer, line_count integer, ready_line_count integer, blocker_count integer, blockers text[], readiness_status text, first_order_ref text, order_refs text, created_draft_count integer, posted_invoice_count integer, queue_action text)'
     OR NOT has_function_privilege('authenticated', v_queue_oid, 'EXECUTE')
     OR has_function_privilege('public', v_queue_oid, 'EXECUTE')
  THEN
    RAISE EXCEPTION 'FAIL: queue signature or permissions changed';
  END IF;

  IF md5(pg_get_functiondef(
       'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
     )) IS DISTINCT FROM '4011a399f02cda16b5d962b8101f91e1'
     OR md5(pg_get_functiondef(
       'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
     )) IS DISTINCT FROM '2e75a619e3cc3cc2fc364d3cb5a85cc3'
     OR md5(pg_get_functiondef(
       'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
     )) IS DISTINCT FROM '25be89183956fe7f756472b0075b4f58'
     OR md5(pg_get_functiondef(
       'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'::regprocedure
     )) IS DISTINCT FROM '0d6c54c50d5594a72b2af79700655020'
     OR md5(pg_get_functiondef(
       'public.customer_sales_release_guard_v1()'::regprocedure
     )) IS DISTINCT FROM '2ed42ccd21ce8f0c9059ef7cddd90825'
     OR md5(pg_get_functiondef(
       'public.customer_sales_release_financial_guard_v1()'::regprocedure
     )) IS DISTINCT FROM 'c492d47d33c6419d14d4cb26799fbfb9'
     OR md5(pg_get_functiondef(
       'public.shipper_shipment_batch_effective_lines_v1(uuid)'::regprocedure
     )) IS DISTINCT FROM '82b4ec6bfd8f9fba09d37871917d0dc4'
     OR md5(pg_get_functiondef(
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'::regprocedure
     )) IS DISTINCT FROM '6209f9e26e8f7b57622b0c81374e6ef0'
  THEN
    RAISE EXCEPTION 'FAIL: protected Mini Build definition changed';
  END IF;
END;
$proof$;

ROLLBACK;

SELECT jsonb_build_object(
  'regression', 'exact_shipment_batch_draft_status_v1',
  'status', 'passed',
  'j040826', jsonb_build_object(
    'shipment_batch_id',
      '1d8ed4af-4d35-4b2d-9913-9bae1a20a717',
    'readiness_status', 'draft_exists',
    'created_draft_count', 1,
    'sales_invoice_id',
      'a3c939e4-0abb-4047-b828-cdc137130fd4',
    'amount_gbp', 10,
    'active_membership_count', 1
  ),
  'j040826v1', jsonb_build_object(
    'readiness_status', 'blocked',
    'created_draft_count', 0,
    'active_membership_count', 0
  ),
  'protected_mini_builds_1_to_3', true,
  'operational_rows_changed', false,
  'note',
    'Authenticated browser refresh remains the final visual acceptance: J040826 must show Draft already exists and J040826v1 must show Blocked.'
) AS result;
