BEGIN;

-- Main-bank completion loyalty funding integration v1.
-- Additive lane: integrates loyalty reward funding proof into the existing main-bank workspace
-- without changing the shipper AP allocation table/action/posting flow.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.main_bank_shipper_ap_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_shipper_ap_allocations'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_reward_approvals'; END IF;
  IF to_regclass('public.completion_loyalty_reward_funding_confirmations') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_reward_funding_confirmations'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_reward_funding_workbench_v1(uuid)') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_completion_loyalty_reward_funding_workbench_v1(uuid)'; END IF;
  IF to_regprocedure('public.staff_approve_completion_loyalty_reward_v1(uuid,numeric,numeric,text,text)') IS NULL THEN RAISE EXCEPTION 'Missing public.staff_approve_completion_loyalty_reward_v1'; END IF;
  IF to_regprocedure('public.staff_confirm_completion_loyalty_reward_funding_v1(uuid,numeric,numeric,uuid,text,text)') IS NULL THEN RAISE EXCEPTION 'Missing public.staff_confirm_completion_loyalty_reward_funding_v1'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.main_bank_completion_loyalty_funding_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_statement_line_id uuid NOT NULL REFERENCES public.dva_statement_lines(id) ON DELETE RESTRICT,
  completed_order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  importer_id uuid NOT NULL,
  approval_id uuid NOT NULL REFERENCES public.completion_loyalty_reward_approvals(id) ON DELETE RESTRICT,
  funding_confirmation_id uuid REFERENCES public.completion_loyalty_reward_funding_confirmations(id) ON DELETE SET NULL,
  credit_ledger_id uuid REFERENCES public.importer_credit_ledger(id) ON DELETE SET NULL,
  matched_gbp_amount numeric(18,2) NOT NULL CHECK (matched_gbp_amount > 0),
  match_status text NOT NULL DEFAULT 'released_available_dashboard_credit' CHECK (match_status IN ('confirmed','released_available_dashboard_credit','reversed')),
  notes text,
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  created_by_auth_user_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  reversed_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  reversed_by_auth_user_id uuid,
  reversed_at timestamptz,
  reversal_reason text
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_main_bank_loyalty_funding_one_active_order
  ON public.main_bank_completion_loyalty_funding_matches(completed_order_id)
  WHERE match_status IN ('confirmed','released_available_dashboard_credit');

CREATE INDEX IF NOT EXISTS idx_main_bank_loyalty_funding_line
  ON public.main_bank_completion_loyalty_funding_matches(dva_statement_line_id, match_status);

CREATE INDEX IF NOT EXISTS idx_main_bank_loyalty_funding_importer
  ON public.main_bank_completion_loyalty_funding_matches(importer_id, match_status);

ALTER TABLE public.main_bank_completion_loyalty_funding_matches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS main_bank_completion_loyalty_funding_staff_select ON public.main_bank_completion_loyalty_funding_matches;
CREATE POLICY main_bank_completion_loyalty_funding_staff_select
ON public.main_bank_completion_loyalty_funding_matches
FOR SELECT
TO authenticated
USING (public.is_active_staff());

CREATE OR REPLACE FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  qualifying_net_spend_gbp numeric,
  suggested_reward_gbp numeric,
  target_status text,
  blocker text,
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
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: main-bank loyalty targets require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for main-bank loyalty targets.'; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      w.order_id,
      w.order_ref,
      w.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      round(COALESCE(w.qualifying_net_spend_gbp, 0)::numeric, 2) AS qualifying_net_spend_gbp,
      round(COALESCE(w.suggested_reward_gbp, 0)::numeric, 2) AS suggested_reward_gbp,
      w.workbench_status::text AS target_status,
      COALESCE(w.completion_blocker, w.basis_blocker)::text AS blocker
    FROM public.internal_completion_loyalty_reward_funding_workbench_v1(NULL::uuid) w
    LEFT JOIN public.importers i ON i.id = w.importer_id
    WHERE w.workbench_status = 'proposed_pending_supervisor_review'
      AND w.approval_id IS NULL
      AND round(COALESCE(w.suggested_reward_gbp, 0)::numeric, 2) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.main_bank_completion_loyalty_funding_matches lm
        WHERE lm.completed_order_id = w.order_id
          AND lm.match_status IN ('confirmed','released_available_dashboard_credit')
      )
  ), filtered AS (
    SELECT b.*
    FROM base b
    WHERE v_search IS NULL
       OR lower(concat_ws(' ', b.order_ref, b.importer_name, b.suggested_reward_gbp::text, b.target_status)) LIKE '%' || v_search || '%'
  )
  SELECT
    f.order_id,
    f.order_ref,
    f.importer_id,
    f.importer_name,
    f.qualifying_net_spend_gbp,
    f.suggested_reward_gbp,
    f.target_status,
    f.blocker,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.order_ref DESC NULLS LAST, f.order_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_match_main_bank_line_to_completion_loyalty_v1(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reward_amount_gbp numeric DEFAULT NULL,
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
  v_line record;
  v_target record;
  v_shipper_allocated numeric(18,2) := 0;
  v_residual_allocated numeric(18,2) := 0;
  v_loyalty_allocated numeric(18,2) := 0;
  v_line_remaining numeric(18,2);
  v_amount numeric(18,2);
  v_approval_result jsonb;
  v_confirmation_result jsonb;
  v_approval_id uuid;
  v_confirmation_id uuid;
  v_credit_ledger_id uuid;
  v_match_id uuid;
  v_evidence_ref text;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: main-bank loyalty match requires auth.uid()'; END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Only admin or supervisor staff can match main-bank loyalty funding.'; END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.reference_raw,
    dsl.statement_date,
    ds.statement_account_context,
    ds.statement_account_label,
    ds.source_bank
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN RAISE EXCEPTION 'Statement line not found: %', p_dva_statement_line_id; END IF;
  IF COALESCE(v_line.statement_account_context, '') <> 'main_company_bank_account' THEN RAISE EXCEPTION 'Statement line is not from the main company bank account.'; END IF;
  IF COALESCE(v_line.direction, '') <> 'out' THEN RAISE EXCEPTION 'Only OUT main-bank lines can fund completion loyalty rewards.'; END IF;
  IF round(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2) <= 0 THEN RAISE EXCEPTION 'Statement line amount must be positive.'; END IF;

  SELECT *
    INTO v_target
  FROM public.internal_main_bank_completion_loyalty_targets_v1(NULL, 300, 0) t
  WHERE t.order_id = p_order_id
  LIMIT 1;

  IF v_target.order_id IS NULL THEN
    RAISE EXCEPTION 'Completion loyalty target is not available for main-bank funding match: %', p_order_id;
  END IF;

  SELECT round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2)
    INTO v_shipper_allocated
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id;

  SELECT round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type IN ('fx_card_difference','bank_fee','unmatched_hold')), 0)::numeric, 2)
    INTO v_residual_allocated
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id;

  SELECT round(COALESCE(sum(lm.matched_gbp_amount) FILTER (WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit')), 0)::numeric, 2)
    INTO v_loyalty_allocated
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.dva_statement_line_id = p_dva_statement_line_id;

  v_line_remaining := greatest(round((COALESCE(v_line.amount_gbp_equivalent, 0) - COALESCE(v_shipper_allocated, 0) - COALESCE(v_residual_allocated, 0) - COALESCE(v_loyalty_allocated, 0))::numeric, 2), 0::numeric);
  v_amount := round(COALESCE(p_reward_amount_gbp, v_target.suggested_reward_gbp, 0)::numeric, 2);

  IF v_amount <= 0 THEN RAISE EXCEPTION 'Completion loyalty reward match amount must be greater than zero.'; END IF;
  IF v_amount > round(COALESCE(v_target.suggested_reward_gbp, 0)::numeric, 2) + 0.01 THEN
    RAISE EXCEPTION 'Match amount % cannot exceed suggested reward amount %.', v_amount, v_target.suggested_reward_gbp;
  END IF;
  IF v_amount > v_line_remaining + 0.01 THEN
    RAISE EXCEPTION 'Match amount % exceeds remaining main-bank line amount %.', v_amount, v_line_remaining;
  END IF;

  v_approval_result := public.staff_approve_completion_loyalty_reward_v1(
    p_order_id,
    v_amount,
    10,
    'completion_loyalty_reward',
    p_notes
  );
  v_approval_id := (v_approval_result->>'approval_id')::uuid;

  IF v_approval_id IS NULL THEN RAISE EXCEPTION 'Approval was not created for completion loyalty reward.'; END IF;

  v_evidence_ref := concat_ws(' · ',
    'main-bank-line:' || p_dva_statement_line_id::text,
    NULLIF(v_line.statement_account_label::text, ''),
    NULLIF(v_line.source_bank::text, ''),
    NULLIF(v_line.statement_date::text, ''),
    NULLIF(v_line.reference_raw::text, '')
  );

  v_confirmation_result := public.staff_confirm_completion_loyalty_reward_funding_v1(
    v_approval_id,
    v_amount,
    v_amount,
    NULL::uuid,
    v_evidence_ref,
    p_notes
  );

  v_confirmation_id := (v_confirmation_result->>'funding_confirmation_id')::uuid;
  v_credit_ledger_id := (v_confirmation_result->>'credit_ledger_id')::uuid;

  INSERT INTO public.main_bank_completion_loyalty_funding_matches (
    dva_statement_line_id,
    completed_order_id,
    importer_id,
    approval_id,
    funding_confirmation_id,
    credit_ledger_id,
    matched_gbp_amount,
    match_status,
    notes,
    created_by_staff_id,
    created_by_auth_user_id
  ) VALUES (
    p_dva_statement_line_id,
    p_order_id,
    v_target.importer_id,
    v_approval_id,
    v_confirmation_id,
    v_credit_ledger_id,
    v_amount,
    'released_available_dashboard_credit',
    p_notes,
    v_staff.id,
    v_auth_uid
  ) RETURNING id INTO v_match_id;

  RETURN jsonb_build_object(
    'ok', true,
    'match_id', v_match_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', p_order_id,
    'order_ref', v_target.order_ref,
    'importer_id', v_target.importer_id,
    'approval_id', v_approval_id,
    'funding_confirmation_id', v_confirmation_id,
    'credit_ledger_id', v_credit_ledger_id,
    'matched_gbp_amount', v_amount,
    'dashboard_credit_released', true
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_main_bank_shipper_statement_lines_v1(
  p_status text DEFAULT 'unmatched',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_id uuid,
  statement_date date,
  reference_raw text,
  direction text,
  amount_local numeric,
  local_currency text,
  amount_gbp numeric,
  allocated_gbp numeric,
  remaining_gbp numeric,
  match_status text,
  statement_account_label text,
  source_bank text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'unmatched'));
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: main bank workspace requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for main bank workspace.'; END IF;

  RETURN QUERY
  WITH shipper_allocations AS (
    SELECT
      a.dva_statement_line_id,
      round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2) AS allocated_gbp
    FROM public.main_bank_shipper_ap_allocations a
    GROUP BY a.dva_statement_line_id
  ), loyalty_matches AS (
    SELECT
      lm.dva_statement_line_id,
      round(COALESCE(sum(lm.matched_gbp_amount) FILTER (WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit')), 0)::numeric, 2) AS matched_gbp
    FROM public.main_bank_completion_loyalty_funding_matches lm
    GROUP BY lm.dva_statement_line_id
  ), base AS (
    SELECT
      dsl.id AS statement_line_id,
      ds.id AS statement_id,
      dsl.statement_date,
      dsl.reference_raw::text,
      dsl.direction::text,
      dsl.amount_local_ccy::numeric AS amount_local,
      dsl.local_ccy::text AS local_currency,
      round(COALESCE(dsl.amount_gbp_equivalent, 0)::numeric, 2) AS amount_gbp,
      COALESCE(sa.allocated_gbp, 0)::numeric AS shipper_allocated_gbp,
      COALESCE(lm.matched_gbp, 0)::numeric AS loyalty_matched_gbp,
      ds.statement_account_label::text,
      ds.source_bank::text
    FROM public.dva_statement_lines dsl
    JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
    LEFT JOIN shipper_allocations sa ON sa.dva_statement_line_id = dsl.id
    LEFT JOIN loyalty_matches lm ON lm.dva_statement_line_id = dsl.id
    WHERE COALESCE(ds.statement_account_context, 'importer_dva_card_account') = 'main_company_bank_account'
      AND dsl.direction = 'out'
  ), enriched AS (
    SELECT
      b.*,
      greatest(round((b.amount_gbp - b.shipper_allocated_gbp - b.loyalty_matched_gbp)::numeric, 2), 0::numeric) AS remaining_after_main_allocations_gbp,
      CASE
        WHEN b.shipper_allocated_gbp + b.loyalty_matched_gbp <= 0 THEN 'unmatched'
        WHEN b.amount_gbp - b.shipper_allocated_gbp - b.loyalty_matched_gbp > 0.01 THEN 'part_allocated'
        ELSE 'balanced'
      END::text AS match_status
    FROM base b
  ), filtered AS (
    SELECT e.*
    FROM enriched e
    WHERE (v_status = 'all' OR e.match_status = v_status)
      AND (v_search IS NULL OR lower(concat_ws(' ', e.reference_raw, e.statement_date::text, e.amount_gbp::text, e.source_bank)) LIKE '%' || v_search || '%')
  )
  SELECT
    f.statement_line_id,
    f.statement_id,
    f.statement_date,
    f.reference_raw,
    f.direction,
    f.amount_local,
    f.local_currency,
    f.amount_gbp,
    f.shipper_allocated_gbp AS allocated_gbp,
    f.remaining_after_main_allocations_gbp AS remaining_gbp,
    f.match_status,
    f.statement_account_label,
    f.source_bank,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date DESC, f.statement_line_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(text, integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.staff_match_main_bank_line_to_completion_loyalty_v1(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_match_main_bank_line_to_completion_loyalty_v1(uuid, uuid, numeric, text) TO authenticated;

COMMENT ON FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(text, integer, integer) IS
'Read-only main-bank loyalty targets: clean completed reward proposals eligible for supervisor-funded dashboard credit release.';

COMMENT ON FUNCTION public.staff_match_main_bank_line_to_completion_loyalty_v1(uuid, uuid, numeric, text) IS
'Matches a main-bank OUT line to a completion loyalty reward target, approves in principle, confirms funding by evidence reference, releases dashboard credit, and records bank-line consumption.';

NOTIFY pgrst, 'reload schema';

COMMIT;
