-- Rollback-only behavioral regression for grouped replacement outcome lanes.
--
-- Uses one existing valid physical-review/remedy/dispute graph as a structural
-- anchor, reshapes it and adds one cloned exact remedy inside this transaction,
-- restores normal trigger enforcement, exercises the real SECURITY DEFINER RPCs,
-- emits PASS, then rolls everything back.
--
-- Requires execution from the Supabase SQL editor as the database owner because
-- fixture shaping temporarily uses session_replication_role = replica.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL
     OR to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: outcome lane RPCs are not installed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations r
    JOIN public.physical_receipt_reviews pr ON pr.id = r.physical_receipt_review_id
    JOIN public.dispute_lines dl ON dl.id = r.dispute_line_id
    JOIN public.disputes d ON d.id = dl.dispute_id AND d.order_id = pr.order_id
    JOIN public.operator_importers oi ON oi.importer_id = pr.importer_id AND oi.revoked_at IS NULL
    JOIN public.operators op ON op.id = oi.operator_id
      AND COALESCE(op.active,true)
      AND op.auth_user_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: no structural physical remedy/dispute graph with an active linked operator exists';
  END IF;
END
$preflight$;

DO $fixture$
DECLARE
  v_source record;
  v_clone_dispute_id uuid := gen_random_uuid();
  v_clone_dispute_line_id uuid := gen_random_uuid();
  v_clone_allocation_id uuid := gen_random_uuid();
  v_idempotency_key uuid := gen_random_uuid();
  v_child_order_count integer;
BEGIN
  SELECT
    r.*,
    pr.order_id,
    pr.importer_id,
    dl.dispute_id,
    dl.supplier_invoice_line_id AS dispute_supplier_invoice_line_id,
    d.raised_by_operator_id,
    d.issue_type,
    d.refund_settlement_mode,
    d.liable_party,
    d.stage_detected,
    d.amount_impact_gbp AS dispute_amount_impact_gbp,
    d.comments_initial,
    d.sop_version,
    op.id AS operator_id,
    op.auth_user_id AS operator_auth_user_id
  INTO v_source
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr ON pr.id = r.physical_receipt_review_id
  JOIN public.dispute_lines dl ON dl.id = r.dispute_line_id
  JOIN public.disputes d ON d.id = dl.dispute_id AND d.order_id = pr.order_id
  JOIN public.operator_importers oi ON oi.importer_id = pr.importer_id AND oi.revoked_at IS NULL
  JOIN public.operators op ON op.id = oi.operator_id
    AND COALESCE(op.active,true)
    AND op.auth_user_id IS NOT NULL
  ORDER BY r.created_at, r.id
  LIMIT 1;

  SELECT COUNT(*) INTO v_child_order_count
  FROM public.orders o
  WHERE o.id IN (
    SELECT replacement_child_order_id
    FROM public.physical_exception_remedy_allocations
    WHERE physical_receipt_review_id = v_source.physical_receipt_review_id
      AND replacement_child_order_id IS NOT NULL
  );

  PERFORM set_config('app.test.review_id', v_source.physical_receipt_review_id::text, true);
  PERFORM set_config('app.test.order_id', v_source.order_id::text, true);
  PERFORM set_config('app.test.operator_auth_user_id', v_source.operator_auth_user_id::text, true);
  PERFORM set_config('app.test.source_allocation_id', v_source.id::text, true);
  PERFORM set_config('app.test.clone_allocation_id', v_clone_allocation_id::text, true);
  PERFORM set_config('app.test.source_dispute_line_id', v_source.dispute_line_id::text, true);
  PERFORM set_config('app.test.clone_dispute_line_id', v_clone_dispute_line_id::text, true);
  PERFORM set_config('app.test.clone_dispute_id', v_clone_dispute_id::text, true);
  PERFORM set_config('app.test.idempotency_key', v_idempotency_key::text, true);
  PERFORM set_config('app.test.child_order_count_before', v_child_order_count::text, true);

  SET LOCAL session_replication_role = replica;

  UPDATE public.disputes
  SET desired_outcome = 'replacement',
      status = 'under_review',
      replacement_child_order_id = NULL,
      resolved_at = NULL
  WHERE id = v_source.dispute_id;

  UPDATE public.dispute_lines
  SET line_status = 'affected',
      resolution_method = NULL,
      resolved_at = NULL,
      resolved_via_child_order_id = NULL,
      conversation_status = 'remedy_selected',
      intended_remedy = 'replacement',
      physical_remedy_allocation_id = v_source.id
  WHERE id = v_source.dispute_line_id;

  UPDATE public.physical_exception_remedy_allocations
  SET approved_remedy_type = 'replacement',
      approved_remedy_qty = GREATEST(1, trunc(COALESCE(approved_remedy_qty, proposed_remedy_qty, 1))),
      approved_by_staff_id = COALESCE(
        approved_by_staff_id,
        (SELECT id FROM public.staff WHERE COALESCE(active,true) ORDER BY id LIMIT 1)
      ),
      approved_at = COALESCE(approved_at, now()),
      dispute_line_id = v_source.dispute_line_id,
      supplier_cost_mode = 'free_replacement',
      replacement_child_order_id = NULL,
      replacement_child_tracking_allocation_id = NULL,
      rerouted_to_remedy_allocation_id = NULL,
      status = 'linked_to_exception',
      updated_at = now()
  WHERE id = v_source.id;

  IF (SELECT approved_by_staff_id FROM public.physical_exception_remedy_allocations WHERE id=v_source.id) IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff row exists for approved fixture shape';
  END IF;

  INSERT INTO public.disputes (
    id, order_id, raised_at, raised_by_operator_id, issue_type, desired_outcome,
    refund_settlement_mode, liable_party, stage_detected, amount_impact_gbp,
    comments_initial, status, reviewed_by_staff_id, reviewed_at,
    refund_approved_by_staff_id, refund_approved_at,
    customer_credit_note_sales_invoice_id, replacement_child_order_id,
    resolved_at, sop_version
  )
  SELECT
    v_clone_dispute_id, order_id, now(), raised_by_operator_id, issue_type, 'replacement',
    NULL, liable_party, stage_detected, GREATEST(amount_impact_gbp,0.01),
    'Rollback regression cloned replacement dispute', 'under_review', reviewed_by_staff_id, reviewed_at,
    NULL, NULL, NULL, NULL, NULL, sop_version
  FROM public.disputes
  WHERE id = v_source.dispute_id;

  INSERT INTO public.dispute_lines (
    id, dispute_id, supplier_invoice_line_id, qty_impact, amount_impact_gbp,
    line_status, resolution_method, resolved_at, resolved_via_child_order_id,
    created_at, conversation_status, intended_remedy, physical_remedy_allocation_id
  )
  SELECT
    v_clone_dispute_line_id, v_clone_dispute_id, supplier_invoice_line_id,
    GREATEST(1,qty_impact), GREATEST(amount_impact_gbp,0.01),
    'affected', NULL, NULL, NULL, now(), 'remedy_selected', 'replacement', v_clone_allocation_id
  FROM public.dispute_lines
  WHERE id = v_source.dispute_line_id;

  INSERT INTO public.physical_exception_remedy_allocations (
    id, physical_receipt_review_id, receipt_line_disposition_id,
    tracking_line_allocation_id, supplier_invoice_line_id,
    proposed_remedy_type, proposed_remedy_qty, proposed_by_operator_id, proposed_at,
    approved_remedy_type, approved_remedy_qty, approved_by_staff_id, approved_at,
    dispute_line_id, supplier_claim_amount_gbp, customer_commercial_value_gbp,
    supplier_cost_mode, replacement_child_order_id,
    replacement_child_tracking_allocation_id, status,
    rerouted_to_remedy_allocation_id, created_at, updated_at
  )
  SELECT
    v_clone_allocation_id, physical_receipt_review_id, receipt_line_disposition_id,
    tracking_line_allocation_id, supplier_invoice_line_id,
    'replacement', GREATEST(1,trunc(COALESCE(proposed_remedy_qty,1))), proposed_by_operator_id, now(),
    'replacement', GREATEST(1,trunc(COALESCE(approved_remedy_qty,proposed_remedy_qty,1))),
    approved_by_staff_id, now(), v_clone_dispute_line_id,
    supplier_claim_amount_gbp, customer_commercial_value_gbp,
    'free_replacement', NULL, NULL, 'linked_to_exception', NULL, now(), now()
  FROM public.physical_exception_remedy_allocations
  WHERE id = v_source.id;

  SET LOCAL session_replication_role = origin;
END
$fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('app.test.operator_auth_user_id'),
    'role', 'authenticated'
  )::text,
  true
);

DO $exercise$
DECLARE
  v_review_id uuid := current_setting('app.test.review_id')::uuid;
  v_source_allocation_id uuid := current_setting('app.test.source_allocation_id')::uuid;
  v_clone_allocation_id uuid := current_setting('app.test.clone_allocation_id')::uuid;
  v_idempotency_key uuid := current_setting('app.test.idempotency_key')::uuid;
  v_lane_id uuid;
  v_materialized jsonb;
  v_update jsonb;
  v_replay jsonb;
  v_update_id uuid;
  v_before_updates integer;
  v_before_messages integer;
  v_error text;
BEGIN
  v_materialized := public.materialize_physical_receipt_outcome_lanes_v1(v_review_id);

  SELECT id INTO v_lane_id
  FROM public.physical_receipt_outcome_lanes
  WHERE physical_receipt_review_id = v_review_id
    AND outcome_type = 'replacement';

  IF v_lane_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: replacement lane was not materialized';
  END IF;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_items WHERE lane_id=v_lane_id) <> 2 THEN
    RAISE EXCEPTION 'FAIL: replacement lane does not contain exactly two items';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.physical_receipt_outcome_lane_items li
    JOIN public.physical_exception_remedy_allocations r ON r.id=li.physical_remedy_allocation_id
    WHERE li.lane_id=v_lane_id
      AND (r.approved_remedy_type<>'replacement' OR r.replacement_child_order_id IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'FAIL: materialized lane item shape is not same-order replacement';
  END IF;

  SELECT COUNT(*) INTO v_before_updates
  FROM public.physical_receipt_outcome_lane_updates
  WHERE lane_id=v_lane_id;

  SELECT COUNT(*) INTO v_before_messages
  FROM public.dispute_messages m
  WHERE m.body='Regression retailer accepted both replacement items.';

  v_update := public.operator_record_physical_outcome_lane_update_v1(
    v_lane_id,
    ARRAY[v_source_allocation_id,v_clone_allocation_id],
    'Regression retailer accepted both replacement items.',
    'retailer_accepted',
    'One grouped operator action for two exact replacements.',
    v_idempotency_key
  );

  IF COALESCE((v_update->>'ok')::boolean,false) IS DISTINCT FROM true
     OR (v_update->>'updated_items')::integer <> 2
  THEN
    RAISE EXCEPTION 'FAIL: grouped update result was not two-item success: %', v_update;
  END IF;

  v_update_id := (v_update->>'lane_update_id')::uuid;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_updates WHERE lane_id=v_lane_id) <> v_before_updates+1 THEN
    RAISE EXCEPTION 'FAIL: grouped action did not create exactly one lane update';
  END IF;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_update_items WHERE lane_update_id=v_update_id) <> 2 THEN
    RAISE EXCEPTION 'FAIL: grouped action did not link both exact lane items';
  END IF;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_update_items WHERE lane_update_id=v_update_id AND dispute_message_id IS NOT NULL) <> 2 THEN
    RAISE EXCEPTION 'FAIL: exact compatibility message link missing for one or more items';
  END IF;

  IF (SELECT COUNT(*) FROM public.dispute_messages WHERE body='Regression retailer accepted both replacement items.') <> v_before_messages+2 THEN
    RAISE EXCEPTION 'FAIL: expected one exact dispute message per selected item';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    WHERE dl.id IN (
      current_setting('app.test.source_dispute_line_id')::uuid,
      current_setting('app.test.clone_dispute_line_id')::uuid
    )
      AND dl.conversation_status <> 'retailer_response_received'
  ) THEN
    RAISE EXCEPTION 'FAIL: both exact dispute lines were not updated';
  END IF;

  IF (SELECT lane_status FROM public.physical_receipt_outcome_lanes WHERE id=v_lane_id) <> 'retailer_response_complete' THEN
    RAISE EXCEPTION 'FAIL: complete two-item acceptance did not complete the lane response state';
  END IF;

  v_replay := public.operator_record_physical_outcome_lane_update_v1(
    v_lane_id,
    ARRAY[v_source_allocation_id,v_clone_allocation_id],
    'Regression retailer accepted both replacement items.',
    'retailer_accepted',
    'Idempotent replay.',
    v_idempotency_key
  );

  IF COALESCE((v_replay->>'idempotent_replay')::boolean,false) IS DISTINCT FROM true
     OR (v_replay->>'lane_update_id')::uuid <> v_update_id
  THEN
    RAISE EXCEPTION 'FAIL: idempotent replay did not return the original grouped update';
  END IF;

  IF (SELECT COUNT(*) FROM public.physical_receipt_outcome_lane_updates WHERE lane_id=v_lane_id) <> v_before_updates+1
     OR (SELECT COUNT(*) FROM public.dispute_messages WHERE body='Regression retailer accepted both replacement items.') <> v_before_messages+2
  THEN
    RAISE EXCEPTION 'FAIL: idempotent replay duplicated updates or messages';
  END IF;

  v_error := NULL;
  BEGIN
    PERFORM public.operator_record_physical_outcome_lane_update_v1(
      v_lane_id,
      ARRAY[v_source_allocation_id,gen_random_uuid()],
      'Invalid mixed selection.',
      'retailer_accepted',
      NULL,
      gen_random_uuid()
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;

  IF v_error IS NULL OR v_error NOT ILIKE '%do not belong to the lane%' THEN
    RAISE EXCEPTION 'FAIL: invalid selection did not fail closed: %', v_error;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.physical_exception_remedy_allocations
    WHERE id IN (v_source_allocation_id,v_clone_allocation_id)
      AND replacement_child_order_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: grouped lane workflow created or linked a replacement child order';
  END IF;
END
$exercise$;

RESET ROLE;

DO $final_assertions$
DECLARE
  v_child_order_count integer;
BEGIN
  SELECT COUNT(*) INTO v_child_order_count
  FROM public.orders o
  WHERE o.id IN (
    SELECT replacement_child_order_id
    FROM public.physical_exception_remedy_allocations
    WHERE physical_receipt_review_id=current_setting('app.test.review_id')::uuid
      AND replacement_child_order_id IS NOT NULL
  );

  IF v_child_order_count <> current_setting('app.test.child_order_count_before')::integer THEN
    RAISE EXCEPTION 'FAIL: replacement child-order count changed';
  END IF;

  IF md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738'
     OR md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233'
     OR md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679'
  THEN
    RAISE EXCEPTION 'FAIL: protected Mini Build fingerprint drift';
  END IF;
END
$final_assertions$;

SELECT jsonb_build_object(
  'result','PASS',
  'regression','physical_outcome_lane_grouped_replacement_rollback_v1',
  'replacement_lane_count',1,
  'exact_lane_items',2,
  'grouped_lane_updates',1,
  'exact_compatibility_messages',2,
  'idempotent_replay_proven',true,
  'invalid_selection_failed_closed',true,
  'replacement_child_orders_created',0,
  'rolled_back',true
) AS result;

ROLLBACK;
