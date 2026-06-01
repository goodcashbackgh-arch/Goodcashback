BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Sales invoice integrity + VAT refresh guard v1
-- Live-tested first in Supabase on 2026-06-01.
-- Purpose:
--   1. Prevent future sales_invoices from being marked posted without Sage confirmation.
--   2. Require non-void customer credit notes to link to their original sales invoice.
--   3. Keep sales_invoices.amount_gbp as a positive source amount; direction/sign is handled by document type / VAT line direction.
--   4. Exclude corrupt sales invoice rows from active VAT Box 6 source lines and raise VAT blockers instead.

ALTER TABLE public.sales_invoices
  DROP CONSTRAINT IF EXISTS sales_invoices_posted_requires_sage_confirmation_chk;

ALTER TABLE public.sales_invoices
  ADD CONSTRAINT sales_invoices_posted_requires_sage_confirmation_chk
  CHECK (
    sage_status <> 'posted'
    OR (
      NULLIF(TRIM(COALESCE(sage_invoice_id, '')), '') IS NOT NULL
      AND sage_posted_at IS NOT NULL
    )
  ) NOT VALID;

ALTER TABLE public.sales_invoices
  DROP CONSTRAINT IF EXISTS sales_invoices_credit_note_requires_link_chk;

ALTER TABLE public.sales_invoices
  ADD CONSTRAINT sales_invoices_credit_note_requires_link_chk
  CHECK (
    invoice_type <> 'credit_note'
    OR sage_status = 'void'
    OR linked_invoice_id IS NOT NULL
  ) NOT VALID;

ALTER TABLE public.sales_invoices
  DROP CONSTRAINT IF EXISTS sales_invoices_non_void_positive_amount_chk;

ALTER TABLE public.sales_invoices
  ADD CONSTRAINT sales_invoices_non_void_positive_amount_chk
  CHECK (
    sage_status = 'void'
    OR amount_gbp > 0
  ) NOT VALID;

CREATE OR REPLACE FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(p_vat_return_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_run record;
  v_purchase jsonb := '{}'::jsonb;
  v_box1 numeric(18,2) := 0;
  v_box2 numeric(18,2) := 0;
  v_box4 numeric(18,2) := 0;
  v_box6 numeric(18,2) := 0;
  v_box7 numeric(18,2) := 0;
  v_blockers integer := 0;
  v_sales_lines integer := 0;
  v_sales_credit_lines integer := 0;
  v_unproved_sales_lines integer := 0;
  v_invalid_sales_lines integer := 0;
  v_now timestamptz := now();
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT source snapshot refresh action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.status IN (
    'admin_approved',
    'sage_adjustment_journals_pending',
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review',
    'superseded'
  ) THEN
    RAISE EXCEPTION 'Cannot refresh VAT source snapshot in status %.', v_run.status;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vat_return_adjustment_journals j
    WHERE j.vat_return_run_id = p_vat_return_run_id
      AND j.status IN (
        'platform_calculated',
        'dry_run_validated',
        'admin_approved',
        'posting_to_sage',
        'posted_to_sage',
        'included_in_sage_return'
      )
  ) THEN
    RAISE EXCEPTION 'Cannot refresh VAT source snapshot while active adjustment journal rows exist.';
  END IF;

  UPDATE public.vat_return_run_lines l
  SET status = 'superseded',
      adjustment_reason = COALESCE(l.adjustment_reason, 'superseded_by_sales_invoice_integrity_guard_refresh_v1')
  WHERE l.vat_return_run_id = p_vat_return_run_id
    AND l.status = 'active'
    AND l.source_table = 'sales_invoices'
    AND l.line_kind = 'sales_invoice_box6_candidate';

  UPDATE public.vat_return_blockers b
  SET status = 'resolved',
      resolved_by_staff_id = v_staff_id,
      resolved_at = v_now,
      resolution_notes = 'superseded_by_sales_invoice_integrity_guard_refresh_v1'
  WHERE b.vat_return_run_id = p_vat_return_run_id
    AND b.status = 'open'
    AND b.source_table = 'sales_invoices'
    AND b.blocker_code IN (
      'sales_invoice_posted_without_sage_confirmation',
      'sales_credit_note_missing_linked_invoice',
      'sales_invoice_non_positive_amount',
      'sales_invoice_void_excluded'
    );

  WITH period_sales AS (
    SELECT
      si.*,
      COALESCE(si.consideration_received_date, si.sage_invoice_date, si.created_at::date) AS vat_tax_point_date,
      (
        COALESCE(si.sage_status, '') = 'posted'
        AND NULLIF(TRIM(COALESCE(si.sage_invoice_id, '')), '') IS NOT NULL
        AND si.sage_posted_at IS NOT NULL
      ) AS sage_proven_covered,
      CASE
        WHEN LOWER(COALESCE(si.invoice_type, '')) IN ('credit_note', 'credit note', 'sales_credit_note', 'sales credit note')
          THEN 'decrease'
        ELSE 'natural'
      END AS box6_direction,
      CASE
        WHEN COALESCE(si.sage_status, '') = 'void'
          THEN 'sales_invoice_void_excluded'
        WHEN COALESCE(si.sage_status, '') = 'posted'
          AND (
            NULLIF(TRIM(COALESCE(si.sage_invoice_id, '')), '') IS NULL
            OR si.sage_posted_at IS NULL
          )
          THEN 'sales_invoice_posted_without_sage_confirmation'
        WHEN LOWER(COALESCE(si.invoice_type, '')) IN ('credit_note', 'credit note', 'sales_credit_note', 'sales credit note')
          AND si.linked_invoice_id IS NULL
          THEN 'sales_credit_note_missing_linked_invoice'
        WHEN COALESCE(si.amount_gbp, 0) <= 0
          THEN 'sales_invoice_non_positive_amount'
        ELSE NULL
      END AS integrity_blocker_code
    FROM public.sales_invoices si
    WHERE COALESCE(si.consideration_received_date, si.sage_invoice_date, si.created_at::date)
      BETWEEN v_run.period_start_date AND v_run.period_end_date
  ), invalid_sales AS (
    SELECT *
    FROM period_sales
    WHERE integrity_blocker_code IS NOT NULL
      AND integrity_blocker_code <> 'sales_invoice_void_excluded'
  ), inserted_blockers AS (
    INSERT INTO public.vat_return_blockers (
      vat_return_run_id,
      blocker_code,
      severity,
      owner_role,
      source_table,
      source_id,
      source_ref,
      message,
      required_action,
      status
    )
    SELECT
      p_vat_return_run_id,
      ps.integrity_blocker_code,
      'blocker',
      'admin',
      'sales_invoices',
      ps.id,
      COALESCE(ps.invoice_type, 'sales_invoice') || ':' || ps.id::text,
      CASE ps.integrity_blocker_code
        WHEN 'sales_invoice_posted_without_sage_confirmation'
          THEN 'Sales invoice is marked posted but has no Sage invoice id and/or Sage posted timestamp.'
        WHEN 'sales_credit_note_missing_linked_invoice'
          THEN 'Sales credit note has no linked original sales invoice.'
        WHEN 'sales_invoice_non_positive_amount'
          THEN 'Sales invoice has a non-positive amount.'
        ELSE 'Sales invoice integrity blocker.'
      END,
      CASE ps.integrity_blocker_code
        WHEN 'sales_invoice_posted_without_sage_confirmation'
          THEN 'Void the legacy/internal bad row or correct it with a real Sage object id and Sage posted timestamp. Do not treat it as Sage-covered.'
        WHEN 'sales_credit_note_missing_linked_invoice'
          THEN 'Link the credit note to the original sales invoice or void the bad credit note.'
        WHEN 'sales_invoice_non_positive_amount'
          THEN 'Correct or void the bad sales invoice amount.'
        ELSE 'Review and correct source sales invoice.'
      END,
      'open'
    FROM invalid_sales ps
    RETURNING id
  ), source_sales AS (
    SELECT *
    FROM period_sales ps
    WHERE ps.integrity_blocker_code IS NULL
  ), inserted_sales AS (
    INSERT INTO public.vat_return_run_lines (
      vat_return_run_id,
      line_kind,
      source_table,
      source_id,
      source_ref,
      source_json,
      source_lineage_json,
      box_number,
      direction,
      amount_gbp,
      vat_amount_gbp,
      vat_basis,
      tax_point_date,
      return_period_label,
      natural_sage_covered,
      adjustment_required,
      adjustment_reason,
      status
    )
    SELECT
      p_vat_return_run_id,
      'sales_invoice_box6_candidate',
      'sales_invoices',
      ss.id,
      COALESCE(ss.invoice_type, 'sales_invoice') || ':' || ss.id::text,
      to_jsonb(ss),
      jsonb_build_object(
        'sales_invoice_id', ss.id,
        'sage_invoice_id', ss.sage_invoice_id,
        'sage_status', ss.sage_status,
        'sage_posted_at', ss.sage_posted_at,
        'zero_rating_deadline_date', ss.zero_rating_deadline_date,
        'zero_rating_status', ss.zero_rating_status,
        'strict_sage_coverage_rule', 'sage_status_posted_and_sage_invoice_id_and_sage_posted_at_present',
        'box6_direction_rule', 'credit_note_decreases_box6',
        'sales_invoice_integrity_guard', 'passed'
      ),
      6,
      ss.box6_direction,
      ABS(COALESCE(ss.amount_gbp, 0)),
      0,
      'sales_invoice_amount_gbp_integrity_guard_refresh_v1',
      ss.vat_tax_point_date,
      v_run.return_period_label,
      ss.sage_proven_covered,
      NOT ss.sage_proven_covered,
      CASE
        WHEN ss.sage_proven_covered THEN NULL
        ELSE 'box6_possible_sage_gap_sales_invoice_not_proven_in_sage'
      END,
      'active'
    FROM source_sales ss
    RETURNING direction, natural_sage_covered
  )
  SELECT
    COALESCE((SELECT count(*) FROM inserted_sales), 0),
    COALESCE((SELECT count(*) FROM inserted_sales WHERE direction = 'decrease'), 0),
    COALESCE((SELECT count(*) FROM inserted_sales WHERE natural_sage_covered IS DISTINCT FROM true), 0),
    COALESCE((SELECT count(*) FROM invalid_sales), 0)
  INTO v_sales_lines, v_sales_credit_lines, v_unproved_sales_lines, v_invalid_sales_lines;

  v_purchase := public.staff_refresh_vat_purchase_source_lines_v1(p_vat_return_run_id);

  SELECT COALESCE(SUM(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box1
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 1 AND status = 'active';

  SELECT COALESCE(SUM(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box2
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 2 AND status = 'active';

  SELECT COALESCE(SUM(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box4
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 4 AND status = 'active';

  SELECT COALESCE(SUM(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box6
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 6 AND status = 'active';

  SELECT COALESCE(SUM(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box7
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id AND box_number = 7 AND status = 'active';

  SELECT count(*) INTO v_blockers
  FROM public.vat_return_blockers
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'open';

  UPDATE public.vat_return_runs
  SET expected_box1_gbp = v_box1,
      expected_box2_gbp = v_box2,
      expected_box3_gbp = v_box1 + v_box2,
      expected_box4_gbp = v_box4,
      expected_box5_gbp = (v_box1 + v_box2) - v_box4,
      expected_box6_gbp = v_box6,
      expected_box7_gbp = v_box7,
      expected_box8_gbp = 0,
      expected_box9_gbp = 0,
      source_counts_json = COALESCE(source_counts_json, '{}'::jsonb) || jsonb_build_object(
        'refresh_version', 'staff_refresh_vat_return_source_snapshot_v1_sales_invoice_integrity_guard_v1',
        'sales_invoice_box6_candidate_lines', v_sales_lines,
        'sales_invoice_box6_credit_note_decrease_lines', v_sales_credit_lines,
        'sales_invoice_box6_unproved_sage_coverage_lines', v_unproved_sales_lines,
        'sales_invoice_integrity_blocker_lines', v_invalid_sales_lines,
        'purchase_refresh', v_purchase
      ),
      blockers_summary_json = jsonb_build_object(
        'open_blockers', v_blockers,
        'refresh_version', 'staff_refresh_vat_return_source_snapshot_v1_sales_invoice_integrity_guard_v1',
        'sage_posting_performed', false,
        'journal_approval_performed', false
      ),
      updated_at = v_now
  WHERE id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'expected_box1_gbp', v_box1,
    'expected_box2_gbp', v_box2,
    'expected_box3_gbp', v_box1 + v_box2,
    'expected_box4_gbp', v_box4,
    'expected_box5_gbp', (v_box1 + v_box2) - v_box4,
    'expected_box6_gbp', v_box6,
    'expected_box7_gbp', v_box7,
    'sales_invoice_box6_candidate_lines', v_sales_lines,
    'sales_invoice_box6_credit_note_decrease_lines', v_sales_credit_lines,
    'sales_invoice_box6_unproved_sage_coverage_lines', v_unproved_sales_lines,
    'sales_invoice_integrity_blocker_lines', v_invalid_sales_lines,
    'purchase_refresh', v_purchase,
    'open_blockers', v_blockers
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid)
IS 'Admin-only VAT source refresh. Rebuilds Box 6 sales invoice lines but excludes corrupt sales invoice rows; posted requires Sage id and posted timestamp; credit notes decrease Box 6 and require linked invoice unless void.';

NOTIFY pgrst, 'reload schema';

COMMIT;
