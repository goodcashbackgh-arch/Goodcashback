-- VAT adjustment multi-source allocation regression v1
-- Rollback-only. Creates synthetic VAT workbench rows, makes no Sage request,
-- and leaves no persistent data. Existing open VAT runs are temporarily
-- marked superseded inside this transaction so sequence enforcement can admit the fixture.

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
  v_preview jsonb;
  v_materialised jsonb;
  v_journal_id uuid;
  v_count integer;
  v_total numeric(18,2);
  v_hash text;
  v_failed boolean;
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

  -- The sequence trigger ignores locked_at and only treats these two statuses
  -- as closed. Changes are transaction-local because the script ends ROLLBACK.
  UPDATE public.vat_return_runs
  SET status = 'superseded',
      updated_at = now()
  WHERE status NOT IN ('matched_to_sage_locked', 'superseded');

  INSERT INTO public.vat_return_runs (
    id, run_ref, return_period_label, period_start_date, period_end_date,
    status, generated_by_staff_id, generated_by_auth_user_id, expected_box6_gbp
  ) VALUES (
    v_run_id,
    'VAT-MULTI-SOURCE-REGRESSION-' || replace(v_run_id::text, '-', ''),
    'Multi-source rollback fixture ' || to_char(v_period_start, 'YYYY-MM'),
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
    'rollback_regression_fixture', 0.00, v_admin_staff_id
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
    'MULTI-SOURCE-60', jsonb_build_object('fixture', true, 'amount', 60),
    jsonb_build_object('fixture', true), 6, 'natural', 60.00, 0.00,
    'net', v_period_end, 'Multi-source rollback fixture', false, true,
    'Regression multi-source Box 6 adjustment', 'active'
  ),
  (
    v_source_40, v_run_id, 'uninvoiced_funding', 'regression_fixture',
    'MULTI-SOURCE-40', jsonb_build_object('fixture', true, 'amount', 40),
    jsonb_build_object('fixture', true), 6, 'natural', 40.00, 0.00,
    'net', v_period_end, 'Multi-source rollback fixture', false, true,
    'Regression multi-source Box 6 adjustment', 'active'
  );

  v_preview := public.staff_preview_vat_adjustment_journal_proposals_v2(v_run_id, 0.01);

  IF (v_preview ->> 'blocker_count')::integer <> 0 THEN
    RAISE EXCEPTION 'Expected no preview blockers, got %', v_preview -> 'blockers';
  END IF;

  IF (v_preview ->> 'proposal_count')::integer <> 1
     OR (v_preview #>> '{proposals,0,source_count}')::integer <> 2
     OR round((v_preview #>> '{proposals,0,amount_gbp}')::numeric, 2) <> 100.00 THEN
    RAISE EXCEPTION 'Preview did not produce one £100 proposal with two sources: %', v_preview;
  END IF;

  SELECT round(sum((x ->> 'allocated_amount_gbp')::numeric), 2)
  INTO v_total
  FROM jsonb_array_elements(v_preview #> '{proposals,0,source_allocations}') x;

  IF v_total <> 100.00 THEN
    RAISE EXCEPTION 'Expected preview allocation total £100, got %', v_total;
  END IF;

  v_materialised := public.staff_materialise_vat_adjustment_journal_proposals_v2(v_run_id, 0.01);

  IF (v_materialised ->> 'created_count')::integer <> 1 THEN
    RAISE EXCEPTION 'Expected one materialised journal, got %', v_materialised;
  END IF;

  v_journal_id := (v_materialised #>> '{journals,0,journal_id}')::uuid;

  SELECT count(*), round(sum(allocated_amount_gbp), 2)
  INTO v_count, v_total
  FROM public.vat_return_adjustment_journal_source_allocations
  WHERE vat_return_adjustment_journal_id = v_journal_id;

  IF v_count <> 2 OR v_total <> 100.00 THEN
    RAISE EXCEPTION 'Expected two allocations totalling £100; count %, total %', v_count, v_total;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vat_return_adjustment_journal_lines
  WHERE vat_return_adjustment_journal_id = v_journal_id;

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Expected exactly two accounting lines, got %', v_count;
  END IF;

  SELECT source_allocation_hash INTO v_hash
  FROM public.vat_return_adjustment_journals
  WHERE id = v_journal_id;

  IF NULLIF(trim(COALESCE(v_hash, '')), '') IS NULL
     OR v_hash <> public.internal_vat_adjustment_allocation_hash_v1(v_journal_id) THEN
    RAISE EXCEPTION 'Allocation hash missing or inconsistent.';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vat_return_adjustment_journals
  WHERE id = v_journal_id
    AND sage_journal_id IS NULL
    AND posted_at IS NULL
    AND status = 'platform_calculated';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Materialisation must not post to Sage or advance posting status.';
  END IF;

  UPDATE public.vat_return_adjustment_journals
  SET source_allocation_hash = repeat('0', 64)
  WHERE id = v_journal_id;

  v_failed := false;
  BEGIN
    UPDATE public.vat_return_adjustment_journals
    SET status = 'admin_approved'
    WHERE id = v_journal_id;
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected approval guard to reject an invalid allocation hash.';
  END IF;

  UPDATE public.vat_return_adjustment_journals
  SET source_allocation_hash = public.internal_vat_adjustment_allocation_hash_v1(v_journal_id)
  WHERE id = v_journal_id;

  UPDATE public.vat_return_adjustment_journals
  SET status = 'admin_approved'
  WHERE id = v_journal_id;

  v_failed := false;
  BEGIN
    UPDATE public.vat_return_adjustment_journal_source_allocations
    SET allocated_amount_gbp = allocated_amount_gbp + 0.01
    WHERE vat_return_adjustment_journal_id = v_journal_id
      AND vat_return_run_line_id = v_source_60;
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected approved allocation mutation to be rejected.';
  END IF;

  RAISE NOTICE 'PASS: £60 + £40 became one £100 journal with two allocations.';
  RAISE NOTICE 'PASS: journal retained exactly two accounting lines and made no Sage post.';
  RAISE NOTICE 'PASS: invalid allocation hash blocked approval and approved allocations were immutable.';
END;
$test$;

ROLLBACK;
