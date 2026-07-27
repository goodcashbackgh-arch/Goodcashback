-- Transaction-based behavioural regression for the shipper canonical review gate.
-- All REG-CANON-REVIEW-* fixtures and route side effects are removed by ROLLBACK.
BEGIN;

SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.customer_review_cycle_component_guard_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL preflight: customer_review_cycle_component_guard_v1() is missing';
  END IF;
  IF to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL preflight: internal_materialize_customer_review_cycles_v1(uuid,uuid) is missing';
  END IF;
  IF to_regprocedure('public.customer_review_cycle_candidates_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL preflight: customer_review_cycle_candidates_v1(uuid) is missing';
  END IF;
  IF to_regprocedure('public.customer_active_order_review_link_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL preflight: installed customer review readers are missing';
  END IF;
  IF to_regprocedure('public.shipper_record_package_receipt_v1(uuid,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL preflight: supported shipper receipt route is missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    JOIN pg_proc trigger_function ON trigger_function.oid = trigger_row.tgfoid
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'customer_review_cycle_memberships'
      AND trigger_function.proname = 'customer_review_cycle_component_guard_v1'
      AND trigger_row.tgenabled <> 'D'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL preflight: enabled membership component guard trigger is missing';
  END IF;
END $$;

CREATE TEMP TABLE canonical_review_controlled_snapshot AS
SELECT jsonb_build_object(
  'orders', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.orders row_value WHERE row_value.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
  'receipts', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.shipper_package_receipts row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
  'review_links', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.customer_order_review_links row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
  'review_memberships', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.customer_review_cycle_memberships row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
  'holds', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.customer_pre_shipment_hold_requests row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
  'shipment_packages', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.shipper_shipment_batch_packages row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
  'sales_invoices', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.sales_invoices row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
  'disputes', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.disputes row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb)
) AS payload;

DO $$
DECLARE
  v_order_id uuid := gen_random_uuid();
  v_tracking_id uuid := gen_random_uuid();
  v_invoice_id uuid := gen_random_uuid();
  v_line_id uuid := gen_random_uuid();
  v_allocation_id uuid := gen_random_uuid();
  v_link_id uuid;
  v_membership_id uuid;
  v_hold_id uuid := gen_random_uuid();
  v_deadline timestamptz;
  v_deadline_after timestamptz;
  v_shipper_user public.shipper_users%ROWTYPE;
  v_source_order public.orders%ROWTYPE;
  v_source_tracking_id uuid;
  v_source_allocation_id uuid;
  v_source_tracking public.order_tracking_submissions%ROWTYPE;
  v_source_invoice public.supplier_invoices%ROWTYPE;
  v_source_line public.supplier_invoice_lines%ROWTYPE;
  v_source_allocation public.order_tracking_line_allocations%ROWTYPE;
  v_active boolean;
  v_bulk_active boolean;
  v_bulk_deadline timestamptz;
  v_candidate_count integer;
  v_batch_id uuid;
  v_order_status text;
  v_error text;
  v_controlled_count integer;
  v_controlled_active_count integer;
BEGIN
  SELECT shipper_user.*
  INTO v_shipper_user
  FROM public.shipper_users shipper_user
  JOIN public.orders source_order ON source_order.shipper_id = shipper_user.shipper_id
  JOIN public.order_tracking_submissions source_tracking ON source_tracking.order_id = source_order.id
  JOIN public.order_tracking_line_allocations source_allocation
    ON source_allocation.order_id = source_order.id
   AND source_allocation.tracking_submission_id = source_tracking.id
   AND source_allocation.qty_allocated > 0
  JOIN public.customer_review_cycle_memberships source_membership
    ON source_membership.order_id = source_order.id
   AND source_membership.tracking_submission_id = source_tracking.id
   AND source_membership.tracking_line_allocation_id = source_allocation.id
  WHERE shipper_user.active = true
    AND source_tracking.superseded_at IS NULL
  ORDER BY shipper_user.created_at
  LIMIT 1;

  IF v_shipper_user.id IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active shipper fixture identity with an allocated tracking package exists';
  END IF;

  SELECT source_order.*
  INTO v_source_order
  FROM public.orders source_order
  JOIN public.order_tracking_submissions source_tracking ON source_tracking.order_id = source_order.id
  JOIN public.order_tracking_line_allocations source_allocation
    ON source_allocation.order_id = source_order.id
   AND source_allocation.tracking_submission_id = source_tracking.id
   AND source_allocation.qty_allocated > 0
  JOIN public.supplier_invoice_lines source_line ON source_line.id = source_allocation.supplier_invoice_line_id
  JOIN public.supplier_invoices source_invoice ON source_invoice.id = source_line.supplier_invoice_id
  JOIN public.customer_review_cycle_memberships source_membership
    ON source_membership.order_id = source_order.id
   AND source_membership.tracking_submission_id = source_tracking.id
   AND source_membership.tracking_line_allocation_id = source_allocation.id
   AND source_membership.supplier_invoice_line_id = source_line.id
   AND source_membership.supplier_invoice_id = source_invoice.id
  WHERE source_order.shipper_id = v_shipper_user.shipper_id
    AND source_tracking.superseded_at IS NULL
  ORDER BY source_order.created_at
  LIMIT 1;

  SELECT
    source_membership.tracking_submission_id,
    source_membership.tracking_line_allocation_id
  INTO STRICT
    v_source_tracking_id,
    v_source_allocation_id
  FROM public.customer_review_cycle_memberships source_membership
  WHERE source_membership.order_id = v_source_order.id
  ORDER BY source_membership.created_at, source_membership.id
  LIMIT 1;

  SELECT source_tracking.* INTO STRICT v_source_tracking
  FROM public.order_tracking_submissions source_tracking
  WHERE source_tracking.id = v_source_tracking_id
    AND source_tracking.order_id = v_source_order.id
    AND source_tracking.superseded_at IS NULL;

  SELECT source_allocation.* INTO STRICT v_source_allocation
  FROM public.order_tracking_line_allocations source_allocation
  WHERE source_allocation.id = v_source_allocation_id
    AND source_allocation.order_id = v_source_order.id
    AND source_allocation.tracking_submission_id = v_source_tracking.id
    AND source_allocation.qty_allocated > 0;

  SELECT source_line.* INTO STRICT v_source_line
  FROM public.supplier_invoice_lines source_line
  WHERE source_line.id = v_source_allocation.supplier_invoice_line_id;

  SELECT source_invoice.* INTO STRICT v_source_invoice
  FROM public.supplier_invoices source_invoice
  WHERE source_invoice.id = v_source_line.supplier_invoice_id;

  PERFORM set_config('request.jwt.claim.sub', v_shipper_user.auth_user_id::text, true);

  INSERT INTO public.orders
  SELECT (jsonb_populate_record(
    NULL::public.orders,
    to_jsonb(v_source_order) || jsonb_build_object(
      'id', v_order_id,
      'order_ref', 'REG-CANON-REVIEW-' || replace(v_order_id::text, '-', ''),
      'payment_auth_id', NULL,
      'parent_order_id', NULL,
      'status', 'evidence_collecting',
      'content_locked_at', NULL,
      'tracking_locked_at', NULL,
      'created_at', clock_timestamp(),
      'updated_at', clock_timestamp(),
      'completed_at', NULL
    )
  )).*;

  INSERT INTO public.supplier_invoices
  SELECT (jsonb_populate_record(
    NULL::public.supplier_invoices,
    to_jsonb(v_source_invoice) || jsonb_build_object(
      'id', v_invoice_id,
      'order_id', v_order_id,
      'invoice_ref', 'REG-CANON-REVIEW-' || left(v_invoice_id::text, 12),
      'invoice_pdf_url', 'regression://REG-CANON-REVIEW-' || v_invoice_id::text,
      'ocr_service_used', 'manual',
      'ocr_raw_json', NULL,
      'ocr_extracted_at', NULL,
      'ocr_invoice_ref', 'REG-CANON-REVIEW-OCR-' || replace(v_invoice_id::text, '-', ''),
      'ocr_invoice_total_gbp', NULL,
      'ocr_retailer_name', NULL,
      'ocr_invoice_date', NULL,
      'mindee_job_id', NULL,
      'mindee_inference_id', NULL,
      'mindee_model_id', NULL,
      'mindee_ocr_status', 'not_started',
      'mindee_enqueued_at', NULL,
      'mindee_completed_at', NULL,
      'mindee_result_saved_at', NULL,
      'mindee_last_http_status', NULL,
      'mindee_pages_consumed', NULL,
      'mindee_error_message', NULL,
      'uploaded_at', clock_timestamp()
    )
  )).*;

  SELECT fixture_order.status::text INTO STRICT v_order_status
  FROM public.orders fixture_order
  WHERE fixture_order.id = v_order_id;
  IF v_order_status <> 'reconciling' THEN
    RAISE EXCEPTION
      'FAIL: supplier-invoice trigger did not advance fixture order from evidence_collecting to reconciling (status: %)',
      v_order_status;
  END IF;

  INSERT INTO public.supplier_invoice_lines
  SELECT (jsonb_populate_record(
    NULL::public.supplier_invoice_lines,
    to_jsonb(v_source_line) || jsonb_build_object(
      'id', v_line_id,
      'supplier_invoice_id', v_invoice_id,
      'created_at', clock_timestamp(),
      'updated_at', clock_timestamp()
    )
  )).*;

  INSERT INTO public.order_tracking_submissions
  SELECT (jsonb_populate_record(
    NULL::public.order_tracking_submissions,
    to_jsonb(v_source_tracking) || jsonb_build_object(
      'id', v_tracking_id,
      'order_id', v_order_id,
      'tracking_ref', 'REG-CANON-REVIEW-' || left(v_tracking_id::text, 12),
      'tracking_date', current_date,
      'submitted_at', clock_timestamp(),
      'superseded_at', NULL,
      'note', 'REG-CANON-REVIEW behavioural regression'
    )
  )).*;

  INSERT INTO public.order_tracking_line_allocations
  SELECT (jsonb_populate_record(
    NULL::public.order_tracking_line_allocations,
    to_jsonb(v_source_allocation) || jsonb_build_object(
      'id', v_allocation_id,
      'order_id', v_order_id,
      'supplier_invoice_line_id', v_line_id,
      'tracking_submission_id', v_tracking_id,
      'created_at', clock_timestamp(),
      'updated_at', clock_timestamp()
    )
  )).*;

  PERFORM public.shipper_record_package_receipt_v1(
    v_tracking_id,
    'received_clean',
    'REG-CANON-REVIEW fixture',
    NULL
  );

  PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);

  SELECT review_link.id, review_link.expires_at
  INTO STRICT v_link_id, v_deadline
  FROM public.customer_order_review_links review_link
  WHERE review_link.order_id = v_order_id
    AND review_link.is_active = true
    AND review_link.expires_at IS NOT NULL
    AND review_link.expires_at > now();

  SELECT membership.id
  INTO STRICT v_membership_id
  FROM public.customer_review_cycle_memberships membership
  WHERE membership.review_link_id = v_link_id
    AND membership.order_id = v_order_id
    AND membership.supplier_invoice_id = v_invoice_id
    AND membership.supplier_invoice_line_id = v_line_id
    AND membership.tracking_submission_id = v_tracking_id
    AND membership.tracking_line_allocation_id = v_allocation_id
    AND membership.membership_status = 'active';

  -- A: active exact timed review is identical across single and bulk readers.
  SELECT state.active_review_yn INTO STRICT v_active
  FROM public.shipper_tracking_review_state_v1(v_order_id, v_tracking_id) state;
  SELECT state.active_review_yn, state.review_expires_at
  INTO STRICT v_bulk_active, v_bulk_deadline
  FROM public.shipper_dashboard_tracking_review_states_v1() state
  WHERE state.order_id = v_order_id AND state.tracking_submission_id = v_tracking_id;

  IF NOT v_active OR NOT v_bulk_active OR v_bulk_deadline IS DISTINCT FROM v_deadline THEN
    RAISE EXCEPTION 'FAIL A: active single/bulk canonical state or stored deadline differs';
  END IF;

  SELECT count(*) INTO v_candidate_count
  FROM public.shipper_shipment_batch_candidates_v1() candidate
  WHERE candidate.tracking_submission_id = v_tracking_id;
  IF v_candidate_count <> 0 THEN
    RAISE EXCEPTION 'FAIL A: actively reviewed package appears in shipment candidates';
  END IF;

  BEGIN
    PERFORM public.shipper_create_shipment_batch_v1(
      v_source_order.importer_id, ARRAY[v_tracking_id], 'REG-CANON-REVIEW-ACTIVE'
    );
    RAISE EXCEPTION 'FAIL A: direct creation accepted an active review';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%active customer review window%' THEN
      RAISE EXCEPTION 'FAIL A: unexpected direct-create rejection: %', v_error;
    END IF;
  END;

  -- E: re-running the production materialiser cannot move the fixed deadline.
  PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);

  SELECT expires_at INTO v_deadline_after
  FROM public.customer_order_review_links WHERE id = v_link_id;
  IF v_deadline_after IS DISTINCT FROM v_deadline THEN
    RAISE EXCEPTION 'FAIL E: production rematerialisation changed the fixed deadline';
  END IF;

  -- C: create the exact line hold while review is still active.
  INSERT INTO public.customer_pre_shipment_hold_requests (
    id, order_id, review_link_id, tracking_submission_id, supplier_invoice_line_id,
    requested_scope, reason, status
  ) VALUES (
    v_hold_id, v_order_id, v_link_id, v_tracking_id, v_line_id,
    'line', 'REG-CANON-REVIEW active hold', 'requested'
  );

  SELECT state.active_review_yn INTO STRICT v_active
  FROM public.shipper_tracking_review_state_v1(v_order_id, v_tracking_id) state;
  IF NOT v_active THEN
    RAISE EXCEPTION 'FAIL C: creating a hold changed the still-active canonical review state';
  END IF;

  -- Close the review through the installed transition without touching expires_at.
  UPDATE public.customer_review_cycle_memberships
  SET membership_status = 'expired', status_updated_at = clock_timestamp()
  WHERE review_link_id = v_link_id AND membership_status = 'active';
  UPDATE public.customer_order_review_links SET is_active = false WHERE id = v_link_id;

  SELECT state.active_review_yn INTO STRICT v_active
  FROM public.shipper_tracking_review_state_v1(v_order_id, v_tracking_id) state;
  SELECT state.active_review_yn INTO STRICT v_bulk_active
  FROM public.shipper_dashboard_tracking_review_states_v1() state
  WHERE state.order_id = v_order_id AND state.tracking_submission_id = v_tracking_id;
  IF v_active OR v_bulk_active THEN
    RAISE EXCEPTION 'FAIL C: closed review remains canonically active while the hold is open';
  END IF;

  SELECT count(*) INTO v_candidate_count
  FROM public.shipper_shipment_batch_candidates_v1() candidate
  WHERE candidate.tracking_submission_id = v_tracking_id;
  IF v_candidate_count <> 0 THEN
    RAISE EXCEPTION 'FAIL C: active hold did not remain authoritative after review closure';
  END IF;

  BEGIN
    PERFORM public.shipper_create_shipment_batch_v1(
      v_source_order.importer_id, ARRAY[v_tracking_id], 'REG-CANON-REVIEW-HOLD'
    );
    RAISE EXCEPTION 'FAIL C: direct creation accepted an actively held package';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE '%customer review%' OR v_error NOT LIKE '%no shipment-eligible lines%' THEN
      RAISE EXCEPTION 'FAIL C: unexpected post-review hold rejection: %', v_error;
    END IF;
  END;

  UPDATE public.customer_pre_shipment_hold_requests
  SET status = 'resolved', resolved_at = clock_timestamp(), updated_at = clock_timestamp()
  WHERE id = v_hold_id;

  -- B: once review is closed and the separate hold is resolved, the package is eligible.
  SELECT state.active_review_yn INTO STRICT v_active
  FROM public.shipper_tracking_review_state_v1(v_order_id, v_tracking_id) state;
  SELECT count(*) INTO v_candidate_count
  FROM public.shipper_shipment_batch_candidates_v1() candidate
  WHERE candidate.tracking_submission_id = v_tracking_id;
  IF v_active OR v_candidate_count <> 1 THEN
    RAISE EXCEPTION 'FAIL B: package did not become eligible after review closure and hold resolution';
  END IF;

  BEGIN
    v_batch_id := public.shipper_create_shipment_batch_v1(
      v_source_order.importer_id, ARRAY[v_tracking_id], 'REG-CANON-REVIEW-CLOSED'
    );
    RAISE EXCEPTION 'REG-CANON-REVIEW-ELIGIBLE-ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'REG-CANON-REVIEW-ELIGIBLE-ROLLBACK' THEN
      RAISE EXCEPTION 'FAIL B: closed review direct creation rejected: %', v_error;
    END IF;
  END;

  -- D: create once, then prove active shipment membership independently remains authoritative.
  v_batch_id := public.shipper_create_shipment_batch_v1(
    v_source_order.importer_id, ARRAY[v_tracking_id], 'REG-CANON-REVIEW-SHIPMENT'
  );
  SELECT count(*) INTO v_candidate_count
  FROM public.shipper_shipment_batch_candidates_v1() candidate
  WHERE candidate.tracking_submission_id = v_tracking_id;
  SELECT state.active_review_yn INTO STRICT v_active
  FROM public.shipper_tracking_review_state_v1(v_order_id, v_tracking_id) state;
  IF v_active OR v_candidate_count <> 0 THEN
    RAISE EXCEPTION 'FAIL D: shipment membership changed review state or remained a candidate';
  END IF;

  BEGIN
    PERFORM public.shipper_create_shipment_batch_v1(
      v_source_order.importer_id, ARRAY[v_tracking_id], 'REG-CANON-REVIEW-DUPLICATE'
    );
    RAISE EXCEPTION 'FAIL D: direct creation accepted existing shipment membership';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error NOT LIKE '%already in an active shipment batch%' THEN
      RAISE EXCEPTION 'FAIL D: unexpected active-shipment rejection: %', v_error;
    END IF;
  END;

  -- F: controlled historical packages exist and remain outside canonical review.
  SELECT count(*), count(*) FILTER (WHERE canonical.active_review_yn)
  INTO v_controlled_count, v_controlled_active_count
  FROM (
    SELECT package.tracking_ref, EXISTS (
      SELECT 1
      FROM public.customer_order_review_links review_link
      JOIN public.customer_review_cycle_memberships membership
        ON membership.review_link_id = review_link.id
       AND membership.order_id = package.order_id
       AND membership.tracking_submission_id = package.id
       AND membership.membership_status = 'active'
      WHERE review_link.order_id = package.order_id
        AND review_link.is_active = true
        AND review_link.expires_at IS NOT NULL
        AND review_link.expires_at > now()
    ) AS active_review_yn
    FROM public.orders controlled
    JOIN public.order_tracking_submissions package ON package.order_id = controlled.id
    WHERE controlled.order_ref = 'ORD-1784976429191'
      AND package.tracking_ref IN ('DPD240726', 'DHL240726A')
  ) canonical;
  IF v_controlled_count <> 2 OR v_controlled_active_count <> 0 THEN
    RAISE EXCEPTION 'FAIL F: controlled package count/state is %, % active', v_controlled_count, v_controlled_active_count;
  END IF;
END $$;

DO $$
DECLARE
  v_before jsonb;
  v_after jsonb;
BEGIN
  SELECT payload INTO v_before FROM canonical_review_controlled_snapshot;
  SELECT jsonb_build_object(
    'orders', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.orders row_value WHERE row_value.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
    'receipts', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.shipper_package_receipts row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
    'review_links', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.customer_order_review_links row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
    'review_memberships', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.customer_review_cycle_memberships row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
    'holds', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.customer_pre_shipment_hold_requests row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
    'shipment_packages', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.shipper_shipment_batch_packages row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
    'sales_invoices', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.sales_invoices row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb),
    'disputes', COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id) FROM public.disputes row_value JOIN public.orders controlled ON controlled.id = row_value.order_id WHERE controlled.order_ref = 'ORD-1784976429191'), '[]'::jsonb)
  ) INTO v_after;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'FAIL F: controlled historical or protected-route data changed';
  END IF;
END $$;

SELECT 'PASS: runtime active, closed, hold, shipment, deadline and controlled-order scenarios' AS regression_result;

ROLLBACK;
