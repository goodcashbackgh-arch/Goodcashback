-- =============================================================================
-- refund_document_workbench_v1.sql
-- Multi Tenant Platform Build — refund document / supplier credit control lane
--
-- Purpose:
--   Build the refund-document lane as a supplier credit / adjustment control
--   pipeline without forcing credit notes into supplier_invoices.
--
-- Design principles:
--   - dispute_refund_evidence_submissions remains the refund evidence header.
--   - credit-note OCR / refund-proof / no-document options feed a dedicated
--     refund document line + accounting coding model.
--   - supplier_invoices and supplier_invoice_lines remain normal supplier AP
--     invoice objects only.
--   - supplier-draft-ready may surface these submissions later, but coding and
--     current approval must use this dedicated net/VAT/gross control model.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;

  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: disputes';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: staff';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Extend existing refund evidence header with OCR / control status fields.
-- -----------------------------------------------------------------------------

ALTER TABLE public.dispute_refund_evidence_submissions
  ADD COLUMN IF NOT EXISTS ocr_status text NOT NULL DEFAULT 'not_applicable',
  ADD COLUMN IF NOT EXISTS ocr_credit_note_ref text NULL,
  ADD COLUMN IF NOT EXISTS ocr_retailer_name text NULL,
  ADD COLUMN IF NOT EXISTS ocr_credit_note_date date NULL,
  ADD COLUMN IF NOT EXISTS ocr_credit_note_total_gbp numeric(12,2) NULL,
  ADD COLUMN IF NOT EXISTS ocr_raw_json jsonb NULL,
  ADD COLUMN IF NOT EXISTS ocr_extracted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS match_status text NOT NULL DEFAULT 'not_applicable',
  ADD COLUMN IF NOT EXISTS supplier_control_status text NOT NULL DEFAULT 'not_released',
  ADD COLUMN IF NOT EXISTS supplier_control_released_by_operator_id uuid NULL REFERENCES public.operators(id),
  ADD COLUMN IF NOT EXISTS supplier_control_released_by_staff_id uuid NULL REFERENCES public.staff(id),
  ADD COLUMN IF NOT EXISTS supplier_control_released_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS supplier_control_release_notes text NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dispute_refund_evidence_submissions_ocr_status_check'
      AND conrelid = 'public.dispute_refund_evidence_submissions'::regclass
  ) THEN
    ALTER TABLE public.dispute_refund_evidence_submissions
      ADD CONSTRAINT dispute_refund_evidence_submissions_ocr_status_check
      CHECK (ocr_status IN ('not_applicable','not_started','queued','processing','completed','failed','cancelled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dispute_refund_evidence_submissions_match_status_check'
      AND conrelid = 'public.dispute_refund_evidence_submissions'::regclass
  ) THEN
    ALTER TABLE public.dispute_refund_evidence_submissions
      ADD CONSTRAINT dispute_refund_evidence_submissions_match_status_check
      CHECK (match_status IN ('not_applicable','pending_ocr','matched_ready_to_release','needs_operator_review','needs_supervisor_review'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dispute_refund_evidence_submissions_supplier_control_status_check'
      AND conrelid = 'public.dispute_refund_evidence_submissions'::regclass
  ) THEN
    ALTER TABLE public.dispute_refund_evidence_submissions
      ADD CONSTRAINT dispute_refund_evidence_submissions_supplier_control_status_check
      CHECK (supplier_control_status IN ('not_released','released_to_supplier_control','blocked','approved_current'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_dispute_refund_evidence_submissions_control
  ON public.dispute_refund_evidence_submissions (supplier_control_status, supplier_approval_status, document_mode);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_evidence_submissions_dispute_control
  ON public.dispute_refund_evidence_submissions (dispute_id, supplier_control_status);

-- -----------------------------------------------------------------------------
-- 2) Refund document lines.
--    Amounts are stored as absolute credit/refund values. The Sage adapter later
--    decides credit-note sign/treatment from document_mode, not from negative rows.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.dispute_refund_document_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_evidence_submission_id uuid NOT NULL REFERENCES public.dispute_refund_evidence_submissions(id) ON DELETE CASCADE,
  dispute_line_id uuid NULL REFERENCES public.dispute_lines(id),
  line_order integer NOT NULL,
  line_source text NOT NULL,
  description text NOT NULL,
  qty numeric(12,2) NULL,
  amount_gbp numeric(12,2) NOT NULL,
  progressed_to_supplier_control_yn boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dispute_refund_document_lines_amount_nonnegative_check CHECK (amount_gbp >= 0),
  CONSTRAINT dispute_refund_document_lines_source_check CHECK (line_source IN ('operator_prefill','ocr_extracted','manual_staff','delivery_adjustment','discount_adjustment','rounding_adjustment'))
);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_document_lines_submission
  ON public.dispute_refund_document_lines (refund_evidence_submission_id, line_order);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_document_lines_progressed
  ON public.dispute_refund_document_lines (refund_evidence_submission_id, progressed_to_supplier_control_yn);

-- -----------------------------------------------------------------------------
-- 3) Refund document line coding. Mirrors supplier invoice line coding, but is
--    kept separate because this is supplier credit/refund evidence, not AP invoice.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.dispute_refund_document_line_accounting_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_document_line_id uuid NOT NULL REFERENCES public.dispute_refund_document_lines(id) ON DELETE CASCADE,
  description_override text NULL,
  sku_override varchar NULL,
  size_override varchar NULL,
  sage_ledger_account_id varchar NULL,
  nominal_code varchar NULL,
  tax_rate_id varchar NULL,
  tax_rate_label varchar NULL,
  vat_rate_percent numeric(7,4) NOT NULL DEFAULT 20.0000,
  net_amount_gbp numeric(12,2) NOT NULL,
  vat_amount_gbp numeric(12,2) NOT NULL,
  gross_amount_gbp numeric(12,2) NOT NULL,
  coded_by_staff_id uuid NULL REFERENCES public.staff(id),
  coded_at timestamptz NOT NULL DEFAULT now(),
  admin_review_required_yn boolean NOT NULL DEFAULT false,
  review_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dispute_refund_document_line_codes_one_per_line UNIQUE (refund_document_line_id),
  CONSTRAINT dispute_refund_document_line_codes_amounts_nonnegative CHECK (
    net_amount_gbp >= 0 AND vat_amount_gbp >= 0 AND gross_amount_gbp >= 0 AND vat_rate_percent >= 0
  ),
  CONSTRAINT dispute_refund_document_line_codes_net_vat_gross_check CHECK (
    abs((net_amount_gbp + vat_amount_gbp) - gross_amount_gbp) <= 0.01
  )
);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_document_line_codes_line
  ON public.dispute_refund_document_line_accounting_codes (refund_document_line_id);

-- Extra accounting adjustment rows for refund document control, equivalent to
-- supplier_invoice_accounting_adjustment_lines but scoped to refund evidence.
CREATE TABLE IF NOT EXISTS public.dispute_refund_document_accounting_adjustment_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_evidence_submission_id uuid NOT NULL REFERENCES public.dispute_refund_evidence_submissions(id) ON DELETE CASCADE,
  description text NOT NULL,
  sku varchar NULL,
  size varchar NULL,
  sage_ledger_account_id varchar NULL,
  nominal_code varchar NULL,
  tax_rate_id varchar NULL,
  tax_rate_label varchar NULL,
  vat_rate_percent numeric(7,4) NOT NULL DEFAULT 20.0000,
  net_amount_gbp numeric(12,2) NOT NULL,
  vat_amount_gbp numeric(12,2) NOT NULL,
  gross_amount_gbp numeric(12,2) NOT NULL,
  created_by_staff_id uuid NULL REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dispute_refund_document_adjustment_net_vat_gross_check CHECK (
    abs((net_amount_gbp + vat_amount_gbp) - gross_amount_gbp) <= 0.01
  )
);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_document_adjustments_submission
  ON public.dispute_refund_document_accounting_adjustment_lines (refund_evidence_submission_id);

-- -----------------------------------------------------------------------------
-- 4) Totals/readiness view for staff coding/control pages.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.dispute_refund_document_accounting_totals_vw AS
WITH line_codes AS (
  SELECT
    l.refund_evidence_submission_id,
    COALESCE(SUM(c.net_amount_gbp), 0)::numeric(12,2) AS coded_net_gbp,
    COALESCE(SUM(c.vat_amount_gbp), 0)::numeric(12,2) AS coded_vat_gbp,
    COALESCE(SUM(c.gross_amount_gbp), 0)::numeric(12,2) AS coded_gross_gbp,
    COUNT(*) FILTER (WHERE l.progressed_to_supplier_control_yn)::int AS progressed_line_count,
    COUNT(c.id) FILTER (WHERE l.progressed_to_supplier_control_yn)::int AS coded_line_count
  FROM public.dispute_refund_document_lines l
  LEFT JOIN public.dispute_refund_document_line_accounting_codes c
    ON c.refund_document_line_id = l.id
  GROUP BY l.refund_evidence_submission_id
), adjustment_codes AS (
  SELECT
    a.refund_evidence_submission_id,
    COALESCE(SUM(a.net_amount_gbp), 0)::numeric(12,2) AS adjustment_net_gbp,
    COALESCE(SUM(a.vat_amount_gbp), 0)::numeric(12,2) AS adjustment_vat_gbp,
    COALESCE(SUM(a.gross_amount_gbp), 0)::numeric(12,2) AS adjustment_gross_gbp,
    COUNT(*)::int AS adjustment_line_count
  FROM public.dispute_refund_document_accounting_adjustment_lines a
  GROUP BY a.refund_evidence_submission_id
), header AS (
  SELECT
    s.id AS refund_evidence_submission_id,
    s.dispute_id,
    s.document_mode,
    COALESCE(
      s.ocr_credit_note_total_gbp,
      s.expected_credit_note_total_gbp,
      s.captured_refund_amount_abs_gbp,
      s.expected_exception_amount_abs_gbp,
      0
    )::numeric(12,2) AS accepted_document_gross_gbp
  FROM public.dispute_refund_evidence_submissions s
)
SELECT
  h.refund_evidence_submission_id,
  h.dispute_id,
  h.document_mode,
  h.accepted_document_gross_gbp,
  (COALESCE(lc.coded_net_gbp, 0) + COALESCE(ac.adjustment_net_gbp, 0))::numeric(12,2) AS total_coded_net_gbp,
  (COALESCE(lc.coded_vat_gbp, 0) + COALESCE(ac.adjustment_vat_gbp, 0))::numeric(12,2) AS total_coded_vat_gbp,
  (COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0))::numeric(12,2) AS total_coded_gross_gbp,
  COALESCE(ac.adjustment_gross_gbp, 0)::numeric(12,2) AS adjustment_gross_gbp,
  COALESCE(lc.progressed_line_count, 0)::int AS progressed_line_count,
  COALESCE(lc.coded_line_count, 0)::int AS coded_line_count,
  COALESCE(ac.adjustment_line_count, 0)::int AS adjustment_line_count,
  (COALESCE(lc.progressed_line_count, 0) = COALESCE(lc.coded_line_count, 0)) AS all_progressed_lines_coded_yn,
  (abs((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - COALESCE(h.accepted_document_gross_gbp, 0)) <= 0.01) AS gross_reconciled_to_document_yn,
  ((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - COALESCE(h.accepted_document_gross_gbp, 0))::numeric(12,2) AS gross_variance_gbp
FROM header h
LEFT JOIN line_codes lc ON lc.refund_evidence_submission_id = h.refund_evidence_submission_id
LEFT JOIN adjustment_codes ac ON ac.refund_evidence_submission_id = h.refund_evidence_submission_id;

-- -----------------------------------------------------------------------------
-- 5) Staff coding RPCs, mirroring supplier invoice coding controls.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.staff_bulk_save_refund_document_line_accounting_codes(
  p_refund_evidence_submission_id uuid,
  p_lines jsonb
)
RETURNS TABLE (
  refund_evidence_submission_id uuid,
  saved_line_count int,
  total_coded_net_gbp numeric,
  total_coded_vat_gbp numeric,
  total_coded_gross_gbp numeric,
  gross_variance_gbp numeric,
  balanced_yn boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_progressed_line_count int;
  v_submitted_line_count int;
  v_saved_line_count int := 0;
  v_row record;
  v_line public.dispute_refund_document_lines%ROWTYPE;
  v_gross numeric(12,2);
  v_net numeric(12,2);
  v_vat numeric(12,2);
  v_rate numeric(7,4);
  v_totals record;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can bulk save refund document coding.';
  END IF;

  IF jsonb_typeof(COALESCE(p_lines, 'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Coding payload must be a JSON array.';
  END IF;

  SELECT count(*) INTO v_progressed_line_count
  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = p_refund_evidence_submission_id
    AND l.progressed_to_supplier_control_yn = true;

  SELECT count(DISTINCT x.refund_document_line_id) INTO v_submitted_line_count
  FROM jsonb_to_recordset(p_lines) AS x(refund_document_line_id uuid);

  IF COALESCE(v_submitted_line_count, 0) <> COALESCE(v_progressed_line_count, 0) THEN
    RAISE EXCEPTION 'All progressed refund document lines must be submitted. Progressed %, submitted %.', v_progressed_line_count, v_submitted_line_count;
  END IF;

  FOR v_row IN
    SELECT *
    FROM jsonb_to_recordset(p_lines) AS x(
      refund_document_line_id uuid,
      description_override text,
      sku_override varchar,
      size_override varchar,
      sage_ledger_account_id varchar,
      nominal_code varchar,
      tax_rate_id varchar,
      tax_rate_label varchar,
      vat_rate_percent numeric,
      net_amount_gbp numeric,
      vat_amount_gbp numeric,
      admin_review_required_yn boolean,
      review_reason text
    )
  LOOP
    SELECT * INTO v_line
    FROM public.dispute_refund_document_lines l
    WHERE l.id = v_row.refund_document_line_id
      AND l.refund_evidence_submission_id = p_refund_evidence_submission_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Submitted refund document line % does not belong to evidence submission %.', v_row.refund_document_line_id, p_refund_evidence_submission_id;
    END IF;

    IF NOT v_line.progressed_to_supplier_control_yn THEN
      RAISE EXCEPTION 'Refund document line % is not released to supplier control.', v_line.id;
    END IF;

    v_gross := COALESCE(v_line.amount_gbp, 0)::numeric(12,2);
    v_net := COALESCE(v_row.net_amount_gbp, 0)::numeric(12,2);
    v_vat := COALESCE(v_row.vat_amount_gbp, 0)::numeric(12,2);
    v_rate := COALESCE(v_row.vat_rate_percent, 20.0000)::numeric(7,4);

    IF v_rate < 0 THEN
      RAISE EXCEPTION 'VAT rate cannot be negative for refund document line %.', v_line.id;
    END IF;

    IF v_net < 0 OR v_vat < 0 THEN
      RAISE EXCEPTION 'Net/VAT cannot be negative for refund document line %.', v_line.id;
    END IF;

    IF abs((v_net + v_vat) - v_gross) > 0.01 THEN
      RAISE EXCEPTION 'Refund line % does not balance. Net % + VAT % must equal locked gross %.', v_line.line_order, v_net, v_vat, v_gross;
    END IF;

    INSERT INTO public.dispute_refund_document_line_accounting_codes (
      refund_document_line_id,
      description_override,
      sku_override,
      size_override,
      sage_ledger_account_id,
      nominal_code,
      tax_rate_id,
      tax_rate_label,
      vat_rate_percent,
      net_amount_gbp,
      vat_amount_gbp,
      gross_amount_gbp,
      coded_by_staff_id,
      coded_at,
      admin_review_required_yn,
      review_reason,
      updated_at
    ) VALUES (
      v_line.id,
      NULLIF(btrim(COALESCE(v_row.description_override, '')), ''),
      NULLIF(btrim(COALESCE(v_row.sku_override, '')), ''),
      NULLIF(btrim(COALESCE(v_row.size_override, '')), ''),
      NULLIF(btrim(COALESCE(v_row.sage_ledger_account_id, '')), ''),
      NULLIF(btrim(COALESCE(v_row.nominal_code, '')), ''),
      NULLIF(btrim(COALESCE(v_row.tax_rate_id, '')), ''),
      NULLIF(btrim(COALESCE(v_row.tax_rate_label, '')), ''),
      v_rate,
      v_net,
      v_vat,
      v_gross,
      v_staff_id,
      now(),
      COALESCE(v_row.admin_review_required_yn, false),
      NULLIF(btrim(COALESCE(v_row.review_reason, '')), ''),
      now()
    )
    ON CONFLICT (refund_document_line_id)
    DO UPDATE SET
      description_override = EXCLUDED.description_override,
      sku_override = EXCLUDED.sku_override,
      size_override = EXCLUDED.size_override,
      sage_ledger_account_id = EXCLUDED.sage_ledger_account_id,
      nominal_code = EXCLUDED.nominal_code,
      tax_rate_id = EXCLUDED.tax_rate_id,
      tax_rate_label = EXCLUDED.tax_rate_label,
      vat_rate_percent = EXCLUDED.vat_rate_percent,
      net_amount_gbp = EXCLUDED.net_amount_gbp,
      vat_amount_gbp = EXCLUDED.vat_amount_gbp,
      gross_amount_gbp = EXCLUDED.gross_amount_gbp,
      coded_by_staff_id = EXCLUDED.coded_by_staff_id,
      coded_at = now(),
      admin_review_required_yn = EXCLUDED.admin_review_required_yn,
      review_reason = EXCLUDED.review_reason,
      updated_at = now();

    v_saved_line_count := v_saved_line_count + 1;
  END LOOP;

  SELECT * INTO v_totals
  FROM public.dispute_refund_document_accounting_totals_vw totals
  WHERE totals.refund_evidence_submission_id = p_refund_evidence_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not calculate refund document accounting totals.';
  END IF;

  IF NOT COALESCE(v_totals.all_progressed_lines_coded_yn, false) THEN
    RAISE EXCEPTION 'Not all progressed refund document lines are coded.';
  END IF;

  IF NOT COALESCE(v_totals.gross_reconciled_to_document_yn, false) THEN
    RAISE EXCEPTION 'Refund document coding does not reconcile to accepted document gross. Variance %.', v_totals.gross_variance_gbp;
  END IF;

  RETURN QUERY SELECT
    p_refund_evidence_submission_id,
    v_saved_line_count,
    v_totals.total_coded_net_gbp,
    v_totals.total_coded_vat_gbp,
    v_totals.total_coded_gross_gbp,
    v_totals.gross_variance_gbp,
    true;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_approve_refund_document_current(
  p_refund_evidence_submission_id uuid,
  p_review_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_totals record;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can approve refund document current.';
  END IF;

  SELECT * INTO v_totals
  FROM public.dispute_refund_document_accounting_totals_vw totals
  WHERE totals.refund_evidence_submission_id = p_refund_evidence_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Refund document accounting totals not found.';
  END IF;

  IF COALESCE(v_totals.progressed_line_count, 0) = 0 THEN
    RAISE EXCEPTION 'No refund document lines have been released to supplier control.';
  END IF;

  IF NOT COALESCE(v_totals.all_progressed_lines_coded_yn, false) THEN
    RAISE EXCEPTION 'All progressed refund document lines must be accounting coded before approval.';
  END IF;

  IF NOT COALESCE(v_totals.gross_reconciled_to_document_yn, false) THEN
    RAISE EXCEPTION 'Refund document coding does not reconcile to accepted document gross. Variance %.', v_totals.gross_variance_gbp;
  END IF;

  UPDATE public.dispute_refund_evidence_submissions s
  SET supplier_approval_status = 'approved_current',
      supplier_approved_by_staff_id = v_staff_id,
      supplier_approved_at = now(),
      supplier_control_status = 'approved_current',
      supervisor_review_status = CASE WHEN s.supervisor_review_status = 'pending_review' THEN 'accepted' ELSE s.supervisor_review_status END,
      supervisor_reviewed_by_staff_id = COALESCE(s.supervisor_reviewed_by_staff_id, v_staff_id),
      supervisor_reviewed_at = COALESCE(s.supervisor_reviewed_at, now()),
      supervisor_review_notes = COALESCE(NULLIF(btrim(COALESCE(p_review_notes, '')), ''), s.supervisor_review_notes)
  WHERE s.id = p_refund_evidence_submission_id;

  RETURN jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', p_refund_evidence_submission_id,
    'supplier_approval_status', 'approved_current'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.staff_bulk_save_refund_document_line_accounting_codes(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_approve_refund_document_current(uuid, text) TO authenticated;

COMMIT;
