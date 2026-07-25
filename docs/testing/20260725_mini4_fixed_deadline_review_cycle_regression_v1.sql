BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_result text;
  v_count integer;
  v_amount numeric;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Additive objects and preserved public route signatures.
  -- -------------------------------------------------------------------------
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regclass('public.customer_review_cycle_legacy_issues') IS NULL
     OR to_regclass('public.customer_hold_review_memberships') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: Mini 4 additive relations are missing.';
  END IF;

  IF to_regprocedure('public.customer_active_order_review_link_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_create_customer_order_review_link_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_order_has_review_ready_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_pre_shipment_hold_review_v1(text)') IS NULL
     OR to_regprocedure('public.customer_hold_enforce_open_review_window_v1()') IS NULL
     OR to_regprocedure('public.customer_hold_refund_target_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_hold_create_refund_exception_v2()') IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL
     OR to_regprocedure('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: a preserved route signature is missing.';
  END IF;

  SELECT pg_get_function_result(
    'public.customer_active_order_review_link_v1(uuid)'::regprocedure
  ) INTO v_result;
  IF position('order_id uuid' IN v_result) = 0
     OR position('customer_review_path text' IN v_result) = 0
  THEN
    RAISE EXCEPTION 'FAIL: customer active-link return shape changed: %.', v_result;
  END IF;

  SELECT pg_get_function_result(
    'public.customer_hold_refund_target_lines_v1(uuid)'::regprocedure
  ) INTO v_result;
  IF position('supplier_invoice_line_id uuid' IN v_result) = 0
     OR position('qty_impact numeric' IN v_result) = 0
     OR position('amount_impact_gbp numeric' IN v_result) = 0
     OR position('source_line_qty numeric' IN v_result) = 0
  THEN
    RAISE EXCEPTION 'FAIL: refund-target resolver return shape changed: %.', v_result;
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Fixed lifecycle, immutable exact provenance and private helper ACLs.
  -- -------------------------------------------------------------------------
  SELECT lower(pg_get_functiondef(
    'public.customer_active_order_review_link_v1(uuid)'::regprocedure
  )) INTO v_definition;
  IF position('internal_materialize_customer_review_cycles_v1' IN v_definition) = 0
     OR position('set expires_at = v_deadline' IN v_definition) > 0
     OR position('from public.sales_invoices' IN v_definition) > 0
  THEN
    RAISE EXCEPTION
      'FAIL: active-link route retained deadline mutation or the order-wide invoice block.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.internal_create_customer_order_review_link_v1(uuid)'::regprocedure
  )) INTO v_definition;
  IF position('internal_materialize_customer_review_cycles_v1' IN v_definition) = 0
     OR position('insert into public.customer_order_review_links' IN v_definition) > 0
  THEN
    RAISE EXCEPTION
      'FAIL: staff link route can create a parallel or untimed link directly.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure
  )) INTO v_definition;
  IF position('v_anchor_receipt + interval ''24 hours''' IN v_definition) = 0
     OR position('open-cycle join is governed only by the already stored deadline' IN v_definition) = 0
     OR position('candidate.receipt_recorded_at < v_deadline' IN v_definition) = 0
     OR position('set expires_at = v_deadline' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: fixed first-receipt/open-cycle lifecycle is not installed.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.customer_review_cycle_component_guard_v1()'::regprocedure
  )) INTO v_definition;
  IF position('exact allocation and quantity' IN v_definition) = 0
     OR position('v_existing_review_qty' IN v_definition) = 0
     OR position('new.membership_fingerprint' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: review membership value/fingerprint guard is incomplete.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.customer_hold_review_membership_sync_v1()'::regprocedure
  )) INTO v_definition;
  IF position('tg_op = ''insert''' IN v_definition) = 0
     OR position('has no frozen review membership' IN v_definition) = 0
     OR position('cannot move outside its frozen review membership' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: hold provenance is not frozen at insertion.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.customer_review_ready_line_ids_v1(uuid)'::regprocedure
  )) INTO v_definition;
  IF position('customer_review_cycle_memberships' IN v_definition) = 0
     OR position('latest_receipt.recorded_at + interval ''24 hours''' IN v_definition) = 0
     OR position('shipper_shipment_batch_packages' IN v_definition) = 0
  THEN
    RAISE EXCEPTION
      'FAIL: immutable timed membership or exact untimed compatibility filter is missing.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)'::regprocedure
  )) INTO v_definition;
  IF position('customer_review_cycle_memberships' IN v_definition) = 0
     OR position('customer_order_review_links' IN v_definition) = 0
     OR position('p_receipt_recorded_at < link_row.expires_at' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: shipper deadline does not use the applicable stored cycle deadline.';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.customer_review_cycle_candidates_v1(uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)',
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'FAIL: private Mini 4 helper execution leaked to authenticated.';
  END IF;

  IF NOT has_function_privilege(
       'service_role',
       'public.customer_review_cycle_candidates_v1(uuid)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role',
       'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)',
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'FAIL: service_role cannot execute the private Mini 4 helpers.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.shipper_shipment_batch_candidates_v1()'::regprocedure
  )) INTO v_definition;
  IF position('customer_tracking_review_deadline_v1' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: shipper candidate list bypasses the stored deadline.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  )) INTO v_definition;
  IF position('customer_tracking_review_deadline_v1' IN v_definition) = 0
     OR position('customer_line_has_active_hold_conflict_v1' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: direct shipment creation bypasses its deadline or hold gate.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.customer_hold_refund_target_lines_v1(uuid)'::regprocedure
  )) INTO v_definition;
  IF position('customer_hold_review_memberships' IN v_definition) = 0
     OR position('legacy implementation retained for untimed links only' IN v_definition) = 0
  THEN
    RAISE EXCEPTION
      'FAIL: timed holds do not use exact membership or legacy fallback is missing.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.customer_hold_create_refund_exception_v2()'::regprocedure
  )) INTO v_definition;
  IF position('customer_hold_refund_target_lines_v1' IN v_definition) = 0
     OR position('customer_hold_review_memberships' IN v_definition) > 0
  THEN
    RAISE EXCEPTION
      'FAIL: existing refund conversion was replaced instead of retaining its resolver boundary.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Existing hold triggers and additive Mini 4 integrity triggers.
  -- -------------------------------------------------------------------------
  SELECT COUNT(*)::integer INTO v_count
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid =
        'public.customer_pre_shipment_hold_requests'::regclass
    AND trigger_row.tgname IN (
      'trg_customer_hold_enforce_open_review_window_v1',
      'trg_customer_hold_enforce_active_target_v1',
      'trg_customer_hold_prevent_duplicate_active_v1',
      'trg_customer_hold_create_refund_exception_v2',
      'trg_customer_hold_00_review_membership_sync_v1'
    )
    AND NOT trigger_row.tgisinternal
    AND trigger_row.tgenabled = 'O';
  IF v_count <> 5 THEN
    RAISE EXCEPTION 'FAIL: required customer-hold triggers are missing or disabled.';
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM pg_trigger trigger_row
  WHERE NOT trigger_row.tgisinternal
    AND trigger_row.tgenabled = 'O'
    AND (
      (
        trigger_row.tgrelid =
          'public.customer_review_cycle_memberships'::regclass
        AND trigger_row.tgname IN (
          'trg_customer_review_cycle_00_cumulative_qty_guard_v1',
          'trg_customer_review_cycle_01_component_guard_v1',
          'trg_customer_review_cycle_membership_immutable_v1'
        )
      )
      OR (
        trigger_row.tgrelid =
          'public.customer_hold_review_memberships'::regclass
        AND trigger_row.tgname =
          'trg_customer_hold_review_membership_guard_v1'
      )
      OR (
        trigger_row.tgrelid =
          'public.customer_order_review_links'::regclass
        AND trigger_row.tgname IN (
          'trg_customer_review_link_fixed_deadline_guard_v1',
          'trg_customer_review_resolve_expired_legacy_issue_v1'
        )
      )
    );
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'FAIL: Mini 4 integrity triggers are incomplete.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Working posting routes remain separate from Mini 4 membership.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.internal_create_cash_control_batch_v1(text[],text)') IS NULL
     OR to_regprocedure('public.internal_retailer_refund_has_posted_settlement_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: an established posting route is missing.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.internal_create_cash_control_batch_v1(text[],text)'::regprocedure
  )) INTO v_definition;
  IF position('customer_review_cycle_memberships' IN v_definition) > 0
     OR position('customer_hold_review_memberships' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: cash batch creation was coupled to Mini 4 tables.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.internal_resolved_customer_sales_sage_payload_v1(uuid)'::regprocedure
  )) INTO v_definition;
  IF position('customer_review_cycle_memberships' IN v_definition) > 0
     OR position('customer_hold_review_memberships' IN v_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: customer Sage payload was coupled to Mini 4 tables.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 5. Actual protected target: ORD-1784498556959.
  -- -------------------------------------------------------------------------
  IF NOT EXISTS (
    SELECT 1
    FROM public.orders order_row
    WHERE order_row.id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND order_row.order_ref = 'ORD-1784498556959'
      AND order_row.status = 'partially_progressed'
  ) THEN
    RAISE EXCEPTION 'FAIL: protected target order identity/status changed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.customer_order_review_links link_row
    WHERE link_row.id = '9408064e-81b8-43bf-af95-c7c9c78264fd'::uuid
      AND link_row.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND link_row.is_active = false
      AND link_row.expires_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: protected historical review link changed.';
  END IF;

  SELECT COUNT(*)::integer,
         ROUND(COALESCE(SUM(release_line.customer_charge_amount_gbp), 0), 2)
  INTO v_count, v_amount
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
    AND release_line.release_status = 'active';
  IF v_count <> 3 OR v_amount <> 819.97 THEN
    RAISE EXCEPTION
      'FAIL: protected customer release baseline changed: rows %, amount £%.',
      v_count,
      v_amount;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND release_line.supplier_invoice_line_id =
          'd7d42758-4a8d-4632-910e-353c06d2f621'::uuid
      AND release_line.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'FAIL: refunded Blender line entered active release membership.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices sales_invoice
    WHERE sales_invoice.id = 'aa66f2a5-360a-4763-9c2e-81cf81432a4d'::uuid
      AND sales_invoice.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND sales_invoice.invoice_type = 'main'
      AND sales_invoice.sage_status = 'posted'
      AND sales_invoice.amount_gbp = 819.97
      AND sales_invoice.sage_invoice_id = 'c1e63ef3a680477087347aa619220f19'
  ) THEN
    RAISE EXCEPTION 'FAIL: protected £819.97 posted customer invoice changed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot
    WHERE snapshot.id = 'c0bd5f5c-badf-4de4-bdd2-c5e23ee4f3ea'::uuid
      AND snapshot.source_table = 'sales_invoices'
      AND snapshot.source_id = 'aa66f2a5-360a-4763-9c2e-81cf81432a4d'::uuid
      AND snapshot.amount_gbp = 819.97
      AND snapshot.approval_status = 'approved_frozen'
      AND snapshot.sage_posting_status = 'posted'
      AND snapshot.sage_invoice_id = 'c1e63ef3a680477087347aa619220f19'
      AND snapshot.posting_attempt_count = 1
      AND snapshot.active = true
  ) THEN
    RAISE EXCEPTION 'FAIL: protected posted Sage snapshot changed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.disputes dispute_row
    WHERE dispute_row.id = '904d1bd3-86e9-47ad-bbf9-96859d900d22'::uuid
      AND dispute_row.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND dispute_row.desired_outcome = 'refund'
      AND dispute_row.status = 'refunded'
      AND dispute_row.amount_impact_gbp = 179.99
      AND dispute_row.resolved_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: protected £179.99 completed refund changed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_review_cycle_memberships membership
    WHERE membership.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.customer_review_cycle_legacy_issues issue
    WHERE issue.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND issue.resolved_at IS NULL
  ) OR EXISTS (
    SELECT 1
    FROM public.customer_order_review_links link_row
    WHERE link_row.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND link_row.is_active = true
  ) OR EXISTS (
    SELECT 1
    FROM public.customer_review_cycle_candidates_v1(
      '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
    )
  ) THEN
    RAISE EXCEPTION
      'FAIL: Mini 4 reopened or manufactured review activity for the protected completed order.';
  END IF;
END
$regression$;

SELECT
  'PASS'::text AS regression_result,
  'Fixed review deadlines, immutable membership, frozen hold provenance, preserved shipment/refund boundaries and the protected £819.97/£179.99 target baseline are consistent.'::text AS details;

ROLLBACK;
