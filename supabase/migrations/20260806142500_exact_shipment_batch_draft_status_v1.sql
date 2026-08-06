BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/governing-pack/architecture/
-- EXACT_SHIPMENT_BATCH_DRAFT_STATUS_CORRECTION_ADDENDUM_v1.md
-- docs/addenda/
-- CUSTOMER_RELEASE_QUEUE_EXACT_SHIPMENT_BATCH_DRAFT_STATUS_AMENDMENT_v1.md
--
-- Exact scope:
--   * replace only draft_count and posted_count inside
--     public.internal_customer_invoice_release_queue_v1();
--   * count an invoice only when its active release ledger contains the exact
--     queue shipment_batch_id;
--   * no operational-row DML and no UI, resolver, preview, creator, ledger,
--     guard, invoice, Sage, VAT, AP, receipt, shipment or order-status change.

DO $migration$
DECLARE
  v_queue_oid regprocedure :=
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure;
  v_definition_before text;
  v_definition_after text;
  v_definition_replaced text;
  v_definition_restored text;
  v_compact_before text;
  v_compact_after text;
  v_actual_md5 text;
  v_count integer;

  v_owner_before oid;
  v_acl_before aclitem[];
  v_security_before boolean;
  v_config_before text[];
  v_language_before oid;
  v_identity_arguments_before text;
  v_arguments_before text;
  v_result_before text;

  v_owner_after oid;
  v_acl_after aclitem[];
  v_security_after boolean;
  v_config_after text[];
  v_language_after oid;
  v_identity_arguments_after text;
  v_arguments_after text;
  v_result_after text;

  v_old_draft text :=
    $old$COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'draft')::integer AS draft_count$old$;
  v_old_posted text :=
    $old$COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'posted')::integer AS posted_count$old$;

  v_draft_pattern text :=
    $pattern$COUNT[[:space:]]*\([[:space:]]*DISTINCT[[:space:]]+invoice\.id[[:space:]]*\)[[:space:]]*FILTER[[:space:]]*\([[:space:]]*WHERE[[:space:]]+invoice\.sage_status[[:space:]]*=[[:space:]]*'draft'[[:space:]]*\)[[:space:]]*::integer[[:space:]]+AS[[:space:]]+draft_count$pattern$;
  v_posted_pattern text :=
    $pattern$COUNT[[:space:]]*\([[:space:]]*DISTINCT[[:space:]]+invoice\.id[[:space:]]*\)[[:space:]]*FILTER[[:space:]]*\([[:space:]]*WHERE[[:space:]]+invoice\.sage_status[[:space:]]*=[[:space:]]*'posted'[[:space:]]*\)[[:space:]]*::integer[[:space:]]+AS[[:space:]]+posted_count$pattern$;

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
  IF to_regprocedure(
       'public.internal_customer_invoice_release_queue_v1()'
     ) IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
  THEN
    RAISE EXCEPTION
      'Exact shipment-batch draft-status prerequisites are missing.';
  END IF;

  SELECT pg_get_functiondef(v_queue_oid)
  INTO v_definition_before;

  v_actual_md5 := md5(v_definition_before);
  IF v_actual_md5 IS DISTINCT FROM '823d4488e24c335596d55351c3e752c3' THEN
    RAISE EXCEPTION
      'Queue fingerprint mismatch: expected %, found %',
      '823d4488e24c335596d55351c3e752c3',
      v_actual_md5;
  END IF;

  SELECT
    p.proowner,
    p.proacl,
    p.prosecdef,
    p.proconfig,
    p.prolang,
    pg_get_function_identity_arguments(p.oid),
    pg_get_function_arguments(p.oid),
    pg_get_function_result(p.oid)
  INTO
    v_owner_before,
    v_acl_before,
    v_security_before,
    v_config_before,
    v_language_before,
    v_identity_arguments_before,
    v_arguments_before,
    v_result_before
  FROM pg_proc p
  WHERE p.oid = v_queue_oid;

  IF v_identity_arguments_before IS DISTINCT FROM ''
     OR v_arguments_before IS DISTINCT FROM ''
     OR v_result_before IS DISTINCT FROM
       'TABLE(shipment_batch_id uuid, booking_ref text, importer_id uuid, importer_name text, shipper_id uuid, shipper_name text, proposed_invoice_type text, customer_action_label text, sales_invoice_state text, vat_code text, proposed_amount_gbp numeric, proposed_goods_amount_gbp numeric, proposed_shipping_amount_gbp numeric, order_count integer, line_count integer, ready_line_count integer, blocker_count integer, blockers text[], readiness_status text, first_order_ref text, order_refs text, created_draft_count integer, posted_invoice_count integer, queue_action text)'
     OR NOT v_security_before
     OR NOT has_function_privilege('authenticated', v_queue_oid, 'EXECUTE')
     OR has_function_privilege('public', v_queue_oid, 'EXECUTE')
  THEN
    RAISE EXCEPTION 'Queue contract or permission baseline mismatch.';
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
    RAISE EXCEPTION 'Protected Mini Build definition mismatch.';
  END IF;

  v_compact_before := regexp_replace(
    lower(v_definition_before),
    '[[:space:]]+',
    '',
    'g'
  );

  IF strpos(
       v_compact_before,
       'internal_customer_sales_release_exact_clean_proof_v1'
     ) = 0
     OR strpos(
       v_compact_before,
       'internal_shipping_customer_invoice_readiness_preview_v1'
     ) = 0
     OR strpos(v_compact_before, 'ready_to_create_draft') = 0
     OR strpos(v_compact_before, 'draft_exists') = 0
     OR strpos(v_compact_before, 'posted_exists') = 0
     OR strpos(v_compact_before, 'review_existing_draft') = 0
     OR strpos(v_compact_before, 'review_posted_invoice') = 0
     OR strpos(v_compact_before, 'resolve_blockers') = 0
  THEN
    RAISE EXCEPTION 'Existing queue routing contract is incomplete.';
  END IF;

  SELECT count(*)
  INTO v_count
  FROM regexp_matches(v_definition_before, v_draft_pattern, 'gi');
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Existing draft count expression expected once, found %.',
      v_count;
  END IF;

  SELECT count(*)
  INTO v_count
  FROM regexp_matches(v_definition_before, v_posted_pattern, 'gi');
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Existing posted count expression expected once, found %.',
      v_count;
  END IF;

  IF strpos(
       v_compact_before,
       'release_line.source_shipment_batch_id=preview.shipment_batch_id'
     ) > 0
     OR strpos(
       v_compact_before,
       'release_line.release_status=''active'''
     ) > 0
  THEN
    RAISE EXCEPTION
      'Exact shipment-batch draft-status predicates are already present.';
  END IF;

  v_definition_replaced := regexp_replace(
    v_definition_before,
    v_draft_pattern,
    v_new_draft,
    'i'
  );
  v_definition_replaced := regexp_replace(
    v_definition_replaced,
    v_posted_pattern,
    v_new_posted,
    'i'
  );

  IF v_definition_replaced = v_definition_before THEN
    RAISE EXCEPTION 'Queue exact-membership replacement made no change.';
  END IF;

  EXECUTE v_definition_replaced;

  v_queue_oid :=
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure;

  SELECT pg_get_functiondef(v_queue_oid)
  INTO v_definition_after;

  SELECT
    p.proowner,
    p.proacl,
    p.prosecdef,
    p.proconfig,
    p.prolang,
    pg_get_function_identity_arguments(p.oid),
    pg_get_function_arguments(p.oid),
    pg_get_function_result(p.oid)
  INTO
    v_owner_after,
    v_acl_after,
    v_security_after,
    v_config_after,
    v_language_after,
    v_identity_arguments_after,
    v_arguments_after,
    v_result_after
  FROM pg_proc p
  WHERE p.oid = v_queue_oid;

  IF v_owner_after IS DISTINCT FROM v_owner_before
     OR v_acl_after IS DISTINCT FROM v_acl_before
     OR v_security_after IS DISTINCT FROM v_security_before
     OR v_config_after IS DISTINCT FROM v_config_before
     OR v_language_after IS DISTINCT FROM v_language_before
     OR v_identity_arguments_after IS DISTINCT FROM v_identity_arguments_before
     OR v_arguments_after IS DISTINCT FROM v_arguments_before
     OR v_result_after IS DISTINCT FROM v_result_before
  THEN
    RAISE EXCEPTION 'Queue function contract changed outside permitted counts.';
  END IF;

  v_compact_after := regexp_replace(
    lower(v_definition_after),
    '[[:space:]]+',
    '',
    'g'
  );

  IF (
       length(v_compact_after)
       - length(replace(
           v_compact_after,
           'release_line.source_shipment_batch_id=preview.shipment_batch_id',
           ''
         ))
     ) / length(
       'release_line.source_shipment_batch_id=preview.shipment_batch_id'
     ) IS DISTINCT FROM 2
     OR (
       length(v_compact_after)
       - length(replace(
           v_compact_after,
           'release_line.release_status=''active''',
           ''
         ))
     ) / length(
       'release_line.release_status=''active'''
     ) IS DISTINCT FROM 2
     OR strpos(
       v_compact_after,
       'count(distinctinvoice.id)filter(whereinvoice.sage_status=''draft'')::integerasdraft_count'
     ) > 0
     OR strpos(
       v_compact_after,
       'count(distinctinvoice.id)filter(whereinvoice.sage_status=''posted'')::integerasposted_count'
     ) > 0
  THEN
    RAISE EXCEPTION 'Exact shipment-batch count predicates are incomplete.';
  END IF;

  v_definition_restored := replace(
    v_definition_after,
    v_new_draft,
    v_old_draft
  );
  v_definition_restored := replace(
    v_definition_restored,
    v_new_posted,
    v_old_posted
  );

  IF md5(v_definition_restored) IS DISTINCT FROM
       '823d4488e24c335596d55351c3e752c3'
  THEN
    RAISE EXCEPTION
      'Reverse-substitution proof failed: the patch changed more than the two governed count expressions.';
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
    RAISE EXCEPTION 'Protected Mini Build definition changed.';
  END IF;
END;
$migration$;

NOTIFY pgrst, 'reload schema';

COMMIT;
