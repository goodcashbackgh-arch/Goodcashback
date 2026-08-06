BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Rollback-only regression for the queue projection correction.
-- No unrelated function fingerprint assumptions.

DO $definition_checks$
DECLARE
  v_definition text;
  v_compact text;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  ) INTO v_definition;

  v_compact := regexp_replace(lower(v_definition), '[[:space:]]+', ' ', 'g');

  IF strpos(v_definition, 'released_in_existing_draft') = 0
     OR strpos(v_definition, 'blocked_by_another_active_draft') = 0
     OR strpos(v_definition, 'draft_membership') = 0
     OR strpos(v_definition, 'batch_orders') = 0
     OR strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_compact, 'from preview_rows preview left join public.sales_invoices') > 0
  THEN
    RAISE EXCEPTION 'Queue ownership projection definition is incomplete.';
  END IF;

  IF to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_sales_release_guard_v1()') IS NULL
     OR to_regprocedure('public.customer_sales_release_financial_guard_v1()') IS NULL
     OR to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL
     OR to_regprocedure('public.approve_vat_release(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.recompute_order_status(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'A protected Mini-build/customer-sales dependency is missing.';
  END IF;
END
$definition_checks$;

DO $fixture_checks$
DECLARE
  v_parent constant uuid := '1b4a2a43-5ddd-41ef-aef5-45e621eb5819';
  v_invoice constant uuid := 'a557ca14-03e5-43c0-b436-f843e9412a28';
  v_batch_a constant uuid := '1d8ed4af-4d35-4b2d-9913-9bae1a20a717';
  v_batch_b constant uuid := '47029c7e-e2db-47fa-8c79-fec09b751542';
  v_count integer;
  v_total numeric;
BEGIN
  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.sales_invoices invoice_row
  WHERE invoice_row.order_id = v_parent
    AND invoice_row.invoice_type IN ('main', 'supplementary');

  IF v_count IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Expected four historical parent invoices; found %.', v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.id = v_invoice
      AND invoice_row.order_id = v_parent
      AND invoice_row.invoice_type = 'supplementary'
      AND invoice_row.sage_status = 'draft'
      AND invoice_row.amount_gbp = 30.00
  ) THEN
    RAISE EXCEPTION 'Protected £30 combined draft is missing or changed.';
  END IF;

  SELECT COUNT(*)::integer,
         ROUND(COALESCE(SUM(line.customer_charge_amount_gbp), 0), 2)
  INTO v_count, v_total
  FROM public.customer_sales_release_lines line
  WHERE line.sales_invoice_id = v_invoice
    AND line.release_status = 'active';

  IF v_count IS DISTINCT FROM 3 OR v_total IS DISTINCT FROM 30.00 THEN
    RAISE EXCEPTION 'Protected combined membership mismatch: count %, total %.', v_count, v_total;
  END IF;

  SELECT COUNT(*)::integer,
         ROUND(COALESCE(SUM(line.customer_charge_amount_gbp), 0), 2)
  INTO v_count, v_total
  FROM public.customer_sales_release_lines line
  WHERE line.sales_invoice_id = v_invoice
    AND line.release_status = 'active'
    AND line.source_shipment_batch_id = v_batch_a;

  IF v_count IS DISTINCT FROM 1 OR v_total IS DISTINCT FROM 10.00 THEN
    RAISE EXCEPTION 'J040826 ownership mismatch: count %, total %.', v_count, v_total;
  END IF;

  SELECT COUNT(*)::integer,
         ROUND(COALESCE(SUM(line.customer_charge_amount_gbp), 0), 2)
  INTO v_count, v_total
  FROM public.customer_sales_release_lines line
  WHERE line.sales_invoice_id = v_invoice
    AND line.release_status = 'active'
    AND line.source_shipment_batch_id = v_batch_b;

  IF v_count IS DISTINCT FROM 2 OR v_total IS DISTINCT FROM 20.00 THEN
    RAISE EXCEPTION 'J040826v1 ownership mismatch: count %, total %.', v_count, v_total;
  END IF;
END
$fixture_checks$;

DO $queue_output_checks$
DECLARE
  v_auth_user uuid;
  v_row record;
BEGIN
  SELECT staff_row.auth_user_id
  INTO v_auth_user
  FROM public.staff staff_row
  WHERE staff_row.active = true
    AND staff_row.auth_user_id IS NOT NULL
  ORDER BY staff_row.created_at, staff_row.id
  LIMIT 1;

  IF v_auth_user IS NULL THEN
    RAISE EXCEPTION 'No active staff auth identity is available for queue regression.';
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
    RAISE EXCEPTION 'J040826 queue projection mismatch: %', row_to_json(v_row);
  END IF;

  SELECT * INTO v_row
  FROM public.internal_customer_invoice_release_queue_v1()
  WHERE shipment_batch_id = '47029c7e-e2db-47fa-8c79-fec09b751542'::uuid;

  IF NOT FOUND
     OR v_row.line_count IS DISTINCT FROM 2
     OR v_row.ready_line_count IS DISTINCT FROM 2
     OR v_row.proposed_amount_gbp IS DISTINCT FROM 20.00
     OR v_row.readiness_status IS DISTINCT FROM 'released_in_existing_draft'
  THEN
    RAISE EXCEPTION 'J040826v1 queue projection mismatch: %', row_to_json(v_row);
  END IF;
END
$queue_output_checks$;

SELECT jsonb_build_object(
  'passed', true,
  'scope', 'customer_release_queue_parent_draft_projection_v2',
  'j040826', jsonb_build_object(
    'line_count', 1,
    'ready_line_count', 1,
    'amount_gbp', 10.00,
    'status', 'released_in_existing_draft'
  ),
  'j040826v1', jsonb_build_object(
    'line_count', 2,
    'ready_line_count', 2,
    'amount_gbp', 20.00,
    'status', 'released_in_existing_draft'
  ),
  'protected_combined_invoice', 'a557ca14-03e5-43c0-b436-f843e9412a28',
  'mini_build_1_to_4_impact', 'none'
) AS result;

ROLLBACK;
