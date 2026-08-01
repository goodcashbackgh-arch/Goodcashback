-- VAT adjustment multi-source negative regression v1
-- Rollback-only. Verifies over-allocation and incompatible-source rejection,
-- and confirms a legacy single-source journal remains outside multi_source_v1.

BEGIN;

DO $test$
DECLARE
  v_admin_auth_user_id uuid;
  v_admin_staff_id uuid;
  v_run_id uuid := gen_random_uuid();
  v_source_60 uuid := gen_random_uuid();
  v_source_40 uuid := gen_random_uuid();
  v_bad_source uuid := gen_random_uuid();
  v_legacy_journal_id uuid := gen_random_uuid();
  v_period_start date := (date_trunc('month', current_date) - interval '1 month')::date;
  v_period_end date := (date_trunc('month', current_date) - interval '1 day')::date;
  v_materialised jsonb;
  v_journal_id uuid;
  v_failed boolean;
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
    'VAT-MULTI-SOURCE-NEGATIVE-' || replace(v_run_id::text, '-', ''),
    'Multi-source negative rollback fixture ' || to_char(v_period_start, 'YYYY-MM'),
    v_period_start, v_period_end, 'calculated',
    v_admin_staff_id, v_admin_auth_user_id, 100.00
  );

  INSERT INTO public.vat_return_sage_reconstruction_snapshots (
    vat_return_run_id, period_start_date, period_end_date, status,
    source_basis, box6_gbp, created_by_staff_id
  ) VALUES (
    v_run_id, v_period_start, v_period_end, 'reconstructed',
    'rollback_negative_fixture', 0.00, v_admin_staff_id
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
    'NEGATIVE-60', '{}'::jsonb, '{}'::jsonb, 6, 'natural', 60.00, 0.00,
    'net', v_period_end, 'Negative rollback fixture', false, true,
    'Regression source', 'active'
  ),
  (
    v_source_40, v_run_id, 'uninvoiced_funding', 'regression_fixture',
    'NEGATIVE-40', '{}'::jsonb, '{}'::jsonb, 6, 'natural', 40.00, 0.00,
    'net', v_period_end, 'Negative rollback fixture', false, true,
    'Regression source', 'active'
  ),
  (
    v_bad_source, v_run_id, 'uninvoiced_funding', 'regression_fixture',
    'NEGATIVE-BAD-BOX', '{}'::jsonb, '{}'::jsonb, 7, 'natural', 100.00, 0.00,
    'net', v_period_end, 'Negative rollback fixture', false, true,
    'Regression incompatible source', 'active'
  );

  -- Synthetic legacy journal: source_allocation_version/hash intentionally null.
  INSERT INTO public.vat_return_adjustment_journals (
    id, vat_return_run_id, vat_return_run_line_id, adjustment_type,
    target_box, direction, amount_gbp, status, idempotency_key,
    endpoint_path, method, request_payload, source_allocation_version,
    source_allocation_hash, created_at, updated_at
  ) VALUES (
    v_legacy_journal_id, v_run_id, v_source_60,
    'box6_output_net_prepayment_adjustment', 6, 'increase', 60.00,
    'platform_calculated',
    'legacy-negative-regression-' || replace(v_legacy_journal_id::text, '-', ''),
    '/journals', 'POST', jsonb_build_object('legacy_fixture', true),
    NULL, NULL, now(), now()
  );

  v_materialised := public.staff_materialise_vat_adjustment_journal_proposals_v2(v_run_id, 0.01);
  v_journal_id := (v_materialised #>> '{journals,0,journal_id}')::uuid;

  IF v_journal_id IS NULL THEN
    RAISE EXCEPTION 'Expected a materialised multi-source journal: %', v_materialised;
  END IF;

  -- Reject over-allocation: source 60 cannot receive 61, even when total remains 100.
  v_failed := false;
  BEGIN
    PERFORM public.staff_replace_vat_adjustment_source_allocations_v1(
      v_journal_id,
      jsonb_build_array(
        jsonb_build_object('vat_return_run_line_id', v_source_60, 'allocated_amount_gbp', 61.00),
        jsonb_build_object('vat_return_run_line_id', v_source_40, 'allocated_amount_gbp', 39.00)
      )
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected over-allocation to be rejected.';
  END IF;

  -- Reject a source from the wrong VAT box.
  v_failed := false;
  BEGIN
    PERFORM public.staff_replace_vat_adjustment_source_allocations_v1(
      v_journal_id,
      jsonb_build_array(
        jsonb_build_object('vat_return_run_line_id', v_bad_source, 'allocated_amount_gbp', 100.00)
      )
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected incompatible box/direction source to be rejected.';
  END IF;

  -- Failed replacements must leave the valid allocation set intact.
  SELECT count(*), round(sum(allocated_amount_gbp), 2)
  INTO v_count, v_total
  FROM public.vat_return_adjustment_journal_source_allocations
  WHERE vat_return_adjustment_journal_id = v_journal_id;

  IF v_count <> 2 OR v_total <> 100.00 THEN
    RAISE EXCEPTION 'Failed allocation attempts corrupted valid allocations; count %, total %.',
      v_count, v_total;
  END IF;

  -- Legacy single-source journal remains outside multi-source governance.
  SELECT count(*) INTO v_count
  FROM public.vat_return_adjustment_journals
  WHERE id = v_legacy_journal_id
    AND vat_return_run_line_id = v_source_60
    AND source_allocation_version IS NULL
    AND source_allocation_hash IS NULL
    AND status = 'platform_calculated';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Legacy single-source journal was unexpectedly converted or modified.';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.vat_return_adjustment_journal_source_allocations
  WHERE vat_return_adjustment_journal_id = v_legacy_journal_id;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Legacy single-source journal unexpectedly received allocation rows.';
  END IF;

  RAISE NOTICE 'PASS: source over-allocation was rejected.';
  RAISE NOTICE 'PASS: incompatible source box/direction was rejected.';
  RAISE NOTICE 'PASS: failed replacements preserved the valid two-source allocation set.';
  RAISE NOTICE 'PASS: legacy single-source journal remained unchanged and unversioned.';
END;
$test$;

ROLLBACK;
