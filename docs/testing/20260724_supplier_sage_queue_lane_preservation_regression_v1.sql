-- Rollback-safe regression for the permanent supplier Sage queue restoration.
-- Proves that the exact pre-restoration queue remains present unchanged, while
-- all current/future rows emitted by the established supplier helpers are
-- composed into the canonical queue exactly once.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $structure$
DECLARE
  v_definition text;
  v_shape text;
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL
     OR to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()') IS NULL
     OR to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL
     OR to_regprocedure('public.internal_supplier_credit_note_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical queue, preserved baseline or supplier helper missing';
  END IF;

  SELECT pg_get_function_result('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  INTO v_shape;

  IF v_shape IS DISTINCT FROM pg_get_function_result('public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()'::regprocedure)
     OR v_shape IS DISTINCT FROM pg_get_function_result('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure)
     OR v_shape IS DISTINCT FROM pg_get_function_result('public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure) THEN
    RAISE EXCEPTION 'FAIL: queue/helper return shape drift';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure))
  INTO v_definition;

  IF position('internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1' IN v_definition) = 0
     OR position('internal_supplier_goods_ap_ready_rows_v1' IN v_definition) = 0
     OR position('internal_supplier_credit_note_ready_rows_v1' IN v_definition) = 0
     OR position('document_lane is not distinct from' IN v_definition) = 0
     OR position('source_table is not distinct from' IN v_definition) = 0
     OR position('source_id is not distinct from' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: canonical queue is not the preserved-baseline plus established-helper composition';
  END IF;

  IF has_function_privilege('PUBLIC', 'public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: private preserved queue remains directly callable';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: canonical queue application execution privilege missing';
  END IF;

  -- Mini-build 1 exact supplier invoice identity remains the supplier AP source.
  SELECT lower(pg_get_functiondef('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure))
  INTO v_definition;
  IF position('si.id as supplier_invoice_id' IN v_definition) = 0
     OR position('supplier_invoices' IN v_definition) = 0
     OR position('supplier_invoice_line_accounting_coding_vw' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: supplier goods helper no longer uses exact established invoice/line identity';
  END IF;

  -- Existing supplier-credit approval, coding, refund-IN and original-invoice controls remain authoritative.
  SELECT lower(pg_get_functiondef('public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure))
  INTO v_definition;
  IF position('supplier_approval_status = ''approved_current''' IN v_definition) = 0
     OR position('supplier_control_status = ''approved_current''' IN v_definition) = 0
     OR position('original_supplier_invoice_id' IN v_definition) = 0
     OR position('dva_statement_line_allocation_detail_vw' IN v_definition) = 0
     OR position('dispute_refund_document_accounting_totals_vw' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: established supplier-credit readiness controls changed';
  END IF;

  -- Mini-build 3 customer release/Sage authority remains installed and is not replaced by this patch.
  IF to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL THEN
    RAISE EXCEPTION 'FAIL: Mini-build 3 authoritative customer release/Sage chain missing';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_resolved_customer_sales_sage_payload_v1(uuid)'::regprocedure))
  INTO v_definition;
  IF position('customer_sales_release_lines' IN v_definition) = 0
     OR position('durable_release_membership_authoritative' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: Mini-build 3 durable release authority regressed';
  END IF;

  -- Existing command-centre and freeze paths remain the consumers; no parallel workflow.
  IF to_regprocedure('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)') IS NULL
     OR to_regprocedure('public.internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[],text)') IS NULL
     OR to_regprocedure('public.internal_freeze_supplier_credit_note_sage_batch_v1(uuid[],text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: established Accounting Command Centre/freeze route missing';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)'::regprocedure))
  INTO v_definition;
  IF position('internal_ready_for_sage_queue_v2' IN v_definition) = 0
     OR position('supplier_goods_ap' IN v_definition) = 0
     OR position('supplier_credit_note' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: command-centre grid is not using the canonical queue with both supplier lanes';
  END IF;
END
$structure$;

DO $behaviour$
DECLARE
  v_auth_uid uuid;
  v_missing_count integer;
  v_duplicate_count integer;
  v_count integer;
  v_amount numeric;
  v_readiness text;
BEGIN
  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 WHEN s.role_type = 'supervisor' THEN 1 ELSE 2 END,
           s.created_at,
           s.id
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff auth identity available for read-only queue regression';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );

  -- Every row that worked immediately before this restoration must remain byte-for-byte present.
  SELECT COUNT(*)::integer
  INTO v_missing_count
  FROM (
    SELECT *
    FROM public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()
    EXCEPT ALL
    SELECT *
    FROM public.internal_ready_for_sage_queue_v2()
  ) missing;

  IF v_missing_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: canonical queue lost % pre-restoration row(s)', v_missing_count;
  END IF;

  -- Every current and future helper result must be represented by the canonical queue.
  SELECT COUNT(*)::integer
  INTO v_missing_count
  FROM public.internal_supplier_goods_ap_ready_rows_v1() helper
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.internal_ready_for_sage_queue_v2() queue_row
    WHERE queue_row.document_lane IS NOT DISTINCT FROM helper.document_lane
      AND queue_row.source_table IS NOT DISTINCT FROM helper.source_table
      AND queue_row.source_id IS NOT DISTINCT FROM helper.source_id
  );

  IF v_missing_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: canonical queue is missing % supplier goods helper row(s)', v_missing_count;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_missing_count
  FROM public.internal_supplier_credit_note_ready_rows_v1() helper
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.internal_ready_for_sage_queue_v2() queue_row
    WHERE queue_row.document_lane IS NOT DISTINCT FROM helper.document_lane
      AND queue_row.source_table IS NOT DISTINCT FROM helper.source_table
      AND queue_row.source_id IS NOT DISTINCT FROM helper.source_id
  );

  IF v_missing_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: canonical queue is missing % supplier credit helper row(s)', v_missing_count;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_duplicate_count
  FROM (
    SELECT document_lane, source_table, source_id
    FROM public.internal_ready_for_sage_queue_v2()
    WHERE document_lane IN ('supplier_goods_ap', 'supplier_credit_note')
    GROUP BY document_lane, source_table, source_id
    HAVING COUNT(*) > 1
  ) duplicates;

  IF v_duplicate_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: canonical queue contains % duplicate supplier source identity group(s)', v_duplicate_count;
  END IF;

  -- Golden-order proof is conditional so this remains reusable in clean environments.
  IF EXISTS (SELECT 1 FROM public.orders WHERE order_ref = 'ORD-1784498556959') THEN
    SELECT COUNT(*)::integer
    INTO v_count
    FROM public.internal_ready_for_sage_queue_v2()
    WHERE order_ref = 'ORD-1784498556959'
      AND document_lane = 'supplier_goods_ap'
      AND source_table = 'supplier_invoices';

    IF v_count <> 3 THEN
      RAISE EXCEPTION 'FAIL: golden order expected 3 supplier goods AP rows, found %', v_count;
    END IF;

    SELECT COUNT(*)::integer, MAX(amount_gbp), MAX(readiness_status)
    INTO v_count, v_amount, v_readiness
    FROM public.internal_ready_for_sage_queue_v2()
    WHERE source_id = '9536b81c-1241-49f2-a8b5-d49d2394713e'::uuid
      AND document_lane = 'supplier_credit_note'
      AND source_table = 'dispute_refund_evidence_submissions';

    IF v_count <> 1 OR ABS(COALESCE(v_amount, 0) - 184.99) > 0.01
       OR COALESCE(v_readiness, '') NOT LIKE 'ready%' THEN
      RAISE EXCEPTION 'FAIL: approved £184.99 supplier credit is not present exactly once and ready (count %, amount %, readiness %)',
        v_count, v_amount, v_readiness;
    END IF;

    SELECT COUNT(*)::integer
    INTO v_count
    FROM public.internal_ready_for_sage_queue_v2()
    WHERE source_id = '9c04368d-40f9-4f9c-bf1a-a3b110cf3366'::uuid
      AND document_lane = 'supplier_credit_note'
      AND COALESCE(readiness_status, '') LIKE 'ready%';

    IF v_count <> 0 THEN
      RAISE EXCEPTION 'FAIL: blocked legacy £189.99 supplier credit became ready';
    END IF;
  END IF;
END
$behaviour$;

DO $$
BEGIN
  RAISE NOTICE 'PASS: exact pre-Mini-build queue behaviour is preserved; Mini-build 1 identity, existing supplier credit controls, Mini-build 3 durable customer release/Sage authority, command-centre lifecycle and both permanent future supplier lanes are intact.';
END $$;

ROLLBACK;
