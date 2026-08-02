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

  IF to_regprocedure('public.shipper_return_tasks_v1()') IS NULL
     OR to_regprocedure('public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Existing refund return-action authorities are missing.';
  END IF;

  IF to_regprocedure('public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text)') IS NOT NULL
     OR to_regprocedure('public.shipper_return_tasks_v2()') IS NOT NULL
     OR to_regprocedure('public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text)') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Replacement return adapters already exist; inspect before replacing.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_return_task_confirmations c
    WHERE c.review_status = 'pending_review'
    GROUP BY c.return_tracking_submission_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate pending shipper confirmations must be resolved before installing the uniqueness invariant.';
  END IF;
END
$preflight$;

CREATE UNIQUE INDEX uq_shipper_return_task_one_pending_v1
  ON public.shipper_return_task_confirmations(return_tracking_submission_id)
  WHERE review_status = 'pending_review';

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
  v_active_count integer;
  v_eligible_count integer;
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

  SELECT op.id
  INTO v_operator_id
  FROM public.operators op
  WHERE op.auth_user_id = auth.uid()
    AND COALESCE(op.active, true) = true
  ORDER BY op.id
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found.';
  END IF;

  SELECT d.*
  INTO v_dispute
  FROM public.disputes d
  WHERE d.id = p_dispute_id
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

  SELECT o.importer_id
  INTO v_importer_id
  FROM public.orders o
  WHERE o.id = v_dispute.order_id;

  IF v_importer_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised to update this dispute.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.dispute_messages dm
    WHERE dm.dispute_id = v_dispute.id
      AND dm.message_type = 'retailer_reply'
      AND dm.counterparty = 'retailer'
  ) THEN
    RAISE EXCEPTION 'At least one retailer reply is required before replacement return instructions are recorded.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    WHERE dl.dispute_id = v_dispute.id
      AND dl.resolved_at IS NULL
      AND dl.conversation_status IS DISTINCT FROM 'retailer_response_received'
  ) THEN
    RAISE EXCEPTION 'Every active replacement line must have an accepted retailer response first.';
  END IF;

  SELECT
    COUNT(*)::integer,
    COUNT(*) FILTER (
      WHERE dl.physical_remedy_allocation_id IS NOT NULL
        AND dl.intended_remedy = 'replacement'
        AND pra.approved_remedy_type = 'replacement'
        AND pra.dispute_line_id = dl.id
        AND disp.disposition_type IN ('damaged','wrong')
    )::integer
  INTO v_active_count, v_eligible_count
  FROM public.dispute_lines dl
  LEFT JOIN public.physical_exception_remedy_allocations pra
    ON pra.id = dl.physical_remedy_allocation_id
  LEFT JOIN public.shipper_package_receipt_line_dispositions disp
    ON disp.id = pra.receipt_line_disposition_id
  WHERE dl.dispute_id = v_dispute.id
    AND dl.resolved_at IS NULL;

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

  IF COALESCE(p_is_final_return_yn, false)
     AND (p_courier_id IS NULL OR v_tracking_ref IS NULL OR p_tracking_date IS NULL)
  THEN
    RAISE EXCEPTION 'Final return/collection requires courier, tracking reference and tracking date.';
  END IF;

  IF p_courier_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.couriers c WHERE c.id = p_courier_id)
  THEN
    RAISE EXCEPTION 'Courier not found.';
  END IF;

  INSERT INTO public.dispute_return_tracking_submissions (
    dispute_id, courier_id, tracking_ref, tracking_date,
    tracking_evidence_url, retailer_return_instructions_file_url,
    return_label_file_url, return_proof_file_url,
    submitted_by_operator_id, is_final_return_yn, note, review_status
  ) VALUES (
    v_dispute.id, p_courier_id, v_tracking_ref, p_tracking_date,
    v_tracking_evidence_url, v_instructions_url,
    v_label_url, v_proof_url,
    v_operator_id, COALESCE(p_is_final_return_yn, false), v_note, 'pending_review'
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

  SELECT su.shipper_id
  INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.id DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  WITH refund_rows AS (
    SELECT * FROM public.shipper_return_tasks_v1()
  ), latest_confirmation AS (
    SELECT DISTINCT ON (c.return_tracking_submission_id) c.*
    FROM public.shipper_return_task_confirmations c
    ORDER BY c.return_tracking_submission_id, c.submitted_at DESC, c.id DESC
  ), lines AS (
    SELECT dl.dispute_id,
      jsonb_agg(jsonb_build_object(
        'supplier_invoice_line_id', dl.supplier_invoice_line_id,
        'description', sil.description,
        'qty', COALESCE(dl.qty_impact, sil.qty),
        'amount_gbp', COALESCE(dl.amount_impact_gbp, sil.amount_inc_vat_gbp),
        'intended_remedy', dl.intended_remedy,
        'line_status', dl.line_status
      ) ORDER BY sil.line_order NULLS LAST, sil.description)
      FILTER (WHERE dl.supplier_invoice_line_id IS NOT NULL) AS affected_lines
    FROM public.dispute_lines dl
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
    GROUP BY dl.dispute_id
  ), replacement_rows AS (
    SELECT
      rt.id AS return_tracking_submission_id,
      d.id AS dispute_id,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Importer')::text AS importer_name,
      r.name::text AS retailer_name,
      c.name::text AS courier_name,
      rt.tracking_ref::text AS tracking_ref,
      rt.tracking_date,
      rt.tracking_evidence_url::text AS tracking_evidence_url,
      rt.retailer_return_instructions_file_url::text AS retailer_return_instructions_file_url,
      rt.return_label_file_url::text AS return_label_file_url,
      rt.return_proof_file_url::text AS operator_return_proof_file_url,
      rt.note::text AS operator_note,
      rt.is_final_return_yn,
      rt.review_status::text AS operator_review_status,
      rt.submitted_at,
      COALESCE(lines.affected_lines, '[]'::jsonb) AS affected_lines,
      lc.id AS latest_confirmation_id,
      lc.outcome::text AS latest_shipper_outcome,
      COALESCE(lc.proof_file_url, lc.proof_url)::text AS latest_shipper_proof_url,
      lc.note::text AS latest_shipper_note,
      lc.submitted_at AS latest_shipper_submitted_at,
      lc.review_status::text AS latest_shipper_review_status,
      lc.review_notes::text AS latest_shipper_review_notes,
      CASE
        WHEN lc.id IS NULL THEN 'ready_to_action'
        WHEN lc.review_status = 'pending_review' THEN 'submitted_for_review'
        WHEN lc.review_status = 'accepted' THEN 'accepted'
        WHEN lc.review_status = 'hold' THEN 'held_query'
        WHEN lc.review_status = 'rejected' THEN 'ready_to_action'
        ELSE 'ready_to_action'
      END::text AS task_status
    FROM public.dispute_return_tracking_submissions rt
    JOIN public.disputes d ON d.id = rt.dispute_id
    JOIN public.orders o ON o.id = d.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    LEFT JOIN public.couriers c ON c.id = rt.courier_id
    LEFT JOIN latest_confirmation lc ON lc.return_tracking_submission_id = rt.id
    LEFT JOIN lines ON lines.dispute_id = d.id
    WHERE o.shipper_id = v_shipper_id
      AND d.desired_outcome = 'replacement'
      AND (
        NULLIF(rt.retailer_return_instructions_file_url, '') IS NOT NULL
        OR NULLIF(rt.return_label_file_url, '') IS NOT NULL
        OR NULLIF(rt.tracking_ref, '') IS NOT NULL
        OR NULLIF(rt.tracking_evidence_url, '') IS NOT NULL
        OR NULLIF(rt.note, '') IS NOT NULL
      )
      AND EXISTS (
        SELECT 1
        FROM public.dispute_lines dl
        JOIN public.physical_exception_remedy_allocations pra
          ON pra.id = dl.physical_remedy_allocation_id
         AND pra.dispute_line_id = dl.id
         AND pra.approved_remedy_type = 'replacement'
        JOIN public.shipper_package_receipt_line_dispositions disp
          ON disp.id = pra.receipt_line_disposition_id
         AND disp.disposition_type IN ('damaged','wrong')
        WHERE dl.dispute_id = d.id
          AND dl.intended_remedy = 'replacement'
          AND (
            (d.replacement_child_order_id IS NULL AND d.resolved_at IS NULL AND dl.resolved_at IS NULL)
            OR
            (d.replacement_child_order_id IS NOT NULL
             AND pra.replacement_child_order_id = d.replacement_child_order_id
             AND dl.resolved_via_child_order_id = d.replacement_child_order_id)
          )
      )
  ), combined AS (
    SELECT * FROM refund_rows
    UNION ALL
    SELECT * FROM replacement_rows
  )
  SELECT *
  FROM combined
  ORDER BY
    CASE task_status
      WHEN 'ready_to_action' THEN 1
      WHEN 'held_query' THEN 2
      WHEN 'submitted_for_review' THEN 3
      WHEN 'accepted' THEN 4
      ELSE 5
    END,
    submitted_at DESC,
    return_tracking_submission_id;
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

  SELECT rt.dispute_id
  INTO v_dispute_id
  FROM public.dispute_return_tracking_submissions rt
  WHERE rt.id = p_return_tracking_submission_id
  FOR UPDATE;

  IF v_dispute_id IS NULL THEN
    RAISE EXCEPTION 'Return task not found.';
  END IF;

  SELECT d.desired_outcome
  INTO v_desired_outcome
  FROM public.disputes d
  WHERE d.id = v_dispute_id;

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

  SELECT su.id, su.shipper_id
  INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.id DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT o.id
  INTO v_order_id
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  WHERE d.id = v_dispute_id
    AND o.shipper_id = v_shipper_id
    AND EXISTS (
      SELECT 1
      FROM public.dispute_lines dl
      JOIN public.physical_exception_remedy_allocations pra
        ON pra.id = dl.physical_remedy_allocation_id
       AND pra.dispute_line_id = dl.id
       AND pra.approved_remedy_type = 'replacement'
      JOIN public.shipper_package_receipt_line_dispositions disp
        ON disp.id = pra.receipt_line_disposition_id
       AND disp.disposition_type IN ('damaged','wrong')
      WHERE dl.dispute_id = d.id
        AND dl.intended_remedy = 'replacement'
        AND (
          (d.replacement_child_order_id IS NULL AND d.resolved_at IS NULL AND dl.resolved_at IS NULL)
          OR
          (d.replacement_child_order_id IS NOT NULL
           AND pra.replacement_child_order_id = d.replacement_child_order_id
           AND dl.resolved_via_child_order_id = d.replacement_child_order_id)
        )
    )
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Replacement return task not found for this shipper account.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_return_task_confirmations c
    WHERE c.return_tracking_submission_id = p_return_tracking_submission_id
      AND c.review_status = 'pending_review'
  ) THEN
    RAISE EXCEPTION 'A shipper return confirmation is already awaiting supervisor review for this task.';
  END IF;

  INSERT INTO public.shipper_return_task_confirmations (
    return_tracking_submission_id, dispute_id, order_id, shipper_id,
    submitted_by_shipper_user_id, outcome, proof_file_url, proof_url, note
  ) VALUES (
    p_return_tracking_submission_id, v_dispute_id, v_order_id, v_shipper_id,
    v_shipper_user_id, p_outcome,
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
'Operator-scoped original-item return instructions for exact damaged/wrong physical replacement exceptions. Uses the existing return-action records.';
COMMENT ON FUNCTION public.shipper_return_tasks_v2() IS
'Backward-compatible return-action reader: existing refund rows plus exact damaged/wrong replacement original-item returns, including post-child tasks.';
COMMENT ON FUNCTION public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text) IS
'Backward-compatible shipper confirmation authority. Delegates refunds to v1 and confirms exact damaged/wrong replacement return actions.';
COMMENT ON TABLE public.dispute_return_tracking_submissions IS
'Structured return/collection instructions and evidence for refund exceptions and exact damaged/wrong physical replacement original-item returns.';

REVOKE ALL ON FUNCTION public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.shipper_return_tasks_v2() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.shipper_return_tasks_v2() TO authenticated;
GRANT EXECUTE ON FUNCTION public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
