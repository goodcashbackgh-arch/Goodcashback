-- =============================================================================
-- refund_document_workbench_v1b_operator_submission.sql
-- Multi Tenant Platform Build — operator refund document submission RPC
--
-- Run after:
--   1. refund_document_workbench_v1.sql
--   2. refund_document_workbench_v1a_staff_actions.sql
--
-- Purpose:
--   Stop using dispute_messages as the primary refund document evidence source.
--   Operator submissions write to dispute_refund_evidence_submissions and, where
--   available, dispute_refund_document_lines for supplier credit/adjustment control.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;

  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines. Run refund_document_workbench_v1.sql first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_submit_refund_document_evidence(
  p_dispute_id uuid,
  p_original_order_id uuid,
  p_original_supplier_invoice_id uuid,
  p_document_mode text,
  p_credit_note_ref text DEFAULT NULL,
  p_credit_note_date date DEFAULT NULL,
  p_expected_credit_note_total_gbp numeric DEFAULT NULL,
  p_credit_note_file_url text DEFAULT NULL,
  p_refund_proof_file_url text DEFAULT NULL,
  p_refund_lines jsonb DEFAULT '[]'::jsonb,
  p_delivery_adjustment_gbp numeric DEFAULT 0,
  p_discount_adjustment_gbp numeric DEFAULT 0,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_importer_id uuid;
  v_desired_outcome text;
  v_status text;
  v_order_id uuid;
  v_expected_exception_amount_abs numeric(12,2);
  v_captured_refund_amount_abs numeric(12,2);
  v_variance_abs numeric(12,2);
  v_amount_balance_status text;
  v_evidence_control_status text;
  v_supplier_readiness_route text;
  v_supplier_approval_status text;
  v_supervisor_review_status text;
  v_ocr_status text;
  v_match_status text;
  v_submission_id uuid;
  v_message_type text;
  v_raw_body text;
  v_line_order int := 0;
  v_line_total numeric(12,2) := 0;
  v_line record;
  v_delivery_abs numeric(12,2) := abs(coalesce(p_delivery_adjustment_gbp, 0))::numeric(12,2);
  v_discount_abs numeric(12,2) := abs(coalesce(p_discount_adjustment_gbp, 0))::numeric(12,2);
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: refund document evidence requires auth.uid()';
  END IF;

  SELECT op.id INTO v_operator_id
  FROM public.operators op
  WHERE op.auth_user_id = v_auth_uid
    AND op.active = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found.';
  END IF;

  IF p_document_mode NOT IN ('credit_note', 'refund_proof_no_credit_note', 'no_document') THEN
    RAISE EXCEPTION 'Invalid refund document mode: %', p_document_mode;
  END IF;

  SELECT o.importer_id, d.desired_outcome, d.status, d.order_id, abs(coalesce(d.amount_impact_gbp, 0))::numeric(12,2)
    INTO v_importer_id, v_desired_outcome, v_status, v_order_id, v_expected_exception_amount_abs
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  WHERE d.id = p_dispute_id
  LIMIT 1;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Dispute not found or parent importer missing.';
  END IF;

  IF v_order_id <> p_original_order_id THEN
    RAISE EXCEPTION 'Original order link does not match this dispute.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised to update this dispute.';
  END IF;

  IF v_desired_outcome <> 'refund' THEN
    RAISE EXCEPTION 'Refund document evidence belongs to refund exceptions only.';
  END IF;

  IF v_status <> 'awaiting_refund_credit' THEN
    RAISE EXCEPTION 'Supervisor must accept the final retailer refund outcome before refund evidence is uploaded. Current status: %', v_status;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.id = p_original_supplier_invoice_id
      AND si.order_id = p_original_order_id
  ) THEN
    RAISE EXCEPTION 'Supplier invoice is not linked to this dispute order.';
  END IF;

  IF p_document_mode = 'credit_note' THEN
    IF NULLIF(btrim(coalesce(p_credit_note_ref, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Credit note reference is required when a credit note exists.';
    END IF;

    IF coalesce(p_expected_credit_note_total_gbp, 0) <= 0 THEN
      RAISE EXCEPTION 'Expected credit note total is required when a credit note exists.';
    END IF;

    IF NULLIF(btrim(coalesce(p_credit_note_file_url, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Credit note file URL is required when a credit note exists.';
    END IF;
  END IF;

  IF p_document_mode = 'refund_proof_no_credit_note'
     AND NULLIF(btrim(coalesce(p_refund_proof_file_url, '')), '') IS NULL
     AND NULLIF(btrim(coalesce(p_notes, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Upload refund proof or add notes when no credit note was issued.';
  END IF;

  IF p_document_mode = 'no_document'
     AND NULLIF(btrim(coalesce(p_notes, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Add notes explaining why no document was issued.';
  END IF;

  IF jsonb_typeof(coalesce(p_refund_lines, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Refund lines payload must be a JSON array.';
  END IF;

  FOR v_line IN
    SELECT *
    FROM jsonb_to_recordset(coalesce(p_refund_lines, '[]'::jsonb)) AS x(
      description text,
      qty numeric,
      amount_gbp numeric
    )
  LOOP
    IF NULLIF(btrim(coalesce(v_line.description, '')), '') IS NULL
       AND coalesce(v_line.qty, 0) = 0
       AND coalesce(v_line.amount_gbp, 0) = 0 THEN
      CONTINUE;
    END IF;

    v_line_total := (v_line_total + abs(coalesce(v_line.amount_gbp, 0)))::numeric(12,2);
  END LOOP;

  IF p_document_mode <> 'credit_note'
     AND v_line_total = 0
     AND v_delivery_abs = 0
     AND v_discount_abs = 0 THEN
    RAISE EXCEPTION 'Confirm at least one prefilled refund line or adjustment.';
  END IF;

  v_captured_refund_amount_abs := CASE
    WHEN p_document_mode = 'credit_note' THEN (abs(coalesce(p_expected_credit_note_total_gbp, 0)) + v_delivery_abs + v_discount_abs)::numeric(12,2)
    ELSE (v_line_total + v_delivery_abs + v_discount_abs)::numeric(12,2)
  END;

  v_variance_abs := abs(coalesce(v_captured_refund_amount_abs, 0) - coalesce(v_expected_exception_amount_abs, 0))::numeric(12,2);
  v_amount_balance_status := CASE WHEN v_variance_abs <= 0.01 THEN 'balanced' ELSE 'variance' END;

  v_message_type := CASE WHEN p_document_mode = 'credit_note' THEN 'credit_note_evidence' ELSE 'refund_evidence' END;

  v_evidence_control_status := CASE
    WHEN p_document_mode = 'credit_note' THEN 'credit_note_uploaded_pending_ocr_compare'
    WHEN p_document_mode = 'no_document' THEN 'no_document_supervisor_review_required'
    WHEN v_amount_balance_status = 'balanced' THEN 'refund_adjustment_ready_no_credit_note'
    ELSE 'variance_supervisor_review_required'
  END;

  v_supplier_readiness_route := CASE
    WHEN p_document_mode = 'credit_note' THEN 'supplier_credit_note_readiness_pending_ocr'
    WHEN v_evidence_control_status = 'refund_adjustment_ready_no_credit_note' THEN 'supplier_refund_adjustment_ready'
    ELSE 'supplier_refund_adjustment_review_required'
  END;

  v_supplier_approval_status := CASE
    WHEN p_document_mode = 'refund_proof_no_credit_note' AND v_amount_balance_status = 'balanced' THEN 'pending'
    ELSE 'blocked'
  END;

  v_supervisor_review_status := CASE
    WHEN p_document_mode = 'no_document' OR v_amount_balance_status = 'variance' THEN 'pending_review'
    ELSE 'not_required'
  END;

  v_ocr_status := CASE WHEN p_document_mode = 'credit_note' THEN 'not_started' ELSE 'not_applicable' END;
  v_match_status := CASE
    WHEN p_document_mode = 'credit_note' THEN 'pending_ocr'
    WHEN p_document_mode = 'refund_proof_no_credit_note' AND v_amount_balance_status = 'balanced' THEN 'matched_ready_to_release'
    ELSE 'needs_supervisor_review'
  END;

  v_raw_body := array_to_string(array[
    '[REFUND_DOCUMENT_EVIDENCE_V1]',
    'uploaded_by: operator',
    'operator_id: ' || v_operator_id::text,
    'document_mode: ' || p_document_mode,
    'original_order_id: ' || p_original_order_id::text,
    'original_supplier_invoice_id: ' || p_original_supplier_invoice_id::text,
    'dispute_id: ' || p_dispute_id::text,
    'credit_note_ref: ' || coalesce(nullif(btrim(coalesce(p_credit_note_ref, '')), ''), '—'),
    'credit_note_date: ' || coalesce(p_credit_note_date::text, '—'),
    'operator_expected_credit_note_total_gbp: ' || coalesce(p_expected_credit_note_total_gbp::text, '0.00'),
    'credit_note_file_url: ' || coalesce(nullif(btrim(coalesce(p_credit_note_file_url, '')), ''), '—'),
    'refund_proof_file_url: ' || coalesce(nullif(btrim(coalesce(p_refund_proof_file_url, '')), ''), '—'),
    'expected_exception_amount_abs_gbp: ' || v_expected_exception_amount_abs::text,
    'captured_refund_amount_abs_gbp: ' || v_captured_refund_amount_abs::text,
    'variance_abs_gbp: ' || v_variance_abs::text,
    'amount_balance_status: ' || v_amount_balance_status,
    'evidence_control_status: ' || v_evidence_control_status,
    'supplier_readiness_route: ' || v_supplier_readiness_route,
    '',
    coalesce(nullif(btrim(coalesce(p_notes, '')), ''), 'No extra notes.')
  ], E'\n');

  INSERT INTO public.dispute_refund_evidence_submissions (
    dispute_id,
    original_order_id,
    original_supplier_invoice_id,
    submitted_by_operator_id,
    document_mode,
    message_type,
    credit_note_ref,
    credit_note_date,
    expected_credit_note_total_gbp,
    credit_note_file_url,
    refund_proof_file_url,
    refund_lines_json,
    delivery_adjustment_gbp,
    discount_adjustment_gbp,
    expected_exception_amount_abs_gbp,
    captured_refund_amount_abs_gbp,
    variance_abs_gbp,
    amount_balance_status,
    evidence_control_status,
    supplier_readiness_route,
    supplier_approval_status,
    supervisor_review_status,
    raw_body,
    notes,
    ocr_status,
    match_status,
    supplier_control_status
  ) VALUES (
    p_dispute_id,
    p_original_order_id,
    p_original_supplier_invoice_id,
    v_operator_id,
    p_document_mode,
    v_message_type,
    NULLIF(btrim(coalesce(p_credit_note_ref, '')), ''),
    p_credit_note_date,
    CASE WHEN p_expected_credit_note_total_gbp IS NULL THEN NULL ELSE abs(p_expected_credit_note_total_gbp)::numeric(12,2) END,
    NULLIF(btrim(coalesce(p_credit_note_file_url, '')), ''),
    NULLIF(btrim(coalesce(p_refund_proof_file_url, '')), ''),
    coalesce(p_refund_lines, '[]'::jsonb),
    (-1 * v_delivery_abs)::numeric(12,2),
    (-1 * v_discount_abs)::numeric(12,2),
    v_expected_exception_amount_abs,
    v_captured_refund_amount_abs,
    v_variance_abs,
    v_amount_balance_status,
    v_evidence_control_status,
    v_supplier_readiness_route,
    v_supplier_approval_status,
    v_supervisor_review_status,
    v_raw_body,
    NULLIF(btrim(coalesce(p_notes, '')), ''),
    v_ocr_status,
    v_match_status,
    'not_released'
  )
  RETURNING id INTO v_submission_id;

  IF p_document_mode <> 'credit_note' THEN
    FOR v_line IN
      SELECT *
      FROM jsonb_to_recordset(coalesce(p_refund_lines, '[]'::jsonb)) AS x(
        description text,
        qty numeric,
        amount_gbp numeric
      )
    LOOP
      IF NULLIF(btrim(coalesce(v_line.description, '')), '') IS NULL
         AND coalesce(v_line.qty, 0) = 0
         AND coalesce(v_line.amount_gbp, 0) = 0 THEN
        CONTINUE;
      END IF;

      v_line_order := v_line_order + 1;
      INSERT INTO public.dispute_refund_document_lines (
        refund_evidence_submission_id,
        line_order,
        line_source,
        description,
        qty,
        amount_gbp
      ) VALUES (
        v_submission_id,
        v_line_order,
        'operator_prefill',
        coalesce(nullif(btrim(coalesce(v_line.description, '')), ''), 'Refund evidence line'),
        abs(coalesce(v_line.qty, 0))::numeric(12,2),
        abs(coalesce(v_line.amount_gbp, 0))::numeric(12,2)
      );
    END LOOP;
  END IF;

  IF v_delivery_abs > 0 THEN
    v_line_order := v_line_order + 1;
    INSERT INTO public.dispute_refund_document_lines (
      refund_evidence_submission_id,
      line_order,
      line_source,
      description,
      qty,
      amount_gbp
    ) VALUES (
      v_submission_id,
      v_line_order,
      'delivery_adjustment',
      'Delivery refund / adjustment',
      1,
      v_delivery_abs
    );
  END IF;

  IF v_discount_abs > 0 THEN
    v_line_order := v_line_order + 1;
    INSERT INTO public.dispute_refund_document_lines (
      refund_evidence_submission_id,
      line_order,
      line_source,
      description,
      qty,
      amount_gbp
    ) VALUES (
      v_submission_id,
      v_line_order,
      'discount_adjustment',
      'Discount refund / adjustment',
      1,
      v_discount_abs
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', v_submission_id,
    'dispute_id', p_dispute_id,
    'document_mode', p_document_mode,
    'supplier_approval_status', v_supplier_approval_status,
    'supplier_control_status', 'not_released',
    'match_status', v_match_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.operator_submit_refund_document_evidence(
  uuid, uuid, uuid, text, text, date, numeric, text, text, jsonb, numeric, numeric, text
) TO authenticated;

COMMIT;
