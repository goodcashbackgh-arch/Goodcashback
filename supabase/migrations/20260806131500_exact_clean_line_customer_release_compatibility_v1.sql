BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/governing-pack/architecture/
-- HYBRID_PHYSICAL_RECEIPT_EXACT_CLEAN_LINE_CUSTOMER_RELEASE_COMPATIBILITY_ADDENDUM_v1.md
--
-- Exact three-object patch only:
--   1. one private read-only helper;
--   2. one resolver receipt predicate;
--   3. one queue batch-admission predicate.
--
-- No operational-row DML and no application, table, trigger, receipt,
-- shipment, review, refund, replacement, Sage or VAT changes.

DO $preflight$
DECLARE
  v_actual text;
BEGIN
  IF to_regprocedure(
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION
      'Exact clean-line customer-release helper already exists; inspect target.';
  END IF;

  IF to_regprocedure(
       'public.internal_customer_sales_release_sources_v1(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.internal_customer_invoice_release_queue_v1()'
     ) IS NULL
     OR to_regprocedure(
       'public.shipper_shipment_batch_effective_lines_v1(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Exact clean-line customer-release prerequisites are missing.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '1ae9d8f827ee5f08a7103fbc2157e130' THEN
    RAISE EXCEPTION
      'Resolver fingerprint mismatch: expected %, found %',
      '1ae9d8f827ee5f08a7103fbc2157e130', v_actual;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '7c4587e4ca91e5bf246f3f02281b2b98' THEN
    RAISE EXCEPTION
      'Queue fingerprint mismatch: expected %, found %',
      '7c4587e4ca91e5bf246f3f02281b2b98', v_actual;
  END IF;
END
$preflight$;

CREATE FUNCTION public.internal_customer_sales_release_exact_clean_proof_v1(
  p_shipment_batch_id uuid,
  p_tracking_line_allocation_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_effective_lines_v1(
      p_shipment_batch_id
    ) effective_line
    CROSS JOIN LATERAL
      public.internal_tracking_allocation_fulfilment_position_v1(
        effective_line.order_id,
        effective_line.tracking_submission_id,
        effective_line.tracking_line_allocation_id
      ) position
    WHERE effective_line.tracking_line_allocation_id
          = p_tracking_line_allocation_id
      AND effective_line.source_mode = 'immutable_snapshot'
      AND effective_line.qty_in_shipment > 0
      AND position.source_receipt_model = 'v2_exact'
      AND position.position_valid_yn = true
      AND position.physical_clean_qty + 0.0005
          >= position.shipped_qty
      AND position.shipped_qty + 0.0005
          >= effective_line.qty_in_shipment
  );
$function$;

ALTER FUNCTION
  public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION
  public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)
  TO service_role;

COMMENT ON FUNCTION
  public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)
IS
'Private fail-closed proof that one immutable effective shipment membership remains covered by a valid exact v2 clean physical position. It does not alter package status or calculate customer invoice values.';

DO $replace_resolver$
DECLARE
  v_definition text;
  v_replaced text;
  v_pattern text :=
    $pattern$WHEN\s+emitted_row\.latest_receipt_status\s+IS\s+DISTINCT\s+FROM\s+'received_clean'\s+THEN\s+'package_not_received_clean'$pattern$;
  v_replacement text :=
    $replacement$WHEN emitted_row.latest_receipt_status IS DISTINCT FROM 'received_clean'
       AND NOT public.internal_customer_sales_release_exact_clean_proof_v1(
         emitted_row.batch_id,
         emitted_row.tracking_line_allocation_id
       )
        THEN 'package_not_received_clean'$replacement$;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  IF (SELECT COUNT(*)
      FROM regexp_matches(v_definition, v_pattern, 'gi')) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Resolver package receipt predicate was not found exactly once.';
  END IF;

  v_replaced := regexp_replace(
    v_definition,
    v_pattern,
    v_replacement,
    'gi'
  );

  IF v_replaced = v_definition
     OR strpos(
       v_replaced,
       'internal_customer_sales_release_exact_clean_proof_v1'
     ) = 0
  THEN
    RAISE EXCEPTION 'Resolver predicate replacement failed closed.';
  END IF;

  EXECUTE v_replaced;
END
$replace_resolver$;

DO $replace_queue$
DECLARE
  v_definition text;
  v_replaced text;
  v_pattern text :=
    $pattern$AND\s+COALESCE\(shipping_control\.receipt_status_summary,\s*''\)\s*=\s*'received_clean'$pattern$;
  v_replacement text :=
    $replacement$AND (
        COALESCE(shipping_control.receipt_status_summary, '') = 'received_clean'
        OR EXISTS (
          SELECT 1
          FROM public.shipper_shipment_batch_effective_lines_v1(
            shipping_control.shipment_batch_id
          ) effective_line
          WHERE public.internal_customer_sales_release_exact_clean_proof_v1(
            shipping_control.shipment_batch_id,
            effective_line.tracking_line_allocation_id
          )
        )
      )$replacement$;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  ) INTO v_definition;

  IF (SELECT COUNT(*)
      FROM regexp_matches(v_definition, v_pattern, 'gi')) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Queue received-clean batch predicate was not found exactly once.';
  END IF;

  v_replaced := regexp_replace(
    v_definition,
    v_pattern,
    v_replacement,
    'gi'
  );

  IF v_replaced = v_definition
     OR strpos(
       v_replaced,
       'internal_customer_sales_release_exact_clean_proof_v1'
     ) = 0
  THEN
    RAISE EXCEPTION 'Queue predicate replacement failed closed.';
  END IF;

  EXECUTE v_replaced;
END
$replace_queue$;

DO $postflight$
DECLARE
  v_actual text;
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'Exact clean-line proof helper was not installed.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;
  IF strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'package_not_received_clean') = 0 THEN
    RAISE EXCEPTION 'Resolver compatibility predicate is incomplete.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  ) INTO v_definition;
  IF strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'internal_shipping_customer_invoice_readiness_preview_v1') = 0
     OR strpos(v_definition, 'ready_to_create_draft') = 0
     OR strpos(v_definition, 'draft_exists') = 0
     OR strpos(v_definition, 'posted_exists') = 0 THEN
    RAISE EXCEPTION 'Queue compatibility predicate or existing route changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'ae13557433f5e8500985b00266347807' THEN
    RAISE EXCEPTION 'Protected fulfilment position changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_tracking_allocation_fulfilment_routing_position_v2(uuid,uuid,uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '77b92854c8cdaca46db4471a32337b1f' THEN
    RAISE EXCEPTION 'Protected routing position changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_shipment_batch_effective_lines_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '82b4ec6bfd8f9fba09d37871917d0dc4' THEN
    RAISE EXCEPTION 'Protected effective shipment-line authority changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '62f5a84b0dd79ec7b09c5ef048747c65' THEN
    RAISE EXCEPTION 'Protected shipment writer changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '2e75a619e3cc3cc2fc364d3cb5a85cc3' THEN
    RAISE EXCEPTION 'Protected draft creator changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '25be89183956fe7f756472b0075b4f58' THEN
    RAISE EXCEPTION 'Protected readiness preview changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '0d6c54c50d5594a72b2af79700655020' THEN
    RAISE EXCEPTION 'Protected remaining preview changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.customer_sales_release_guard_v1()'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'd50b362d97a46f36a07acdb237231b46' THEN
    RAISE EXCEPTION 'Protected release guard changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.customer_sales_release_financial_guard_v1()'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'c492d47d33c6419d14d4cb26799fbfb9' THEN
    RAISE EXCEPTION 'Protected financial guard changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_resolved_customer_sales_sage_payload_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '4f8266c7932461b4e19afc789817d31f' THEN
    RAISE EXCEPTION 'Protected resolved Sage payload changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'e3bd71d7ec951731d60b0f04a18f5960' THEN
    RAISE EXCEPTION 'Protected pre-ledger Sage payload changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.approve_vat_release(uuid,uuid,jsonb)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM '13491a2d250a480ebb1ac607ce7acce5' THEN
    RAISE EXCEPTION 'Protected VAT authority changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.mark_order_accounting_release_ready(uuid,uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'dacaf00c6470a626cfc2d7e7aac2ccb8' THEN
    RAISE EXCEPTION 'Protected accounting readiness authority changed.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.recompute_order_status(uuid)'::regprocedure
  )) INTO v_actual;
  IF v_actual IS DISTINCT FROM 'f7c40c868381252a5432f70894ca2b2f' THEN
    RAISE EXCEPTION 'Protected order status authority changed.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
