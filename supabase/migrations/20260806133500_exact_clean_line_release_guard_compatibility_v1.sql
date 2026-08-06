BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governed by:
-- docs/governing-pack/architecture/
-- HYBRID_PHYSICAL_RECEIPT_EXACT_CLEAN_LINE_CUSTOMER_RELEASE_COMPATIBILITY_ADDENDUM_v1_1.md
--
-- Corrects the fourth and final package-clean gate discovered by authenticated
-- draft creation. This migration changes only the receipt predicate inside the
-- durable release-ledger trigger guard. The draft creator remains unchanged.

DO $$
DECLARE
  v_guard regprocedure := to_regprocedure('public.customer_sales_release_guard_v1()');
  v_helper regprocedure := to_regprocedure('public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)');
BEGIN
  IF v_helper IS NULL THEN
    RAISE EXCEPTION 'Missing exact-clean proof helper';
  END IF;

  IF v_guard IS NULL THEN
    RAISE EXCEPTION 'Missing customer sales release guard';
  END IF;

  IF md5(pg_get_functiondef(v_guard)) <> 'd50b362d97a46f36a07acdb237231b46' THEN
    RAISE EXCEPTION 'customer_sales_release_guard_v1 definition drifted from governed live baseline';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])')))
       <> '2e75a619e3cc3cc2fc364d3cb5a85cc3' THEN
    RAISE EXCEPTION 'Draft creator definition drifted';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)')))
       <> '25be89183956fe7f756472b0075b4f58' THEN
    RAISE EXCEPTION 'Readiness preview definition drifted';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)')))
       <> '0d6c54c50d5594a72b2af79700655020' THEN
    RAISE EXCEPTION 'Remaining preview definition drifted';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.customer_sales_release_financial_guard_v1()')))
       <> 'c492d47d33c6419d14d4cb26799fbfb9' THEN
    RAISE EXCEPTION 'Financial guard definition drifted';
  END IF;
END $$;

DO $$
DECLARE
  v_definition text;
  v_old text := $old$
  IF v_receipt IS DISTINCT FROM 'received_clean' THEN
    RAISE EXCEPTION 'Package is not currently received clean';
  END IF;
$old$;
  v_new text := $new$
  IF v_receipt IS DISTINCT FROM 'received_clean'
     AND (
       NEW.source_shipment_batch_id IS NULL
       OR NOT public.internal_customer_sales_release_exact_clean_proof_v1(
         NEW.source_shipment_batch_id,
         NEW.tracking_line_allocation_id
       )
     )
  THEN
    RAISE EXCEPTION 'Package is not currently received clean';
  END IF;
$new$;
BEGIN
  v_definition := pg_get_functiondef(
    to_regprocedure('public.customer_sales_release_guard_v1()')
  );

  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Expected package-clean guard predicate not found exactly once';
  END IF;

  IF length(v_definition) - length(replace(v_definition, v_old, ''))
       <> length(v_old) THEN
    RAISE EXCEPTION 'Expected package-clean guard predicate occurs more than once';
  END IF;

  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END $$;

DO $$
DECLARE
  v_definition text := pg_get_functiondef(
    to_regprocedure('public.customer_sales_release_guard_v1()')
  );
BEGIN
  IF v_definition NOT ILIKE '%internal_customer_sales_release_exact_clean_proof_v1(%' THEN
    RAISE EXCEPTION 'Release guard does not contain exact-clean proof compatibility branch';
  END IF;

  IF v_definition NOT ILIKE '%Package is not currently received clean%' THEN
    RAISE EXCEPTION 'Release guard package-clean exception changed';
  END IF;

  IF v_definition NOT ILIKE '%shipper_shipment_batch_effective_lines_v1%' THEN
    RAISE EXCEPTION 'Release guard effective shipment membership check changed';
  END IF;

  IF v_definition NOT ILIKE '%Active customer hold conflicts with release membership%' THEN
    RAISE EXCEPTION 'Release guard hold protection changed';
  END IF;

  IF v_definition NOT ILIKE '%Unresolved exception conflicts with release membership%' THEN
    RAISE EXCEPTION 'Release guard exception protection changed';
  END IF;

  IF v_definition NOT ILIKE '%Terminal refunded line cannot be attached to a customer sales release%' THEN
    RAISE EXCEPTION 'Release guard terminal refund protection changed';
  END IF;

  IF v_definition NOT ILIKE '%Release quantity exceeds exact effective shipment membership%' THEN
    RAISE EXCEPTION 'Release guard quantity protection changed';
  END IF;

  IF v_definition NOT ILIKE '%Release goods value exceeds exact effective shipment membership%' THEN
    RAISE EXCEPTION 'Release guard goods protection changed';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])')))
       <> '2e75a619e3cc3cc2fc364d3cb5a85cc3' THEN
    RAISE EXCEPTION 'Draft creator changed unexpectedly';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)')))
       <> '25be89183956fe7f756472b0075b4f58' THEN
    RAISE EXCEPTION 'Readiness preview changed unexpectedly';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)')))
       <> '0d6c54c50d5594a72b2af79700655020' THEN
    RAISE EXCEPTION 'Remaining preview changed unexpectedly';
  END IF;

  IF md5(pg_get_functiondef(to_regprocedure('public.customer_sales_release_financial_guard_v1()')))
       <> 'c492d47d33c6419d14d4cb26799fbfb9' THEN
    RAISE EXCEPTION 'Financial guard changed unexpectedly';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
