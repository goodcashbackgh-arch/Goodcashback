BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regclass('public.physical_receipt_review_dispute_links') IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'dispute_lines'
         AND column_name = 'physical_remedy_allocation_id'
     )
  THEN
    RAISE EXCEPTION 'Physical dispute compatibility migration must be installed first.';
  END IF;

  IF to_regprocedure('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'staff_decide_physical_receipt_review_v1 already exists; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.staff_decide_physical_receipt_review_v1(
  p_review_id uuid,
  p_decision text,
  p_allocations jsonb DEFAULT '[]'::jsonb,
  p_liable_party text DEFAULT 'unknown',
  p_decision_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_staff record;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_note text := NULLIF(BTRIM(COALESCE(p_decision_note, '')), '');
  v_decision text := lower(BTRIM(COALESCE(p_decision, '')));
  v_input_count integer := 0;
  v_proposed_count integer := 0;
  v_distinct_input_count integer := 0;
  v_bad_count integer := 0;
  v_refund_dispute_id uuid;
  v_replacement_dispute_id uuid;
  v_primary_dispute_id uuid;
  v_operator_id uuid;
  v_sop_version text;
  v_issue_type text;
  v_now timestamptz := clock_timestamp();
  v_item record;
  v_dispute_id uuid;
  v_dispute_line_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: supervisor physical receipt decision requires auth.uid().';
  END IF;

  SELECT s.id, s.role_type
  INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only active admin or supervisor staff can decide a physical receipt review.';
  END IF;

  IF v_decision NOT IN (
    'return_for_information',
    'reject',
    'close_no_action',
    'approve_investigation',
    'approve_existing_exception'
  ) THEN
    RAISE EXCEPTION 'Unsupported physical receipt decision: %', p_decision;
  END IF;

  IF v_note IS NULL THEN
    RAISE EXCEPTION 'A factual supervisor decision note is required.';
  END IF;

  IF p_liable_party NOT IN ('retailer','shipper','unknown','no_liability') THEN
    RAISE EXCEPTION 'Invalid approved liable party: %', p_liable_party;
  END IF;

  IF jsonb_typeof(COALESCE(p_allocations, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Supervisor allocation payload must be a JSON array.';
  END IF;

  SELECT review_row.*
  INTO v_review
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = p_review_id
  FOR UPDATE;

  IF v_review.id IS NULL THEN
    RAISE EXCEPTION 'Physical receipt review not found: %', p_review_id;
  END IF;

  IF v_review.status <> 'awaiting_supervisor_review' THEN
    RAISE EXCEPTION 'Physical receipt review is not awaiting supervisor review. Current status: %', v_review.status;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_review.order_id::text));

  PERFORM 1
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.physical_receipt_review_id = v_review.id
  FOR UPDATE;

  SELECT COUNT(*)::integer
  INTO v_proposed_count
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.physical_receipt_review_id = v_review.id
    AND remedy_row.status = 'proposed';

  IF v_proposed_count = 0 THEN
    RAISE EXCEPTION 'No active importer proposal rows are available for supervisor decision.';
  END IF;

  IF v_decision = 'return_for_information' THEN
    IF jsonb_array_length(COALESCE(p_allocations, '[]'::jsonb)) <> 0 THEN
      RAISE EXCEPTION 'Return-for-information must not approve remedy allocations.';
    END IF;

    UPDATE public.physical_receipt_reviews
    SET status = 'returned_for_information',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = NULL,
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'returned_for_information'
    );
  END IF;

  IF v_decision = 'reject' THEN
    IF jsonb_array_length(COALESCE(p_allocations, '[]'::jsonb)) <> 0 THEN
      RAISE EXCEPTION 'Rejected review must not approve remedy allocations.';
    END IF;

    UPDATE public.physical_exception_remedy_allocations
    SET status = 'cancelled',
        updated_at = v_now
    WHERE physical_receipt_review_id = v_review.id
      AND status = 'proposed';

    UPDATE public.physical_receipt_reviews
    SET status = 'rejected',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = NULL,
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'rejected'
    );
  END IF;

  WITH payload AS (
    SELECT *
    FROM jsonb_to_recordset(COALESCE(p_allocations, '[]'::jsonb)) AS x(
      remedy_allocation_id uuid,
      approved_remedy_type text,
      approved_remedy_qty numeric,
      supplier_cost_mode text
    )
  )
  SELECT COUNT(*)::integer,
         COUNT(DISTINCT remedy_allocation_id)::integer
  INTO v_input_count, v_distinct_input_count
  FROM payload;

  IF v_input_count = 0 THEN
    RAISE EXCEPTION 'This supervisor decision requires at least one exact allocation decision.';
  END IF;

  IF v_input_count <> v_distinct_input_count THEN
    RAISE EXCEPTION 'Each importer proposal row may appear only once. Return for a revised importer split proposal rather than inventing duplicate proposal history.';
  END IF;

  IF v_input_count <> v_proposed_count THEN
    RAISE EXCEPTION 'Every active importer proposal row must be explicitly decided. Return for information if a different split is required.';
  END IF;

  WITH payload AS (
    SELECT *
    FROM jsonb_to_recordset(COALESCE(p_allocations, '[]'::jsonb)) AS x(
      remedy_allocation_id uuid,
      approved_remedy_type text,
      approved_remedy_qty numeric,
      supplier_cost_mode text
    )
  )
  SELECT COUNT(*)::integer
  INTO v_bad_count
  FROM payload p
  LEFT JOIN public.physical_exception_remedy_allocations remedy_row
    ON remedy_row.id = p.remedy_allocation_id
   AND remedy_row.physical_receipt_review_id = v_review.id
   AND remedy_row.status = 'proposed'
  LEFT JOIN public.shipper_package_receipt_line_dispositions disposition
    ON disposition.id = remedy_row.receipt_line_disposition_id
  WHERE remedy_row.id IS NULL
     OR p.approved_remedy_type NOT IN ('refund','replacement','hold_investigate','no_action')
     OR COALESCE(p.approved_remedy_qty, 0) <= 0
     OR p.approved_remedy_qty > remedy_row.proposed_remedy_qty + 0.0005
     OR p.approved_remedy_qty > disposition.quantity + 0.0005
     OR (
       p.approved_remedy_type = 'replacement'
       AND p.supplier_cost_mode NOT IN (
         'free_replacement','charged_repurchase','pending_supplier_evidence'
       )
     )
     OR (
       p.approved_remedy_type <> 'replacement'
       AND COALESCE(p.supplier_cost_mode, 'not_applicable') <> 'not_applicable'
     );

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION 'One or more supervisor allocation decisions are invalid, exceed proposed/source quantity, or have incompatible supplier-cost mode.';
  END IF;

  IF v_decision = 'close_no_action' THEN
    IF p_liable_party <> 'no_liability' THEN
      RAISE EXCEPTION 'Close-no-action requires approved liable party no_liability.';
    END IF;

    WITH payload AS (
      SELECT *
      FROM jsonb_to_recordset(p_allocations) AS x(
        remedy_allocation_id uuid,
        approved_remedy_type text,
        approved_remedy_qty numeric,
        supplier_cost_mode text
      )
    )
    SELECT COUNT(*)::integer INTO v_bad_count
    FROM payload
    WHERE approved_remedy_type <> 'no_action';

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'Close-no-action may approve only no_action allocations.';
    END IF;
  ELSIF v_decision = 'approve_investigation' THEN
    WITH payload AS (
      SELECT *
      FROM jsonb_to_recordset(p_allocations) AS x(
        remedy_allocation_id uuid,
        approved_remedy_type text,
        approved_remedy_qty numeric,
        supplier_cost_mode text
      )
    )
    SELECT COUNT(*)::integer INTO v_bad_count
    FROM payload
    WHERE approved_remedy_type <> 'hold_investigate';

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'Investigation approval may approve only hold_investigate allocations.';
    END IF;
  ELSE
    WITH payload AS (
      SELECT *
      FROM jsonb_to_recordset(p_allocations) AS x(
        remedy_allocation_id uuid,
        approved_remedy_type text,
        approved_remedy_qty numeric,
        supplier_cost_mode text
      )
    )
    SELECT COUNT(*)::integer INTO v_bad_count
    FROM payload
    WHERE approved_remedy_type NOT IN ('refund','replacement')
       OR ABS(approved_remedy_qty - ROUND(approved_remedy_qty)) > 0.0005;

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'Existing refund/replacement routes accept whole-unit quantities only. Fractional quantities are not rounded.';
    END IF;

    IF p_liable_party = 'no_liability' THEN
      RAISE EXCEPTION 'Refund/replacement approval cannot use no_liability.';
    END IF;
  END IF;

  WITH payload AS (
    SELECT *
    FROM jsonb_to_recordset(p_allocations) AS x(
      remedy_allocation_id uuid,
      approved_remedy_type text,
      approved_remedy_qty numeric,
      supplier_cost_mode text
    )
  )
  UPDATE public.physical_exception_remedy_allocations remedy_row
  SET approved_remedy_type = payload.approved_remedy_type,
      approved_remedy_qty = ROUND(payload.approved_remedy_qty, 3),
      approved_by_staff_id = v_staff.id,
      approved_at = v_now,
      supplier_cost_mode = CASE
        WHEN payload.approved_remedy_type = 'replacement'
          THEN payload.supplier_cost_mode
        ELSE 'not_applicable'
      END,
      status = CASE
        WHEN payload.approved_remedy_type = 'no_action'
          THEN 'closed_no_action'
        ELSE 'approved'
      END,
      updated_at = v_now
  FROM payload
  WHERE remedy_row.id = payload.remedy_allocation_id;

  IF v_decision = 'close_no_action' THEN
    UPDATE public.physical_receipt_reviews
    SET status = 'closed_no_action',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = 'no_liability',
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'closed_no_action'
    );
  END IF;

  IF v_decision = 'approve_investigation' THEN
    UPDATE public.physical_exception_remedy_allocations
    SET status = 'in_progress',
        updated_at = v_now
    WHERE physical_receipt_review_id = v_review.id
      AND status = 'approved'
      AND approved_remedy_type = 'hold_investigate';

    UPDATE public.physical_receipt_reviews
    SET status = 'approved_for_investigation',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = p_liable_party,
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'approved_for_investigation'
    );
  END IF;

  SELECT o.operator_id, o.sop_version
  INTO v_operator_id, v_sop_version
  FROM public.orders o
  WHERE o.id = v_review.order_id;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Order operator could not be resolved for physical exception linkage.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines existing_line
    WHERE existing_line.supplier_invoice_line_id IN (
      SELECT remedy_row.supplier_invoice_line_id
      FROM public.physical_exception_remedy_allocations remedy_row
      WHERE remedy_row.physical_receipt_review_id = v_review.id
        AND remedy_row.status = 'approved'
        AND remedy_row.approved_remedy_type IN ('refund','replacement')
    )
      AND existing_line.resolved_at IS NULL
      AND existing_line.physical_remedy_allocation_id IS NULL
  ) THEN
    RAISE EXCEPTION 'An ambiguous unresolved legacy exception already exists for an approved physical source line.';
  END IF;

  FOR v_item IN
    SELECT
      remedy_row.id AS remedy_allocation_id,
      remedy_row.approved_remedy_type,
      remedy_row.approved_remedy_qty,
      remedy_row.supplier_invoice_line_id,
      disposition.disposition_type
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN public.shipper_package_receipt_line_dispositions disposition
      ON disposition.id = remedy_row.receipt_line_disposition_id
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
    ORDER BY
      CASE remedy_row.approved_remedy_type WHEN 'refund' THEN 1 ELSE 2 END,
      remedy_row.id
  LOOP
    v_issue_type := CASE v_item.disposition_type
      WHEN 'missing' THEN 'missing'
      WHEN 'damaged' THEN 'damaged'
      WHEN 'wrong' THEN 'wrong_item'
      ELSE NULL
    END;

    IF v_issue_type IS NULL THEN
      RAISE EXCEPTION 'Disposition % cannot enter the existing refund/replacement route automatically.', v_item.disposition_type;
    END IF;

    IF v_item.approved_remedy_type = 'refund' THEN
      v_dispute_id := v_refund_dispute_id;
    ELSE
      v_dispute_id := v_replacement_dispute_id;
    END IF;

    IF v_dispute_id IS NULL THEN
      INSERT INTO public.disputes (
        order_id,
        raised_by_operator_id,
        issue_type,
        desired_outcome,
        liable_party,
        stage_detected,
        amount_impact_gbp,
        comments_initial,
        status,
        sop_version,
        refund_approved_by_staff_id,
        refund_approved_at
      ) VALUES (
        v_review.order_id,
        v_operator_id,
        v_issue_type,
        v_item.approved_remedy_type,
        p_liable_party,
        'at_ghana_delivery',
        0,
        'Created from physical receipt review ' || v_review.id::text || '. Initial route approval only; retailer outcome and financial value are not yet proven.',
        'raised',
        v_sop_version,
        CASE WHEN v_item.approved_remedy_type = 'refund' THEN v_staff.id ELSE NULL END,
        CASE WHEN v_item.approved_remedy_type = 'refund' THEN v_now ELSE NULL END
      )
      RETURNING id INTO v_dispute_id;

      INSERT INTO public.physical_receipt_review_dispute_links (
        physical_receipt_review_id,
        dispute_id,
        desired_outcome,
        created_by_staff_id,
        created_at
      ) VALUES (
        v_review.id,
        v_dispute_id,
        v_item.approved_remedy_type,
        v_staff.id,
        v_now
      );

      IF v_item.approved_remedy_type = 'refund' THEN
        v_refund_dispute_id := v_dispute_id;
      ELSE
        v_replacement_dispute_id := v_dispute_id;
      END IF;
    END IF;

    INSERT INTO public.dispute_lines (
      dispute_id,
      supplier_invoice_line_id,
      qty_impact,
      amount_impact_gbp,
      line_status,
      intended_remedy,
      conversation_status,
      physical_remedy_allocation_id
    ) VALUES (
      v_dispute_id,
      v_item.supplier_invoice_line_id,
      ROUND(v_item.approved_remedy_qty)::integer,
      0,
      'affected',
      v_item.approved_remedy_type,
      CASE
        WHEN v_item.approved_remedy_type = 'refund'
          THEN 'refund_pending_approval'
        ELSE 'remedy_selected'
      END,
      v_item.remedy_allocation_id
    )
    RETURNING id INTO v_dispute_line_id;

    UPDATE public.physical_exception_remedy_allocations
    SET dispute_line_id = v_dispute_line_id,
        status = 'linked_to_exception',
        updated_at = v_now
    WHERE id = v_item.remedy_allocation_id;
  END LOOP;

  SELECT link_row.dispute_id
  INTO v_primary_dispute_id
  FROM public.physical_receipt_review_dispute_links link_row
  WHERE link_row.physical_receipt_review_id = v_review.id
  ORDER BY
    CASE link_row.desired_outcome WHEN 'refund' THEN 1 ELSE 2 END,
    link_row.dispute_id
  LIMIT 1;

  IF v_primary_dispute_id IS NULL THEN
    RAISE EXCEPTION 'No outcome-specific dispute was linked for the approved physical review.';
  END IF;

  UPDATE public.physical_receipt_reviews
  SET status = 'approved_to_existing_exception',
      supervisor_decided_by_staff_id = v_staff.id,
      supervisor_decided_at = v_now,
      approved_liable_party = p_liable_party,
      decision_note = v_note,
      linked_dispute_id = v_primary_dispute_id,
      updated_at = v_now
  WHERE id = v_review.id;

  RETURN jsonb_build_object(
    'ok', true,
    'review_id', v_review.id,
    'status', 'approved_to_existing_exception',
    'primary_dispute_id', v_primary_dispute_id,
    'refund_dispute_id', v_refund_dispute_id,
    'replacement_dispute_id', v_replacement_dispute_id
  );
END;
$function$;

REVOKE ALL
ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
TO authenticated;

COMMENT ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text) IS
'Initial supervisor physical-receipt route authority. Preserves exact physical provenance, fails closed on fractional legacy routes, and creates separate outcome-specific existing disputes without recording retailer or financial completion.';

NOTIFY pgrst, 'reload schema';

COMMIT;
