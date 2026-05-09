-- Supervisor rejection / resubmission request for refund document control.
--
-- Purpose:
--   Complete the structured refund/credit-note control lane when staff decide
--   the uploaded credit note / refund proof / no-document evidence is wrong or
--   needs resubmission.
--
-- Surgical scope:
--   - adds one SECURITY DEFINER RPC
--   - updates only the selected dispute_refund_evidence_submissions row
--   - writes an audit message to dispute_messages
--   - does not delete evidence, lines, coding, orders, invoices, DVA/card rows,
--     or Sage/VAT readiness data
--   - blocks action if already approved_current

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_request_refund_document_resubmission(
  p_refund_evidence_submission_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_submission public.dispute_refund_evidence_submissions%rowtype;
  v_reason text;
  v_message_id uuid;
BEGIN
  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can request refund document resubmission.';
  END IF;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Resubmission reason is required.';
  END IF;

  SELECT s.*
    INTO v_submission
  FROM public.dispute_refund_evidence_submissions s
  WHERE s.id = p_refund_evidence_submission_id
  FOR UPDATE;

  IF v_submission.id IS NULL THEN
    RAISE EXCEPTION 'Refund evidence submission not found.';
  END IF;

  IF coalesce(v_submission.supplier_approval_status, 'pending') = 'approved_current'
     OR coalesce(v_submission.supplier_control_status, 'not_released') = 'approved_current' THEN
    RAISE EXCEPTION 'Cannot request resubmission after refund document has been approved current.';
  END IF;

  UPDATE public.dispute_refund_evidence_submissions s
     SET match_status = 'needs_operator_review',
         supplier_control_status = 'blocked',
         supplier_approval_status = 'blocked',
         supervisor_review_status = 'rejected',
         supervisor_reviewed_by_staff_id = v_staff_id,
         supervisor_reviewed_at = now(),
         supervisor_review_notes = v_reason,
         evidence_control_status = 'staff_rejected_resubmission_required',
         supplier_readiness_route = 'operator_resubmission_required',
         notes = nullif(btrim(coalesce(s.notes, '') || E'\nSupervisor resubmission request: ' || v_reason), '')
   WHERE s.id = p_refund_evidence_submission_id;

  INSERT INTO public.dispute_messages (
    dispute_id,
    message_type,
    counterparty,
    generated_by,
    body
  ) VALUES (
    v_submission.dispute_id,
    'refund_evidence_review',
    'internal',
    'supervisor_review',
    array_to_string(array[
      '[REFUND_DOCUMENT_STAFF_RESUBMISSION_REQUESTED_V1]',
      'reviewed_by_staff_id: ' || v_staff_id::text,
      'review_decision: rejected',
      'source_evidence_submission_id: ' || p_refund_evidence_submission_id::text,
      'source_evidence_message_id: ' || coalesce(v_submission.source_dispute_message_id::text, '—'),
      'supplier_control_status: blocked',
      'supplier_approval_status: blocked',
      'operator_next_action: resubmit_refund_document_or_correct_evidence',
      '',
      v_reason
    ], E'\n')
  ) RETURNING id INTO v_message_id;

  RETURN jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', p_refund_evidence_submission_id,
    'dispute_id', v_submission.dispute_id,
    'review_message_id', v_message_id,
    'decision', 'resubmission_requested'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.staff_request_refund_document_resubmission(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
