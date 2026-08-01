-- =============================================================================
-- VAT integrity, evidence and atomic Sage posting v1 regression checks
-- Governing addendum:
-- docs/governing-pack/architecture/
-- VAT_RETURN_INTEGRITY_EVIDENCE_AND_ATOMIC_SAGE_POSTING_ADDENDUM_v1.md
--
-- Safe characteristics:
--   * transaction rolls back;
--   * no locked or superseded VAT return is mutated;
--   * live mutation checks run only when a suitable editable/test row exists;
--   * installation assertions always run.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

DO $$
BEGIN
  IF to_regprocedure('public.staff_finalize_vat_return_integrity_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_finalize_vat_return_integrity_v1';
  END IF;
  IF to_regprocedure('public.staff_refresh_vat_return_source_snapshot_v2(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_refresh_vat_return_source_snapshot_v2';
  END IF;
  IF to_regprocedure(
    'public.staff_record_vat_sage_submission_and_lock_v2(uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamp with time zone,text,jsonb,numeric,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Missing staff_record_vat_sage_submission_and_lock_v2';
  END IF;
  IF to_regprocedure('public.staff_claim_vat_adjustment_journal_post_v1(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_claim_vat_adjustment_journal_post_v1';
  END IF;
END $$;

DO $$
DECLARE
  v_public boolean;
BEGIN
  SELECT b.public INTO v_public
  FROM storage.buckets b
  WHERE b.id = 'vat-return-evidence';

  IF v_public IS NULL THEN
    RAISE EXCEPTION 'vat-return-evidence bucket missing';
  END IF;
  IF v_public THEN
    RAISE EXCEPTION 'vat-return-evidence bucket must be private';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_vat_export_reinstatement_active_prior_line_v1'
      AND indexdef ILIKE '%prior_vat_return_line_id%'
      AND indexdef ILIKE '%box1_export_evidence_reinstatement%'
      AND indexdef ILIKE '%status = ''active''%'
  ) THEN
    RAISE EXCEPTION 'Active export reinstatement uniqueness index missing or malformed';
  END IF;
END $$;

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.staff_finalize_vat_return_integrity_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute the VAT integrity finaliser';
  END IF;
  IF has_function_privilege('authenticated', 'public.staff_finalize_vat_return_integrity_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must not directly execute the VAT integrity finaliser';
  END IF;
  IF has_function_privilege('authenticated', 'public.staff_claim_vat_adjustment_journal_post_v1(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must not execute the service-role Sage claim';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.staff_refresh_vat_return_source_snapshot_v2(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must execute refresh v2; the function performs its own admin check';
  END IF;
END $$;

-- No active reinstatement may point to the same prior breach twice.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.vat_return_run_lines
    WHERE line_kind = 'box1_export_evidence_reinstatement'
      AND status = 'active'
      AND prior_vat_return_line_id IS NOT NULL
    GROUP BY prior_vat_return_line_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate active export reinstatement links detected';
  END IF;
END $$;

-- All finaliser-owned active lines must have exact funding-event provenance and
-- must not coexist with a non-void positive main/supplementary invoice.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.vat_return_run_lines l
    LEFT JOIN public.order_funding_events fe
      ON l.source_table = 'order_funding_events'
     AND l.source_id = fe.id
    WHERE l.line_kind = 'box6_uninvoiced_order_funding'
      AND l.status = 'active'
      AND (
        fe.id IS NULL
        OR l.box_number IS DISTINCT FROM 6
        OR l.vat_amount_gbp IS DISTINCT FROM 0
        OR EXISTS (
          SELECT 1
          FROM public.sales_invoices si
          WHERE si.order_id = fe.order_id
            AND COALESCE(si.sage_status, '') <> 'void'
            AND lower(COALESCE(si.invoice_type, '')) IN ('main', 'supplementary')
            AND COALESCE(si.amount_gbp, 0) > 0
        )
      )
  ) THEN
    RAISE EXCEPTION 'Invalid active box6_uninvoiced_order_funding line detected';
  END IF;
END $$;

-- Idempotency/non-regression smoke test on one editable run, where available.
DO $$
DECLARE
  v_run_id uuid;
  v_before jsonb;
  v_after_first jsonb;
  v_after_second jsonb;
BEGIN
  SELECT r.id INTO v_run_id
  FROM public.vat_return_runs r
  WHERE r.locked_at IS NULL
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
  ORDER BY r.period_end_date DESC
  LIMIT 1;

  IF v_run_id IS NULL THEN
    RAISE NOTICE 'No editable VAT return available; finaliser idempotency smoke test skipped.';
    RETURN;
  END IF;

  SELECT jsonb_build_object(
    'box1', expected_box1_gbp,
    'box2', expected_box2_gbp,
    'box3', expected_box3_gbp,
    'box4', expected_box4_gbp,
    'box5', expected_box5_gbp,
    'box6', expected_box6_gbp,
    'box7', expected_box7_gbp,
    'active_lines', (
      SELECT count(*)
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = v_run_id
        AND l.status = 'active'
    )
  ) INTO v_before
  FROM public.vat_return_runs
  WHERE id = v_run_id;

  PERFORM public.staff_finalize_vat_return_integrity_v1(v_run_id);

  SELECT jsonb_build_object(
    'box1', expected_box1_gbp,
    'box2', expected_box2_gbp,
    'box3', expected_box3_gbp,
    'box4', expected_box4_gbp,
    'box5', expected_box5_gbp,
    'box6', expected_box6_gbp,
    'box7', expected_box7_gbp,
    'owned_lines', (
      SELECT count(*)
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = v_run_id
        AND l.status = 'active'
        AND l.line_kind = 'box6_uninvoiced_order_funding'
    ),
    'owned_blockers', (
      SELECT count(*)
      FROM public.vat_return_blockers b
      WHERE b.vat_return_run_id = v_run_id
        AND b.status = 'open'
        AND b.blocker_code IN (
          'vat_box6_negative_uninvoiced_funding_balance_v1',
          'vat_export_reinstatement_missing_prior_breach_v1',
          'vat_export_reinstatement_ambiguous_prior_breach_v1',
          'vat_export_reinstatement_prior_breach_already_reversed_v1'
        )
    )
  ) INTO v_after_first
  FROM public.vat_return_runs
  WHERE id = v_run_id;

  PERFORM public.staff_finalize_vat_return_integrity_v1(v_run_id);

  SELECT jsonb_build_object(
    'box1', expected_box1_gbp,
    'box2', expected_box2_gbp,
    'box3', expected_box3_gbp,
    'box4', expected_box4_gbp,
    'box5', expected_box5_gbp,
    'box6', expected_box6_gbp,
    'box7', expected_box7_gbp,
    'owned_lines', (
      SELECT count(*)
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = v_run_id
        AND l.status = 'active'
        AND l.line_kind = 'box6_uninvoiced_order_funding'
    ),
    'owned_blockers', (
      SELECT count(*)
      FROM public.vat_return_blockers b
      WHERE b.vat_return_run_id = v_run_id
        AND b.status = 'open'
        AND b.blocker_code IN (
          'vat_box6_negative_uninvoiced_funding_balance_v1',
          'vat_export_reinstatement_missing_prior_breach_v1',
          'vat_export_reinstatement_ambiguous_prior_breach_v1',
          'vat_export_reinstatement_prior_breach_already_reversed_v1'
        )
    )
  ) INTO v_after_second
  FROM public.vat_return_runs
  WHERE id = v_run_id;

  IF v_after_first IS DISTINCT FROM v_after_second THEN
    RAISE EXCEPTION 'Finaliser is not idempotent. First %, second %', v_after_first, v_after_second;
  END IF;

  RAISE NOTICE 'Finaliser idempotency passed for run %. Before %, after %', v_run_id, v_before, v_after_second;
END $$;

-- Atomic claim smoke test on one suitable journal, where available. The whole
-- transaction rolls back, so the journal is not left claimed.
DO $$
DECLARE
  v_journal_id uuid;
  v_staff_id uuid;
  v_first jsonb;
  v_second jsonb;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.active = true
    AND s.role_type = 'admin'
  ORDER BY s.id
  LIMIT 1;

  SELECT j.id INTO v_journal_id
  FROM public.vat_return_adjustment_journals j
  JOIN public.vat_return_runs r ON r.id = j.vat_return_run_id
  WHERE j.status = 'admin_approved'
    AND NULLIF(btrim(COALESCE(j.sage_journal_id, '')), '') IS NULL
    AND r.status = 'admin_approved'
    AND r.locked_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.vat_return_blockers b
      WHERE b.vat_return_run_id = r.id
        AND b.status = 'open'
        AND b.severity = 'blocker'
    )
  ORDER BY j.created_at
  LIMIT 1;

  IF v_staff_id IS NULL OR v_journal_id IS NULL THEN
    RAISE NOTICE 'No suitable admin-approved journal; atomic claim smoke test skipped.';
    RETURN;
  END IF;

  v_first := public.staff_claim_vat_adjustment_journal_post_v1(v_journal_id, v_staff_id);
  v_second := public.staff_claim_vat_adjustment_journal_post_v1(v_journal_id, v_staff_id);

  IF COALESCE((v_first->>'claimed')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'First claim did not succeed: %', v_first;
  END IF;
  IF COALESCE((v_second->>'claimed')::boolean, false) IS NOT FALSE THEN
    RAISE EXCEPTION 'Second claim unexpectedly succeeded: %', v_second;
  END IF;
END $$;

ROLLBACK;
