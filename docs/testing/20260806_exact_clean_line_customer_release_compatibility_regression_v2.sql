BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Read-only, rollback-only post-E2E regression.
-- Validates exact-clean compatibility after the controlled £30 grouped draft exists.

DO $catalog_checks$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Exact-clean compatibility prerequisites are missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'shipper_shipment_batch_effective_lines_v1') = 0
     OR strpos(v_definition, 'internal_tracking_allocation_fulfilment_position_v1') = 0
     OR strpos(v_definition, 'immutable_snapshot') = 0
     OR strpos(v_definition, 'v2_exact') = 0
     OR strpos(v_definition, 'position_valid_yn = true') = 0
  THEN
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
     )
  THEN
    RAISE EXCEPTION 'Private exact clean-line helper is exposed to browser roles.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'package_not_received_clean') = 0
     OR strpos(v_definition, 'customer_sales_release_draft_already_exists') = 0
     OR strpos(v_definition, 'source_fully_released') = 0
  THEN
    RAISE EXCEPTION 'Resolver compatibility or blocker contract is incomplete.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'internal_shipping_customer_invoice_readiness_preview_v1') = 0
     OR strpos(v_definition, 'ready_to_create_draft') = 0
     OR strpos(v_definition, 'posted_exists') = 0
     OR strpos(v_definition, 'released_in_existing_draft') = 0
     OR strpos(v_definition, 'blocked_by_another_active_draft') = 0
  THEN
    RAISE EXCEPTION 'Queue compatibility or current ownership-aware readiness contract is incomplete.';
  END IF;
END
$catalog_checks$;

DO $fixture_checks$
DECLARE
  v_batch constant uuid := '1d8ed4af-4d35-4b2d-9913-9bae1a20a717';
  v_parent constant uuid := '1b4a2a43-5ddd-41ef-aef5-45e621eb5819';
  v_allocation constant uuid := '9dd8c47c-9dd9-4191-910b-41095f15feee';
  v_invoice constant uuid := 'a557ca14-03e5-43c0-b436-f843e9412a28';
  v_count integer;
  v_total numeric;
  v_proof boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batches batch
    WHERE batch.id = v_batch
      AND batch.booking_ref = 'J040826'
  ) THEN
    RAISE EXCEPTION 'J040826 target batch is missing.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch);

  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'J040826 must retain exactly one effective line; found %.', v_count;
  END IF;

  SELECT public.internal_customer_sales_release_exact_clean_proof_v1(v_batch, v_allocation)
  INTO v_proof;

  IF v_proof IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'J040826 exact clean-line proof is no longer true.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice
    WHERE invoice.id = v_invoice
      AND invoice.order_id = v_parent
      AND invoice.invoice_type = 'supplementary'
      AND invoice.sage_status = 'draft'
      AND invoice.amount_gbp = 30.00
  ) THEN
    RAISE EXCEPTION 'Protected £30 grouped draft is missing or changed.';
  END IF;

  SELECT COUNT(*)::integer,
         ROUND(COALESCE(SUM(line.customer_charge_amount_gbp), 0), 2)
  INTO v_count, v_total
  FROM public.customer_sales_release_lines line
  WHERE line.sales_invoice_id = v_invoice
    AND line.release_status = 'active'
    AND line.source_shipment_batch_id = v_batch
    AND line.tracking_line_allocation_id = v_allocation;

  IF v_count IS DISTINCT FROM 1 OR v_total IS DISTINCT FROM 10.00 THEN
    RAISE EXCEPTION 'J040826 active grouped-draft membership mismatch: count %, total %.', v_count, v_total;
  END IF;
END
$fixture_checks$;

DO $queue_checks$
DECLARE
  v_auth_user uuid;
  v_row record;
BEGIN
  SELECT staff.auth_user_id
  INTO v_auth_user
  FROM public.staff staff
  WHERE staff.active = true
    AND staff.auth_user_id IS NOT NULL
  ORDER BY staff.created_at, staff.id
  LIMIT 1;

  IF v_auth_user IS NULL THEN
    RAISE EXCEPTION 'No active staff auth identity is available.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  SELECT * INTO v_row
  FROM public.internal_customer_invoice_release_queue_v1()
  WHERE shipment_batch_id = '1d8ed4af-4d35-4b2d-9913-9bae1a20a717'::uuid;

  IF NOT FOUND
     OR v_row.line_count IS DISTINCT FROM 1
     OR v_row.ready_line_count IS DISTINCT FROM 1
     OR v_row.proposed_amount_gbp IS DISTINCT FROM 10.00
     OR v_row.readiness_status IS DISTINCT FROM 'released_in_existing_draft'
  THEN
    RAISE EXCEPTION 'J040826 queue compatibility mismatch: %', row_to_json(v_row);
  END IF;
END
$queue_checks$;

SELECT jsonb_build_object(
  'regression', 'exact_clean_line_customer_release_compatibility_v2',
  'status', 'passed',
  'booking_ref', 'J040826',
  'batch_id', '1d8ed4af-4d35-4b2d-9913-9bae1a20a717',
  'proven_allocation_id', '9dd8c47c-9dd9-4191-910b-41095f15feee',
  'current_state', 'released_in_existing_draft',
  'amount_gbp', 10.00,
  'line_count', 1,
  'protected_grouped_invoice', 'a557ca14-03e5-43c0-b436-f843e9412a28'
) AS result;

ROLLBACK;
