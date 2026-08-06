BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Rollback-only regression for:
-- docs/governing-pack/architecture/
-- HYBRID_PHYSICAL_RECEIPT_EXACT_CLEAN_LINE_CUSTOMER_RELEASE_COMPATIBILITY_ADDENDUM_v1.md
--
-- This regression performs no customer draft creation because SQL Editor has no
-- authenticated staff JWT. Authenticated draft creation remains a preview/live
-- acceptance step. Every statement in this file is read-only and the transaction
-- is rolled back.

DO $catalog_checks$
DECLARE
  v_actual text;
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'Exact clean-line proof helper is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'LANGUAGE sql') = 0
     OR strpos(v_definition, 'SECURITY DEFINER') = 0
     OR strpos(v_definition, 'shipper_shipment_batch_effective_lines_v1') = 0
     OR strpos(v_definition, 'internal_tracking_allocation_fulfilment_position_v1') = 0
     OR strpos(v_definition, 'immutable_snapshot') = 0
     OR strpos(v_definition, 'v2_exact') = 0
     OR strpos(v_definition, 'position_valid_yn = true') = 0
     OR strpos(v_definition, 'physical_clean_qty + 0.0005') = 0
     OR strpos(v_definition, 'shipped_qty + 0.0005') = 0 THEN
    RAISE EXCEPTION 'Exact clean-line proof helper contract is incomplete.';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Private exact clean-line helper is exposed to browser roles.';
  END IF;

  IF NOT has_function_privilege(
       'service_role',
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Service-role diagnostic execute grant is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;
  IF strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'package_not_received_clean') = 0
     OR strpos(v_definition, 'customer_sales_release_draft_already_exists') = 0
     OR strpos(v_definition, 'supplier_invoice_not_approved_current') = 0
     OR strpos(v_definition, 'supplier_line_not_progressed') = 0
     OR strpos(v_definition, 'customer_hold_active') = 0
     OR strpos(v_definition, 'unresolved_exception') = 0
     OR strpos(v_definition, 'terminal_refund_line_excluded') = 0
     OR strpos(v_definition, 'released_shipping_exceeds_current_approved_allocation') = 0
     OR strpos(v_definition, 'shipping_only_main_not_permitted') = 0
     OR strpos(v_definition, 'source_fully_released') = 0 THEN
    RAISE EXCEPTION 'Resolver compatibility or existing blocker contract is incomplete.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  ) INTO v_definition;
  IF strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'receipt_status_summary') = 0
     OR strpos(v_definition, 'received_clean') = 0
     OR strpos(v_definition, 'internal_shipping_customer_invoice_readiness_preview_v1') = 0
     OR strpos(v_definition, 'ready_to_create_draft') = 0
     OR strpos(v_definition, 'draft_exists') = 0
     OR strpos(v_definition, 'posted_exists') = 0 THEN
    RAISE EXCEPTION 'Queue compatibility or existing readiness contract is incomplete.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'ae13557433f5e8500985b00266347807' THEN
    RAISE EXCEPTION 'Fulfilment position fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_tracking_allocation_fulfilment_routing_position_v2(uuid,uuid,uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '77b92854c8cdaca46db4471a32337b1f' THEN
    RAISE EXCEPTION 'Routing position fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_shipment_batch_effective_lines_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '82b4ec6bfd8f9fba09d37871917d0dc4' THEN
    RAISE EXCEPTION 'Effective shipment lines fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '62f5a84b0dd79ec7b09c5ef048747c65' THEN
    RAISE EXCEPTION 'Shipment creation fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '2e75a619e3cc3cc2fc364d3cb5a85cc3' THEN
    RAISE EXCEPTION 'Draft creator fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '25be89183956fe7f756472b0075b4f58' THEN
    RAISE EXCEPTION 'Readiness preview fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '0d6c54c50d5594a72b2af79700655020' THEN
    RAISE EXCEPTION 'Remaining preview fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.customer_sales_release_guard_v1()'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'd50b362d97a46f36a07acdb237231b46' THEN
    RAISE EXCEPTION 'Release guard fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.customer_sales_release_financial_guard_v1()'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'c492d47d33c6419d14d4cb26799fbfb9' THEN
    RAISE EXCEPTION 'Financial guard fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_resolved_customer_sales_sage_payload_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '4f8266c7932461b4e19afc789817d31f' THEN
    RAISE EXCEPTION 'Resolved Sage payload fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'e3bd71d7ec951731d60b0f04a18f5960' THEN
    RAISE EXCEPTION 'Pre-ledger Sage payload fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.approve_vat_release(uuid,uuid,jsonb)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '13491a2d250a480ebb1ac607ce7acce5' THEN
    RAISE EXCEPTION 'VAT authority fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.mark_order_accounting_release_ready(uuid,uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'dacaf00c6470a626cfc2d7e7aac2ccb8' THEN
    RAISE EXCEPTION 'Accounting readiness fingerprint changed: %', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.recompute_order_status(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'f7c40c868381252a5432f70894ca2b2f' THEN
    RAISE EXCEPTION 'Order status fingerprint changed: %', v_actual;
  END IF;
END
$catalog_checks$;

DO $target_checks$
DECLARE
  v_batch_id uuid;
  v_effective_count integer;
  v_true_count integer;
  v_false_count integer;
  v_target_proof boolean;
  v_target_qty numeric;
  v_target_goods numeric;
  v_target_source_mode text;
  v_clean numeric;
  v_exception numeric;
  v_reviewed numeric;
  v_shipped numeric;
  v_valid boolean;
  v_blocker text;
BEGIN
  SELECT id
  INTO v_batch_id
  FROM public.shipper_shipment_batches
  WHERE booking_ref = 'J040826'
  ORDER BY created_at DESC, id DESC
  LIMIT 1;

  IF v_batch_id IS DISTINCT FROM
     '1d8ed4af-4d35-4b2d-9913-9bae1a20a717'::uuid THEN
    RAISE EXCEPTION 'J040826 target batch is missing or changed: %', v_batch_id;
  END IF;

  SELECT COUNT(*)
  INTO v_effective_count
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);

  IF v_effective_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'J040826 must retain exactly one effective shipment line; found %',
      v_effective_count;
  END IF;

  SELECT
    effective.qty_in_shipment,
    effective.adjusted_net_value_gbp,
    effective.source_mode,
    public.internal_customer_sales_release_exact_clean_proof_v1(
      v_batch_id,
      effective.tracking_line_allocation_id
    )
  INTO
    v_target_qty,
    v_target_goods,
    v_target_source_mode,
    v_target_proof
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) effective
  WHERE effective.tracking_line_allocation_id =
    '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid;

  IF v_target_qty IS DISTINCT FROM 1
     OR v_target_goods IS DISTINCT FROM 10
     OR v_target_source_mode IS DISTINCT FROM 'immutable_snapshot'
     OR v_target_proof IS DISTINCT FROM true THEN
    RAISE EXCEPTION
      'J040826 exact clean-line proof mismatch: qty %, goods %, mode %, proof %',
      v_target_qty, v_target_goods, v_target_source_mode, v_target_proof;
  END IF;

  SELECT
    position.physical_clean_qty,
    position.physical_exception_qty,
    position.reviewed_qty,
    position.shipped_qty,
    position.position_valid_yn,
    position.position_blocker
  INTO
    v_clean,
    v_exception,
    v_reviewed,
    v_shipped,
    v_valid,
    v_blocker
  FROM public.internal_tracking_allocation_fulfilment_position_v1(
    '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid,
    'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid,
    '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
  ) position;

  IF v_clean IS DISTINCT FROM 1
     OR v_exception IS DISTINCT FROM 0
     OR v_reviewed IS DISTINCT FROM 1
     OR v_shipped IS DISTINCT FROM 1
     OR v_valid IS DISTINCT FROM true
     OR v_blocker IS NOT NULL THEN
    RAISE EXCEPTION
      'J040826 fulfilment position mismatch: clean %, exception %, reviewed %, shipped %, valid %, blocker %',
      v_clean, v_exception, v_reviewed, v_shipped, v_valid, v_blocker;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE proof.proven),
    COUNT(*) FILTER (WHERE NOT proof.proven)
  INTO v_true_count, v_false_count
  FROM (
    SELECT
      allocation.id,
      public.internal_customer_sales_release_exact_clean_proof_v1(
        v_batch_id,
        allocation.id
      ) AS proven
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.tracking_submission_id =
      'd9791dc1-3149-496d-b087-5ac8dcd28d3e'::uuid
  ) proof;

  IF v_true_count IS DISTINCT FROM 1
     OR v_false_count IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION
      'Exact proof must separate one clean and four diverted allocations; true %, false %',
      v_true_count, v_false_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.tracking_line_allocation_id =
      '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
      AND release_line.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'J040826 clean line unexpectedly already has an active release.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice
    WHERE invoice.order_id =
      '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
      AND invoice.invoice_type IN ('main', 'supplementary')
      AND invoice.sage_status = 'draft'
  ) THEN
    RAISE EXCEPTION 'J040826 order unexpectedly already has an active sales draft.';
  END IF;
END
$target_checks$;

SELECT jsonb_build_object(
  'regression', 'exact_clean_line_customer_release_compatibility_v1',
  'status', 'passed',
  'batch_id', '1d8ed4af-4d35-4b2d-9913-9bae1a20a717',
  'booking_ref', 'J040826',
  'proven_allocation_id', '9dd8c47c-9dd9-4191-910b-41095f15feee',
  'proven_qty', 1,
  'proven_goods_gbp', 10,
  'diverted_allocation_count', 4,
  'note', 'Authenticated queue, resolver and draft-creation acceptance remains a post-install staff-session test.'
) AS result;

ROLLBACK;
