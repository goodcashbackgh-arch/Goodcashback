BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing correction: grouped refund acceptance stops at awaiting_refund_credit.
-- Existing refund-document, invoice-progression, settlement, VAT, Sage and
-- accounting authorities remain unchanged.

ALTER TABLE public.physical_receipt_outcome_lane_decisions
  DROP CONSTRAINT IF EXISTS physical_receipt_outcome_lane_decisions_decision_type_check;

ALTER TABLE public.physical_receipt_outcome_lane_decisions
  ADD CONSTRAINT physical_receipt_outcome_lane_decisions_decision_type_check
  CHECK (decision_type = ANY (ARRAY[
    'refund_settlement_credit'::text,
    'refund_final_outcome_accept'::text,
    'replacement_accept'::text
  ]));

ALTER TABLE public.physical_receipt_outcome_lane_decision_items
  DROP CONSTRAINT IF EXISTS physical_receipt_outcome_lane_decision_item_decision_type_check;

ALTER TABLE public.physical_receipt_outcome_lane_decision_items
  ADD CONSTRAINT physical_receipt_outcome_lane_decision_item_decision_type_check
  CHECK (decision_type = ANY (ARRAY[
    'refund_settlement_credit'::text,
    'refund_final_outcome_accept'::text,
    'replacement_accept'::text
  ]));

CREATE OR REPLACE FUNCTION public.staff_decide_physical_outcome_lane_v1(
  p_lane_id uuid,
  p_staff_id uuid,
  p_item_decisions jsonb,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_lane public.physical_receipt_outcome_lanes%ROWTYPE;
  v_staff public.staff%ROWTYPE;
  v_requested_decision text;
  v_max_requested_decision text;
  v_decision_type text;
  v_count integer;
  v_request_hash text;
  v_existing_result jsonb;
  v_decision_id uuid;
  v_dispute_ids uuid[];
  v_item record;
  v_route_id uuid;
  v_authority_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_total_count integer;
  v_completed_count integer;
  v_lane_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  IF p_item_decisions IS NULL
     OR jsonb_typeof(p_item_decisions) <> 'array'
     OR jsonb_array_length(p_item_decisions) = 0
  THEN
    RAISE EXCEPTION 'At least one item decision is required.';
  END IF;

  SELECT * INTO v_staff
  FROM public.staff s
  WHERE s.id = p_staff_id
    AND s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true)
    AND s.role_type IN ('admin', 'supervisor')
  FOR UPDATE;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active supervisor/admin authority not found.';
  END IF;

  SELECT * INTO v_lane
  FROM public.physical_receipt_outcome_lanes l
  WHERE l.id = p_lane_id
  FOR UPDATE;

  IF v_lane.id IS NULL THEN
    RAISE EXCEPTION 'Outcome lane not found.';
  END IF;

  SELECT COUNT(*), MIN(item->>'decision'), MAX(item->>'decision')
  INTO v_count, v_requested_decision, v_max_requested_decision
  FROM jsonb_array_elements(p_item_decisions) item;

  IF v_requested_decision IS NULL OR v_requested_decision <> v_max_requested_decision THEN
    RAISE EXCEPTION 'Mixed decisions are not allowed in one grouped call.';
  END IF;

  IF v_count <> (
    SELECT COUNT(DISTINCT item->>'physical_remedy_allocation_id')
    FROM jsonb_array_elements(p_item_decisions) item
  ) THEN
    RAISE EXCEPTION 'Duplicate remedy allocation IDs are not allowed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_item_decisions) item
    WHERE COALESCE(item->>'physical_remedy_allocation_id', '')
      !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) THEN
    RAISE EXCEPTION 'Every item decision requires a valid physical_remedy_allocation_id.';
  END IF;

  IF v_lane.outcome_type = 'replacement'
     AND v_requested_decision = 'replacement_accept'
  THEN
    v_decision_type := 'replacement_accept';
  ELSIF v_lane.outcome_type = 'refund'
        AND v_requested_decision IN ('refund_settlement_credit', 'refund_final_outcome_accept')
  THEN
    v_decision_type := 'refund_final_outcome_accept';
  ELSE
    RAISE EXCEPTION 'Decision type does not match the outcome lane.';
  END IF;

  PERFORM 1
  FROM public.physical_receipt_outcome_lane_items li
  JOIN public.physical_exception_remedy_allocations allocation
    ON allocation.id = li.physical_remedy_allocation_id
  JOIN public.dispute_lines dl ON dl.id = li.dispute_line_id
  JOIN public.disputes d ON d.id = li.dispute_id
  WHERE li.lane_id = p_lane_id
    AND li.physical_remedy_allocation_id IN (
      SELECT (item->>'physical_remedy_allocation_id')::uuid
      FROM jsonb_array_elements(p_item_decisions) item
    )
  ORDER BY li.physical_remedy_allocation_id
  FOR UPDATE OF li, allocation, dl, d;

  IF (
    SELECT COUNT(*)
    FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id = p_lane_id
      AND li.physical_remedy_allocation_id IN (
        SELECT (item->>'physical_remedy_allocation_id')::uuid
        FROM jsonb_array_elements(p_item_decisions) item
      )
  ) <> v_count THEN
    RAISE EXCEPTION 'One or more selected items do not belong to the lane.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.physical_receipt_outcome_lane_items li
    JOIN public.physical_exception_remedy_allocations allocation
      ON allocation.id = li.physical_remedy_allocation_id
    WHERE li.lane_id = p_lane_id
      AND li.physical_remedy_allocation_id IN (
        SELECT (item->>'physical_remedy_allocation_id')::uuid
        FROM jsonb_array_elements(p_item_decisions) item
      )
      AND allocation.approved_remedy_type IS DISTINCT FROM v_lane.outcome_type
  ) THEN
    RAISE EXCEPTION 'Selected remedy type does not match the lane outcome.';
  END IF;

  SELECT md5(
    p_lane_id::text || '|' || p_staff_id::text || '|' || v_decision_type || '|'
    || COALESCE((
      SELECT string_agg(item->>'physical_remedy_allocation_id', ',' ORDER BY item->>'physical_remedy_allocation_id')
      FROM jsonb_array_elements(p_item_decisions) item
    ), '') || '|' || COALESCE(btrim(p_note), '')
  ) INTO v_request_hash;

  SELECT d.result_json INTO v_existing_result
  FROM public.physical_receipt_outcome_lane_decisions d
  WHERE d.lane_id = p_lane_id AND d.request_hash = v_request_hash;

  IF v_existing_result IS NOT NULL THEN
    RETURN v_existing_result;
  END IF;

  IF v_lane.lane_status = 'cancelled' THEN
    RAISE EXCEPTION 'Cancelled outcome lane cannot be decided.';
  END IF;

  IF v_decision_type = 'refund_final_outcome_accept'
     AND v_lane.lane_status <> 'awaiting_supervisor_decision'
  THEN
    RAISE EXCEPTION 'Refund lane is not awaiting supervisor decision. Current status: %', v_lane.lane_status;
  END IF;

  IF v_decision_type = 'refund_final_outcome_accept' THEN
    IF EXISTS (
      SELECT 1
      FROM public.physical_receipt_outcome_lane_items li
      JOIN public.disputes d ON d.id = li.dispute_id
      WHERE li.lane_id = p_lane_id
        AND li.physical_remedy_allocation_id IN (
          SELECT (item->>'physical_remedy_allocation_id')::uuid
          FROM jsonb_array_elements(p_item_decisions) item
        )
        AND (
          d.desired_outcome IS DISTINCT FROM 'refund'
          OR d.refund_approved_at IS NULL
          OR d.resolved_at IS NOT NULL
          OR d.status NOT IN ('raised', 'under_review', 'approved_refund', 'awaiting_refund_credit')
          OR NOT EXISTS (
            SELECT 1
            FROM public.dispute_messages m
            WHERE m.dispute_id = d.id
              AND m.message_type = 'retailer_reply'
              AND m.counterparty = 'retailer'
          )
          OR EXISTS (
            SELECT 1
            FROM public.dispute_lines dl
            WHERE dl.dispute_id = d.id
              AND dl.resolved_at IS NULL
              AND dl.conversation_status IS DISTINCT FROM 'retailer_response_received'
          )
        )
    ) THEN
      RAISE EXCEPTION 'Every grouped refund dispute requires refund approval, a retailer reply, accepted retailer line status, and an unresolved legal refund status.';
    END IF;
  END IF;

  SELECT array_agg(DISTINCT li.dispute_id ORDER BY li.dispute_id)
  INTO v_dispute_ids
  FROM public.physical_receipt_outcome_lane_items li
  WHERE li.lane_id = p_lane_id
    AND li.physical_remedy_allocation_id IN (
      SELECT (item->>'physical_remedy_allocation_id')::uuid
      FROM jsonb_array_elements(p_item_decisions) item
    );

  INSERT INTO public.physical_receipt_outcome_lane_decisions(
    lane_id, staff_id, outcome_type, decision_type, request_hash, note
  ) VALUES (
    p_lane_id, p_staff_id, v_lane.outcome_type, v_decision_type,
    v_request_hash, NULLIF(btrim(COALESCE(p_note, '')), '')
  ) RETURNING id INTO v_decision_id;

  IF v_decision_type = 'replacement_accept' THEN
    FOR v_item IN
      SELECT li.physical_remedy_allocation_id, li.dispute_id
      FROM public.physical_receipt_outcome_lane_items li
      WHERE li.lane_id = p_lane_id
        AND li.physical_remedy_allocation_id IN (
          SELECT (item->>'physical_remedy_allocation_id')::uuid
          FROM jsonb_array_elements(p_item_decisions) item
        )
      ORDER BY li.physical_remedy_allocation_id
    LOOP
      v_route_id := public.staff_accept_same_order_free_replacement_v1(
        v_item.dispute_id, p_staff_id, 'free_replacement', p_note
      );
      v_authority_result := jsonb_build_object('route_id', v_route_id);

      INSERT INTO public.physical_receipt_outcome_lane_decision_items(
        lane_decision_id, physical_remedy_allocation_id, dispute_id,
        decision_type, route_id, authority_result
      ) VALUES (
        v_decision_id, v_item.physical_remedy_allocation_id, v_item.dispute_id,
        v_decision_type, v_route_id, v_authority_result
      );

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'physical_remedy_allocation_id', v_item.physical_remedy_allocation_id,
        'dispute_id', v_item.dispute_id,
        'decision', v_decision_type,
        'route_id', v_route_id
      ));
    END LOOP;
  ELSE
    UPDATE public.disputes SET status = 'under_review'
    WHERE id = ANY(v_dispute_ids) AND status = 'raised';

    UPDATE public.disputes SET status = 'approved_refund'
    WHERE id = ANY(v_dispute_ids) AND status = 'under_review';

    UPDATE public.disputes SET status = 'awaiting_refund_credit'
    WHERE id = ANY(v_dispute_ids) AND status = 'approved_refund';

    IF EXISTS (
      SELECT 1 FROM public.disputes d
      WHERE d.id = ANY(v_dispute_ids) AND d.status <> 'awaiting_refund_credit'
    ) THEN
      RAISE EXCEPTION 'Not every grouped refund dispute reached awaiting_refund_credit.';
    END IF;

    v_authority_result := jsonb_build_object(
      'ok', true,
      'action', 'final_refund_outcome_accepted',
      'target_status', 'awaiting_refund_credit',
      'dispute_ids', to_jsonb(v_dispute_ids),
      'settlement_credit_created', false,
      'dispute_lines_resolved', false,
      'next_action', 'operator_submit_refund_document_evidence'
    );

    INSERT INTO public.physical_receipt_outcome_lane_decision_items(
      lane_decision_id, physical_remedy_allocation_id, dispute_id,
      decision_type, authority_result
    )
    SELECT v_decision_id, li.physical_remedy_allocation_id, li.dispute_id,
           v_decision_type, v_authority_result
    FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id = p_lane_id
      AND li.physical_remedy_allocation_id IN (
        SELECT (item->>'physical_remedy_allocation_id')::uuid
        FROM jsonb_array_elements(p_item_decisions) item
      );

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'physical_remedy_allocation_id', li.physical_remedy_allocation_id,
      'dispute_id', li.dispute_id,
      'decision', v_decision_type,
      'target_status', 'awaiting_refund_credit',
      'settlement_credit_created', false
    ) ORDER BY li.physical_remedy_allocation_id), '[]'::jsonb)
    INTO v_results
    FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id = p_lane_id
      AND li.physical_remedy_allocation_id IN (
        SELECT (item->>'physical_remedy_allocation_id')::uuid
        FROM jsonb_array_elements(p_item_decisions) item
      );
  END IF;

  SELECT COUNT(*) INTO v_total_count
  FROM public.physical_receipt_outcome_lane_items li
  WHERE li.lane_id = p_lane_id;

  IF v_lane.outcome_type = 'replacement' THEN
    SELECT COUNT(*) INTO v_completed_count
    FROM public.physical_receipt_outcome_lane_items li
    WHERE li.lane_id = p_lane_id
      AND EXISTS (
        SELECT 1 FROM public.physical_replacement_same_order_routes r
        WHERE r.physical_remedy_allocation_id = li.physical_remedy_allocation_id
          AND r.route_status <> 'cancelled'
      );
    v_lane_status := CASE
      WHEN v_completed_count = v_total_count AND v_total_count > 0 THEN 'resolved'
      ELSE 'partially_resolved'
    END;
  ELSE
    SELECT COUNT(*) INTO v_completed_count
    FROM public.physical_receipt_outcome_lane_items li
    JOIN public.disputes d ON d.id = li.dispute_id
    WHERE li.lane_id = p_lane_id
      AND d.status IN ('awaiting_refund_credit', 'refunded', 'closed');
    v_lane_status := 'partially_resolved';
  END IF;

  UPDATE public.physical_receipt_outcome_lanes
  SET lane_status = v_lane_status, updated_at = now()
  WHERE id = p_lane_id;

  v_existing_result := jsonb_build_object(
    'ok', true,
    'lane_decision_id', v_decision_id,
    'lane_id', p_lane_id,
    'outcome_type', v_lane.outcome_type,
    'decision_type', v_decision_type,
    'selected_items', v_count,
    'resolved_items', v_completed_count,
    'lane_item_count', v_total_count,
    'lane_status', v_lane_status,
    'settlement_credit_created', CASE WHEN v_lane.outcome_type = 'refund' THEN false ELSE NULL END,
    'next_action', CASE WHEN v_lane.outcome_type = 'refund' THEN 'operator_submit_refund_document_evidence' ELSE NULL END,
    'items', v_results
  );

  UPDATE public.physical_receipt_outcome_lane_decisions
  SET result_json = v_existing_result
  WHERE id = v_decision_id;

  RETURN v_existing_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)
TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.staff_close_physical_refund_lane_as_settlement_credit_v1(uuid,uuid,uuid[],text,text);
DROP FUNCTION IF EXISTS public.staff_decide_physical_outcome_lane_legacy_20260804(uuid,uuid,jsonb,text);

-- Replay-safe fixture restoration for the exact erroneous grouped settlement.
DO $fixture$
DECLARE
  v_transition_id uuid := gen_random_uuid();
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.importer_credit_ledger
    WHERE id = '59cabd99-d55b-423d-8685-c42a1975beab'::uuid
  ) THEN
    IF EXISTS (
      SELECT 1 FROM public.dispute_refund_evidence_submissions
      WHERE dispute_id IN (
        '677410ab-fa94-48c1-ba23-5a1b9ca8ebad'::uuid,
        'c4cecfc3-1e1d-4709-9307-6f01e3b4b98a'::uuid
      )
    ) THEN
      RAISE EXCEPTION 'Fixture repair aborted: refund evidence now exists.';
    END IF;

    INSERT INTO public.status_transitions(
      id, entity_type, from_status, to_status,
      actor_roles_allowed, required_conditions_json, active
    ) VALUES (
      v_transition_id, 'dispute', 'closed', 'raised', ARRAY['system']::text[],
      '{"fixture_repair":"grouped_refund_settlement_bypass_20260804"}'::jsonb, true
    );

    DELETE FROM public.physical_receipt_outcome_lane_decision_items
    WHERE lane_decision_id = '5ea89040-c2c1-4309-b49a-4c4f5ad0ed79'::uuid;

    DELETE FROM public.physical_receipt_outcome_lane_decisions
    WHERE id = '5ea89040-c2c1-4309-b49a-4c4f5ad0ed79'::uuid;

    DELETE FROM public.dispute_messages
    WHERE id IN (
      '09341ed1-c115-4632-9c2a-2151cb220798'::uuid,
      '3d357a5b-d3d7-48ee-a32b-c31bd831d074'::uuid
    );

    DELETE FROM public.importer_credit_ledger
    WHERE id = '59cabd99-d55b-423d-8685-c42a1975beab'::uuid;

    UPDATE public.disputes
    SET status = 'raised', resolved_at = NULL, reviewed_at = NULL,
        reviewed_by_staff_id = NULL, refund_settlement_mode = NULL
    WHERE id IN (
      '677410ab-fa94-48c1-ba23-5a1b9ca8ebad'::uuid,
      'c4cecfc3-1e1d-4709-9307-6f01e3b4b98a'::uuid
    );

    UPDATE public.dispute_lines
    SET line_status = 'affected',
        conversation_status = 'retailer_response_received',
        resolution_method = NULL,
        resolved_at = NULL
    WHERE id IN (
      '74a42e45-4719-4931-8c3a-45e0ed00fc34'::uuid,
      'bb95351a-99e7-49d2-a35e-a71bfc664860'::uuid
    );

    UPDATE public.physical_receipt_outcome_lanes
    SET lane_status = 'awaiting_supervisor_decision', updated_at = now()
    WHERE id = 'd2bc507e-f050-4701-ab8e-4147723f00c4'::uuid;

    DELETE FROM public.status_transitions WHERE id = v_transition_id;
  END IF;
END;
$fixture$;

NOTIFY pgrst, 'reload schema';
COMMIT;
