BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines';
  END IF;
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.dispute_refund_document_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_line_accounting_codes';
  END IF;
  IF to_regclass('public.dispute_refund_document_accounting_adjustment_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_accounting_adjustment_lines';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sage_posting_snapshots';
  END IF;
  IF to_regclass('public.dispute_messages') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_messages';
  END IF;
  IF to_regprocedure('public.refund_credit_note_submission_is_aligned_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: refund_credit_note_submission_is_aligned_v1(uuid)';
  END IF;
  IF to_regprocedure('public.internal_supplier_credit_note_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_supplier_credit_note_ready_rows_v1()';
  END IF;
END $$;

ALTER TABLE public.dispute_refund_document_lines
  ADD COLUMN IF NOT EXISTS included_in_supplier_credit_yn boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS exclusion_reason text NULL,
  ADD COLUMN IF NOT EXISTS excluded_by_staff_id uuid NULL REFERENCES public.staff(id),
  ADD COLUMN IF NOT EXISTS excluded_at timestamptz NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'dispute_refund_document_lines_inclusion_state_chk'
      AND conrelid = 'public.dispute_refund_document_lines'::regclass
  ) THEN
    ALTER TABLE public.dispute_refund_document_lines
      ADD CONSTRAINT dispute_refund_document_lines_inclusion_state_chk
      CHECK (
        (included_in_supplier_credit_yn = true
          AND exclusion_reason IS NULL
          AND excluded_by_staff_id IS NULL
          AND excluded_at IS NULL)
        OR
        (included_in_supplier_credit_yn = false
          AND NULLIF(btrim(COALESCE(exclusion_reason, '')), '') IS NOT NULL
          AND excluded_by_staff_id IS NOT NULL
          AND excluded_at IS NOT NULL)
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_refund_document_lines_inclusion
  ON public.dispute_refund_document_lines (
    refund_evidence_submission_id,
    included_in_supplier_credit_yn,
    progressed_to_supplier_control_yn,
    line_order
  );

CREATE OR REPLACE FUNCTION public.refund_document_accepted_credit_gbp_v1(
  p_refund_evidence_submission_id uuid
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT round((
    CASE
      WHEN s.document_mode = 'credit_note' THEN
        COALESCE(s.ocr_credit_note_total_gbp, 0)
        + COALESCE(SUM(abs(COALESCE(l.amount_gbp, 0))) FILTER (
            WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true
              AND l.line_source IN ('delivery_adjustment', 'discount_adjustment')
          ), 0)
      ELSE
        COALESCE(SUM(abs(COALESCE(l.amount_gbp, 0))) FILTER (
          WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true
        ), 0)
    END
  )::numeric, 2)
  FROM public.dispute_refund_evidence_submissions s
  LEFT JOIN public.dispute_refund_document_lines l
    ON l.refund_evidence_submission_id = s.id
  WHERE s.id = p_refund_evidence_submission_id
  GROUP BY s.id, s.document_mode, s.ocr_credit_note_total_gbp;
$$;

COMMENT ON FUNCTION public.refund_document_accepted_credit_gbp_v1(uuid) IS
'Authoritative accepted supplier-credit gross. Formal CN = verified OCR face total plus included supplementary delivery/discount evidence outside the CN. Other modes = all included evidence lines.';

REVOKE ALL ON FUNCTION public.refund_document_accepted_credit_gbp_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_document_accepted_credit_gbp_v1(uuid) TO authenticated;

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

  IF COALESCE(v_submission.ocr_status, '') <> 'completed'
     OR NULLIF(btrim(COALESCE(v_submission.credit_note_ref, '')), '') IS NULL
     OR v_submission.credit_note_date IS NULL
     OR COALESCE(v_submission.expected_credit_note_total_gbp, 0) <= 0
     OR NULLIF(btrim(COALESCE(v_submission.ocr_credit_note_ref, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(v_submission.ocr_retailer_name, '')), '') IS NULL
     OR v_submission.ocr_credit_note_date IS NULL
     OR COALESCE(v_submission.ocr_credit_note_total_gbp, 0) <= 0
  THEN
    RETURN false;
  END IF;

  SELECT NULLIF(btrim(COALESCE(r.name::text, '')), '')
    INTO v_expected_retailer_name
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  WHERE d.id = v_submission.dispute_id;

  v_ref_match := lower(regexp_replace(v_submission.credit_note_ref, '[^a-zA-Z0-9]+', '', 'g'))
    = lower(regexp_replace(v_submission.ocr_credit_note_ref, '[^a-zA-Z0-9]+', '', 'g'));
  v_date_match := v_submission.credit_note_date = v_submission.ocr_credit_note_date;
  v_amount_match := abs(
    COALESCE(v_submission.expected_credit_note_total_gbp, 0)
    - COALESCE(v_submission.ocr_credit_note_total_gbp, 0)
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
         round(COALESCE(sum(abs(COALESCE(l.amount_gbp, 0))), 0)::numeric, 2)
    INTO v_line_count, v_line_total
  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission.id
    AND COALESCE(l.included_in_supplier_credit_yn, true) = true
    AND l.line_source = 'ocr_extracted';

  v_line_match := COALESCE(v_line_count, 0) > 0
    AND abs(COALESCE(v_line_total, 0) - v_submission.ocr_credit_note_total_gbp) <= 0.01;

  RETURN v_ref_match
    AND v_date_match
    AND v_amount_match
    AND v_retailer_match
    AND v_line_match;
END;
$$;

REVOKE ALL ON FUNCTION public.refund_credit_note_submission_is_aligned_v1(uuid) FROM PUBLIC;

CREATE OR REPLACE VIEW public.dispute_refund_document_accounting_totals_vw AS
WITH line_codes AS (
  SELECT
    l.refund_evidence_submission_id,
    COALESCE(SUM(c.net_amount_gbp) FILTER (WHERE l.progressed_to_supplier_control_yn), 0)::numeric(12,2) AS coded_net_gbp,
    COALESCE(SUM(c.vat_amount_gbp) FILTER (WHERE l.progressed_to_supplier_control_yn), 0)::numeric(12,2) AS coded_vat_gbp,
    COALESCE(SUM(c.gross_amount_gbp) FILTER (WHERE l.progressed_to_supplier_control_yn), 0)::numeric(12,2) AS coded_gross_gbp,
    COUNT(*) FILTER (WHERE l.progressed_to_supplier_control_yn)::int AS progressed_line_count,
    COUNT(c.id) FILTER (WHERE l.progressed_to_supplier_control_yn)::int AS coded_line_count
  FROM public.dispute_refund_document_lines l
  LEFT JOIN public.dispute_refund_document_line_accounting_codes c
    ON c.refund_document_line_id = l.id
  WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true
  GROUP BY l.refund_evidence_submission_id
), evidence_totals AS (
  SELECT
    l.refund_evidence_submission_id,
    COUNT(*) FILTER (WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true)::int AS included_line_count,
    COUNT(*) FILTER (WHERE COALESCE(l.included_in_supplier_credit_yn, true) = false)::int AS excluded_line_count,
    COALESCE(SUM(abs(COALESCE(l.amount_gbp, 0))) FILTER (
      WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true
        AND l.line_source = 'ocr_extracted'
    ), 0)::numeric(12,2) AS included_ocr_gross_gbp,
    COALESCE(SUM(abs(COALESCE(l.amount_gbp, 0))) FILTER (
      WHERE COALESCE(l.included_in_supplier_credit_yn, true) = true
        AND l.line_source IN ('delivery_adjustment', 'discount_adjustment')
    ), 0)::numeric(12,2) AS included_supplementary_gross_gbp
  FROM public.dispute_refund_document_lines l
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
    COALESCE(public.refund_document_accepted_credit_gbp_v1(s.id), 0)::numeric(12,2) AS accepted_document_gross_gbp
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
  ((COALESCE(lc.coded_gross_gbp, 0) + COALESCE(ac.adjustment_gross_gbp, 0)) - COALESCE(h.accepted_document_gross_gbp, 0))::numeric(12,2) AS gross_variance_gbp,
  COALESCE(et.included_line_count, 0)::int AS included_line_count,
  COALESCE(et.excluded_line_count, 0)::int AS excluded_line_count,
  COALESCE(et.included_ocr_gross_gbp, 0)::numeric(12,2) AS included_ocr_gross_gbp,
  COALESCE(et.included_supplementary_gross_gbp, 0)::numeric(12,2) AS included_supplementary_gross_gbp
FROM header h
LEFT JOIN line_codes lc ON lc.refund_evidence_submission_id = h.refund_evidence_submission_id
LEFT JOIN evidence_totals et ON et.refund_evidence_submission_id = h.refund_evidence_submission_id
LEFT JOIN adjustment_codes ac ON ac.refund_evidence_submission_id = h.refund_evidence_submission_id;

CREATE OR REPLACE FUNCTION public.enforce_refund_line_included_before_release_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_becoming_released boolean;
BEGIN
  v_becoming_released := COALESCE(NEW.progressed_to_supplier_control_yn, false)
    AND (TG_OP = 'INSERT' OR NOT COALESCE(OLD.progressed_to_supplier_control_yn, false));

  IF v_becoming_released
     AND COALESCE(NEW.included_in_supplier_credit_yn, true) = false THEN
    RAISE EXCEPTION 'Excluded refund-document lines cannot be released to supplier control.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispute_refund_line_included_before_release_trg
  ON public.dispute_refund_document_lines;
CREATE TRIGGER dispute_refund_line_included_before_release_trg
BEFORE INSERT OR UPDATE OF progressed_to_supplier_control_yn
ON public.dispute_refund_document_lines
FOR EACH ROW
EXECUTE FUNCTION public.enforce_refund_line_included_before_release_v1();

CREATE OR REPLACE FUNCTION public.enforce_refund_line_included_before_coding_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.dispute_refund_document_lines l
    WHERE l.id = NEW.refund_document_line_id
      AND COALESCE(l.included_in_supplier_credit_yn, true) = true
  ) THEN
    RAISE EXCEPTION 'Excluded refund-document lines cannot be accounting coded.'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispute_refund_line_included_before_coding_trg
  ON public.dispute_refund_document_line_accounting_codes;
CREATE TRIGGER dispute_refund_line_included_before_coding_trg
BEFORE INSERT OR UPDATE
ON public.dispute_refund_document_line_accounting_codes
FOR EACH ROW
EXECUTE FUNCTION public.enforce_refund_line_included_before_coding_v1();

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
  v_selected_count int;
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

  SELECT count(DISTINCT selected.line_id)::int
    INTO v_selected_count
  FROM unnest(p_line_ids) AS selected(line_id);

  IF EXISTS (
    SELECT 1
    FROM unnest(p_line_ids) AS selected(line_id)
    LEFT JOIN public.dispute_refund_document_lines l
      ON l.id = selected.line_id
     AND l.refund_evidence_submission_id = p_refund_evidence_submission_id
    WHERE l.id IS NULL
       OR COALESCE(l.included_in_supplier_credit_yn, true) = false
  ) THEN
    RAISE EXCEPTION 'Every selected line must belong to this submission and remain included in supplier credit.';
  END IF;

  UPDATE public.dispute_refund_document_lines l
  SET progressed_to_supplier_control_yn = true,
      updated_at = now()
  WHERE l.refund_evidence_submission_id = p_refund_evidence_submission_id
    AND l.id = ANY(p_line_ids)
    AND COALESCE(l.included_in_supplier_credit_yn, true) = true;

  GET DIAGNOSTICS v_release_count = ROW_COUNT;

  IF v_release_count <> v_selected_count THEN
    RAISE EXCEPTION 'Selected refund-document line scope changed before release. Expected %, released %.', v_selected_count, v_release_count;
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

CREATE OR REPLACE FUNCTION public.staff_set_refund_line_inclusion_v1(
  p_refund_evidence_submission_id uuid,
  p_line_ids uuid[],
  p_include boolean,
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
  v_reason text;
  v_target_count int;
  v_changed_count int;
  v_aligned boolean;
  v_amount_match boolean;
  v_match_status text;
  v_amount_balance_status text;
  v_accepted_gross numeric(12,2);
  v_line_audit jsonb;
  v_message_id uuid;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin/supervisor staff can change refund-document line inclusion.';
  END IF;

  IF p_include IS NULL THEN
    RAISE EXCEPTION 'The requested inclusion state is required.';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'A reason is required to exclude or restore refund-document lines.';
  END IF;

  IF p_line_ids IS NULL OR array_length(p_line_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one refund-document line.';
  END IF;

  SELECT s.*
    INTO v_submission
  FROM public.dispute_refund_evidence_submissions s
  WHERE s.id = p_refund_evidence_submission_id
  FOR UPDATE;

  IF v_submission.id IS NULL THEN
    RAISE EXCEPTION 'Refund evidence submission not found.';
  END IF;

  IF COALESCE(v_submission.supplier_approval_status, '') = 'approved_current'
     OR COALESCE(v_submission.supplier_control_status, '') IN ('released_to_supplier_control', 'approved_current') THEN
    RAISE EXCEPTION 'Refund-document line scope is locked after release or approval.';
  END IF;

  IF COALESCE(v_submission.supervisor_review_status, '') = 'rejected'
     OR COALESCE(v_submission.evidence_control_status, '') = 'staff_rejected_resubmission_required'
     OR COALESCE(v_submission.supplier_readiness_route, '') = 'operator_resubmission_required' THEN
    RAISE EXCEPTION 'This rejected submission is audit-only. Submit corrected evidence instead.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_refund_document_lines l
    WHERE l.refund_evidence_submission_id = v_submission.id
      AND COALESCE(l.progressed_to_supplier_control_yn, false) = true
  ) THEN
    RAISE EXCEPTION 'Refund-document line scope is locked after any line is released.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot
    WHERE snapshot.source_table = 'dispute_refund_evidence_submissions'
      AND snapshot.source_id = v_submission.id
      AND COALESCE(snapshot.active, true) = true
  ) THEN
    RAISE EXCEPTION 'Refund-document line scope is locked after an active Sage snapshot is created.';
  END IF;

  PERFORM 1
  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission.id
    AND l.id = ANY(p_line_ids)
  FOR UPDATE;

  SELECT count(DISTINCT selected.line_id)::int
    INTO v_target_count
  FROM unnest(p_line_ids) AS selected(line_id)
  JOIN public.dispute_refund_document_lines l
    ON l.id = selected.line_id
   AND l.refund_evidence_submission_id = v_submission.id;

  IF v_target_count <> (
    SELECT count(DISTINCT selected.line_id)::int
    FROM unnest(p_line_ids) AS selected(line_id)
  ) THEN
    RAISE EXCEPTION 'One or more selected lines do not belong to this refund evidence submission.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_refund_document_line_accounting_codes c
    JOIN public.dispute_refund_document_lines l ON l.id = c.refund_document_line_id
    WHERE l.refund_evidence_submission_id = v_submission.id
      AND l.id = ANY(p_line_ids)
  ) THEN
    RAISE EXCEPTION 'Coded refund-document lines cannot be excluded or restored.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_refund_document_lines l
    WHERE l.refund_evidence_submission_id = v_submission.id
      AND l.id = ANY(p_line_ids)
      AND COALESCE(l.included_in_supplier_credit_yn, true) = p_include
  ) THEN
    RAISE EXCEPTION 'Every selected line must currently have the opposite inclusion state.';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'line_id', l.id,
      'line_order', l.line_order,
      'line_source', l.line_source,
      'description', l.description,
      'qty', l.qty,
      'amount_gbp', l.amount_gbp,
      'previous_included_yn', COALESCE(l.included_in_supplier_credit_yn, true),
      'new_included_yn', p_include
    ) ORDER BY l.line_order, l.id
  )
  INTO v_line_audit
  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission.id
    AND l.id = ANY(p_line_ids);

  UPDATE public.dispute_refund_document_lines l
  SET included_in_supplier_credit_yn = p_include,
      exclusion_reason = CASE WHEN p_include THEN NULL ELSE v_reason END,
      excluded_by_staff_id = CASE WHEN p_include THEN NULL ELSE v_staff_id END,
      excluded_at = CASE WHEN p_include THEN NULL ELSE now() END,
      updated_at = now()
  WHERE l.refund_evidence_submission_id = v_submission.id
    AND l.id = ANY(p_line_ids);

  GET DIAGNOSTICS v_changed_count = ROW_COUNT;

  IF v_changed_count <> v_target_count THEN
    RAISE EXCEPTION 'Refund-document line inclusion scope changed concurrently. Expected %, changed %.', v_target_count, v_changed_count;
  END IF;

  IF v_submission.document_mode = 'credit_note' THEN
    v_amount_match := COALESCE(v_submission.expected_credit_note_total_gbp, 0) > 0
      AND COALESCE(v_submission.ocr_credit_note_total_gbp, 0) > 0
      AND abs(
        COALESCE(v_submission.expected_credit_note_total_gbp, 0)
        - COALESCE(v_submission.ocr_credit_note_total_gbp, 0)
      ) <= 0.01;

    v_aligned := public.refund_credit_note_submission_is_aligned_v1(v_submission.id);
    v_amount_balance_status := CASE WHEN v_amount_match THEN 'balanced' ELSE 'variance' END;
    v_match_status := CASE WHEN v_aligned THEN 'matched_ready_to_release' ELSE 'needs_supervisor_review' END;

    UPDATE public.dispute_refund_evidence_submissions s
    SET amount_balance_status = v_amount_balance_status,
        match_status = v_match_status,
        evidence_control_status = CASE WHEN v_aligned THEN 'credit_note_ocr_matched_ready' ELSE 'credit_note_ocr_review_required' END,
        supplier_readiness_route = CASE WHEN v_aligned THEN 'supplier_credit_note_ready_to_release' ELSE 'supplier_credit_note_review_required' END,
        supplier_control_status = CASE WHEN v_aligned THEN 'not_released' ELSE 'blocked' END,
        supplier_approval_status = CASE WHEN v_aligned THEN 'pending' ELSE 'blocked' END,
        supervisor_review_status = CASE WHEN v_aligned THEN 'not_required' ELSE 'pending_review' END
    WHERE s.id = v_submission.id;
  ELSE
    v_match_status := v_submission.match_status;
    v_amount_balance_status := v_submission.amount_balance_status;
  END IF;

  v_accepted_gross := public.refund_document_accepted_credit_gbp_v1(v_submission.id);

  INSERT INTO public.dispute_messages (
    dispute_id,
    message_type,
    counterparty,
    generated_by,
    body
  ) VALUES (
    v_submission.dispute_id,
    'supervisor_note',
    'internal',
    'manual',
    array_to_string(ARRAY[
      '[REFUND_DOCUMENT_LINE_INCLUSION_V1]',
      'staff_id: ' || v_staff_id::text,
      'refund_evidence_submission_id: ' || v_submission.id::text,
      'action: ' || CASE WHEN p_include THEN 'restore' ELSE 'exclude' END,
      'reason: ' || v_reason,
      'accepted_supplier_credit_gbp: ' || COALESCE(v_accepted_gross, 0)::text,
      'resulting_match_status: ' || COALESCE(v_match_status, ''),
      '',
      'lines: ' || COALESCE(v_line_audit, '[]'::jsonb)::text
    ], E'\n')
  ) RETURNING id INTO v_message_id;

  RETURN jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', v_submission.id,
    'changed_line_count', v_changed_count,
    'included_yn', p_include,
    'accepted_supplier_credit_gbp', v_accepted_gross,
    'match_status', v_match_status,
    'amount_balance_status', v_amount_balance_status,
    'audit_message_id', v_message_id
  );
END;
$$;

COMMENT ON FUNCTION public.staff_set_refund_line_inclusion_v1(uuid, uuid[], boolean, text) IS
'Reversibly excludes or restores unreleased, uncoded refund-document evidence lines with audit, recalculating formal CN alignment and accepted supplier credit.';

REVOKE ALL ON FUNCTION public.staff_set_refund_line_inclusion_v1(uuid, uuid[], boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_set_refund_line_inclusion_v1(uuid, uuid[], boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_release_refund_document_lines_to_supplier_control(uuid, uuid[], text) TO authenticated;

DO $patch_header$
DECLARE
  v_definition text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef('public.staff_correct_refund_credit_note_header_v1(uuid,text,date,numeric,text,text,date,numeric,text)'::regprocedure)
    INTO v_definition;

  IF position('included_in_supplier_credit_yn' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old$  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission.id;$old$,
$new$  FROM public.dispute_refund_document_lines l
  WHERE l.refund_evidence_submission_id = v_submission.id
    AND COALESCE(l.included_in_supplier_credit_yn, true) = true
    AND l.line_source = 'ocr_extracted';$new$
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not patch staff_correct_refund_credit_note_header_v1 included OCR line alignment.';
    END IF;
  END IF;

  EXECUTE v_definition;
END;
$patch_header$;

DO $patch_ocr$
DECLARE
  v_definition text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef('public.staff_save_refund_credit_note_ocr_result(uuid,varchar,integer,varchar,varchar,jsonb,text,text,date,numeric,integer,jsonb,jsonb)'::regprocedure)
    INTO v_definition;

  IF position('Restore excluded OCR lines before replacing the OCR result.' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old$  delete from public.dispute_refund_document_lines l
  where l.refund_evidence_submission_id = p_refund_evidence_submission_id
    and l.line_source = 'ocr_extracted'
    and l.progressed_to_supplier_control_yn = false;$old$,
$new$  if exists (
    select 1
    from public.dispute_refund_document_lines l
    where l.refund_evidence_submission_id = p_refund_evidence_submission_id
      and l.line_source = 'ocr_extracted'
      and coalesce(l.included_in_supplier_credit_yn, true) = false
  ) then
    raise exception 'Restore excluded OCR lines before replacing the OCR result.';
  end if;

  delete from public.dispute_refund_document_lines l
  where l.refund_evidence_submission_id = p_refund_evidence_submission_id
    and l.line_source = 'ocr_extracted'
    and l.progressed_to_supplier_control_yn = false;$new$
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not add excluded OCR replacement guard.';
    END IF;
  END IF;

  IF position('abs(v_line_total - v_ocr_total) > 0.01' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old$  if v_inserted_count = 0 then
    v_match_status := 'needs_supervisor_review';
  end if;$old$,
$new$  if v_inserted_count = 0 or abs(v_line_total - v_ocr_total) > 0.01 then
    v_match_status := 'needs_supervisor_review';
  end if;$new$
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not add OCR line-total alignment guard.';
    END IF;
  END IF;

  EXECUTE v_definition;
END;
$patch_ocr$;

DO $patch_ready$
DECLARE
  v_definition text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef('public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure)
    INTO v_definition;

  IF position('COALESCE(b.accepted_document_gross_gbp, 0)::numeric(18,2) AS accepted_gross_gbp' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old$      GREATEST(
        COALESCE(b.accepted_document_gross_gbp, 0),
        COALESCE(b.captured_refund_amount_abs_gbp, 0),
        COALESCE(b.expected_exception_amount_abs_gbp, 0),
        COALESCE(b.amount_impact_gbp, 0)
      )::numeric(18,2) AS accepted_gross_gbp,$old$,
$new$      COALESCE(b.accepted_document_gross_gbp, 0)::numeric(18,2) AS accepted_gross_gbp,$new$
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not replace supplier-credit GREATEST accepted amount fallback.';
    END IF;
  END IF;

  IF position('COALESCE(l.included_in_supplier_credit_yn, true) = true' IN v_definition) = 0 THEN
    v_before := v_definition;
    v_definition := replace(
      v_definition,
$old$    WHERE COALESCE(l.progressed_to_supplier_control_yn, false) = true$old$,
$new$    WHERE COALESCE(l.progressed_to_supplier_control_yn, false) = true
      AND COALESCE(l.included_in_supplier_credit_yn, true) = true$new$
    );

    IF v_definition = v_before THEN
      RAISE EXCEPTION 'Could not filter excluded supplier-credit source lines from Sage readiness.';
    END IF;
  END IF;

  EXECUTE v_definition;
END;
$patch_ready$;

REVOKE ALL ON FUNCTION public.enforce_refund_line_included_before_release_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_refund_line_included_before_coding_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() TO authenticated;

COMMIT;
