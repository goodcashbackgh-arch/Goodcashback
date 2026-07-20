BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sage_posting_snapshots';
  END IF;
  IF to_regclass('public.dispute_messages') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_messages';
  END IF;
END $$;

-- One authoritative alignment test is reused by every downstream transition
-- guard. It reads the stored row, so the existing operator progress RPC cannot
-- manufacture readiness in the same UPDATE that attempts to progress it.
CREATE OR REPLACE FUNCTION public.refund_credit_note_submission_is_aligned_v1(
  p_refund_evidence_submission_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_submission public.dispute_refund_evidence_submissions%ROWTYPE;
  v_expected_retailer_name text;
  v_line_count integer;
  v_line_total numeric(12,2);
  v_ref_match boolean;
  v_date_match boolean;
  v_amount_match boolean;
  v_retailer_match boolean := true;
  v_line_match boolean;
BEGIN
  SELECT s.*
    INTO v_submission
  FROM public.dispute_refund_evidence_submissions s
  WHERE s.id = p_refund_evidence_submission_id;

  IF v_submission.id IS NULL THEN
    RETURN false;
  END IF;

  IF v_submission.document_mode IS DISTINCT FROM 'credit_note' THEN
    RETURN true;
  END IF;

  IF coalesce(v_submission.ocr_status, '') <> 'completed'
     OR coalesce(v_submission.match_status, '') <> 'matched_ready_to_release'
     OR coalesce(v_submission.amount_balance_status, '') <> 'balanced'
     OR nullif(btrim(coalesce(v_submission.credit_note_ref, '')), '') IS NULL
     OR v_submission.credit_note_date IS NULL
     OR coalesce(v_submission.expected_credit_note_total_gbp, 0) <= 0
     OR nullif(btrim(coalesce(v_submission.ocr_credit_note_ref, '')), '') IS NULL
     OR nullif(btrim(coalesce(v_submission.ocr_retailer_name, '')), '') IS NULL
     OR v_submission.ocr_credit_note_date IS NULL
     OR coalesce(v_submission.ocr_credit_note_total_gbp, 0) <= 0
  THEN
    RETURN false;
  END IF;

  SELECT nullif(btrim(coalesce(r.name::text, '')), '')
    INTO v_expected_retailer_name
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  WHERE d.id = v_submission.dispute_id;

  v_ref_match := lower(regexp_replace(v_submission.credit_note_ref, '[^a-zA-Z0-9]+', '', 'g'))
    = lower(regexp_replace(v_submission.ocr_credit_note_ref, '[^a-zA-Z0-9]+', '', 'g'));
  v_date_match := v_submission.credit_note_date = v_submission.ocr_credit_note_date;
  v_amount_match := abs(
    coalesce(v_submission.expected_credit_note_total_gbp, 0)
    - coalesce(v_submission.ocr_credit_note_total_gbp, 0)
  ) <= 0.01;

  IF v_expected_retailer_name IS NOT NULL THEN
    v_retailer_match :=
      lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
        = lower(regexp_replace(v_submission.ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
      OR lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
        LIKE '%' || lower(regexp_replace(v_submission.ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) || '%'
      OR lower(regexp_replace(v_submission.ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
        LIKE '%' || lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) || '%';
  END IF;

  SELECT count(*)::integer,
         round(coalesce(sum(abs(coalesce(l.amount_gbp, 0))), 0)::numeric, 2)
    INTO v_line_count, v_line_total
  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission.id;

  v_line_match := coalesce(v_line_count, 0) > 0
    AND abs(coalesce(v_line_total, 0) - v_submission.ocr_credit_note_total_gbp) <= 0.01;

  RETURN v_ref_match
    AND v_date_match
    AND v_amount_match
    AND v_retailer_match
    AND v_line_match;
END;
$$;

REVOKE ALL ON FUNCTION public.refund_credit_note_submission_is_aligned_v1(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.staff_correct_refund_credit_note_header_v1(
  p_refund_evidence_submission_id uuid,
  p_credit_note_ref text,
  p_credit_note_date date,
  p_expected_credit_note_total_gbp numeric,
  p_ocr_credit_note_ref text,
  p_ocr_retailer_name text,
  p_ocr_credit_note_date date,
  p_ocr_credit_note_total_gbp numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_submission public.dispute_refund_evidence_submissions%ROWTYPE;
  v_expected_retailer_name text;
  v_credit_note_ref text;
  v_ocr_credit_note_ref text;
  v_ocr_retailer_name text;
  v_reason text;
  v_expected_amount numeric(12,2);
  v_ocr_total numeric(12,2);
  v_variance numeric(12,2);
  v_line_count integer;
  v_line_total numeric(12,2);
  v_ref_match boolean;
  v_date_match boolean;
  v_amount_match boolean;
  v_retailer_match boolean := true;
  v_line_match boolean;
  v_match_status text;
  v_amount_balance_status text;
  v_before jsonb;
  v_after jsonb;
  v_changed_fields text[] := ARRAY[]::text[];
  v_message_id uuid;
BEGIN
  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin', 'supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can correct credit-note header values.';
  END IF;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'A correction reason is required.';
  END IF;

  SELECT s.*
    INTO v_submission
  FROM public.dispute_refund_evidence_submissions s
  WHERE s.id = p_refund_evidence_submission_id
  FOR UPDATE;

  IF v_submission.id IS NULL THEN
    RAISE EXCEPTION 'Refund evidence submission not found.';
  END IF;

  IF v_submission.document_mode IS DISTINCT FROM 'credit_note' THEN
    RAISE EXCEPTION 'Header correction is only available for formal credit-note submissions.';
  END IF;

  IF coalesce(v_submission.ocr_status, '') <> 'completed' THEN
    RAISE EXCEPTION 'Credit-note OCR must be completed before header correction.';
  END IF;

  IF coalesce(v_submission.supplier_control_status, 'not_released') IN ('released_to_supplier_control', 'approved_current')
     OR coalesce(v_submission.supplier_approval_status, 'pending') = 'approved_current' THEN
    RAISE EXCEPTION 'Credit-note header values are locked after release or approval.';
  END IF;

  IF coalesce(v_submission.supervisor_review_status, '') = 'rejected'
     OR coalesce(v_submission.evidence_control_status, '') = 'staff_rejected_resubmission_required'
     OR coalesce(v_submission.supplier_readiness_route, '') = 'operator_resubmission_required' THEN
    RAISE EXCEPTION 'This rejected submission is audit-only and cannot be corrected in place.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_refund_document_lines l
    WHERE l.refund_evidence_submission_id = v_submission.id
      AND coalesce(l.progressed_to_supplier_control_yn, false) = true
  ) THEN
    RAISE EXCEPTION 'Credit-note header values are locked after any line is released.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot
    WHERE snapshot.source_table = 'dispute_refund_evidence_submissions'
      AND snapshot.source_id = v_submission.id
  ) THEN
    RAISE EXCEPTION 'Credit-note header values are locked after a Sage snapshot has been created.';
  END IF;

  v_credit_note_ref := nullif(btrim(coalesce(p_credit_note_ref, '')), '');
  v_ocr_credit_note_ref := nullif(btrim(coalesce(p_ocr_credit_note_ref, '')), '');
  v_ocr_retailer_name := nullif(btrim(coalesce(p_ocr_retailer_name, '')), '');
  v_expected_amount := round(coalesce(p_expected_credit_note_total_gbp, 0)::numeric, 2);
  v_ocr_total := round(coalesce(p_ocr_credit_note_total_gbp, 0)::numeric, 2);

  IF v_credit_note_ref IS NULL THEN RAISE EXCEPTION 'Submitted credit-note reference is required.'; END IF;
  IF p_credit_note_date IS NULL THEN RAISE EXCEPTION 'Submitted credit-note date is required.'; END IF;
  IF v_expected_amount <= 0 THEN RAISE EXCEPTION 'Expected credit-note total must be above zero.'; END IF;
  IF v_ocr_credit_note_ref IS NULL THEN RAISE EXCEPTION 'OCR credit-note reference is required.'; END IF;
  IF v_ocr_retailer_name IS NULL THEN RAISE EXCEPTION 'OCR retailer name is required.'; END IF;
  IF p_ocr_credit_note_date IS NULL THEN RAISE EXCEPTION 'OCR credit-note date is required.'; END IF;
  IF v_ocr_total <= 0 THEN RAISE EXCEPTION 'OCR credit-note total must be above zero.'; END IF;

  SELECT nullif(btrim(coalesce(r.name::text, '')), '')
    INTO v_expected_retailer_name
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  WHERE d.id = v_submission.dispute_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispute or order context was not found for the credit-note submission.';
  END IF;

  v_variance := round(abs(v_expected_amount - v_ocr_total)::numeric, 2);
  v_ref_match := lower(regexp_replace(v_credit_note_ref, '[^a-zA-Z0-9]+', '', 'g'))
    = lower(regexp_replace(v_ocr_credit_note_ref, '[^a-zA-Z0-9]+', '', 'g'));
  v_date_match := p_credit_note_date = p_ocr_credit_note_date;
  v_amount_match := v_variance <= 0.01;

  IF v_expected_retailer_name IS NOT NULL THEN
    v_retailer_match :=
      lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
        = lower(regexp_replace(v_ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
      OR lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
        LIKE '%' || lower(regexp_replace(v_ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) || '%'
      OR lower(regexp_replace(v_ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
        LIKE '%' || lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) || '%';
  END IF;

  SELECT count(*)::integer,
         round(coalesce(sum(abs(coalesce(l.amount_gbp, 0))), 0)::numeric, 2)
    INTO v_line_count, v_line_total
  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission.id;

  v_line_match := coalesce(v_line_count, 0) > 0
    AND abs(coalesce(v_line_total, 0) - v_ocr_total) <= 0.01;
  v_amount_balance_status := CASE WHEN v_amount_match THEN 'balanced' ELSE 'variance' END;
  v_match_status := CASE
    WHEN v_ref_match AND v_date_match AND v_amount_match AND v_retailer_match AND v_line_match
      THEN 'matched_ready_to_release'
    ELSE 'needs_supervisor_review'
  END;

  v_before := jsonb_build_object(
    'credit_note_ref', v_submission.credit_note_ref,
    'credit_note_date', v_submission.credit_note_date,
    'expected_credit_note_total_gbp', v_submission.expected_credit_note_total_gbp,
    'ocr_credit_note_ref', v_submission.ocr_credit_note_ref,
    'ocr_retailer_name', v_submission.ocr_retailer_name,
    'ocr_credit_note_date', v_submission.ocr_credit_note_date,
    'ocr_credit_note_total_gbp', v_submission.ocr_credit_note_total_gbp,
    'match_status', v_submission.match_status,
    'amount_balance_status', v_submission.amount_balance_status
  );

  IF v_submission.credit_note_ref IS DISTINCT FROM v_credit_note_ref THEN v_changed_fields := array_append(v_changed_fields, 'credit_note_ref'); END IF;
  IF v_submission.credit_note_date IS DISTINCT FROM p_credit_note_date THEN v_changed_fields := array_append(v_changed_fields, 'credit_note_date'); END IF;
  IF v_submission.expected_credit_note_total_gbp IS DISTINCT FROM v_expected_amount THEN v_changed_fields := array_append(v_changed_fields, 'expected_credit_note_total_gbp'); END IF;
  IF v_submission.ocr_credit_note_ref IS DISTINCT FROM v_ocr_credit_note_ref THEN v_changed_fields := array_append(v_changed_fields, 'ocr_credit_note_ref'); END IF;
  IF v_submission.ocr_retailer_name IS DISTINCT FROM v_ocr_retailer_name THEN v_changed_fields := array_append(v_changed_fields, 'ocr_retailer_name'); END IF;
  IF v_submission.ocr_credit_note_date IS DISTINCT FROM p_ocr_credit_note_date THEN v_changed_fields := array_append(v_changed_fields, 'ocr_credit_note_date'); END IF;
  IF v_submission.ocr_credit_note_total_gbp IS DISTINCT FROM v_ocr_total THEN v_changed_fields := array_append(v_changed_fields, 'ocr_credit_note_total_gbp'); END IF;

  IF coalesce(array_length(v_changed_fields, 1), 0) = 0 THEN
    RAISE EXCEPTION 'No credit-note header values were changed.';
  END IF;

  UPDATE public.dispute_refund_evidence_submissions s
  SET credit_note_ref = v_credit_note_ref,
      credit_note_date = p_credit_note_date,
      expected_credit_note_total_gbp = v_expected_amount,
      ocr_credit_note_ref = v_ocr_credit_note_ref,
      ocr_retailer_name = v_ocr_retailer_name,
      ocr_credit_note_date = p_ocr_credit_note_date,
      ocr_credit_note_total_gbp = v_ocr_total,
      captured_refund_amount_abs_gbp = v_ocr_total,
      variance_abs_gbp = v_variance,
      amount_balance_status = v_amount_balance_status,
      match_status = v_match_status,
      evidence_control_status = CASE WHEN v_match_status = 'matched_ready_to_release' THEN 'credit_note_ocr_matched_ready' ELSE 'credit_note_ocr_review_required' END,
      supplier_readiness_route = CASE WHEN v_match_status = 'matched_ready_to_release' THEN 'supplier_credit_note_ready_to_release' ELSE 'supplier_credit_note_review_required' END,
      supplier_control_status = CASE WHEN v_match_status = 'matched_ready_to_release' THEN 'not_released' ELSE 'blocked' END,
      supplier_approval_status = CASE WHEN v_match_status = 'matched_ready_to_release' THEN 'pending' ELSE 'blocked' END,
      supervisor_review_status = CASE WHEN v_match_status = 'matched_ready_to_release' THEN 'not_required' ELSE 'pending_review' END
  WHERE s.id = v_submission.id;

  v_after := jsonb_build_object(
    'credit_note_ref', v_credit_note_ref,
    'credit_note_date', p_credit_note_date,
    'expected_credit_note_total_gbp', v_expected_amount,
    'ocr_credit_note_ref', v_ocr_credit_note_ref,
    'ocr_retailer_name', v_ocr_retailer_name,
    'ocr_credit_note_date', p_ocr_credit_note_date,
    'ocr_credit_note_total_gbp', v_ocr_total,
    'match_status', v_match_status,
    'amount_balance_status', v_amount_balance_status,
    'ref_match', v_ref_match,
    'date_match', v_date_match,
    'retailer_match', v_retailer_match,
    'amount_match', v_amount_match,
    'line_total_match', v_line_match,
    'line_count', v_line_count,
    'line_total_gbp', v_line_total
  );

  INSERT INTO public.dispute_messages (
    dispute_id, message_type, counterparty, generated_by, body
  ) VALUES (
    v_submission.dispute_id,
    'supervisor_note',
    'internal',
    'manual',
    array_to_string(ARRAY[
      '[SUPERVISOR_CREDIT_NOTE_HEADER_CORRECTION_V1]',
      'staff_id: ' || v_staff_id::text,
      'refund_evidence_submission_id: ' || v_submission.id::text,
      'changed_fields: ' || array_to_string(v_changed_fields, ', '),
      'resulting_match_status: ' || v_match_status,
      'reason: ' || v_reason,
      '',
      'before: ' || v_before::text,
      'after: ' || v_after::text
    ], E'\n')
  ) RETURNING id INTO v_message_id;

  RETURN jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', v_submission.id,
    'changed_fields', to_jsonb(v_changed_fields),
    'match_status', v_match_status,
    'amount_balance_status', v_amount_balance_status,
    'supplier_control_status', CASE WHEN v_match_status = 'matched_ready_to_release' THEN 'not_released' ELSE 'blocked' END,
    'supplier_approval_status', CASE WHEN v_match_status = 'matched_ready_to_release' THEN 'pending' ELSE 'blocked' END,
    'audit_message_id', v_message_id
  );
END;
$$;

COMMENT ON FUNCTION public.staff_correct_refund_credit_note_header_v1(uuid, text, date, numeric, text, text, date, numeric, text) IS
'Atomically corrects submitted and OCR credit-note header fields before release, approval or Sage freeze; recalculates alignment and writes an immutable audit message.';

REVOKE ALL ON FUNCTION public.staff_correct_refund_credit_note_header_v1(uuid, text, date, numeric, text, text, date, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_correct_refund_credit_note_header_v1(uuid, text, date, numeric, text, text, date, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_refund_credit_note_alignment_transition_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_requires_alignment boolean := false;
BEGIN
  IF NEW.document_mode IS DISTINCT FROM 'credit_note' THEN
    RETURN NEW;
  END IF;

  v_requires_alignment :=
    (NEW.evidence_control_status = 'operator_confirmed_ready_for_staff_control'
      AND NEW.evidence_control_status IS DISTINCT FROM OLD.evidence_control_status)
    OR (NEW.supplier_control_status IN ('released_to_supplier_control', 'approved_current')
      AND NEW.supplier_control_status IS DISTINCT FROM OLD.supplier_control_status)
    OR (NEW.supplier_approval_status = 'approved_current'
      AND NEW.supplier_approval_status IS DISTINCT FROM OLD.supplier_approval_status);

  IF v_requires_alignment
     AND NOT public.refund_credit_note_submission_is_aligned_v1(OLD.id)
  THEN
    RAISE EXCEPTION 'Credit-note evidence remains under supervisor review. Correct and align the submitted/OCR header before customer progression, release or approval.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispute_refund_evidence_alignment_transition_guard_trg
  ON public.dispute_refund_evidence_submissions;
CREATE TRIGGER dispute_refund_evidence_alignment_transition_guard_trg
BEFORE UPDATE OF evidence_control_status, supplier_control_status, supplier_approval_status
ON public.dispute_refund_evidence_submissions
FOR EACH ROW
EXECUTE FUNCTION public.enforce_refund_credit_note_alignment_transition_v1();

CREATE OR REPLACE FUNCTION public.enforce_refund_credit_note_line_alignment_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_becoming_released boolean;
BEGIN
  v_becoming_released := coalesce(NEW.progressed_to_supplier_control_yn, false)
    AND (TG_OP = 'INSERT' OR NOT coalesce(OLD.progressed_to_supplier_control_yn, false));

  IF v_becoming_released
     AND NOT public.refund_credit_note_submission_is_aligned_v1(NEW.refund_evidence_submission_id)
  THEN
    RAISE EXCEPTION 'Credit-note evidence remains under supervisor review. Lines cannot be released until the submitted and OCR header values are aligned.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispute_refund_document_lines_alignment_guard_trg
  ON public.dispute_refund_document_lines;
CREATE TRIGGER dispute_refund_document_lines_alignment_guard_trg
BEFORE INSERT OR UPDATE OF progressed_to_supplier_control_yn
ON public.dispute_refund_document_lines
FOR EACH ROW
EXECUTE FUNCTION public.enforce_refund_credit_note_line_alignment_guard_v1();

COMMIT;
