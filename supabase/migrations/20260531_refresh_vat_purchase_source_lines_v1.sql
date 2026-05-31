BEGIN;

-- Adds a focused admin RPC to refresh platform Box 4/7 purchase source lines for one VAT return run.
-- No Sage API call. No journal approval. No journal posting.

CREATE OR REPLACE FUNCTION public.staff_refresh_vat_purchase_source_lines_v1(p_vat_return_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_staff_id uuid;
  v_purchase_lines integer := 0;
  v_credit_lines integer := 0;
  v_box4 numeric(18,2) := 0;
  v_box7 numeric(18,2) := 0;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT purchase refresh action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.status IN ('matched_to_sage_locked', 'sage_return_submitted', 'sage_adjustment_journals_posted') THEN
    RAISE EXCEPTION 'Cannot refresh purchase source lines for VAT run in status %.', v_run.status;
  END IF;

  DELETE FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND line_kind IN (
      'supplier_purchase_invoice_box4_vat',
      'supplier_purchase_invoice_box7_net',
      'supplier_credit_note_box4_decrease',
      'supplier_credit_note_box7_decrease'
    );

  WITH base AS (
    SELECT
      si.id,
      COALESCE(si.ocr_invoice_ref, si.invoice_ref, si.id::text)::text AS ref,
      COALESCE(si.ocr_invoice_date, si.created_at::date)::date AS tax_date,
      si.order_id,
      o.order_ref::text AS order_ref,
      COALESCE(t.total_coded_net_gbp, 0)::numeric(18,2) AS net_gbp,
      COALESCE(t.total_coded_vat_gbp, 0)::numeric(18,2) AS vat_gbp,
      COALESCE(t.total_coded_gross_gbp, 0)::numeric(18,2) AS gross_gbp,
      si.review_status,
      si.is_current_for_order
    FROM public.supplier_invoices si
    JOIN public.orders o ON o.id = si.order_id
    LEFT JOIN public.supplier_invoice_accounting_coding_totals_vw t ON t.supplier_invoice_id = si.id
    WHERE COALESCE(si.ocr_invoice_date, si.created_at::date) BETWEEN v_run.period_start_date AND v_run.period_end_date
      AND (si.review_status IN ('approved_current', 'ref_corrected_approved') OR si.is_current_for_order = true)
      AND COALESCE(si.blocked_from_sage_yn, false) IS DISTINCT FROM true
      AND COALESCE(t.total_coded_gross_gbp, 0) > 0
      AND COALESCE(t.progressed_line_count, 0) > 0
      AND COALESCE(t.coded_line_count, 0) > 0
      AND COALESCE(t.all_progressed_lines_coded_yn, false) = true
      AND COALESCE(t.gross_reconciled_to_invoice_yn, false) = true
      AND COALESCE(t.net_reconciled_to_invoice_yn, true) = true
      AND COALESCE(t.vat_reconciled_to_invoice_yn, true) = true
  ), rows AS (
    SELECT id, ref, tax_date, order_id, order_ref, 7 AS box_number, 'supplier_purchase_invoice_box7_net' AS line_kind, net_gbp AS amount_gbp, 0::numeric AS vat_amount_gbp, 'total_coded_net_gbp' AS basis FROM base WHERE net_gbp <> 0
    UNION ALL
    SELECT id, ref, tax_date, order_id, order_ref, 4 AS box_number, 'supplier_purchase_invoice_box4_vat' AS line_kind, vat_gbp AS amount_gbp, vat_gbp AS vat_amount_gbp, 'total_coded_vat_gbp' AS basis FROM base WHERE vat_gbp <> 0
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
    box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
    natural_sage_covered, adjustment_required, adjustment_reason, status
  )
  SELECT
    p_vat_return_run_id,
    r.line_kind,
    'supplier_invoices',
    r.id,
    'supplier_invoice:' || COALESCE(r.ref, r.id::text),
    to_jsonb(r),
    jsonb_build_object('supplier_invoice_id', r.id, 'supplier_invoice_ref', r.ref, 'order_id', r.order_id, 'order_ref', r.order_ref, 'invoice_date', r.tax_date),
    r.box_number,
    'natural',
    r.amount_gbp,
    r.vat_amount_gbp,
    r.basis,
    r.tax_date,
    v_run.return_period_label,
    false,
    true,
    'purchase_source_needs_sage_natural_comparison',
    'active'
  FROM rows r;

  GET DIAGNOSTICS v_purchase_lines = ROW_COUNT;

  WITH base AS (
    SELECT
      s.id,
      COALESCE(s.credit_note_ref, s.id::text)::text AS ref,
      COALESCE(s.credit_note_date, s.supplier_approved_at::date, s.submitted_at::date)::date AS tax_date,
      s.original_order_id AS order_id,
      o.order_ref::text AS order_ref,
      COALESCE(t.total_coded_net_gbp, 0)::numeric(18,2) AS net_gbp,
      COALESCE(t.total_coded_vat_gbp, 0)::numeric(18,2) AS vat_gbp,
      COALESCE(t.total_coded_gross_gbp, 0)::numeric(18,2) AS gross_gbp
    FROM public.dispute_refund_evidence_submissions s
    LEFT JOIN public.orders o ON o.id = s.original_order_id
    LEFT JOIN public.dispute_refund_document_accounting_totals_vw t ON t.refund_evidence_submission_id = s.id
    WHERE s.document_mode = 'credit_note'
      AND s.supplier_approval_status = 'approved_current'
      AND s.supplier_control_status = 'approved_current'
      AND COALESCE(s.credit_note_date, s.supplier_approved_at::date, s.submitted_at::date)::date BETWEEN v_run.period_start_date AND v_run.period_end_date
      AND COALESCE(t.total_coded_gross_gbp, 0) > 0
  ), rows AS (
    SELECT id, ref, tax_date, order_id, order_ref, 7 AS box_number, 'supplier_credit_note_box7_decrease' AS line_kind, net_gbp AS amount_gbp, 0::numeric AS vat_amount_gbp, 'credit_note_total_coded_net_gbp' AS basis FROM base WHERE net_gbp <> 0
    UNION ALL
    SELECT id, ref, tax_date, order_id, order_ref, 4 AS box_number, 'supplier_credit_note_box4_decrease' AS line_kind, vat_gbp AS amount_gbp, vat_gbp AS vat_amount_gbp, 'credit_note_total_coded_vat_gbp' AS basis FROM base WHERE vat_gbp <> 0
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
    box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
    natural_sage_covered, adjustment_required, adjustment_reason, status
  )
  SELECT
    p_vat_return_run_id,
    r.line_kind,
    'dispute_refund_evidence_submissions',
    r.id,
    'supplier_credit_note:' || COALESCE(r.ref, r.id::text),
    to_jsonb(r),
    jsonb_build_object('refund_evidence_submission_id', r.id, 'credit_note_ref', r.ref, 'order_id', r.order_id, 'order_ref', r.order_ref, 'document_date', r.tax_date),
    r.box_number,
    'decrease',
    r.amount_gbp,
    r.vat_amount_gbp,
    r.basis,
    r.tax_date,
    v_run.return_period_label,
    false,
    true,
    'purchase_credit_note_needs_sage_natural_comparison',
    'active'
  FROM rows r;

  GET DIAGNOSTICS v_credit_lines = ROW_COUNT;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box4
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 4;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box7
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 7;

  UPDATE public.vat_return_runs
  SET expected_box4_gbp = v_box4,
      expected_box5_gbp = COALESCE(expected_box3_gbp, 0) - v_box4,
      expected_box7_gbp = v_box7,
      source_counts_json = COALESCE(source_counts_json, '{}'::jsonb) || jsonb_build_object(
        'supplier_purchase_box_lines', v_purchase_lines,
        'supplier_credit_note_box_lines', v_credit_lines
      ),
      updated_at = now()
  WHERE id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'supplier_purchase_box_lines', v_purchase_lines,
    'supplier_credit_note_box_lines', v_credit_lines,
    'expected_box4_gbp', v_box4,
    'expected_box7_gbp', v_box7
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_refresh_vat_purchase_source_lines_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_purchase_source_lines_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
