-- =============================================================================
-- Focused regression for PR #213 review defects.
--
-- Covers:
--   * PostgreSQL UUID-safe candidate selection;
--   * two current reinstatements competing for one locked breach;
--   * TSV MIME support in the private final-evidence bucket.
--
-- This script always rolls back.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

DO $$
DECLARE
  v_mimes text[];
BEGIN
  SELECT allowed_mime_types
  INTO v_mimes
  FROM storage.buckets
  WHERE id = 'vat-return-evidence';

  IF v_mimes IS NULL THEN
    RAISE EXCEPTION 'vat-return-evidence bucket missing or has no MIME contract';
  END IF;

  IF NOT ('text/tab-separated-values' = ANY(v_mimes)) THEN
    RAISE EXCEPTION 'vat-return-evidence bucket does not accept text/tab-separated-values';
  END IF;
END $$;

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    to_regprocedure('public.staff_finalize_vat_return_integrity_v1(uuid)')
  )
  INTO v_definition;

  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'staff_finalize_vat_return_integrity_v1(uuid) missing';
  END IF;

  IF v_definition ~* 'min\s*\(\s*b\.id\s*\)' THEN
    RAISE EXCEPTION 'UUID-unsafe min(b.id) found in VAT integrity finaliser';
  END IF;

  IF v_definition NOT ILIKE '%array_agg(b.id ORDER BY b.id)%' THEN
    RAISE EXCEPTION 'Expected deterministic UUID candidate selection is missing';
  END IF;

  IF v_definition NOT ILIKE '%current_candidate_claim_count%' THEN
    RAISE EXCEPTION 'Same-breach current-claim conflict classification is missing';
  END IF;
END $$;

DO $$
DECLARE
  v_breach public.vat_return_run_lines%rowtype;
  v_breach_period_end date;
  v_run public.vat_return_runs%rowtype;
  v_reinstatement_1 uuid := gen_random_uuid();
  v_reinstatement_2 uuid := gen_random_uuid();
  v_active_count integer;
  v_superseded_count integer;
  v_blocker_count integer;
BEGIN
  SELECT b.*
  INTO v_breach
  FROM public.vat_return_run_lines b
  JOIN public.vat_return_runs br
    ON br.id = b.vat_return_run_id
  WHERE b.line_kind = 'box1_export_evidence_breach'
    AND b.status = 'active'
    AND br.status = 'matched_to_sage_locked'
    AND br.locked_at IS NOT NULL
    AND b.source_id IS NOT NULL
    AND b.amount_gbp > 0
  ORDER BY br.period_end_date, b.created_at, b.id
  LIMIT 1;

  IF v_breach.id IS NULL THEN
    RAISE NOTICE 'No suitable locked export breach; duplicate-current-claim fixture skipped.';
    RETURN;
  END IF;

  SELECT br.period_end_date
  INTO v_breach_period_end
  FROM public.vat_return_runs br
  WHERE br.id = v_breach.vat_return_run_id;

  SELECT r.*
  INTO v_run
  FROM public.vat_return_runs r
  WHERE r.locked_at IS NULL
    AND r.period_end_date > v_breach_period_end
    AND r.status NOT IN (
      'admin_approved',
      'sage_adjustment_journals_pending',
      'sage_adjustment_journals_posted',
      'sage_return_review_required',
      'sage_return_submitted',
      'matched_to_sage_locked',
      'mismatch_needs_admin_review',
      'superseded'
    )
  ORDER BY r.period_start_date, r.created_at
  LIMIT 1;

  IF v_run.id IS NULL THEN
    RAISE NOTICE 'No later editable VAT run; duplicate-current-claim fixture skipped.';
    RETURN;
  END IF;

  INSERT INTO public.vat_return_run_lines (
    id,
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
  VALUES
  (
    v_reinstatement_1,
    v_run.id,
    'box1_export_evidence_reinstatement',
    v_breach.source_table,
    v_breach.source_id,
    'review-regression-duplicate-1',
    jsonb_build_object('test_fixture', 'duplicate_current_export_claim_v1'),
    jsonb_build_object('prior_breach_id', v_breach.id),
    1,
    'decrease',
    v_breach.amount_gbp,
    v_breach.vat_amount_gbp,
    'review_regression_only',
    GREATEST(v_run.period_start_date, v_breach_period_end + 1),
    v_run.return_period_label,
    false,
    true,
    'Rollback-only review regression fixture.',
    'active'
  ),
  (
    v_reinstatement_2,
    v_run.id,
    'box1_export_evidence_reinstatement',
    v_breach.source_table,
    v_breach.source_id,
    'review-regression-duplicate-2',
    jsonb_build_object('test_fixture', 'duplicate_current_export_claim_v1'),
    jsonb_build_object('prior_breach_id', v_breach.id),
    1,
    'decrease',
    v_breach.amount_gbp,
    v_breach.vat_amount_gbp,
    'review_regression_only',
    GREATEST(v_run.period_start_date, v_breach_period_end + 1),
    v_run.return_period_label,
    false,
    true,
    'Rollback-only review regression fixture.',
    'active'
  );

  PERFORM public.staff_finalize_vat_return_integrity_v1(v_run.id);

  SELECT count(*)
  INTO v_active_count
  FROM public.vat_return_run_lines
  WHERE id IN (v_reinstatement_1, v_reinstatement_2)
    AND status = 'active';

  SELECT count(*)
  INTO v_superseded_count
  FROM public.vat_return_run_lines
  WHERE id IN (v_reinstatement_1, v_reinstatement_2)
    AND status = 'superseded'
    AND prior_vat_return_line_id IS NULL;

  SELECT count(*)
  INTO v_blocker_count
  FROM public.vat_return_blockers
  WHERE vat_return_run_id = v_run.id
    AND status = 'open'
    AND blocker_code = 'vat_export_reinstatement_prior_breach_already_reversed_v1'
    AND source_id = v_breach.source_id
    AND source_ref IN (
      'review-regression-duplicate-1',
      'review-regression-duplicate-2'
    );

  IF v_active_count <> 0 THEN
    RAISE EXCEPTION 'Competing reinstatements remained active: %', v_active_count;
  END IF;

  IF v_superseded_count <> 2 THEN
    RAISE EXCEPTION 'Expected two safely superseded competing reinstatements, found %', v_superseded_count;
  END IF;

  IF v_blocker_count <> 2 THEN
    RAISE EXCEPTION 'Expected two exact conflict blockers, found %', v_blocker_count;
  END IF;
END $$;

ROLLBACK;
