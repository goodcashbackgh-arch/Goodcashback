-- VAT adjustment multi-source idempotency regression v1
-- Rollback-only. Verifies that rematerialising the same proposal reuses the
-- existing journal and retains exactly two journal lines and two allocations.

BEGIN;

DO $test$
DECLARE
  v_admin_auth_user_id uuid;
  v_admin_staff_id uuid;
  v_run_id uuid := gen_random_uuid();
  v_source_60 uuid := gen_random_uuid();
  v_source_40 uuid := gen_random_uuid();
  v_period_start date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_period_end date := (date_trunc('month', current_date) - interval '1 day')::date;
  v_first jsonb;
  v_second jsonb;
  v_first_journal_id uuid;
  v_second_journal_id uuid;
  v_count integer;
  v_total numeric(18,2);
BEGIN
  SELECT s.auth_user_id, s.id
  INTO v_admin_auth_user_id, v_admin_staff_id
  FROM public.staff s
  WHERE s.active = true
    AND s.role_type = 'admin'
    AND s.auth_user_id IS NOT NULL
  ORDER BY s.created_at
  LIMIT 1;

  IF v_admin_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Regression requires one active admin staff auth user.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_admin_auth_user_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  UPDATE public.vat_return_runs
  SET status = 'superseded', updated_at = now()
  WHERE status NOT IN ('matched_to_sage_locked', 'superseded');

  INSERT INTO public.vat_return_runs (
    id, run_ref, return_period_label, period_start_date, period_end_date,
    status, generated_by_staff_id, generated_by_auth_user_id, expected_box6_gbp
  ) VALUES (
    v_run_id,
    'VAT-MULTI-SOURCE-IDEMPOTENCY-' || replace(v_run_id::text, '-', ''),
    'Multi-source idempotency fixture ' || to_char(v_period_start, 'YYYY-MM'),
    v_period_start,
    v_period_end,
    'calculated',
    v_admin_staff_id,
    v_admin_auth_user_id,
    100.00
  );

  INSERT INTO public.vat_return_sage_reconstruction_snapshots (
    vat_return_run_id, period_start_date, period_end_date, status,
    source_basis, box6_gbp, created_by_staff_id
  ) VALUES (
    v_run_id, v_period_start, v_period_end, 'reconstructed',
    'rollback_idempotency_fixture', 0.00, v_admin_staff_id
  );

  INSERT INTO public.vat_return_run_lines (
    id, vat_return_run_id, line_kind, source_table, source_ref,
    source_json, source_lineage_json, box_number, direction,
    amount_gbp, vat_amount_gbp, vat_basis, tax_point_date,
    return_period_label, natural_sage_covered, adjustment_required,
    adjustment_reason, status
  ) VALUES
  (
    v_source_60, v_run_id, 'uninvoiced_funding', 'regression_fixture',
    'IDEMPOTENCY-60', jsonb_build_object('fixture', true, 'amount', 60),
    jsonb_build_object('fixture', true), 6, 'natural', 60.00, 0.00,
    'net', v_period_end, 'Multi-source idempotency fixture', false, true,
    'Regression multi-source Box 6 adjustment', 'active'
  ),
  (
    v_source_40, v_run_id, 'uninvoiced_funding', 'regression_fixture',
    'IDEMPOTENCY-40', jsonb_build_object('fixture', true, 'amount', 40),
    jsonb_build_object('fixture', true), 6, 'natural', 40.00, 0.00,
    'net', v_period_end, 'Multi-source idempotency fixture', false, true,
    'Regression multi-source Box 6 adjustment', 'active'
  );

  v_first := public.staff_materialise_vat_adjustment_journal_proposals_v2(v_run_id, 0.01);
  v_second := public.staff_materialise_vat_adjustment_journal_proposals_v2(v_run_id, 0.01);

  IF (v_first ->> 'created_count')::integer <> 1
     OR (v_second ->> 'created_count')::integer <> 1 THEN
    RAISE EXCEPTION 'Each materialisation should resolve one journal. First %, second %', v_first, v_second;
  END IF;

  v_first_journal_id := (v_first #>> '{journals,0,journal_id}')::uuid;
  v_second_journal_id := (v_second #>> '{journals,0,journal_id}')::uuid;

  IF v_first_journal_id IS NULL OR v_second_journal_id IS NULL
     OR v_first_journal_id <> v_second_journal_id THEN
    RAISE EXCEPTION 'Idempotent rerun did not reuse the same journal. First %, second %',
      v_first_journal_id, v_second_journal_id;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vat_return_adjustment_journals
  WHERE vat_return_run_id = v_run_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one journal after two materialisations, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_first_journal_id;

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Expected exactly two journal lines after rerun, got %', v_count;
  END IF;

  SELECT count(*), round(sum(allocated_amount_gbp), 2)
  INTO v_count, v_total
  FROM public.vat_return_adjustment_journal_source_allocations
  WHERE vat_return_adjustment_journal_id = v_first_journal_id;

  IF v_count <> 2 OR v_total <> 100.00 THEN
    RAISE EXCEPTION 'Expected two allocations totalling £100 after rerun; count %, total %',
      v_count, v_total;
  END IF;

  RAISE NOTICE 'PASS: second materialisation reused journal %.', v_first_journal_id;
  RAISE NOTICE 'PASS: rerun retained one journal, two lines and two allocations totalling £100.';
END;
$test$;

ROLLBACK;
