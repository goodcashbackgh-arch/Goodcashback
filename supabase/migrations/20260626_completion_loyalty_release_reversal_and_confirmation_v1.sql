BEGIN;

-- Completion-loyalty release reversal and confirmation controls v1.
-- Locked scope:
-- - released but unapplied loyalty credits may be reset to before funding selection;
-- - wrong same-importer IN selections can be corrected before order application/Sage posting;
-- - single-row sufficient-IN excess is treated as unconsumed IN balance, not loyalty FX variance;
-- - no VAT, shipper AP, supplier AP, customer sales, residual, or Sage posting changes.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_reward_approvals'; END IF;
  IF to_regclass('public.completion_loyalty_reward_funding_confirmations') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_reward_funding_confirmations'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_events'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.dva_reconciliation') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_reconciliation'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing public.staff'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
  IF to_regprocedure('public.staff_confirm_completion_loyalty_reward_funding_v1(uuid,numeric,numeric,uuid,text,text)') IS NULL THEN RAISE EXCEPTION 'Missing public.staff_confirm_completion_loyalty_reward_funding_v1'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_release_reversal_candidates_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  loyalty_match_id uuid,
  reversal_group_key text,
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  source_out_statement_line_id uuid,
  source_out_reference text,
  source_out_date date,
  source_out_amount_gbp numeric,
  destination_in_statement_line_id uuid,
  destination_in_reference text,
  destination_in_date date,
  destination_in_amount_gbp numeric,
  matched_gbp_amount numeric,
  group_reward_count integer,
  group_released_gbp numeric,
  group_destination_excess_gbp numeric,
  variance_gbp numeric,
  credit_ledger_id uuid,
  funding_confirmation_id uuid,
  credit_application_debit_rows integer,
  order_funding_event_rows integer,
  can_reset_to_selection boolean,
  reversal_blocker text,
  created_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: completion-loyalty reversal candidates require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for completion-loyalty reversal candidates.'; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      lm.id AS loyalty_match_id,
      md5(concat_ws(':', lm.importer_id::text, lm.dva_statement_line_id::text, COALESCE(lm.destination_in_statement_line_id::text, ''))) AS reversal_group_key,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      lm.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      lm.dva_statement_line_id AS source_out_statement_line_id,
      src.reference_raw::text AS source_out_reference,
      src.statement_date AS source_out_date,
      round(COALESCE(src.amount_gbp_equivalent, 0)::numeric, 2) AS source_out_amount_gbp,
      lm.destination_in_statement_line_id,
      dst.reference_raw::text AS destination_in_reference,
      dst.statement_date AS destination_in_date,
      round(COALESCE(dst.amount_gbp_equivalent, 0)::numeric, 2) AS destination_in_amount_gbp,
      round(COALESCE(lm.matched_gbp_amount, 0)::numeric, 2) AS matched_gbp_amount,
      round(COALESCE(lm.variance_gbp, 0)::numeric, 2) AS variance_gbp,
      lm.credit_ledger_id,
      lm.funding_confirmation_id,
      lm.created_at,
      COALESCE(app.credit_application_debit_rows, 0)::integer AS credit_application_debit_rows,
      COALESCE(app.order_funding_event_rows, 0)::integer AS order_funding_event_rows
    FROM public.main_bank_completion_loyalty_funding_matches lm
    JOIN public.orders o ON o.id = lm.completed_order_id
    LEFT JOIN public.importers i ON i.id = lm.importer_id
    LEFT JOIN public.dva_statement_lines src ON src.id = lm.dva_statement_line_id
    LEFT JOIN public.dva_statement_lines dst ON dst.id = lm.destination_in_statement_line_id
    LEFT JOIN LATERAL (
      WITH debit_rows AS (
        SELECT d.id
        FROM public.importer_credit_ledger d
        WHERE d.direction = 'debit'
          AND (
            (COALESCE(d.source_table, '') = 'importer_credit_ledger' AND d.source_id = lm.credit_ledger_id)
            OR (COALESCE(d.source_entity_type, '') = 'importer_credit_ledger' AND d.source_entity_id = lm.credit_ledger_id)
          )
      )
      SELECT
        (SELECT count(*) FROM debit_rows)::integer AS credit_application_debit_rows,
        (
          SELECT count(*)
          FROM public.order_funding_events ofe
          JOIN debit_rows d ON d.id = ofe.source_entity_id
          WHERE ofe.event_type = 'credit_applied'
            AND ofe.source_entity_type = 'importer_credit_ledger'
        )::integer AS order_funding_event_rows
    ) app ON true
    WHERE lm.match_status = 'released_available_dashboard_credit'
      AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
      AND lm.credit_ledger_id IS NOT NULL
  ), enriched AS (
    SELECT
      b.*,
      count(*) OVER (PARTITION BY b.reversal_group_key)::integer AS group_reward_count,
      round(sum(b.matched_gbp_amount) OVER (PARTITION BY b.reversal_group_key)::numeric, 2) AS group_released_gbp,
      round(greatest(b.destination_in_amount_gbp - sum(b.matched_gbp_amount) OVER (PARTITION BY b.reversal_group_key), 0)::numeric, 2) AS group_destination_excess_gbp
    FROM base b
  ), filtered AS (
    SELECT e.*
    FROM enriched e
    WHERE v_search IS NULL
       OR lower(concat_ws(' ', e.order_ref, e.importer_name, e.source_out_reference, e.destination_in_reference, e.matched_gbp_amount::text, e.reversal_group_key)) LIKE '%' || v_search || '%'
  )
  SELECT
    f.loyalty_match_id,
    f.reversal_group_key,
    f.order_id,
    f.order_ref,
    f.importer_id,
    f.importer_name,
    f.source_out_statement_line_id,
    f.source_out_reference,
    f.source_out_date,
    f.source_out_amount_gbp,
    f.destination_in_statement_line_id,
    f.destination_in_reference,
    f.destination_in_date,
    f.destination_in_amount_gbp,
    f.matched_gbp_amount,
    f.group_reward_count,
    f.group_released_gbp,
    f.group_destination_excess_gbp,
    f.variance_gbp,
    f.credit_ledger_id,
    f.funding_confirmation_id,
    f.credit_application_debit_rows,
    f.order_funding_event_rows,
    (f.credit_application_debit_rows = 0 AND f.order_funding_event_rows = 0) AS can_reset_to_selection,
    CASE
      WHEN f.credit_application_debit_rows > 0 OR f.order_funding_event_rows > 0 THEN 'Credit already applied to an order; use later accounting correction lane.'
      ELSE NULL::text
    END AS reversal_blocker,
    f.created_at,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.created_at DESC NULLS LAST, f.order_ref DESC NULLS LAST, f.loyalty_match_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_reverse_completion_loyalty_release_to_selection_v1(
  p_loyalty_match_id uuid,
  p_reason text DEFAULT NULL,
  p_reverse_group boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_seed_match record;
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_match_ids uuid[];
  v_match_count integer := 0;
  v_credit_ids uuid[];
  v_confirmation_ids uuid[];
  v_approval_ids uuid[];
  v_debit_count integer := 0;
  v_event_count integer := 0;
  v_total_amount numeric(18,2) := 0;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: completion-loyalty release reversal requires auth.uid()'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Reversal reason is required.'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Only admin or supervisor staff can reverse completion-loyalty releases.'; END IF;

  SELECT lm.* INTO v_seed_match
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = p_loyalty_match_id
  FOR UPDATE;

  IF v_seed_match.id IS NULL THEN RAISE EXCEPTION 'Completion-loyalty funding match not found: %', p_loyalty_match_id; END IF;
  IF v_seed_match.match_status <> 'released_available_dashboard_credit' OR COALESCE(v_seed_match.transfer_pair_status, '') <> 'paired_released' THEN
    RAISE EXCEPTION 'Only paired/released completion-loyalty credits can be reset. Current status %, pair status %.', v_seed_match.match_status, v_seed_match.transfer_pair_status;
  END IF;
  IF v_seed_match.credit_ledger_id IS NULL OR v_seed_match.funding_confirmation_id IS NULL THEN
    RAISE EXCEPTION 'Released match % is missing credit/funding links and cannot use this reset path.', p_loyalty_match_id;
  END IF;

  IF COALESCE(p_reverse_group, true) THEN
    SELECT array_agg(lm.id ORDER BY lm.created_at, lm.id)
      INTO v_match_ids
    FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE lm.importer_id = v_seed_match.importer_id
      AND lm.dva_statement_line_id = v_seed_match.dva_statement_line_id
      AND lm.destination_in_statement_line_id = v_seed_match.destination_in_statement_line_id
      AND lm.match_status = 'released_available_dashboard_credit'
      AND COALESCE(lm.transfer_pair_status, '') = 'paired_released';
  ELSE
    v_match_ids := ARRAY[p_loyalty_match_id];
  END IF;

  v_match_count := COALESCE(array_length(v_match_ids, 1), 0);
  IF v_match_count <= 0 THEN RAISE EXCEPTION 'No released match rows were resolved for reversal.'; END IF;

  PERFORM 1
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = ANY(v_match_ids)
  FOR UPDATE;

  SELECT
    array_agg(DISTINCT lm.credit_ledger_id) FILTER (WHERE lm.credit_ledger_id IS NOT NULL),
    array_agg(DISTINCT lm.funding_confirmation_id) FILTER (WHERE lm.funding_confirmation_id IS NOT NULL),
    array_agg(DISTINCT lm.approval_id) FILTER (WHERE lm.approval_id IS NOT NULL),
    round(COALESCE(sum(lm.matched_gbp_amount), 0)::numeric, 2)
  INTO v_credit_ids, v_confirmation_ids, v_approval_ids, v_total_amount
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = ANY(v_match_ids);

  IF COALESCE(array_length(v_credit_ids, 1), 0) <> v_match_count THEN
    RAISE EXCEPTION 'All selected released matches must have one credit ledger id each before reset.';
  END IF;

  PERFORM 1 FROM public.importer_credit_ledger c WHERE c.id = ANY(v_credit_ids) FOR UPDATE;
  PERFORM 1 FROM public.completion_loyalty_reward_funding_confirmations c WHERE c.id = ANY(v_confirmation_ids) FOR UPDATE;
  PERFORM 1 FROM public.completion_loyalty_reward_approvals a WHERE a.id = ANY(v_approval_ids) FOR UPDATE;

  WITH debit_rows AS (
    SELECT d.id
    FROM public.importer_credit_ledger d
    WHERE d.direction = 'debit'
      AND (
        (COALESCE(d.source_table, '') = 'importer_credit_ledger' AND d.source_id = ANY(v_credit_ids))
        OR (COALESCE(d.source_entity_type, '') = 'importer_credit_ledger' AND d.source_entity_id = ANY(v_credit_ids))
      )
  )
  SELECT
    (SELECT count(*) FROM debit_rows)::integer,
    (
      SELECT count(*)
      FROM public.order_funding_events ofe
      JOIN debit_rows d ON d.id = ofe.source_entity_id
      WHERE ofe.event_type = 'credit_applied'
        AND ofe.source_entity_type = 'importer_credit_ledger'
    )::integer
  INTO v_debit_count, v_event_count;

  IF v_debit_count > 0 OR v_event_count > 0 THEN
    RAISE EXCEPTION 'Cannot reset completion-loyalty release: credit has already been applied to an order. Debit rows %, funding events %.', v_debit_count, v_event_count;
  END IF;

  UPDATE public.importer_credit_ledger c
     SET lock_reason = 'completion_loyalty_release_reversed_to_selection',
         lock_source_entity_id = COALESCE(lock_source_entity_id, p_loyalty_match_id),
         notes = concat_ws(E'\n', c.notes, 'Completion-loyalty release reset to before funding selection by staff. Reason: ' || v_reason)
   WHERE c.id = ANY(v_credit_ids)
     AND c.lock_reason IS NULL;

  UPDATE public.completion_loyalty_reward_funding_confirmations fc
     SET funding_status = 'reversed_before_order_application',
         notes = concat_ws(E'\n', fc.notes, 'Reversed before order application; reward reset to funding selection. Reason: ' || v_reason),
         updated_at = now()
   WHERE fc.id = ANY(v_confirmation_ids);

  UPDATE public.completion_loyalty_reward_approvals a
     SET approval_status = 'approved_pending_funding',
         credit_ledger_id = NULL,
         funding_confirmation_id = NULL,
         funding_confirmed_at = NULL,
         released_at = NULL,
         notes = concat_ws(E'\n', a.notes, 'Released credit reset to funding selection. Reason: ' || v_reason),
         updated_at = now()
   WHERE a.id = ANY(v_approval_ids);

  UPDATE public.main_bank_completion_loyalty_funding_matches lm
     SET match_status = 'reversed',
         transfer_pair_status = 'reversed',
         destination_in_statement_line_id = NULL,
         credit_ledger_id = NULL,
         funding_confirmation_id = NULL,
         variance_gbp = 0,
         variance_reason = 'reset_to_before_funding_selection',
         reversed_by_staff_id = v_staff.id,
         reversed_by_auth_user_id = v_auth_uid,
         reversed_at = now(),
         reversal_reason = v_reason,
         notes = concat_ws(E'\n', lm.notes, 'Reversed/reset to before reward funding selection by staff. Reason: ' || v_reason)
   WHERE lm.id = ANY(v_match_ids);

  RETURN jsonb_build_object(
    'ok', true,
    'reset_to_selection', true,
    'reverse_group', COALESCE(p_reverse_group, true),
    'reversed_count', v_match_count,
    'reversed_total_gbp', v_total_amount,
    'seed_loyalty_match_id', p_loyalty_match_id,
    'reversed_match_ids', v_match_ids,
    'approval_ids_reset', v_approval_ids,
    'credit_ledger_ids_locked', v_credit_ids,
    'funding_confirmation_ids_reversed', v_confirmation_ids
  );
END;
$$;

-- Replace single-row release so same-importer sufficient-IN excess is not recorded as loyalty FX variance.
CREATE OR REPLACE FUNCTION public.staff_pair_loyalty_destination_in_and_release_v1(
  p_loyalty_match_id uuid,
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
  v_match record;
  v_dest record;
  v_existing_dest_consumed numeric(18,2) := 0;
  v_remaining_dest numeric(18,2);
  v_destination_excess_gbp numeric(18,2) := 0;
  v_confirmation_result jsonb;
  v_confirmation_id uuid;
  v_credit_id uuid;
  v_evidence_ref text;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: loyalty destination pairing requires auth.uid()'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Only admin or supervisor staff can pair and release completion loyalty.'; END IF;

  SELECT lm.* INTO v_match
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.id = p_loyalty_match_id
  FOR UPDATE;

  IF v_match.id IS NULL THEN RAISE EXCEPTION 'Completion loyalty funding match not found: %', p_loyalty_match_id; END IF;
  IF v_match.match_status <> 'confirmed' THEN RAISE EXCEPTION 'Only confirmed/staged loyalty matches can be paired. Current status: %', v_match.match_status; END IF;
  IF COALESCE(v_match.transfer_pair_status, '') NOT IN ('source_out_reserved','paired_ready_to_release','') THEN
    RAISE EXCEPTION 'Loyalty match % is not waiting for destination IN pairing. Pair status: %', p_loyalty_match_id, v_match.transfer_pair_status;
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
  IF v_dest.importer_id IS DISTINCT FROM v_match.importer_id THEN RAISE EXCEPTION 'Destination importer % does not match loyalty importer %.', v_dest.importer_id, v_match.importer_id; END IF;

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
    SELECT COALESCE(sum(lm.matched_gbp_amount) FILTER (WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit') AND lm.id <> p_loyalty_match_id), 0)::numeric AS consumed_gbp
    FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE lm.destination_in_statement_line_id = p_destination_in_statement_line_id
  ) x;

  v_remaining_dest := greatest(round((COALESCE(v_dest.amount_gbp_equivalent, 0) - COALESCE(v_existing_dest_consumed, 0))::numeric, 2), 0::numeric);

  IF round(COALESCE(v_match.matched_gbp_amount, 0)::numeric, 2) > v_remaining_dest + 0.01 THEN
    RAISE EXCEPTION 'Destination IN line remaining % is less than loyalty release amount %.', v_remaining_dest, v_match.matched_gbp_amount;
  END IF;

  v_destination_excess_gbp := round((v_remaining_dest - v_match.matched_gbp_amount)::numeric, 2);

  UPDATE public.main_bank_completion_loyalty_funding_matches
     SET destination_in_statement_line_id = p_destination_in_statement_line_id,
         transfer_pair_status = 'paired_ready_to_release',
         paired_at = now(),
         paired_by_staff_id = v_staff.id,
         paired_by_auth_user_id = v_auth_uid,
         variance_gbp = 0,
         variance_reason = CASE WHEN v_destination_excess_gbp > 0.01 THEN 'destination_in_excess_unconsumed_not_loyalty_fx' ELSE NULL END,
         notes = concat_ws(E'\n', COALESCE(p_notes, notes), CASE WHEN v_destination_excess_gbp > 0.01 THEN 'Single sufficient-IN release: excess remains on the DVA/card statement line and is not loyalty FX.' ELSE NULL END)
   WHERE id = p_loyalty_match_id;

  v_evidence_ref := concat_ws(' · ',
    'loyalty-transfer-match:' || p_loyalty_match_id::text,
    'destination-in-line:' || p_destination_in_statement_line_id::text,
    NULLIF(v_dest.statement_account_label::text, ''),
    NULLIF(v_dest.source_bank::text, ''),
    NULLIF(v_dest.statement_date::text, ''),
    NULLIF(v_dest.reference_raw::text, '')
  );

  v_confirmation_result := public.staff_confirm_completion_loyalty_reward_funding_v1(
    v_match.approval_id,
    v_match.matched_gbp_amount,
    v_match.matched_gbp_amount,
    p_destination_in_statement_line_id,
    v_evidence_ref,
    p_notes
  );

  v_confirmation_id := (v_confirmation_result->>'funding_confirmation_id')::uuid;
  v_credit_id := (v_confirmation_result->>'credit_ledger_id')::uuid;

  UPDATE public.main_bank_completion_loyalty_funding_matches
     SET funding_confirmation_id = v_confirmation_id,
         credit_ledger_id = v_credit_id,
         match_status = 'released_available_dashboard_credit',
         transfer_pair_status = 'paired_released',
         paired_at = COALESCE(paired_at, now()),
         paired_by_staff_id = COALESCE(paired_by_staff_id, v_staff.id),
         paired_by_auth_user_id = COALESCE(paired_by_auth_user_id, v_auth_uid),
         variance_gbp = 0,
         variance_reason = CASE WHEN v_destination_excess_gbp > 0.01 THEN 'destination_in_excess_unconsumed_not_loyalty_fx' ELSE NULL END,
         notes = concat_ws(E'\n', COALESCE(p_notes, notes), CASE WHEN v_destination_excess_gbp > 0.01 THEN 'Single sufficient-IN release: excess remains on the DVA/card statement line and is not loyalty FX.' ELSE NULL END)
   WHERE id = p_loyalty_match_id;

  RETURN jsonb_build_object(
    'ok', true,
    'loyalty_match_id', p_loyalty_match_id,
    'approval_id', v_match.approval_id,
    'funding_confirmation_id', v_confirmation_id,
    'credit_ledger_id', v_credit_id,
    'order_id', v_match.completed_order_id,
    'importer_id', v_match.importer_id,
    'matched_gbp_amount', v_match.matched_gbp_amount,
    'destination_remaining_before_gbp', v_remaining_dest,
    'destination_excess_after_release_gbp', v_destination_excess_gbp,
    'per_row_variance_gbp', 0,
    'match_status', 'released_available_dashboard_credit',
    'transfer_pair_status', 'paired_released',
    'credit_available_now', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_release_reversal_candidates_v1(text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_reverse_completion_loyalty_release_to_selection_v1(uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_release_reversal_candidates_v1(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_reverse_completion_loyalty_release_to_selection_v1(uuid, text, boolean) TO authenticated;

COMMENT ON FUNCTION public.internal_completion_loyalty_release_reversal_candidates_v1(text, integer, integer) IS
'Read-only released completion-loyalty rows/pots eligible for reset-to-selection reversal. Blocks rows already applied to an order.';

COMMENT ON FUNCTION public.staff_reverse_completion_loyalty_release_to_selection_v1(uuid, text, boolean) IS
'Resets released but unapplied completion-loyalty credit back to before reward funding selection. Locks released credit, reverses funding confirmation, resets approval to approved_pending_funding, and marks old funding match reversed. Does not touch VAT/Sage/order funding.';

COMMENT ON FUNCTION public.staff_pair_loyalty_destination_in_and_release_v1(uuid, uuid, text) IS
'Single completion-loyalty release requires same-importer sufficient DVA/card IN. Any destination-IN excess remains unconsumed on the statement line and is not recorded as loyalty FX variance.';

NOTIFY pgrst, 'reload schema';

COMMIT;
