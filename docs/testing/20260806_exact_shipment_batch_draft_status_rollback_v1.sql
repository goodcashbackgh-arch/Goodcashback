BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Compensating rollback for:
-- supabase/migrations/
-- 20260806142500_exact_shipment_batch_draft_status_v1.sql
--
-- Restores only the two queue aggregate expressions changed by that migration.
-- Performs no operational-row DML and leaves every earlier exact-clean,
-- resolver, guard, preview, draft, ledger and financial correction installed.

DO $rollback$
DECLARE
  v_queue_oid regprocedure :=
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure;
  v_definition_before text;
  v_definition_after text;
  v_definition_restored text;
  v_compact_before text;
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
  IF v_queue_oid IS NULL THEN
    RAISE EXCEPTION 'Queue function is missing.';
  END IF;

  SELECT pg_get_functiondef(v_queue_oid)
  INTO v_definition_before;

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
    RAISE EXCEPTION 'Installed queue contract or permissions are unexpected.';
  END IF;

  v_compact_before := regexp_replace(
    lower(v_definition_before),
    '[[:space:]]+',
    '',
    'g'
  );

  IF (
       length(v_compact_before)
       - length(replace(
           v_compact_before,
           'release_line.source_shipment_batch_id=preview.shipment_batch_id',
           ''
         ))
     ) / length(
       'release_line.source_shipment_batch_id=preview.shipment_batch_id'
     ) IS DISTINCT FROM 2
     OR (
       length(v_compact_before)
       - length(replace(
           v_compact_before,
           'release_line.release_status=''active''',
           ''
         ))
     ) / length(
       'release_line.release_status=''active'''
     ) IS DISTINCT FROM 2
  THEN
    RAISE EXCEPTION
      'Exact shipment-batch queue predicates are not installed exactly twice.';
  END IF;

  v_count := (
    length(v_definition_before)
    - length(replace(v_definition_before, v_new_draft, ''))
  ) / NULLIF(length(v_new_draft), 0);
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Installed exact draft-count expression expected once, found %.',
      v_count;
  END IF;

  v_count := (
    length(v_definition_before)
    - length(replace(v_definition_before, v_new_posted, ''))
  ) / NULLIF(length(v_new_posted), 0);
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Installed exact posted-count expression expected once, found %.',
      v_count;
  END IF;

  v_definition_restored := replace(
    v_definition_before,
    v_new_draft,
    v_old_draft
  );
  v_definition_restored := replace(
    v_definition_restored,
    v_new_posted,
    v_old_posted
  );

  IF v_definition_restored = v_definition_before
     OR md5(v_definition_restored) IS DISTINCT FROM
        '823d4488e24c335596d55351c3e752c3'
  THEN
    RAISE EXCEPTION
      'Rollback reverse-substitution did not reproduce the governed pre-install definition.';
  END IF;

  EXECUTE v_definition_restored;

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

  IF md5(v_definition_after) IS DISTINCT FROM
       '823d4488e24c335596d55351c3e752c3'
  THEN
    RAISE EXCEPTION
      'Rollback installed an unexpected queue definition: %',
      md5(v_definition_after);
  END IF;

  IF v_owner_after IS DISTINCT FROM v_owner_before
     OR v_acl_after IS DISTINCT FROM v_acl_before
     OR v_security_after IS DISTINCT FROM v_security_before
     OR v_config_after IS DISTINCT FROM v_config_before
     OR v_language_after IS DISTINCT FROM v_language_before
     OR v_identity_arguments_after IS DISTINCT FROM v_identity_arguments_before
     OR v_arguments_after IS DISTINCT FROM v_arguments_before
     OR v_result_after IS DISTINCT FROM v_result_before
     OR NOT has_function_privilege('authenticated', v_queue_oid, 'EXECUTE')
     OR has_function_privilege('public', v_queue_oid, 'EXECUTE')
  THEN
    RAISE EXCEPTION
      'Rollback changed the queue contract or permissions outside the two aggregates.';
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
    RAISE EXCEPTION 'Protected Mini Build definition changed during rollback.';
  END IF;
END;
$rollback$;

NOTIFY pgrst, 'reload schema';

COMMIT;
