-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — CONCURRENCY PROOF / SESSION B
--
-- RUN THIS IN SUPABASE SQL EDITOR TAB B IMMEDIATELY AFTER STARTING SESSION A.
--
-- Session A executes the real Undo and holds its transaction locks. This file
-- then proves six competing lock edges cannot cross that live Undo boundary:
--   1. re-batching / shipment creation (order+tracking advisory lock),
--   2. customer-sales release allocation lock,
--   3. shipment header writer,
--   4. completion-fields writer,
--   5. shipping-document writer,
--   6. final-export-evidence submit writer.
--
-- Expected signal for each live race is PostgreSQL lock timeout (SQLSTATE 55P03).
-- Every attempted mutation is inside a subtransaction and the outer transaction
-- ends ROLLBACK.
--
-- SAFETY:
--   * No Groupage mutation.
--   * No trigger disabling / ACL / DDL / product-function changes.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '750ms';
SET LOCAL statement_timeout = '5s';

CREATE TEMP TABLE shipment_undo_concurrency_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

DO $race$
DECLARE
  v_batch_id uuid := '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid;
  v_uid uuid;
  v_importer_id uuid;
  v_tracking_id uuid;
  v_allocation_id uuid;
  v_booking_ref text;
  v_err text;
  v_sqlstate text;
  v_release_guard text;
BEGIN
  -- Session B reads the committed pre-race state while Session A's Undo remains
  -- uncommitted. That is exactly the stale-reader condition the lock contract
  -- must serialize safely.
  SELECT b.importer_id, b.booking_ref
    INTO v_importer_id, v_booking_ref
  FROM public.shipper_shipment_batches b
  WHERE b.id = v_batch_id;

  SELECT p.tracking_submission_id
    INTO v_tracking_id
  FROM public.shipper_shipment_batch_packages p
  WHERE p.shipment_batch_id = v_batch_id
    AND p.active = true
  ORDER BY p.order_id,p.tracking_submission_id,p.id
  LIMIT 1;

  SELECT e.tracking_line_allocation_id
    INTO v_allocation_id
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) e
  ORDER BY e.tracking_line_allocation_id
  LIMIT 1;

  SELECT su.auth_user_id
    INTO v_uid
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su
    ON su.shipper_id = b.shipper_id
   AND su.active = true
   AND su.auth_user_id IS NOT NULL
  WHERE b.id = v_batch_id
  ORDER BY su.created_at DESC,su.id DESC
  LIMIT 1;

  IF v_importer_id IS NULL OR v_tracking_id IS NULL OR v_allocation_id IS NULL OR v_uid IS NULL THEN
    RAISE EXCEPTION 'Concurrency Session B prerequisite missing: importer %, tracking %, allocation %, auth %',
      v_importer_id,v_tracking_id,v_allocation_id,v_uid;
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_uid::text,true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',v_uid::text,'role','authenticated')::text,
    true
  );

  -- ---------------------------------------------------------------------------
  -- 1. Re-batching / shipment creation must wait on the same advisory lock held
  --    by Undo before it can pass stale candidate/membership state.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_create_shipment_batch_v2(
      v_importer_id,
      ARRAY[v_tracking_id],
      'CONCURRENCY-REBATCH-' || substr(gen_random_uuid()::text,1,8),
      NULL,NULL,NULL,NULL,NULL,
      'Rollback-only two-session re-batch race proof'
    );

    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_rebatch_serialized',
      false,
      jsonb_build_object('reason','Competing create returned without lock timeout while Session A should hold Undo advisory locks.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_rebatch_serialized',
      v_sqlstate = '55P03',
      jsonb_build_object(
        'sqlstate',v_sqlstate,
        'error',v_err,
        'expected','55P03 lock timeout on shared order/tracking advisory lock',
        'tracking_submission_id',v_tracking_id
      )
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 2. Customer-sales release guard uses FOR UPDATE on this same allocation.
  --    Prove the live allocation lock is unavailable while Undo holds it, and
  --    separately prove the installed release guard still contains that lock.
  -- ---------------------------------------------------------------------------
  SELECT pg_get_functiondef('public.customer_sales_release_guard_v1()'::regprocedure)
    INTO v_release_guard;

  BEGIN
    PERFORM 1
    FROM public.order_tracking_line_allocations a
    WHERE a.id = v_allocation_id
    FOR UPDATE;

    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_customer_release_allocation_serialized',
      false,
      jsonb_build_object('reason','Exact allocation row lock was obtainable while Session A should hold Undo allocation lock.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_customer_release_allocation_serialized',
      v_sqlstate = '55P03'
      AND v_release_guard ILIKE '%order_tracking_line_allocations%'
      AND v_release_guard ILIKE '%FOR UPDATE%',
      jsonb_build_object(
        'sqlstate',v_sqlstate,
        'error',v_err,
        'expected','55P03 lock timeout on exact allocation held by Undo',
        'allocation_id',v_allocation_id,
        'installed_release_guard_uses_allocation_for_update',
          v_release_guard ILIKE '%order_tracking_line_allocations%'
          AND v_release_guard ILIKE '%FOR UPDATE%'
      )
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 3. Header writer.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_update_shipment_batch_header_v1(
      v_batch_id,
      v_booking_ref
    );
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_header_writer_serialized',false,
      jsonb_build_object('reason','Header writer returned without lock timeout while Session A should hold parent batch lock.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_header_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row lock timeout')
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 4. Completion-fields writer.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_save_export_evidence_completion_fields_v1(v_batch_id);
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_completion_writer_serialized',false,
      jsonb_build_object('reason','Completion writer returned without lock timeout while Session A should hold parent batch lock.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_completion_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row lock timeout')
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 5. Shipping-document writer.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_submit_shipping_document_v1(
      v_batch_id,
      'shipper_invoice',
      'CONCURRENCY-PROBE',
      current_date,
      'GBP',
      1,
      'regression://shipment-undo-concurrency',
      'Rollback-only two-session shipping-document race proof'
    );
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_shipping_document_writer_serialized',false,
      jsonb_build_object('reason','Shipping-document writer returned without lock timeout while Session A should hold parent batch lock.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_shipping_document_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row lock timeout')
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 6. Final-export-evidence submit writer. Parent-batch lock occurs before its
  --    completion-ready validation, so live contention must timeout first.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_submit_final_export_evidence_v1(
      v_batch_id,
      'completed_cos',
      'CONCURRENCY-PROBE',
      'regression://shipment-undo-concurrency-final-evidence',
      'Rollback-only two-session final-evidence race proof'
    );
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_final_evidence_writer_serialized',false,
      jsonb_build_object('reason','Final-evidence writer returned without lock timeout while Session A should hold parent batch lock.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_results VALUES(
      'concurrent_final_evidence_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row lock timeout')
    );
  END;
END
$race$;

-- Protected Groupage and line-trigger authorities remain unchanged after the
-- actual two-session race probes.
INSERT INTO shipment_undo_concurrency_results(test_name,passed,detail)
SELECT
  'protected_authorities_still_unchanged',
  bool_and(live_md5 = expected_md5),
  jsonb_build_object(
    'comparisons',jsonb_agg(jsonb_build_object(
      'signature',signature,
      'expected_md5',expected_md5,
      'live_md5',live_md5,
      'matches',live_md5=expected_md5
    ) ORDER BY signature)
  )
FROM (
  SELECT * FROM (VALUES
    ('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)'::text,'8691cf78f34912d9522f545ebb495529'::text),
    ('public.internal_review_final_export_evidence_document_v1(uuid,text,text)','87c619fbd1bcea84f90718dc538bf6ef'),
    ('public.groupage_recompute_movement_status_v1(uuid)','e78cc0c67e422a88afbae815bc600a0b'),
    ('public.shipper_block_shipment_line_membership_mutation_v1()','c56d6a1a2b2c1bf0ef751a07e3b33ff2')
  ) x(signature,expected_md5)
) expected
CROSS JOIN LATERAL (
  SELECT md5(pg_get_functiondef(to_regprocedure(expected.signature))) AS live_md5
) live;

SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_concurrency_session_b',
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'expected_race_signal','55P03 lock timeout while Session A holds real Undo transaction locks',
  'transaction_wrapped',true,
  'will_rollback',true,
  'groupage_mutation_performed',false,
  'failed_tests',COALESCE(jsonb_agg(test_name ORDER BY test_name) FILTER(WHERE NOT passed),'[]'::jsonb),
  'tests',jsonb_agg(
    jsonb_build_object('test',test_name,'passed',passed,'detail',detail)
    ORDER BY test_name
  )
)) AS result
FROM shipment_undo_concurrency_results;

ROLLBACK;
