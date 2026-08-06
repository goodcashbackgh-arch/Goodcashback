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

  SELECT count(*)
  INTO v_count
  FROM regexp_matches(
    v_definition_before,
    regexp_replace(v_new_draft, '([\\.\\(\\)\\[\\]\\{\\}\\*\\+\\?\\^\\$\\|])', '\\\1', 'g'),
    'g'
  );
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Installed exact draft-count expression expected once, found %.',
      v_count;
  END IF;

  SELECT count(*)
  INTO v_count
  FROM regexp_matches(
    v_definition_before,
    regexp_replace(v_new_posted, '([\\.\\(\\)\\[\\]\\{\\}\\*\\+\\?\\^\\$\\|])', '\\\1', 'g'),
    'g'
  );
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

  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  )
  INTO v_definition_after;

  IF md5(v_definition_after) IS DISTINCT FROM
       '823d4488e24c335596d55351c3e752c3'
  THEN
    RAISE EXCEPTION
      'Rollback installed an unexpected queue definition: %',
      md5(v_definition_after);
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
