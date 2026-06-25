BEGIN;

-- Relax bulk completion-loyalty destination-IN release from exact-only to sufficient-IN.
-- Accounting rule: loyalty consumes only the selected GBP pot. Any excess remains on the DVA/card IN line.
-- No loyalty FX/card residual is created by this release.
-- Bulk per-row variance is forced to 0 after release because any excess is aggregate remaining statement-line balance, not per-reward FX.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.main_bank_shipper_ap_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_shipper_ap_allocations'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.dva_reconciliation') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_reconciliation'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing public.staff'; END IF;
  IF to_regprocedure('public.staff_pair_loyalty_destination_in_and_release_v1(uuid, uuid, text)') IS NULL THEN RAISE EXCEPTION 'Missing public.staff_pair_loyalty_destination_in_and_release_v1(uuid, uuid, text)'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_pair_loyalty_funding_pot_and_release_v1(
  p_loyalty_match_ids uuid[],
  p_destination_in_statement_line_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_match_ids uuid[];
  v_match_count integer := 0;
  v_found_count integer := 0;
  v_bad_match_id uuid;
  v_distinct_importers integer := 0;
  v_distinct_source_outs integer := 0;
  v_importer_id uuid;
  v_source_out_statement_line_id uuid;
  v_total_amount numeric(18,2) := 0;
  v_dest record;
  v_source_line record;
  v_existing_dest_consumed numeric(18,2) := 0;
  v_remaining_dest numeric(18,2) := 0;
  v_destination_excess_gbp numeric(18,2) := 0;
  v_shipper_allocated numeric(18,2) := 0;
  v_residual_allocated numeric(18,2) := 0;
  v_source_loyalty_allocated numeric(18,2) := 0;
  v_source_remaining_after_allocations numeric(18,2) := 0;
  v_match_id uuid;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: bulk loyalty funding-pot release requires auth.uid()'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Only admin or supervisor staff can bulk-release completion loyalty funding pots.'; END IF;

  SELECT array_agg(DISTINCT item ORDER BY item) INTO v_match_ids
  FROM unnest(COALESCE(p_loyalty_match_ids, ARRAY[]::uuid[])) AS item
  WHERE item IS NOT NULL;

  v_match_count := COALESCE(array_length(v_match_ids, 1), 0);
  IF v_match_count < 2 THEN
    RAISE EXCEPTION 'Bulk funding-pot release requires at least two selected loyalty matches. Use the single-row release for one match.';
  END IF;

  PERFORM 1
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = ANY(v_match_ids)
  FOR UPDATE;

  SELECT count(*)::integer INTO v_found_count
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = ANY(v_match_ids);

  IF v_found_count <> v_match_count THEN
    RAISE EXCEPTION 'One or more selected loyalty matches could not be found.';
  END IF;

  SELECT lm.id INTO v_bad_match_id
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = ANY(v_match_ids)
    AND NOT (
      lm.match_status = 'confirmed'
      AND COALESCE(lm.transfer_pair_status, 'source_out_reserved') IN ('source_out_reserved','paired_ready_to_release')
      AND lm.destination_in_statement_line_id IS NULL
      AND lm.funding_confirmation_id IS NULL
      AND lm.credit_ledger_id IS NULL
    )
  ORDER BY lm.created_at DESC, lm.id DESC
  LIMIT 1;

  IF v_bad_match_id IS NOT NULL THEN
    RAISE EXCEPTION 'Selected loyalty match % is not an unpaired staged OUT row and cannot be bulk released.', v_bad_match_id;
  END IF;

  SELECT
    count(DISTINCT lm.importer_id)::integer,
    count(DISTINCT lm.dva_statement_line_id)::integer,
    (array_agg(DISTINCT lm.importer_id) FILTER (WHERE lm.importer_id IS NOT NULL))[1],
    (array_agg(DISTINCT lm.dva_statement_line_id) FILTER (WHERE lm.dva_statement_line_id IS NOT NULL))[1],
    round(COALESCE(sum(lm.matched_gbp_amount), 0)::numeric, 2)
  INTO v_distinct_importers, v_distinct_source_outs, v_importer_id, v_source_out_statement_line_id, v_total_amount
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = ANY(v_match_ids);

  IF v_distinct_importers <> 1 OR v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Bulk funding-pot release requires all selected rewards to belong to one importer.';
  END IF;

  IF v_distinct_source_outs <> 1 OR v_source_out_statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Bulk funding-pot release requires all selected rewards to use the same reserved main-bank OUT line.';
  END IF;

  IF v_total_amount <= 0 THEN
    RAISE EXCEPTION 'Bulk funding-pot release total must be greater than zero.';
  END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.reference_raw,
    dsl.statement_date,
    ds.importer_id,
    ds.statement_account_context,
    ds.statement_account_label,
    ds.source_bank
  INTO v_dest
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_destination_in_statement_line_id
  FOR UPDATE OF dsl;

  IF v_dest.id IS NULL THEN RAISE EXCEPTION 'Destination IN statement line not found: %', p_destination_in_statement_line_id; END IF;
  IF COALESCE(v_dest.statement_account_context, 'importer_dva_card_account') <> 'importer_dva_card_account' THEN RAISE EXCEPTION 'Destination line must be an importer DVA/card/virtual-card account line.'; END IF;
  IF COALESCE(v_dest.direction, '') <> 'in' THEN RAISE EXCEPTION 'Destination line % is direction %, expected IN.', p_destination_in_statement_line_id, v_dest.direction; END IF;
  IF v_dest.importer_id IS DISTINCT FROM v_importer_id THEN RAISE EXCEPTION 'Destination importer % does not match loyalty importer %.', v_dest.importer_id, v_importer_id; END IF;

  SELECT round(COALESCE(sum(x.consumed_gbp), 0)::numeric, 2)
    INTO v_existing_dest_consumed
  FROM (
    SELECT COALESCE(sum(dr.reconciled_gbp_amount), 0)::numeric AS consumed_gbp
    FROM public.dva_reconciliation dr
    WHERE dr.dva_statement_line_id = p_destination_in_statement_line_id
    UNION ALL
    SELECT COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric AS consumed_gbp
    FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_destination_in_statement_line_id
    UNION ALL
    SELECT COALESCE(sum(lm.matched_gbp_amount) FILTER (WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit') AND NOT (lm.id = ANY(v_match_ids))), 0)::numeric AS consumed_gbp
    FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE lm.destination_in_statement_line_id = p_destination_in_statement_line_id
  ) x;

  v_remaining_dest := greatest(round((COALESCE(v_dest.amount_gbp_equivalent, 0) - COALESCE(v_existing_dest_consumed, 0))::numeric, 2), 0::numeric);

  IF v_total_amount > v_remaining_dest + 0.01 THEN
    RAISE EXCEPTION 'Destination IN line remaining % is less than selected loyalty pot total %.', v_remaining_dest, v_total_amount;
  END IF;

  v_destination_excess_gbp := round((v_remaining_dest - v_total_amount)::numeric, 2);

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.reference_raw,
    dsl.statement_date,
    ds.statement_account_context,
    ds.statement_account_label,
    ds.source_bank
  INTO v_source_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = v_source_out_statement_line_id
  FOR UPDATE OF dsl;

  IF v_source_line.id IS NULL THEN RAISE EXCEPTION 'Source OUT statement line not found: %', v_source_out_statement_line_id; END IF;
  IF COALESCE(v_source_line.statement_account_context, '') <> 'main_company_bank_account' THEN RAISE EXCEPTION 'Source line is not from the main company bank account.'; END IF;
  IF COALESCE(v_source_line.direction, '') <> 'out' THEN RAISE EXCEPTION 'Source line % is direction %, expected OUT.', v_source_out_statement_line_id, v_source_line.direction; END IF;

  SELECT round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2)
    INTO v_shipper_allocated
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.dva_statement_line_id = v_source_out_statement_line_id;

  SELECT round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type IN ('fx_card_difference','bank_fee','unmatched_hold')), 0)::numeric, 2)
    INTO v_residual_allocated
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = v_source_out_statement_line_id;

  SELECT round(COALESCE(sum(lm.matched_gbp_amount) FILTER (WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit')), 0)::numeric, 2)
    INTO v_source_loyalty_allocated
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.dva_statement_line_id = v_source_out_statement_line_id;

  v_source_remaining_after_allocations := round((COALESCE(v_source_line.amount_gbp_equivalent, 0) - COALESCE(v_shipper_allocated, 0) - COALESCE(v_residual_allocated, 0) - COALESCE(v_source_loyalty_allocated, 0))::numeric, 2);

  IF v_source_remaining_after_allocations < -0.01 THEN
    RAISE EXCEPTION 'Source OUT line is over-allocated by %. Resolve source line allocations before bulk release.', abs(v_source_remaining_after_allocations);
  END IF;

  FOREACH v_match_id IN ARRAY v_match_ids LOOP
    v_result := public.staff_pair_loyalty_destination_in_and_release_v1(
      v_match_id,
      p_destination_in_statement_line_id,
      concat_ws(E'\n', NULLIF(p_notes, ''), 'Bulk same-importer completion-loyalty funding-pot release. Sufficient-IN release consumes only the selected loyalty pot amount; any excess remains on the DVA/card line. Per-reward variance is not used for bulk accounting.')
    );
    v_results := v_results || jsonb_build_array(v_result);
  END LOOP;

  -- The single-row release function records variance per reward by comparing that reward with the full remaining IN.
  -- In a grouped sufficient-IN release that value is misleading, so force it to zero for the selected bulk rows.
  UPDATE public.main_bank_completion_loyalty_funding_matches lm
     SET variance_gbp = 0,
         notes = concat_ws(E'\n', lm.notes, 'Bulk sufficient-IN release: per-row variance zeroed; aggregate excess remains on the DVA/card statement line and is not loyalty FX.')
   WHERE lm.id = ANY(v_match_ids);

  RETURN jsonb_build_object(
    'ok', true,
    'bulk_release', true,
    'sufficient_in_release', true,
    'released_count', v_match_count,
    'released_total_gbp', v_total_amount,
    'importer_id', v_importer_id,
    'source_out_statement_line_id', v_source_out_statement_line_id,
    'destination_in_statement_line_id', p_destination_in_statement_line_id,
    'destination_remaining_before_gbp', v_remaining_dest,
    'destination_excess_after_release_gbp', v_destination_excess_gbp,
    'per_row_variance_gbp', 0,
    'results', v_results
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.staff_pair_loyalty_funding_pot_and_release_v1(uuid[], uuid, text) TO authenticated;

COMMENT ON FUNCTION public.staff_pair_loyalty_funding_pot_and_release_v1(uuid[], uuid, text) IS
'Bulk completion-loyalty release is backend-gated by importer, source OUT, and sufficient destination IN balance. The release consumes only the selected loyalty pot amount; any excess remains on the DVA/card line and is not loyalty FX. Per-row variance is zeroed for bulk rows.';

NOTIFY pgrst, 'reload schema';

COMMIT;
