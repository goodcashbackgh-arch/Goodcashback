BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_completion_loyalty_reward_proposals_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_completion_loyalty_reward_proposals_v1(uuid)';
  END IF;
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.completion_loyalty_reward_approvals';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_lines';
  END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statements';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

ALTER TABLE public.completion_loyalty_reward_approvals
  ADD COLUMN IF NOT EXISTS funding_confirmation_id uuid,
  ADD COLUMN IF NOT EXISTS funding_confirmed_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS released_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS superseded_by_cash_backed_v2_yn boolean NOT NULL DEFAULT true;

CREATE UNIQUE INDEX IF NOT EXISTS completion_loyalty_reward_approvals_one_active_order_cash_backed_v2_uidx
ON public.completion_loyalty_reward_approvals(order_id)
WHERE approval_status IN (
  'approved_locked_awaiting_sage',
  'ready_for_sage_posting_preview',
  'posted_to_sage',
  'credit_unlocked',
  'approved_pending_funding',
  'funding_submitted_pending_match',
  'funding_confirmed_ready_to_release',
  'released_available_dashboard_credit',
  'applied_to_future_order'
);

CREATE TABLE IF NOT EXISTS public.completion_loyalty_reward_funding_confirmations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id uuid NOT NULL REFERENCES public.completion_loyalty_reward_approvals(id),
  completed_order_id uuid NOT NULL REFERENCES public.orders(id),
  importer_id uuid NOT NULL,
  funded_by_staff_id uuid NOT NULL REFERENCES public.staff(id),
  funding_evidence_type character varying NOT NULL DEFAULT 'supervisor_funded_customer_dva',
  dva_statement_line_id uuid REFERENCES public.dva_statement_lines(id),
  funding_evidence_ref text,
  amount_funded_gbp numeric NOT NULL CHECK (amount_funded_gbp > 0),
  amount_released_gbp numeric NOT NULL CHECK (amount_released_gbp > 0),
  funding_status character varying NOT NULL DEFAULT 'funding_confirmed_ready_to_release',
  credit_ledger_id uuid,
  notes text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS completion_loyalty_reward_funding_one_released_approval_uidx
ON public.completion_loyalty_reward_funding_confirmations(approval_id)
WHERE funding_status IN ('funding_confirmed_ready_to_release','released_available_dashboard_credit');

REVOKE ALL ON TABLE public.completion_loyalty_reward_funding_confirmations FROM PUBLIC;
GRANT SELECT ON TABLE public.completion_loyalty_reward_funding_confirmations TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_approve_completion_loyalty_reward_v1(
  p_order_id uuid,
  p_approved_amount_gbp numeric,
  p_reward_rate_pct numeric DEFAULT 10,
  p_reason text DEFAULT 'completion_loyalty_reward',
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
  v_order record;
  v_proposal record;
  v_existing_approval_id uuid;
  v_existing_credit_id uuid;
  v_approval_id uuid;
  v_amount_gbp numeric;
  v_reward_rate_pct numeric;
  v_reason text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: completion loyalty reward approval requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found.';
  END IF;

  IF v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can approve completion loyalty reward.';
  END IF;

  v_amount_gbp := ROUND(COALESCE(p_approved_amount_gbp, 0)::numeric, 2);
  IF v_amount_gbp <= 0 THEN
    RAISE EXCEPTION 'Approved completion loyalty reward amount must be positive.';
  END IF;

  v_reward_rate_pct := ROUND(COALESCE(p_reward_rate_pct, 10)::numeric, 4);
  IF v_reward_rate_pct <= 0 THEN
    RAISE EXCEPTION 'Reward rate percent must be positive.';
  END IF;

  v_reason := lower(btrim(COALESCE(p_reason, 'completion_loyalty_reward')));
  IF v_reason <> 'completion_loyalty_reward' THEN
    RAISE EXCEPTION 'Invalid reason %. Use completion_loyalty_reward.', p_reason;
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, COALESCE(o.order_type, 'original') AS order_type
    INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.order_type <> 'original' THEN
    RAISE EXCEPTION 'Completion loyalty reward can only be approved on original orders. Order % has order_type %', p_order_id, v_order.order_type;
  END IF;

  SELECT a.id
    INTO v_existing_approval_id
  FROM public.completion_loyalty_reward_approvals a
  WHERE a.order_id = p_order_id
    AND a.approval_status IN (
      'approved_locked_awaiting_sage',
      'ready_for_sage_posting_preview',
      'posted_to_sage',
      'credit_unlocked',
      'approved_pending_funding',
      'funding_submitted_pending_match',
      'funding_confirmed_ready_to_release',
      'released_available_dashboard_credit',
      'applied_to_future_order'
    )
  ORDER BY a.created_at DESC, a.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_approval_id IS NOT NULL THEN
    RAISE EXCEPTION 'Completion loyalty reward approval already exists for this order: %', v_existing_approval_id;
  END IF;

  SELECT icl.id
    INTO v_existing_credit_id
  FROM public.importer_credit_ledger icl
  WHERE icl.source_type = 'completion_loyalty_reward'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id = p_order_id
  ORDER BY icl.created_at DESC, icl.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_credit_id IS NOT NULL THEN
    RAISE EXCEPTION 'Completion loyalty reward credit already exists for order %: %', p_order_id, v_existing_credit_id;
  END IF;

  SELECT *
    INTO v_proposal
  FROM public.internal_completion_loyalty_reward_proposals_v1(p_order_id)
  WHERE order_id = p_order_id;

  IF v_proposal.order_id IS NULL THEN
    RAISE EXCEPTION 'Completion loyalty reward proposal not found for order %.', p_order_id;
  END IF;

  IF v_proposal.proposal_status <> 'ready_for_supervisor_approval' THEN
    RAISE EXCEPTION 'Completion loyalty reward is not ready for approval. Current status %, blocker %.', v_proposal.proposal_status, COALESCE(v_proposal.approval_blocker, v_proposal.basis_blocker, 'unknown');
  END IF;

  IF v_proposal.existing_reward_credit_id IS NOT NULL THEN
    RAISE EXCEPTION 'Completion loyalty reward credit already exists for order %: %', p_order_id, v_proposal.existing_reward_credit_id;
  END IF;

  INSERT INTO public.completion_loyalty_reward_approvals (
    order_id,
    importer_id,
    approved_by_staff_id,
    proposal_snapshot_json,
    qualifying_signed_gross_basis_gbp,
    qualifying_net_spend_gbp,
    default_reward_rate_pct,
    suggested_reward_gbp,
    approved_reward_rate_pct,
    approved_amount_gbp,
    reason,
    notes,
    approval_status
  ) VALUES (
    p_order_id,
    v_order.importer_id,
    v_staff.id,
    to_jsonb(v_proposal),
    COALESCE(v_proposal.qualifying_signed_gross_basis_gbp, 0),
    COALESCE(v_proposal.qualifying_net_spend_gbp, 0),
    COALESCE(v_proposal.default_reward_rate_pct, 10),
    COALESCE(v_proposal.suggested_reward_gbp, 0),
    v_reward_rate_pct,
    v_amount_gbp,
    v_reason,
    p_notes,
    'approved_pending_funding'
  )
  RETURNING id INTO v_approval_id;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'approval_id', v_approval_id,
    'approved_amount_gbp', v_amount_gbp,
    'approved_reward_rate_pct', v_reward_rate_pct,
    'approval_status', 'approved_pending_funding',
    'credit_available_now', false,
    'credit_ledger_id', NULL,
    'next_step', 'supervisor_fund_customer_dva_or_customer_account_then_confirm_funding'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(
  p_approval_id uuid,
  p_amount_funded_gbp numeric,
  p_amount_released_gbp numeric DEFAULT NULL,
  p_dva_statement_line_id uuid DEFAULT NULL,
  p_funding_evidence_ref text DEFAULT NULL,
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
  v_approval record;
  v_line record;
  v_existing_confirmation_id uuid;
  v_confirmation_id uuid;
  v_existing_credit record;
  v_credit_id uuid;
  v_amount_funded numeric;
  v_amount_released numeric;
  v_evidence_ref text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: completion loyalty reward funding confirmation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found.';
  END IF;

  IF v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can confirm completion loyalty reward funding.';
  END IF;

  v_amount_funded := ROUND(COALESCE(p_amount_funded_gbp, 0)::numeric, 2);
  IF v_amount_funded <= 0 THEN
    RAISE EXCEPTION 'Funded amount must be positive.';
  END IF;

  SELECT a.*
    INTO v_approval
  FROM public.completion_loyalty_reward_approvals a
  WHERE a.id = p_approval_id
  FOR UPDATE;

  IF v_approval.id IS NULL THEN
    RAISE EXCEPTION 'Completion loyalty reward approval not found: %', p_approval_id;
  END IF;

  IF v_approval.approval_status NOT IN (
    'approved_pending_funding',
    'funding_submitted_pending_match',
    'funding_confirmed_ready_to_release',
    'approved_locked_awaiting_sage'
  ) THEN
    RAISE EXCEPTION 'Completion loyalty reward approval % is not awaiting funding confirmation. Current status: %', p_approval_id, v_approval.approval_status;
  END IF;

  v_amount_released := ROUND(COALESCE(p_amount_released_gbp, v_approval.approved_amount_gbp, 0)::numeric, 2);
  IF v_amount_released <= 0 THEN
    RAISE EXCEPTION 'Released amount must be positive.';
  END IF;
  IF v_amount_released > ROUND(COALESCE(v_approval.approved_amount_gbp, 0)::numeric, 2) THEN
    RAISE EXCEPTION 'Released amount % cannot exceed approved reward amount %.', v_amount_released, v_approval.approved_amount_gbp;
  END IF;
  IF v_amount_released > v_amount_funded THEN
    RAISE EXCEPTION 'Released amount % cannot exceed funded amount %.', v_amount_released, v_amount_funded;
  END IF;

  v_evidence_ref := NULLIF(BTRIM(COALESCE(p_funding_evidence_ref, '')), '');

  IF p_dva_statement_line_id IS NULL AND v_evidence_ref IS NULL THEN
    RAISE EXCEPTION 'Funding confirmation requires either a matched DVA statement line or a funding evidence reference.';
  END IF;

  IF p_dva_statement_line_id IS NOT NULL THEN
    SELECT
      dsl.id,
      dsl.direction,
      dsl.amount_gbp_equivalent,
      dsl.match_status,
      dsl.auth_id_ref,
      dsl.reference_raw,
      ds.importer_id
    INTO v_line
    FROM public.dva_statement_lines dsl
    JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
    WHERE dsl.id = p_dva_statement_line_id
    FOR UPDATE OF dsl;

    IF v_line.id IS NULL THEN
      RAISE EXCEPTION 'DVA statement line not found: %', p_dva_statement_line_id;
    END IF;
    IF v_line.importer_id IS DISTINCT FROM v_approval.importer_id THEN
      RAISE EXCEPTION 'DVA statement line importer % does not match approval importer %.', v_line.importer_id, v_approval.importer_id;
    END IF;
    IF COALESCE(v_line.direction, '') <> 'in' THEN
      RAISE EXCEPTION 'DVA statement line % is direction %, expected inbound customer/DVA funding proof.', p_dva_statement_line_id, v_line.direction;
    END IF;
    IF ROUND(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2) < v_amount_released THEN
      RAISE EXCEPTION 'DVA statement line amount % is lower than released reward amount %.', v_line.amount_gbp_equivalent, v_amount_released;
    END IF;
  END IF;

  SELECT c.id
    INTO v_existing_confirmation_id
  FROM public.completion_loyalty_reward_funding_confirmations c
  WHERE c.approval_id = p_approval_id
    AND c.funding_status IN ('funding_confirmed_ready_to_release','released_available_dashboard_credit')
  ORDER BY c.created_at DESC, c.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_confirmation_id IS NOT NULL THEN
    RAISE EXCEPTION 'Funding confirmation already exists for approval %: %', p_approval_id, v_existing_confirmation_id;
  END IF;

  SELECT icl.id, icl.lock_reason, icl.amount_gbp
    INTO v_existing_credit
  FROM public.importer_credit_ledger icl
  WHERE icl.source_type = 'completion_loyalty_reward'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id = v_approval.order_id
  ORDER BY icl.created_at DESC, icl.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_credit.id IS NOT NULL AND v_existing_credit.lock_reason IS NULL THEN
    RAISE EXCEPTION 'Completion loyalty reward dashboard credit is already released for order %: %', v_approval.order_id, v_existing_credit.id;
  END IF;

  INSERT INTO public.completion_loyalty_reward_funding_confirmations (
    approval_id,
    completed_order_id,
    importer_id,
    funded_by_staff_id,
    funding_evidence_type,
    dva_statement_line_id,
    funding_evidence_ref,
    amount_funded_gbp,
    amount_released_gbp,
    funding_status,
    notes
  ) VALUES (
    p_approval_id,
    v_approval.order_id,
    v_approval.importer_id,
    v_staff.id,
    CASE WHEN p_dva_statement_line_id IS NOT NULL THEN 'matched_dva_statement_line' ELSE 'supervisor_funded_customer_dva' END,
    p_dva_statement_line_id,
    v_evidence_ref,
    v_amount_funded,
    v_amount_released,
    'funding_confirmed_ready_to_release',
    p_notes
  ) RETURNING id INTO v_confirmation_id;

  IF v_existing_credit.id IS NULL THEN
    INSERT INTO public.importer_credit_ledger (
      importer_id,
      entry_type,
      source_table,
      source_id,
      linked_order_id,
      linked_dispute_id,
      direction,
      amount_gbp,
      amount_local_ccy,
      local_ccy,
      effective_at,
      source_type,
      source_entity_type,
      source_entity_id,
      applied_to_order_id,
      lock_reason,
      lock_source_entity_id,
      created_by_staff_id,
      notes
    ) VALUES (
      v_approval.importer_id,
      'manual_credit',
      'completion_loyalty_reward_funding_confirmations',
      v_confirmation_id,
      v_approval.order_id,
      NULL,
      'credit',
      v_amount_released,
      v_amount_released,
      'GBP',
      now(),
      'completion_loyalty_reward',
      'order',
      v_approval.order_id,
      NULL,
      NULL,
      v_confirmation_id,
      v_staff.id,
      'Completion loyalty reward funded and released after supervisor-confirmed DVA/customer account top-up.'
    ) RETURNING id INTO v_credit_id;
  ELSE
    UPDATE public.importer_credit_ledger
       SET amount_gbp = v_amount_released,
           amount_local_ccy = v_amount_released,
           local_ccy = 'GBP',
           direction = 'credit',
           source_table = 'completion_loyalty_reward_funding_confirmations',
           source_id = v_confirmation_id,
           source_type = 'completion_loyalty_reward',
           source_entity_type = 'order',
           source_entity_id = v_approval.order_id,
           applied_to_order_id = NULL,
           lock_reason = NULL,
           lock_source_entity_id = v_confirmation_id,
           created_by_staff_id = COALESCE(created_by_staff_id, v_staff.id),
           effective_at = now(),
           notes = 'Completion loyalty reward funded and released after supervisor-confirmed DVA/customer account top-up.'
     WHERE id = v_existing_credit.id
     RETURNING id INTO v_credit_id;
  END IF;

  UPDATE public.completion_loyalty_reward_funding_confirmations
     SET funding_status = 'released_available_dashboard_credit',
         credit_ledger_id = v_credit_id,
         updated_at = now()
   WHERE id = v_confirmation_id;

  UPDATE public.completion_loyalty_reward_approvals
     SET funding_confirmation_id = v_confirmation_id,
         funding_confirmed_at = now(),
         released_at = now(),
         credit_ledger_id = v_credit_id,
         approval_status = 'released_available_dashboard_credit',
         updated_at = now()
   WHERE id = p_approval_id;

  RETURN jsonb_build_object(
    'ok', true,
    'approval_id', p_approval_id,
    'funding_confirmation_id', v_confirmation_id,
    'credit_ledger_id', v_credit_id,
    'order_id', v_approval.order_id,
    'importer_id', v_approval.importer_id,
    'amount_funded_gbp', v_amount_funded,
    'amount_released_gbp', v_amount_released,
    'credit_available_now', true,
    'next_step', 'customer_can_apply_credit_to_future_order'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_reward_funding_workbench_v1(
  p_order_id uuid DEFAULT NULL
)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_id uuid,
  proposal_status text,
  completion_state text,
  completion_blocker text,
  basis_status text,
  basis_blocker text,
  qualifying_net_spend_gbp numeric,
  suggested_reward_gbp numeric,
  approval_id uuid,
  approval_status text,
  approved_amount_gbp numeric,
  funding_confirmation_id uuid,
  funding_status text,
  amount_funded_gbp numeric,
  amount_released_gbp numeric,
  dva_statement_line_id uuid,
  funding_evidence_ref text,
  credit_ledger_id uuid,
  available_dashboard_credit_gbp numeric,
  workbench_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: completion loyalty reward funding workbench requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for completion loyalty reward funding workbench.';
  END IF;

  RETURN QUERY
  WITH proposals AS (
    SELECT p.*
    FROM public.internal_completion_loyalty_reward_proposals_v1(p_order_id) p
  ), approvals AS (
    SELECT DISTINCT ON (a.order_id)
      a.*
    FROM public.completion_loyalty_reward_approvals a
    WHERE p_order_id IS NULL OR a.order_id = p_order_id
    ORDER BY a.order_id, a.created_at DESC, a.id DESC
  ), confirmations AS (
    SELECT DISTINCT ON (c.approval_id)
      c.*
    FROM public.completion_loyalty_reward_funding_confirmations c
    ORDER BY c.approval_id, c.created_at DESC, c.id DESC
  ), available_credit AS (
    SELECT
      icl.source_entity_id AS order_id,
      ROUND(COALESCE(SUM(CASE WHEN icl.direction = 'credit' THEN ABS(icl.amount_gbp) ELSE -ABS(icl.amount_gbp) END), 0)::numeric, 2) AS available_dashboard_credit_gbp
    FROM public.importer_credit_ledger icl
    WHERE icl.source_type = 'completion_loyalty_reward'
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id IS NOT NULL
      AND icl.lock_reason IS NULL
      AND (p_order_id IS NULL OR icl.source_entity_id = p_order_id)
    GROUP BY icl.source_entity_id
  )
  SELECT
    p.order_id,
    p.order_ref,
    p.importer_id,
    p.proposal_status,
    p.completion_state,
    p.completion_blocker,
    p.basis_status,
    p.basis_blocker,
    p.qualifying_net_spend_gbp,
    p.suggested_reward_gbp,
    a.id AS approval_id,
    a.approval_status::text,
    a.approved_amount_gbp,
    c.id AS funding_confirmation_id,
    c.funding_status::text,
    c.amount_funded_gbp,
    c.amount_released_gbp,
    c.dva_statement_line_id,
    c.funding_evidence_ref,
    COALESCE(c.credit_ledger_id, a.credit_ledger_id) AS credit_ledger_id,
    COALESCE(ac.available_dashboard_credit_gbp, 0)::numeric AS available_dashboard_credit_gbp,
    CASE
      WHEN p.proposal_status <> 'ready_for_supervisor_approval' AND a.id IS NULL THEN 'not_ready_for_reward'
      WHEN a.id IS NULL THEN 'proposed_pending_supervisor_review'
      WHEN a.approval_status = 'approved_pending_funding' THEN 'approved_pending_funding'
      WHEN a.approval_status IN ('funding_submitted_pending_match','funding_confirmed_ready_to_release') THEN a.approval_status::text
      WHEN a.approval_status = 'released_available_dashboard_credit' THEN 'released_available_dashboard_credit'
      WHEN COALESCE(ac.available_dashboard_credit_gbp, 0) > 0 THEN 'released_available_dashboard_credit'
      ELSE COALESCE(a.approval_status::text, p.proposal_status)
    END::text AS workbench_status
  FROM proposals p
  LEFT JOIN approvals a ON a.order_id = p.order_id
  LEFT JOIN confirmations c ON c.approval_id = a.id
  LEFT JOIN available_credit ac ON ac.order_id = p.order_id;
END;
$$;

COMMENT ON FUNCTION public.staff_approve_completion_loyalty_reward_v1(uuid, numeric, numeric, text, text) IS
'Cash-backed v2 behaviour: supervisor/admin approval records a completion loyalty reward approval-in-principle only. It does not create available credit or Sage-ready posting. Funding proof is required before dashboard credit release.';

COMMENT ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) IS
'Confirms supervisor-funded customer DVA/customer-account top-up for an approved completion loyalty reward and releases cash-backed dashboard credit through importer_credit_ledger.';

REVOKE ALL ON FUNCTION public.staff_approve_completion_loyalty_reward_v1(uuid, numeric, numeric, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_completion_loyalty_reward_funding_workbench_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_approve_completion_loyalty_reward_v1(uuid, numeric, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_confirm_completion_loyalty_reward_funding_v1(uuid, numeric, numeric, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_reward_funding_workbench_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
