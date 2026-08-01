BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_indexdef text;
BEGIN
  IF to_regclass('public.physical_receipt_review_dispute_links') IS NULL THEN
    RAISE EXCEPTION 'FAIL: physical_receipt_review_dispute_links missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dispute_lines'
      AND column_name = 'physical_remedy_allocation_id'
      AND data_type = 'uuid'
      AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'FAIL: dispute_lines.physical_remedy_allocation_id shape missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'dispute_lines'
      AND indexname = 'uq_dispute_lines_open'
  ) THEN
    RAISE EXCEPTION 'FAIL: legacy unqualified open-line index still exists';
  END IF;

  SELECT indexdef INTO v_indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'dispute_lines'
    AND indexname = 'uq_dispute_lines_open_legacy';

  IF v_indexdef IS NULL
     OR v_indexdef NOT ILIKE '%supplier_invoice_line_id%'
     OR v_indexdef NOT ILIKE '%resolved_at IS NULL%'
     OR v_indexdef NOT ILIKE '%physical_remedy_allocation_id IS NULL%'
  THEN
    RAISE EXCEPTION 'FAIL: legacy open-line uniqueness was not preserved';
  END IF;

  SELECT indexdef INTO v_indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'dispute_lines'
    AND indexname = 'uq_dispute_lines_open_physical';

  IF v_indexdef IS NULL
     OR v_indexdef NOT ILIKE '%physical_remedy_allocation_id%'
     OR v_indexdef NOT ILIKE '%resolved_at IS NULL%'
     OR v_indexdef NOT ILIKE '%physical_remedy_allocation_id IS NOT NULL%'
  THEN
    RAISE EXCEPTION 'FAIL: physical open-line uniqueness missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.physical_receipt_review_dispute_links'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid, true)
        ILIKE '%physical_receipt_review_id, dispute_id%'
  ) THEN
    RAISE EXCEPTION 'FAIL: review/dispute pair uniqueness missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'physical_receipt_review_dispute_links'
      AND policyname = 'physical_review_dispute_links_read_v1'
  ) THEN
    RAISE EXCEPTION 'FAIL: review/dispute link read policy missing';
  END IF;

  IF has_table_privilege('authenticated', 'public.physical_receipt_review_dispute_links', 'INSERT')
     OR has_table_privilege('authenticated', 'public.physical_receipt_review_dispute_links', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.physical_receipt_review_dispute_links', 'DELETE')
  THEN
    RAISE EXCEPTION 'FAIL: authenticated direct writes remain on review/dispute links';
  END IF;

  IF to_regprocedure('public.physical_review_dispute_link_guard_v1()') IS NULL
     OR to_regprocedure('public.physical_dispute_line_guard_v1()') IS NULL
     OR to_regprocedure('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: compatibility or supervisor functions missing';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated execute missing on supervisor RPC';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute supervisor RPC';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure
  ) INTO v_definition;

  FOREACH v_indexdef IN ARRAY ARRAY[
    'awaiting_supervisor_review',
    'return_for_information',
    'approve_existing_exception',
    'Every active importer proposal row must be explicitly decided',
    'Return for information if a different split is required',
    'Fractional quantities are not rounded',
    'physical_remedy_allocation_id IS NULL',
    'at_ghana_delivery',
    'amount_impact_gbp',
    'physical_receipt_review_dispute_links',
    'CASE link_row.desired_outcome WHEN ''refund'' THEN 1 ELSE 2 END',
    'linked_to_exception'
  ] LOOP
    IF POSITION(v_indexdef IN v_definition) = 0 THEN
      RAISE EXCEPTION 'FAIL: supervisor RPC missing required control: %', v_indexdef;
    END IF;
  END LOOP;

  FOREACH v_indexdef IN ARRAY ARRAY[
    'DELETE FROM public.physical_exception_remedy_allocations',
    'create_replacement_child_order(',
    'replacement_child_order_id =',
    'customer_commercial_value_gbp =',
    'supplier_claim_amount_gbp =',
    'status = ''refunded''',
    'status = ''replaced'''
  ] LOOP
    IF POSITION(v_indexdef IN v_definition) > 0 THEN
      RAISE EXCEPTION 'FAIL: supervisor RPC writes prohibited completion fact: %', v_indexdef;
    END IF;
  END LOOP;

  SELECT pg_get_functiondef(
    'public.physical_remedy_allocation_guard_v1()'::regprocedure
  ) INTO v_definition;

  IF POSITION('physical_receipt_review_dispute_links' IN v_definition) = 0
     OR POSITION('desired_outcome = NEW.approved_remedy_type' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: remedy guard does not accept only proven outcome-specific review links';
  END IF;

  IF md5(pg_get_viewdef('public.order_reconciliation_vw'::regclass, true))
       <> '4f71ebb1a3743d470687ecaee2f23a9a'
  THEN
    RAISE EXCEPTION 'FAIL: protected order_reconciliation_vw changed';
  END IF;

  IF md5(pg_get_functiondef(
       'public.create_replacement_child_order(uuid,uuid,uuid,text)'::regprocedure
     )) <> 'fdf1c2e955a34b81fbfc75c6a34a21b4'
  THEN
    RAISE EXCEPTION 'FAIL: protected replacement-child authority changed';
  END IF;

  IF md5(pg_get_functiondef(
       'public.customer_hold_create_refund_exception_v2()'::regprocedure
     )) <> 'f01bd2ff7e857bfbeff25ad85366dda3'
  THEN
    RAISE EXCEPTION 'FAIL: protected customer-hold refund bridge changed';
  END IF;
END
$regression$;

DO $unauthenticated_gate$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '', true);

  BEGIN
    PERFORM public.staff_decide_physical_receipt_review_v1(
      gen_random_uuid(),
      'reject',
      '[]'::jsonb,
      'unknown',
      'Regression unauthenticated call.'
    );
    RAISE EXCEPTION 'FAIL: unauthenticated supervisor decision unexpectedly succeeded';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%Unauthenticated user%' THEN
        RAISE;
      END IF;
  END;
END
$unauthenticated_gate$;

SELECT
  'PASS — supervisor decision compatibility catalog, privilege, source-contract and unauthenticated gates passed' AS result;

ROLLBACK;
