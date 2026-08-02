-- Governed by HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md.
BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regclass('public.dispute_return_tracking_submissions') IS NULL
     OR to_regclass('public.shipper_return_task_confirmations') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL
  THEN
    RAISE EXCEPTION 'Replacement return adapter prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.operator_submit_return_collection_tracking(uuid,uuid,text,date,text,boolean,text,text,text,text)') IS NULL
     OR to_regprocedure('public.shipper_return_tasks_v1()') IS NULL
     OR to_regprocedure('public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)') IS NULL
     OR to_regprocedure('public.staff_review_return_collection_tracking(uuid,text,text)') IS NULL
     OR to_regprocedure('public.staff_review_shipper_return_task_confirmation_v1(uuid,text,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Existing return-action authorities are missing.';
  END IF;

  IF to_regprocedure('public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text)') IS NOT NULL
     OR to_regprocedure('public.shipper_return_tasks_v2()') IS NOT NULL
     OR to_regprocedure('public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text)') IS NOT NULL
  THEN
    RAISE EXCEPTION 'One or more replacement return adapter functions already exist; inspect before replacing.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_return_task_confirmations confirmation
    WHERE confirmation.review_status = 'pending_review'
    GROUP BY confirmation.return_tracking_submission_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Existing duplicate pending shipper confirmations prevent the governed uniqueness invariant.';
  END IF;
END
$preflight$;

CREATE UNIQUE INDEX uq_shipper_return_task_one_pending_v1
  ON public.shipper_return_task_confirmations(return_tracking_submission_id)
  WHERE review_status = 'pending_review';

COMMENT ON INDEX public.uq_shipper_return_task_one_pending_v1 IS
'At most one shipper return confirmation may await supervisor review for one return-tracking submission.';

CREATE FUNCTION public.operator_submit_replacement_return_collection_tracking_v1(
  p_dispute_id uuid,
  p_courier_id uuid DEFAULT NULL,
  p_tracking_ref text DEFAULT NULL,
  p_tracking_date date DEFAULT NULL,
  p_tracking_evidence_url text DEFAULT NULL,
  p_is_final_return_yn boolean DEFAULT false,
  p_retailer_return_instructions_file_url text DEFAULT NULL,
  p_return_label_file_url text DEFAULT NULL,
  p_return_proof_file_url text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_operator_id uuid;
  v_importer_id uuid;
  v_dispute public.disputes%ROWTYPE;
  v_active_count integer := 0;
  v_eligible_count integer := 0;
  v_submission_id uuid;
  v_tracking_ref text := NULLIF(BTRIM(COALESCE(p_tracking_ref, '')), '');
  v_tracking_evidence_url text := NULLIF(BTRIM(COALESCE(p_tracking_evidence_url, '')), '');
  v_instructions_url text := NULLIF(BTRIM(COALESCE(p_retailer_return_instructions_file_url, '')), '');
  v_label_url text := NULLIF(BTRIM(COALESCE(p_return_label_file_url, '')), '');
  v_proof_url text := NULLIF(BTRIM(COALESCE(p_return_proof_file_url, '')), '');
  v_note text := NULLIF(BTRIM(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: replacement return instructions require auth.uid().';
  END IF;

  SELECT operator_row.id
  INTO v_operator_id
  FROM public.operators operator_row
  WHERE operator_row.auth_user_id = auth.uid()
    AND COALESCE(operator_row.active, true) = true
  ORDER BY operator_row.id
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found.';
  END IF;

  SELECT dispute_row.*
  INTO v_dispute
  FROM public.disputes dispute_row
  WHERE dispute_row.id = p_dispute_id
  FOR UPDATE;

  IF v_dispute.id IS NULL THEN
    RAISE EXCEPTION 'Dispute not found.';
  END IF;

  IF v_dispute.desired_outcome IS DISTINCT FROM 'replacement' THEN
    RAISE EXCEPTION 'Replacement return instructions belong to replacement exceptions only.';
  END IF;

  IF v_dispute.replacement_child_order_id IS NOT NULL OR v_dispute.resolved_at IS NOT NULL THEN
    RAISE EXCEPTION 'New replacement return instructions must be recorded before replacement-child creation.';
  END IF;

  SELECT order_row.importer_id
  INTO v_importer_id
  FROM public.orders order_row
  WHERE order_row.id = v_dispute.order_id;

  IF v_importer_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.operator_importers access_row
    WHERE access_row.operator_id = v_operator_id
      AND access_row.importer_id = v_importer_id
      AND access_row.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised to update this dispute.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.dispute_messages message_row
    WHERE message_row.dispute_id = v_dispute.id
      AND message_row.message_type = 'retailer_reply'
      AND message_row.counterparty = 'retailer'
  ) THEN
    RAISE EXCEPTION 'At least one retailer reply is required before replacement return instructions are recorded.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines line_row
    WHERE line_row.dispute_id = v_dispute.id
      AND line_row.resolved_at IS NULL
      AND line_row.conversation_status IS DISTINCT FROM 'retailer_response_received'
  ) THEN
    RAISE EXCEPTION 'Every active replacement line must have an accepted retailer response first.';
  END IF;

  SELECT
    COUNT(*)::integer,
    COUNT(*) FILTER (
      WHERE line_row.physical_remedy_allocation_id IS NOT NULL
        AND line_row.intended_remedy = 'replacement'
        AND remedy_row.approved_remedy_type = 'replacement'
        AND remedy_row.dispute_line_id = line_row.id
        AND disposition.disposition_type IN ('damaged','wrong')
    )::integer
  INTO v_active_count, v_eligible_count
  FROM public.dispute_lines line_row
  LEFT JOIN public.physical_exception_remedy_allocations remedy_row
    ON remedy_row.id = line_row.physical_remedy_allocation_id
  LEFT JOIN public.shipper_package_receipt_line_dispositions disposition
    ON disposition.id = remedy_row.receipt_line_disposition_id
  WHERE line_row.dispute_id = v_dispute.id
    AND line_row.resolved_at IS NULL;

  IF v_active_count <> 1 OR v_eligible_count <> 1 THEN
    RAISE EXCEPTION 'Replacement return instructions require exactly one active damaged/wrong physical remedy-linked line.';
  END IF;

  IF v_instructions_url IS NULL
     AND v_label_url IS NULL
     AND v_tracking_ref IS NULL
     AND v_tracking_evidence_url IS NULL
     AND v_note IS NULL
  THEN
    RAISE EXCEPTION 'Add retailer instructions, a return label, a tracking reference, a tracking URL, or a meaningful note.';
  END IF;

  IF p_is_final_return_yn
     AND (p_courier_id IS NULL OR v_tracking_ref IS NULL OR p_tracking_date IS NULL)
  THEN
    RAISE EXCEPTION 'Final return/collection requires courier, tracking reference and tracking date.';
  END IF;

  IF p_courier_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.couriers courier_row WHERE courier_row.id = p_courier_id)
  THEN
    RAISE EXCEPTION 'Courier not found.';
  END IF;

  INSERT INTO public.dispute_return_tracking_submissions (
    dispute_id,
    courier_id,
    tracking_ref,
    tracking_date,
    tracking_evidence_url,
    retailer_return_instructions_file_url,
    return_label_file_url,
    return_proof_file_url,
    submitted_by_operator_id,
    is_final_return_yn,
    note,
    review_status
  ) VALUES (
    v_dispute.id,
    p_courier_id,
    v_tracking_ref,
    p_tracking_date,
    v_tracking_evidence_url,
    v_instructions_url,
    v_label_url,
    v_proof_url,
    v_operator_id,
    COALESCE(p_is_final_return_yn, false),
    v_note,
    'pending_review'
  )
  RETURNING id INTO v_submission_id;

  RETURN jsonb_build_object(
    'ok', true,
    'return_tracking_submission_id', v_submission_id,
    'dispute_id', v_dispute.id,
    'review_status', 'pending_review'
  );
END;
$function$;

CREATE FUNCTION public.shipper_return_tasks_v2()
RETURNS TABLE (
  return_tracking_submission_id uuid,
  dispute_id uuid,
  order_id uuid,
  order_ref text,
  importer_name text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  tracking_date date,
  tracking_evidence_url text,
  retailer_return_instructions_file_url text,
  return_label_file_url text,
  operator_return_proof_file_url text,
  operator_note text,
  is_final_return_yn boolean,
  operator_review_status text,
  submitted_at timestamptz,
  affected_lines jsonb,
  latest_confirmation_id uuid,
  latest_shipper_outcome text,
  latest_shipper_proof_url text,
  latest_shipper_note text,
  latest_shipper_submitted_at timestamptz,
  latest_shipper_review_status text,
  latest_shipper_review_notes text,
  task_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper return tasks require auth.uid().';
  END IF;

  SELECT shipper_user.shipper_id
  INTO v_shipper_id
  FROM public.shipper_users shipper_user
  WHERE shipper_user.auth_user_id = auth.uid()
    AND shipper_user.active = true
  ORDER BY shipper_user.id DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT * FROM public.shipper_return_tasks_v1()
  UNION ALL
  WITH latest_confirmation AS (
    SELECT DISTINCT ON (confirmation.return_tracking_submission_id)
      confirmation.*
    FROM public.shipper_return_task_confirmations confirmation
    ORDER BY confirmation.return_tracking_submission_id,
             confirmation.submitted_at DESC,
             confirmation.id DESC
  ), lines AS (
    SELECT
      line_row.dispute_id,
      jsonb_agg(jsonb_build_object(
        'supplier_invoice_line_id', line_row.supplier_invoice_line_id,
        'description', supplier_line.description,
        'qty', COALESCE(line_row.qty_impact, supplier_line.qty),
        'amount_gbp', COALESCE(line_row.amount_impact_gbp, supplier_line.amount_inc_vat_gbp),
        'intended_remedy', line_row.intended_remedy,
        'line_status', line_row.line_status
      ) ORDER BY supplier_line.line_order NULLS LAST, supplier_line.description)
        FILTER (WHERE line_row.supplier_invoice_line_id IS NOT NULL) AS affected_lines
    FROM public.dispute_lines line_row
    LEFT JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = line_row.supplier_invoice_line_id
    GROUP BY line_row.dispute_id
  )
  SELECT
    return_row.id,
    dispute_row.id,
    order_row.id,
    order_row.order_ref::text,
    COALESCE(NULLIF(importer_row.trading_name, ''), importer_row.company_name, 'Importer')::text,
    retailer_row.name::text,
    courier_row.name::text,
    return_row.tracking_ref::text,
    return_row.tracking_date,
    return_row.tracking_evidence_url::text,
    return_row.retailer_return_instructions_file_url::text,
    return_row.return_label_file_url::text,
    return_row.return_proof_file_url::text,
    return_row.note::text,
    return_row.is_final_return_yn,
    return_row.review_status::text,
    return_row.submitted_at,
    COALESCE(lines.affected_lines, '[]'::jsonb),
    latest.id,
    latest.outcome::text,
    COALESCE(latest.proof_file_url, latest.proof_url)::text,
    latest.note::text,
    latest.submitted_at,
    latest.review_status::text,
    latest.review_notes::text,
    CASE
      WHEN latest.id IS NULL THEN 'ready_to_action'
      WHEN latest.review_status = 'pending_review' THEN 'submitted_for_review'
      WHEN latest.review_status = 'accepted' THEN 'accepted'
      WHEN latest.review_status = 'hold' THEN 'held_query'
      WHEN latest.review_status = 'rejected' THEN 'ready_to_action'
      ELSE 'ready_to_action'
    END::text
  FROM public.dispute_return_tracking_submissions return_row
  JOIN public.disputes dispute_row ON dispute_row.id = return_row.dispute_id
  JOIN public.orders order_row ON order_row.id = dispute_row.order_id
  LEFT JOIN public.importers importer_row ON importer_row.id = order_row.importer_id
  LEFT JOIN public.retailers retailer_row ON retailer_row.id = order_row.retailer_id
  LEFT JOIN public.couriers courier_row ON courier_row.id = return_row.courier_id
  LEFT JOIN latest_confirmation latest ON latest.return_tracking_submission_id = return_row.id
  LEFT JOIN lines ON lines.dispute_id = dispute_row.id
  WHERE order_row.shipper_id = v_shipper_id
    AND dispute_row.desired_outcome = 'replacement'
    AND (
      NULLIF(return_row.retailer_return_instructions_file_url, '') IS NOT NULL
      OR NULLIF(return_row.return_label_file_url, '') IS NOT NULL
      OR NULLIF(return_row.tracking_ref, '') IS NOT NULL
      OR NULLIF(return_row.tracking_evidence_url, '') IS NOT NULL
      OR NULLIF(return_row.note, '') IS NOT NULL
    )
    AND EXISTS (
      SELECT 1
      FROM public.dispute_lines source_line
      JOIN public.physical_exception_remedy_allocations remedy_row
        ON remedy_row.id = source_line.physical_remedy_allocation_id
       AND remedy_row.dispute_line_id = source_line.id
       AND remedy_row.approved_remedy_type = 'replacement'
      JOIN public.shipper_package_receipt_line_dispositions disposition
        ON disposition.id = remedy_row.receipt_line_disposition_id
       AND disposition.disposition_type IN ('damaged','wrong')
      WHERE source_line.dispute_id = dispute_row.id
        AND source_line.intended_remedy = 'replacement'
        AND (
          (
            dispute_row.replacement_child_order_id IS NULL
            AND dispute_row.resolved_at IS NULL
            AND source_line.resolved_at IS NULL
          )
          OR
          (
            dispute_row.replacement_child_order_id IS NOT NULL
            AND remedy_row.replacement_child_order_id = dispute_row.replacement_child_order_id
            AND source_line.resolved_via_child_order_id = dispute_row.replacement_child_order_id
          )
        )
    );
END;
$function$;

CREATE FUNCTION public.shipper_submit_return_task_confirmation_v2(
  p_return_tracking_submission_id uuid,
  p_outcome text,
  p_proof_file_url text DEFAULT NULL,
  p_proof_url text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_dispute_id uuid;
  v_order_id uuid;
  v_desired_outcome text;
  v_confirmation_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper return confirmation requires auth.uid().';
  END IF;

  SELECT return_row.dispute_id
  INTO v_dispute_id
  FROM public.dispute_return_tracking_submissions return_row
  WHERE return_row.id = p_return_tracking_submission_id
  FOR UPDATE;

  IF v_dispute_id IS NULL THEN
    RAISE EXCEPTION 'Return task not found.';
  END IF;

  SELECT dispute_row.desired_outcome
  INTO v_desired_outcome
  FROM public.disputes dispute_row
  WHERE dispute_row.id = v_dispute_id;

  IF v_desired_outcome = 'refund' THEN
    RETURN public.shipper_submit_return_task_confirmation_v1(
      p_return_tracking_submission_id,
      p_outcome,
      p_proof_file_url,
      p_proof_url,
      p_note
    );
  END IF;

  IF v_desired_outcome IS DISTINCT FROM 'replacement' THEN
    RAISE EXCEPTION 'Return task does not belong to a supported refund or replacement exception.';
  END IF;

  IF p_outcome NOT IN ('collected','handed_to_courier','returned_to_retailer','unable_to_return','query') THEN
    RAISE EXCEPTION 'Invalid shipper return outcome: %', p_outcome;
  END IF;

  SELECT shipper_user.id, shipper_user.shipper_id
  INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users shipper_user
  WHERE shipper_user.auth_user_id = auth.uid()
    AND shipper_user.active = true
  ORDER BY shipper_user.id DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT order_row.id
  INTO v_order_id
  FROM public.disputes dispute_row
  JOIN public.orders order_row ON order_row.id = dispute_row.order_id
  WHERE dispute_row.id = v_dispute_id
    AND order_row.shipper_id = v_shipper_id
    AND EXISTS (
      SELECT 1
      FROM public.dispute_lines source_line
      JOIN public.physical_exception_remedy_allocations remedy_row
        ON remedy_row.id = source_line.physical_remedy_allocation_id
       AND remedy_row.dispute_line_id = source_line.id
       AND remedy_row.approved_remedy_type = 'replacement'
      JOIN public.shipper_package_receipt_line_dispositions disposition
        ON disposition.id = remedy_row.receipt_line_disposition_id
       AND disposition.disposition_type IN ('damaged','wrong')
      WHERE source_line.dispute_id = dispute_row.id
        AND source_line.intended_remedy = 'replacement'
        AND (
          (
            dispute_row.replacement_child_order_id IS NULL
            AND dispute_row.resolved_at IS NULL
            AND source_line.resolved_at IS NULL
          )
          OR
          (
            dispute_row.replacement_child_order_id IS NOT NULL
            AND remedy_row.replacement_child_order_id = dispute_row.replacement_child_order_id
            AND source_line.resolved_via_child_order_id = dispute_row.replacement_child_order_id
          )
        )
    )
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Replacement return task not found for this shipper account.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_return_task_confirmations confirmation
    WHERE confirmation.return_tracking_submission_id = p_return_tracking_submission_id
      AND confirmation.review_status = 'pending_review'
  ) THEN
    RAISE EXCEPTION 'A shipper return confirmation is already awaiting supervisor review for this task.';
  END IF;

  INSERT INTO public.shipper_return_task_confirmations (
    return_tracking_submission_id,
    dispute_id,
    order_id,
    shipper_id,
    submitted_by_shipper_user_id,
    outcome,
    proof_file_url,
    proof_url,
    note
  ) VALUES (
    p_return_tracking_submission_id,
    v_dispute_id,
    v_order_id,
    v_shipper_id,
    v_shipper_user_id,
    p_outcome,
    NULLIF(BTRIM(COALESCE(p_proof_file_url, '')), ''),
    NULLIF(BTRIM(COALESCE(p_proof_url, '')), ''),
    NULLIF(BTRIM(COALESCE(p_note, '')), '')
  )
  RETURNING id INTO v_confirmation_id;

  RETURN jsonb_build_object(
    'ok', true,
    'confirmation_id', v_confirmation_id,
    'return_tracking_submission_id', p_return_tracking_submission_id,
    'review_status', 'pending_review'
  );
END;
$function$;

COMMENT ON FUNCTION public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text) IS
'Operator-scoped structured original-item return instructions for exact damaged/wrong physical replacement exceptions. Uses the existing return-action record family.';
COMMENT ON FUNCTION public.shipper_return_tasks_v2() IS
'Backward-compatible return-action reader: exact existing refund rows plus physical damaged/wrong replacement original-item return actions, including post-child tasks.';
COMMENT ON FUNCTION public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text) IS
'Backward-compatible shipper confirmation authority. Delegates refunds to v1 and confirms exact damaged/wrong replacement return actions through the existing confirmation table.';

REVOKE ALL ON FUNCTION public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.shipper_return_tasks_v2() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.shipper_return_tasks_v2() TO authenticated;
GRANT EXECUTE ON FUNCTION public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text) TO authenticated;

COMMENT ON TABLE public.dispute_return_tracking_submissions IS
'Structured return/collection instructions and evidence for refund exceptions and exact damaged/wrong physical replacement original-item returns. It does not post accounting or settlement.';

DO $postflight$
BEGIN
  IF has_function_privilege('anon', 'public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.shipper_return_tasks_v2()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'anon unexpectedly gained replacement return adapter execution.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_shipper_return_task_one_pending_v1'
      AND indexdef LIKE '%WHERE (review_status = ''pending_review''::text)%'
  ) THEN
    RAISE EXCEPTION 'Pending confirmation uniqueness invariant was not installed as expected.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
