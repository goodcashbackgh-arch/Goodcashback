-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — CONCURRENCY PROOF / SESSION B v2
--
-- RUN THIS IN SUPABASE SQL EDITOR TAB B IMMEDIATELY AFTER STARTING SESSION A v2.
--
-- This version has an explicit concurrency handshake. It WILL NOT run the race
-- assertions unless Session A is demonstrably holding the same order/tracking
-- advisory transaction locks used by the real Undo authority.
--
-- Expected handshake while A is live:
--   pg_try_advisory_xact_lock(order key)    = false
--   pg_try_advisory_xact_lock(tracking key) = false
--
-- Expected race signal: SQLSTATE 55P03 (lock_not_available / lock timeout).
-- Everything ends ROLLBACK.
--
-- SAFETY:
--   * No Groupage mutation.
--   * No trigger disabling / ACL / DDL / product-function changes.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '750ms';
SET LOCAL statement_timeout = '5s';

CREATE TEMP TABLE shipment_undo_concurrency_v2_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

DO $race$
DECLARE
  v_batch_id uuid := '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid;
  v_uid uuid;
  v_importer_id uuid;
  v_order_id uuid;
  v_tracking_id uuid;
  v_allocation_id uuid;
  v_booking_ref text;
  v_order_lock_obtainable boolean;
  v_tracking_lock_obtainable boolean;
  v_err text;
  v_sqlstate text;
  v_release_guard text;
BEGIN
  SELECT b.importer_id,b.booking_ref,p.order_id,p.tracking_submission_id
    INTO v_importer_id,v_booking_ref,v_order_id,v_tracking_id
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_shipment_batch_packages p
    ON p.shipment_batch_id = b.id
   AND p.active = true
  WHERE b.id = v_batch_id
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

  IF v_importer_id IS NULL OR v_order_id IS NULL OR v_tracking_id IS NULL
     OR v_allocation_id IS NULL OR v_uid IS NULL
  THEN
    RAISE EXCEPTION
      'Concurrency Session B v2 prerequisite missing: importer %, order %, tracking %, allocation %, auth %',
      v_importer_id,v_order_id,v_tracking_id,v_allocation_id,v_uid;
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_uid::text,true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',v_uid::text,'role','authenticated')::text,
    true
  );

  -- ---------------------------------------------------------------------------
  -- HANDSHAKE: prove Session A is live before interpreting any race result.
  -- pg_try_advisory_xact_lock returns FALSE when another transaction owns key.
  -- ---------------------------------------------------------------------------
  SELECT pg_try_advisory_xact_lock(hashtext(v_order_id::text))
    INTO v_order_lock_obtainable;
  SELECT pg_try_advisory_xact_lock(hashtext(v_tracking_id::text))
    INTO v_tracking_lock_obtainable;

  INSERT INTO shipment_undo_concurrency_v2_results VALUES(
    'session_a_live_lock_handshake',
    NOT v_order_lock_obtainable AND NOT v_tracking_lock_obtainable,
    jsonb_build_object(
      'order_id',v_order_id,
      'tracking_submission_id',v_tracking_id,
      'order_lock_obtainable_by_session_b',v_order_lock_obtainable,
      'tracking_lock_obtainable_by_session_b',v_tracking_lock_obtainable,
      'expected_while_session_a_live',false
    )
  );

  IF v_order_lock_obtainable OR v_tracking_lock_obtainable THEN
    -- Do not manufacture six false FAILs if the user ran the tabs sequentially.
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrency_race_suite_executed',
      false,
      jsonb_build_object(
        'result','NOT_RUN',
        'reason','Session A real Undo locks were not both active. Start A v2, then immediately run B v2 before A finishes.'
      )
    );
    RETURN;
  END IF;

  INSERT INTO shipment_undo_concurrency_v2_results VALUES(
    'concurrency_race_suite_executed',true,
    jsonb_build_object('result','RUN','session_a_lock_handshake_confirmed',true)
  );

  -- ---------------------------------------------------------------------------
  -- 1. Concurrent re-batching / shipment creation.
  -- Must timeout on the shared order/tracking advisory lock before stale active
  -- membership can be acted upon.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_create_shipment_batch_v2(
      v_importer_id,
      ARRAY[v_tracking_id],
      'CONCURRENCY-V2-' || substr(gen_random_uuid()::text,1,8),
      NULL,NULL,NULL,NULL,NULL,
      'Rollback-only two-session re-batch race proof v2'
    );

    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_rebatch_serialized',false,
      jsonb_build_object('reason','Competing create returned while Session A lock handshake was confirmed.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_rebatch_serialized',
      v_sqlstate = '55P03',
      jsonb_build_object(
        'sqlstate',v_sqlstate,
        'error',v_err,
        'expected','55P03 shared order/tracking advisory lock timeout',
        'order_id',v_order_id,
        'tracking_submission_id',v_tracking_id
      )
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 2. Concurrent customer-sales release allocation boundary.
  -- The release guard uses FOR UPDATE on this exact allocation row. Directly
  -- prove the row is unavailable while Undo holds it and fingerprint the guard.
  -- ---------------------------------------------------------------------------
  SELECT pg_get_functiondef('public.customer_sales_release_guard_v1()'::regprocedure)
    INTO v_release_guard;

  BEGIN
    PERFORM 1
    FROM public.order_tracking_line_allocations a
    WHERE a.id = v_allocation_id
    FOR UPDATE;

    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_customer_release_allocation_serialized',false,
      jsonb_build_object('reason','Exact allocation row became lockable while Session A lock handshake was confirmed.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_customer_release_allocation_serialized',
      v_sqlstate='55P03'
      AND v_release_guard ILIKE '%order_tracking_line_allocations%'
      AND v_release_guard ILIKE '%FOR UPDATE%',
      jsonb_build_object(
        'sqlstate',v_sqlstate,
        'error',v_err,
        'expected','55P03 exact allocation row timeout',
        'allocation_id',v_allocation_id,
        'installed_release_guard_uses_allocation_for_update',
          v_release_guard ILIKE '%order_tracking_line_allocations%'
          AND v_release_guard ILIKE '%FOR UPDATE%'
      )
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 3. Shipment header writer.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_update_shipment_batch_header_v1(v_batch_id,v_booking_ref);
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_header_writer_serialized',false,
      jsonb_build_object('reason','Header writer returned while Session A lock handshake was confirmed.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_header_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row timeout')
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 4. Completion-fields writer.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_save_export_evidence_completion_fields_v1(v_batch_id);
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_completion_writer_serialized',false,
      jsonb_build_object('reason','Completion writer returned while Session A lock handshake was confirmed.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_completion_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row timeout')
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 5. Shipping-document writer.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_submit_shipping_document_v1(
      v_batch_id,
      'shipper_invoice',
      'CONCURRENCY-V2-PROBE',
      current_date,
      'GBP',
      1,
      'regression://shipment-undo-concurrency-v2',
      'Rollback-only shipping-document race proof v2'
    );
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_shipping_document_writer_serialized',false,
      jsonb_build_object('reason','Shipping-document writer returned while Session A lock handshake was confirmed.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_shipping_document_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row timeout')
    );
  END;

  -- ---------------------------------------------------------------------------
  -- 6. Final-export-evidence writer.
  -- Its parent-batch lock is before completion-ready validation, so live Undo
  -- contention must timeout before any completion-field validation can execute.
  -- ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_submit_final_export_evidence_v1(
      v_batch_id,
      'completed_cos',
      'CONCURRENCY-V2-PROBE',
      'regression://shipment-undo-concurrency-v2-final',
      'Rollback-only final-evidence race proof v2'
    );
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_final_evidence_writer_serialized',false,
      jsonb_build_object('reason','Final-evidence writer returned while Session A lock handshake was confirmed.')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    INSERT INTO shipment_undo_concurrency_v2_results VALUES(
      'concurrent_final_evidence_writer_serialized',
      v_sqlstate='55P03',
      jsonb_build_object('sqlstate',v_sqlstate,'error',v_err,'expected','55P03 parent-batch row timeout')
    );
  END;
END
$race$;

-- Protected Groupage/line authorities must remain unchanged after the real race.
INSERT INTO shipment_undo_concurrency_v2_results(test_name,passed,detail)
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
  'probe','shipment_batch_undo_release_control_concurrency_session_b_v2',
  'result',CASE
    WHEN EXISTS(
      SELECT 1 FROM shipment_undo_concurrency_v2_results
      WHERE test_name='concurrency_race_suite_executed'
        AND detail->>'result'='NOT_RUN'
    ) THEN 'NOT_RUN'
    WHEN bool_and(passed) THEN 'PASS'
    ELSE 'FAIL'
  END,
  'transaction_wrapped',true,
  'will_rollback',true,
  'handshake_required',true,
  'expected_race_signal','55P03 lock timeout after Session A live-lock handshake is confirmed',
  'groupage_mutation_performed',false,
  'failed_tests',COALESCE(jsonb_agg(test_name ORDER BY test_name) FILTER(WHERE NOT passed),'[]'::jsonb),
  'tests',jsonb_agg(
    jsonb_build_object('test',test_name,'passed',passed,'detail',detail)
    ORDER BY test_name
  )
)) AS result
FROM shipment_undo_concurrency_v2_results;

ROLLBACK;
