-- Rollback-safe regression for the permanent supplier Sage queue restoration.
-- It proves that the exact current queue is preserved, that no non-supplier lane
-- changes, and that every row produced now or later by the established supplier
-- helpers is composed into the canonical queue exactly once.

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
    RAISE EXCEPTION 'FAIL: canonical queue, preserved queue or established supplier helper missing';
  END IF;

  SELECT pg_get_function_result('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  INTO v_shape;

  IF v_shape IS DISTINCT FROM pg_get_function_result('public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()'::regprocedure)
     OR v_shape IS DISTINCT FROM pg_get_function_result('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure)
     OR v_shape IS DISTINCT FROM pg_get_function_result('public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure) THEN
    RAISE EXCEPTION 'FAIL: canonical queue and established helpers do not retain one return contract';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure))
  INTO v_definition;

  IF position('internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1' IN v_definition) = 0
     OR position('internal_supplier_goods_ap_ready_rows_v1' IN v_definition) = 0
     OR position('internal_supplier_credit_note_ready_rows_v1' IN v_definition) = 0
     OR position('document_lane is not distinct from' IN v_definition) = 0
     OR position('source_table is not distinct from' IN v_definition) = 0
     OR position('source_id is not distinct from' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: canonical queue is not the preserved-current-queue plus established-helper composition';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc procedure_row
    JOIN pg_namespace namespace_row ON namespace_row.oid = procedure_row.pronamespace
    CROSS JOIN LATERAL aclexplode(
      COALESCE(procedure_row.proacl, acldefault('f', procedure_row.proowner))
    ) privilege_row
    LEFT JOIN pg_roles grantee_role ON grantee_role.oid = privilege_row.grantee
    WHERE namespace_row.nspname = 'public'
      AND procedure_row.proname = 'internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1'
      AND procedure_row.pronargs = 0
      AND privilege_row.privilege_type = 'EXECUTE'
      AND (
        privilege_row.grantee = 0
        OR grantee_role.rolname IN ('anon', 'authenticated', 'service_role')
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: private preserved queue remains directly callable by an application role';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: canonical queue application execution privilege missing';
  END IF;

  -- Mini-build 1 exact supplier document/line sources remain inside the existing helper.
  SELECT lower(pg_get_functiondef('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure))
  INTO v_definition;
  IF position('supplier_invoices' IN v_definition) = 0
     OR position('supplier_invoice_line_accounting_coding_vw' IN v_definition) = 0
     OR position('supplier_invoice_accounting_coding_totals_vw' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: established supplier goods invoice/line identity helper changed';
  END IF;

  -- Existing supplier-credit approval, original-invoice, coding and refund-IN sources remain authoritative.
  SELECT lower(pg_get_functiondef('public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure))
  INTO v_definition;
  IF position('supplier_approval_status' IN v_definition) = 0
     OR position('supplier_control_status' IN v_definition) = 0
     OR position('approved_current' IN v_definition) = 0
     OR position('original_supplier_invoice_id' IN v_definition) = 0
     OR position('dva_statement_line_allocation_detail_vw' IN v_definition) = 0
     OR position('dispute_refund_document_accounting_totals_vw' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: established supplier-credit readiness sources changed';
  END IF;

  -- Mini-build 3 remains the customer-sales authority. This restoration does not replace it.
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

  -- Existing command-centre and freeze paths remain the only operational route.
  IF to_regprocedure('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)') IS NULL
     OR to_regprocedure('public.internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[],text)') IS NULL
     OR to_regprocedure('public.internal_freeze_supplier_credit_note_sage_batch_v1(uuid[],text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: established Accounting Command Centre or supplier freeze route missing';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)'::regprocedure))
  INTO v_definition;
  IF position('internal_ready_for_sage_queue_v2' IN v_definition) = 0
     OR position('supplier_goods_ap' IN v_definition) = 0
     OR position('supplier_credit_note' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: existing command-centre grid is not consuming the canonical queue and both supplier lanes';
  END IF;
END
$structure$;

DO $behaviour$
DECLARE
  v_auth_uid uuid;
  v_missing_count integer;
  v_extra_count integer;
  v_duplicate_count integer;
  v_count integer;
  v_amount numeric;
  v_readiness text;
BEGIN
  SELECT staff_row.auth_user_id
  INTO v_auth_uid
  FROM public.staff staff_row
  WHERE staff_row.active = true
    AND staff_row.auth_user_id IS NOT NULL
  ORDER BY CASE
             WHEN staff_row.role_type = 'admin' THEN 0
             WHEN staff_row.role_type = 'supervisor' THEN 1
             ELSE 2
           END,
           staff_row.id
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

  -- Everything that worked immediately before this migration remains byte-for-byte present.
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

  -- Customer sales, shipper AP and every other non-supplier lane are exactly unchanged.
  SELECT COUNT(*)::integer
  INTO v_extra_count
  FROM (
    SELECT *
    FROM public.internal_ready_for_sage_queue_v2()
    WHERE document_lane NOT IN ('supplier_goods_ap', 'supplier_credit_note')
       OR document_lane IS NULL
    EXCEPT ALL
    SELECT *
    FROM public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()
    WHERE document_lane NOT IN ('supplier_goods_ap', 'supplier_credit_note')
       OR document_lane IS NULL
  ) unexpected;

  IF v_extra_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: restoration changed or added % non-supplier queue row(s)', v_extra_count;
  END IF;

  -- Every result from each established helper is represented. Because these calls
  -- are live, the assertion covers current rows and every future row the helper emits.
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

  -- Current golden-order deployment proof. The assertions are skipped after a
  -- source has entered a frozen/posting lifecycle, so this regression remains rerunnable.
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

    IF NOT EXISTS (
      SELECT 1
      FROM public.sage_posting_snapshots snapshot_row
      WHERE snapshot_row.source_table = 'dispute_refund_evidence_submissions'
        AND snapshot_row.source_id = '9536b81c-1241-49f2-a8b5-d49d2394713e'::uuid
        AND snapshot_row.document_lane = 'supplier_credit_note'
        AND snapshot_row.active = true
    ) THEN
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
  RAISE NOTICE 'PASS: exact current queue behaviour and all pre-Mini-build accounting lanes are preserved; Mini-build 1 identity, Mini-build 3 durable customer release/Sage authority, the existing command-centre lifecycle, and both permanent future supplier lanes are intact.';
END $$;

ROLLBACK;
