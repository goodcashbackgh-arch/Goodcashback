BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_completion_loyalty_reward_proposals_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_completion_loyalty_reward_proposals_v1(uuid)';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.completion_loyalty_reward_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  importer_id uuid NOT NULL,
  approved_by_staff_id uuid NOT NULL REFERENCES public.staff(id),
  proposal_snapshot_json jsonb NOT NULL,
  qualifying_signed_gross_basis_gbp numeric NOT NULL,
  qualifying_net_spend_gbp numeric NOT NULL,
  default_reward_rate_pct numeric NOT NULL,
  suggested_reward_gbp numeric NOT NULL,
  approved_reward_rate_pct numeric NOT NULL,
  approved_amount_gbp numeric NOT NULL CHECK (approved_amount_gbp > 0),
  reason text NOT NULL DEFAULT 'completion_loyalty_reward',
  notes text,
  credit_ledger_id uuid,
  approval_status character varying NOT NULL DEFAULT 'approved_locked_awaiting_sage',
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS completion_loyalty_reward_approvals_one_active_order_uidx
ON public.completion_loyalty_reward_approvals(order_id)
WHERE approval_status IN ('approved_locked_awaiting_sage','ready_for_sage_posting_preview','posted_to_sage','credit_unlocked');

REVOKE ALL ON TABLE public.completion_loyalty_reward_approvals FROM PUBLIC;
GRANT SELECT ON TABLE public.completion_loyalty_reward_approvals TO authenticated;

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
  v_approval_id uuid;
  v_credit_id uuid;
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
    AND a.approval_status IN ('approved_locked_awaiting_sage','ready_for_sage_posting_preview','posted_to_sage','credit_unlocked')
  ORDER BY a.created_at DESC, a.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_approval_id IS NOT NULL THEN
    RAISE EXCEPTION 'Completion loyalty reward approval already exists for this order: %', v_existing_approval_id;
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
    'approved_locked_awaiting_sage'
  )
  RETURNING id INTO v_approval_id;

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
    v_order.importer_id,
    'manual_credit',
    'completion_loyalty_reward_approvals',
    v_approval_id,
    p_order_id,
    NULL,
    'credit',
    v_amount_gbp,
    v_amount_gbp,
    'GBP',
    now(),
    'completion_loyalty_reward',
    'order',
    p_order_id,
    NULL,
    'awaiting_sage_loyalty_journal',
    v_approval_id,
    v_staff.id,
    CONCAT('Completion loyalty reward approved for clean completed order.', CASE WHEN COALESCE(p_notes, '') <> '' THEN CONCAT(' Notes: ', p_notes) ELSE '' END)
  )
  RETURNING id INTO v_credit_id;

  UPDATE public.completion_loyalty_reward_approvals
     SET credit_ledger_id = v_credit_id,
         updated_at = now()
   WHERE id = v_approval_id;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'approval_id', v_approval_id,
    'credit_ledger_id', v_credit_id,
    'approved_amount_gbp', v_amount_gbp,
    'approved_reward_rate_pct', v_reward_rate_pct,
    'lock_reason', 'awaiting_sage_loyalty_journal',
    'credit_available_now', false,
    'next_step', 'sage_loyalty_journal_posting'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_approve_completion_loyalty_reward_v1(uuid, numeric, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_approve_completion_loyalty_reward_v1(uuid, numeric, numeric, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
