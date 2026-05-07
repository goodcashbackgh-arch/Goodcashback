-- =============================================================================
-- refund_document_workbench_v1a_staff_actions.sql
-- Multi Tenant Platform Build — staff actions for refund document control
--
-- Run after refund_document_workbench_v1.sql.
-- Adds SECURITY DEFINER RPCs used by the staff refund document control page.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines. Run refund_document_workbench_v1.sql first.';
  END IF;

  IF to_regclass('public.dispute_refund_document_accounting_adjustment_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_accounting_adjustment_lines. Run refund_document_workbench_v1.sql first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_release_refund_document_lines_to_supplier_control(
  p_refund_evidence_submission_id uuid,
  p_line_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_release_count int;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can release refund document lines.';
  END IF;

  IF p_line_ids IS NULL OR array_length(p_line_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one refund document line to release.';
  END IF;

  UPDATE public.dispute_refund_document_lines l
  SET progressed_to_supplier_control_yn = true,
      updated_at = now()
  WHERE l.refund_evidence_submission_id = p_refund_evidence_submission_id
    AND l.id = ANY(p_line_ids);

  GET DIAGNOSTICS v_release_count = ROW_COUNT;

  IF v_release_count = 0 THEN
    RAISE EXCEPTION 'No matching refund document lines were released.';
  END IF;

  UPDATE public.dispute_refund_evidence_submissions s
  SET supplier_control_status = 'released_to_supplier_control',
      supplier_control_released_by_staff_id = v_staff_id,
      supplier_control_released_at = now(),
      supplier_control_release_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
      supplier_approval_status = CASE WHEN s.supplier_approval_status = 'blocked' THEN 'pending' ELSE s.supplier_approval_status END
  WHERE s.id = p_refund_evidence_submission_id;

  RETURN jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', p_refund_evidence_submission_id,
    'released_line_count', v_release_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_create_refund_document_accounting_adjustment_line(
  p_refund_evidence_submission_id uuid,
  p_description text,
  p_sku varchar,
  p_size varchar,
  p_sage_ledger_account_id varchar,
  p_nominal_code varchar,
  p_tax_rate_id varchar,
  p_tax_rate_label varchar,
  p_vat_rate_percent numeric,
  p_net_amount_gbp numeric,
  p_vat_amount_gbp numeric
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_adjustment_id uuid;
  v_net numeric(12,2);
  v_vat numeric(12,2);
  v_gross numeric(12,2);
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can add refund document adjustment lines.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.dispute_refund_evidence_submissions s WHERE s.id = p_refund_evidence_submission_id) THEN
    RAISE EXCEPTION 'Refund evidence submission not found.';
  END IF;

  IF NULLIF(btrim(COALESCE(p_description, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Adjustment description is required.';
  END IF;

  v_net := COALESCE(p_net_amount_gbp, 0)::numeric(12,2);
  v_vat := COALESCE(p_vat_amount_gbp, 0)::numeric(12,2);
  v_gross := round((v_net + v_vat)::numeric, 2);

  INSERT INTO public.dispute_refund_document_accounting_adjustment_lines (
    refund_evidence_submission_id,
    description,
    sku,
    size,
    sage_ledger_account_id,
    nominal_code,
    tax_rate_id,
    tax_rate_label,
    vat_rate_percent,
    net_amount_gbp,
    vat_amount_gbp,
    gross_amount_gbp,
    created_by_staff_id,
    updated_at
  ) VALUES (
    p_refund_evidence_submission_id,
    btrim(p_description),
    NULLIF(btrim(COALESCE(p_sku, '')), ''),
    NULLIF(btrim(COALESCE(p_size, '')), ''),
    NULLIF(btrim(COALESCE(p_sage_ledger_account_id, '')), ''),
    NULLIF(btrim(COALESCE(p_nominal_code, '')), ''),
    NULLIF(btrim(COALESCE(p_tax_rate_id, '')), ''),
    NULLIF(btrim(COALESCE(p_tax_rate_label, '')), ''),
    COALESCE(p_vat_rate_percent, 20.0000),
    v_net,
    v_vat,
    v_gross,
    v_staff_id,
    now()
  )
  RETURNING id INTO v_adjustment_id;

  RETURN v_adjustment_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_delete_refund_document_accounting_adjustment_line(
  p_adjustment_line_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can delete refund document adjustment lines.';
  END IF;

  DELETE FROM public.dispute_refund_document_accounting_adjustment_lines
  WHERE id = p_adjustment_line_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.staff_release_refund_document_lines_to_supplier_control(uuid, uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_create_refund_document_accounting_adjustment_line(uuid, text, varchar, varchar, varchar, varchar, varchar, varchar, numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_delete_refund_document_accounting_adjustment_line(uuid) TO authenticated;

COMMIT;
