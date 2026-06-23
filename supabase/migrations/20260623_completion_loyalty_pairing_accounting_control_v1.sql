BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Completion loyalty pairing/accounting control v1.
-- Additive contract implementation:
-- - rejection table/RPC;
-- - split normal credit from completion-loyalty credit;
-- - staff-only loyalty application to orders;
-- - stage main-bank OUT before DVA/card IN pairing;
-- - release loyalty only after paired destination IN;
-- - read-only accounting-control rows.
-- No DVA core, main-bank shipper AP, VAT return, supplier/OCR, shipper AP, shipment, or Sage sales invoice posting changes.

DO $$
BEGIN
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN RAISE EXCEPTION 'Missing completion_loyalty_reward_approvals'; END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.completion_loyalty_reward_funding_confirmations') IS NULL THEN RAISE EXCEPTION 'Missing completion_loyalty_reward_funding_confirmations'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing importer_credit_ledger'; END IF;
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing order_funding_events'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing dva_statements'; END IF;
  IF to_regclass('public.dva_reconciliation') IS NULL THEN RAISE EXCEPTION 'Missing dva_reconciliation'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing dva_statement_line_allocations'; END IF;
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing orders'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing staff'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_reward_proposals_v1(uuid)') IS NULL THEN RAISE EXCEPTION 'Missing internal_completion_loyalty_reward_proposals_v1'; END IF;
  IF to_regprocedure('public.staff_approve_completion_loyalty_reward_v1(uuid,numeric,numeric,text,text)') IS NULL THEN RAISE EXCEPTION 'Missing staff_approve_completion_loyalty_reward_v1'; END IF;
  IF to_regprocedure('public.staff_confirm_completion_loyalty_reward_funding_v1(uuid,numeric,numeric,uuid,text,text)') IS NULL THEN RAISE EXCEPTION 'Missing staff_confirm_completion_loyalty_reward_funding_v1'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing internal_has_accounting_admin_access_v1'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.completion_loyalty_reward_rejections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  importer_id uuid NOT NULL,
  rejection_reason_code text NOT NULL,
  notes text,
  proposal_snapshot_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  rejected_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  rejected_by_auth_user_id uuid,
  rejected_at timestamptz NOT NULL DEFAULT now(),
  active boolean NOT NULL DEFAULT true,
  reversed_at timestamptz,
  reversed_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  reversed_by_auth_user_id uuid,
  reversal_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS completion_loyalty_reward_rejections_one_active_order_uidx
  ON public.completion_loyalty_reward_rejections(order_id)
  WHERE active = true;

ALTER TABLE public.completion_loyalty_reward_rejections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS completion_loyalty_reward_rejections_staff_select ON public.completion_loyalty_reward_rejections;
CREATE POLICY completion_loyalty_reward_rejections_staff_select
ON public.completion_loyalty_reward_rejections
FOR SELECT
TO authenticated
USING (public.is_active_staff());

ALTER TABLE public.main_bank_completion_loyalty_funding_matches
  ADD COLUMN IF NOT EXISTS destination_in_statement_line_id uuid REFERENCES public.dva_statement_lines(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS activation_route text,
  ADD COLUMN IF NOT EXISTS card_used_by text,
  ADD COLUMN IF NOT EXISTS transfer_pair_status text,
  ADD COLUMN IF NOT EXISTS paired_at timestamptz,
  ADD COLUMN IF NOT EXISTS paired_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS paired_by_auth_user_id uuid,
  ADD COLUMN IF NOT EXISTS variance_gbp numeric(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS variance_reason text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'main_bank_completion_loyalty_activation_route_chk'
      AND conrelid = 'public.main_bank_completion_loyalty_funding_matches'::regclass
  ) THEN
    ALTER TABLE public.main_bank_completion_loyalty_funding_matches
      ADD CONSTRAINT main_bank_completion_loyalty_activation_route_chk CHECK (
        activation_route IS NULL OR activation_route IN ('dva_account_top_up','virtual_card_top_up')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'main_bank_completion_loyalty_card_used_by_chk'
      AND conrelid = 'public.main_bank_completion_loyalty_funding_matches'::regclass
  ) THEN
    ALTER TABLE public.main_bank_completion_loyalty_funding_matches
      ADD CONSTRAINT main_bank_completion_loyalty_card_used_by_chk CHECK (
        card_used_by IS NULL OR card_used_by IN ('customer','staff','supervisor','operator')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'main_bank_completion_loyalty_transfer_pair_status_chk'
      AND conrelid = 'public.main_bank_completion_loyalty_funding_matches'::regclass
  ) THEN
    ALTER TABLE public.main_bank_completion_loyalty_funding_matches
      ADD CONSTRAINT main_bank_completion_loyalty_transfer_pair_status_chk CHECK (
        transfer_pair_status IS NULL OR transfer_pair_status IN (
          'legacy_released_out_only',
          'source_out_reserved',
          'paired_ready_to_release',
          'paired_released',
          'reversed'
        )
      );
  END IF;
END $$;

UPDATE public.main_bank_completion_loyalty_funding_matches
   SET transfer_pair_status = CASE
         WHEN match_status = 'released_available_dashboard_credit' AND destination_in_statement_line_id IS NULL THEN 'legacy_released_out_only'
         WHEN match_status = 'confirmed' AND transfer_pair_status IS NULL THEN 'source_out_reserved'
         WHEN match_status = 'reversed' THEN 'reversed'
         ELSE transfer_pair_status
       END,
       activation_route = COALESCE(activation_route, 'dva_account_top_up'),
       card_used_by = COALESCE(card_used_by, 'staff')
 WHERE transfer_pair_status IS NULL
    OR activation_route IS NULL
    OR card_used_by IS NULL;

CREATE INDEX IF NOT EXISTS idx_main_bank_loyalty_destination_in_line
  ON public.main_bank_completion_loyalty_funding_matches(destination_in_statement_line_id, match_status);

CREATE INDEX IF NOT EXISTS idx_main_bank_loyalty_transfer_pair_status
  ON public.main_bank_completion_loyalty_funding_matches(transfer_pair_status, match_status);

-- Normal available account credit now excludes completion_loyalty_reward.
CREATE OR REPLACE FUNCTION public.internal_importer_available_account_credit_lots_v1(
  p_importer_id uuid
)
RETURNS TABLE (
  credit_ledger_id uuid,
  source_type text,
  available_amount_gbp numeric,
  priority integer,
  effective_at timestamptz,
  created_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH source_credit_types AS (
    SELECT *
    FROM (VALUES
      ('settlement_credit'::text, 1),
      ('overfunding'::text, 2),
      ('refund_resolution'::text, 3),
      ('liability_settlement'::text, 4),
      ('payout_reversal'::text, 5),
      ('manual'::text, 7)
    ) AS v(source_type, priority)
  ), source_credit_ids AS (
    SELECT c.id
    FROM public.importer_credit_ledger c
    JOIN source_credit_types sct ON sct.source_type = c.source_type::text
    WHERE c.importer_id = p_importer_id
      AND c.direction = 'credit'
      AND c.lock_reason IS NULL
  ), legacy_unlinked_debits AS (
    SELECT
      ROUND(COALESCE(SUM(ABS(d.amount_gbp)), 0)::numeric, 2) AS amount_gbp
    FROM public.importer_credit_ledger d
    WHERE d.importer_id = p_importer_id
      AND d.direction = 'debit'
      AND d.lock_reason IS NULL
      AND NOT (
        COALESCE(d.source_table, '') = 'importer_credit_ledger'
        AND d.source_id IN (SELECT id FROM source_credit_ids)
      )
      AND NOT (
        COALESCE(d.source_entity_type, '') = 'importer_credit_ledger'
        AND d.source_entity_id IN (SELECT id FROM source_credit_ids)
      )
  ), lot_base AS (
    SELECT
      c.id AS credit_ledger_id,
      c.source_type::text AS source_type,
      sct.priority,
      COALESCE(c.effective_at, c.created_at) AS effective_at,
      c.created_at,
      ROUND(GREATEST(
        ABS(COALESCE(c.amount_gbp, 0)) - COALESCE(linked.linked_debit_gbp, 0),
        0
      )::numeric, 2) AS amount_after_linked_debits_gbp
    FROM public.importer_credit_ledger c
    JOIN source_credit_types sct ON sct.source_type = c.source_type::text
    LEFT JOIN LATERAL (
      SELECT ROUND(COALESCE(SUM(ABS(d.amount_gbp)), 0)::numeric, 2) AS linked_debit_gbp
      FROM public.importer_credit_ledger d
      WHERE d.importer_id = c.importer_id
        AND d.direction = 'debit'
        AND d.lock_reason IS NULL
        AND (
          (COALESCE(d.source_table, '') = 'importer_credit_ledger' AND d.source_id = c.id)
          OR (COALESCE(d.source_entity_type, '') = 'importer_credit_ledger' AND d.source_entity_id = c.id)
        )
    ) linked ON true
    WHERE c.importer_id = p_importer_id
      AND c.direction = 'credit'
      AND c.lock_reason IS NULL
  ), ordered_lots AS (
    SELECT
      lb.*,
      COALESCE(SUM(lb.amount_after_linked_debits_gbp) OVER (
        ORDER BY lb.priority, lb.effective_at, lb.created_at, lb.credit_ledger_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0)::numeric AS prior_lot_amount_gbp,
      (SELECT amount_gbp FROM legacy_unlinked_debits) AS legacy_unlinked_debit_gbp
    FROM lot_base lb
    WHERE lb.amount_after_linked_debits_gbp > 0
  ), available_lots AS (
    SELECT
      ol.*,
      LEAST(
        ol.amount_after_linked_debits_gbp,
        GREATEST(ol.legacy_unlinked_debit_gbp - ol.prior_lot_amount_gbp, 0)
      ) AS virtual_legacy_consumed_gbp
    FROM ordered_lots ol
  )
  SELECT
    al.credit_ledger_id,
    al.source_type,
    ROUND(GREATEST(al.amount_after_linked_debits_gbp - al.virtual_legacy_consumed_gbp, 0)::numeric, 2) AS available_amount_gbp,
    al.priority,
    al.effective_at,
    al.created_at
  FROM available_lots al
  WHERE ROUND(GREATEST(al.amount_after_linked_debits_gbp - al.virtual_legacy_consumed_gbp, 0)::numeric, 2) > 0
  ORDER BY al.priority, al.effective_at, al.created_at, al.credit_ledger_id;
$$;

CREATE OR REPLACE FUNCTION public.internal_importer_available_completion_loyalty_lots_v1(
  p_importer_id uuid
)
RETURNS TABLE (
  credit_ledger_id uuid,
  source_type text,
  available_amount_gbp numeric,
  effective_at timestamptz,
  created_at timestamptz,
  source_order_id uuid
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    c.id AS credit_ledger_id,
    c.source_type::text AS source_type,
    ROUND(GREATEST(ABS(COALESCE(c.amount_gbp, 0)) - COALESCE(linked.linked_debit_gbp, 0), 0)::numeric, 2) AS available_amount_gbp,
    COALESCE(c.effective_at, c.created_at) AS effective_at,
    c.created_at,
    c.source_entity_id AS source_order_id
  FROM public.importer_credit_ledger c
  LEFT JOIN LATERAL (
    SELECT ROUND(COALESCE(SUM(ABS(d.amount_gbp)), 0)::numeric, 2) AS linked_debit_gbp
    FROM public.importer_credit_ledger d
    WHERE d.importer_id = c.importer_id
      AND d.direction = 'debit'
      AND d.lock_reason IS NULL
      AND (
        (COALESCE(d.source_table, '') = 'importer_credit_ledger' AND d.source_id = c.id)
        OR (COALESCE(d.source_entity_type, '') = 'importer_credit_ledger' AND d.source_entity_id = c.id)
      )
  ) linked ON true
  WHERE c.importer_id = p_importer_id
    AND c.direction = 'credit'
    AND c.lock_reason IS NULL
    AND c.source_type = 'completion_loyalty_reward'
    AND ROUND(GREATEST(ABS(COALESCE(c.amount_gbp, 0)) - COALESCE(linked.linked_debit_gbp, 0), 0)::numeric, 2) > 0
  ORDER BY COALESCE(c.effective_at, c.created_at), c.created_at, c.id;
$$;

CREATE OR REPLACE FUNCTION public.customer_completion_loyalty_reward_balance_v1()
RETURNS TABLE(importer_id uuid, pending_activation_gbp numeric, ready_to_use_gbp numeric)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH current_importer AS (
    SELECT oi.importer_id
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id = op.id AND oi.revoked_at IS NULL
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
    ORDER BY oi.granted_at DESC NULLS LAST, oi.id DESC
    LIMIT 1
  ), pending AS (
    SELECT
      ci.importer_id,
      ROUND(COALESCE(SUM(a.approved_amount_gbp), 0)::numeric, 2) AS pending_activation_gbp
    FROM current_importer ci
    LEFT JOIN public.completion_loyalty_reward_approvals a
      ON a.importer_id = ci.importer_id
     AND a.approval_status IN ('approved_pending_funding','funding_submitted_pending_match','funding_confirmed_ready_to_release')
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.completion_loyalty_reward_rejections r
      WHERE r.order_id = a.order_id
        AND r.active = true
    )
    GROUP BY ci.importer_id
  ), ready AS (
    SELECT
      ci.importer_id,
      ROUND(COALESCE(SUM(l.available_amount_gbp), 0)::numeric, 2) AS ready_to_use_gbp
    FROM current_importer ci
    LEFT JOIN LATERAL public.internal_importer_available_completion_loyalty_lots_v1(ci.importer_id) l ON true
    GROUP BY ci.importer_id
  )
  SELECT
    ci.importer_id,
    COALESCE(p.pending_activation_gbp, 0)::numeric AS pending_activation_gbp,
    COALESCE(r.ready_to_use_gbp, 0)::numeric AS ready_to_use_gbp
  FROM current_importer ci
  LEFT JOIN pending p ON p.importer_id = ci.importer_id
  LEFT JOIN ready r ON r.importer_id = ci.importer_id;
$$;

CREATE OR REPLACE FUNCTION public.staff_reject_completion_loyalty_reward_v1(
  p_order_id uuid,
  p_rejection_reason_code text,
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
  v_rejection_id uuid;
  v_reason text := lower(NULLIF(btrim(COALESCE(p_rejection_reason_code, '')), ''));
  v_active_released_credit uuid;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: completion loyalty rejection requires auth.uid()'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Only admin or supervisor staff can reject completion loyalty reward.'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Rejection reason is required.'; END IF;

  SELECT o.id, o.order_ref, o.importer_id, COALESCE(o.order_type, 'original') AS order_type
    INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found: %', p_order_id; END IF;
  IF v_order.order_type <> 'original' THEN RAISE EXCEPTION 'Completion loyalty rejection can only be recorded on original orders.'; END IF;

  SELECT icl.id INTO v_active_released_credit
  FROM public.importer_credit_ledger icl
  WHERE icl.source_type = 'completion_loyalty_reward'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id = p_order_id
    AND icl.lock_reason IS NULL
  LIMIT 1
  FOR UPDATE;

  IF v_active_released_credit IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot reject a released completion loyalty credit. Reverse or lock released credit first: %', v_active_released_credit;
  END IF;

  SELECT * INTO v_proposal
  FROM public.internal_completion_loyalty_reward_proposals_v1(p_order_id)
  WHERE order_id = p_order_id;

  INSERT INTO public.completion_loyalty_reward_rejections (
    order_id,
    importer_id,
    rejection_reason_code,
    notes,
    proposal_snapshot_json,
    rejected_by_staff_id,
    rejected_by_auth_user_id
  ) VALUES (
    p_order_id,
    v_order.importer_id,
    v_reason,
    p_notes,
    COALESCE(to_jsonb(v_proposal), jsonb_build_object('order_id', p_order_id, 'order_ref', v_order.order_ref)),
    v_staff.id,
    v_auth_uid
  )
  ON CONFLICT (order_id) WHERE active = true DO UPDATE
    SET rejection_reason_code = EXCLUDED.rejection_reason_code,
        notes = EXCLUDED.notes,
        proposal_snapshot_json = EXCLUDED.proposal_snapshot_json,
        rejected_by_staff_id = EXCLUDED.rejected_by_staff_id,
        rejected_by_auth_user_id = EXCLUDED.rejected_by_auth_user_id,
        rejected_at = now(),
        updated_at = now()
  RETURNING id INTO v_rejection_id;

  RETURN jsonb_build_object('ok', true, 'rejection_id', v_rejection_id, 'order_id', p_order_id, 'order_ref', v_order.order_ref, 'proposal_status', 'rejected_in_principle');
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_stage_main_bank_line_to_completion_loyalty_v2(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reward_amount_gbp numeric DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_activation_route text DEFAULT 'dva_account_top_up',
  p_card_used_by text DEFAULT 'staff'
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
  v_order record;
  v_target record;
  v_existing_approval record;
  v_existing_match record;
  v_shipper_allocated numeric(18,2) := 0;
  v_residual_allocated numeric(18,2) := 0;
  v_loyalty_allocated numeric(18,2) := 0;
  v_line_remaining numeric(18,2);
  v_amount numeric(18,2);
  v_approval_result jsonb;
  v_approval_id uuid;
  v_match_id uuid;
  v_activation_route text := COALESCE(NULLIF(btrim(p_activation_route), ''), 'dva_account_top_up');
  v_card_used_by text := COALESCE(NULLIF(btrim(p_card_used_by), ''), 'staff');
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: loyalty main-bank staging requires auth.uid()'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Only admin or supervisor staff can stage completion loyalty funding.'; END IF;
  IF v_activation_route NOT IN ('dva_account_top_up','virtual_card_top_up') THEN RAISE EXCEPTION 'Unsupported activation route: %', v_activation_route; END IF;
  IF v_card_used_by NOT IN ('customer','staff','supervisor','operator') THEN RAISE EXCEPTION 'Unsupported card used by value: %', v_card_used_by; END IF;

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
  IF COALESCE(v_line.direction, '') <> 'out' THEN RAISE EXCEPTION 'Only OUT main-bank lines can be reserved for completion loyalty.'; END IF;
  IF round(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2) <= 0 THEN RAISE EXCEPTION 'Statement line amount must be positive.'; END IF;

  SELECT o.id, o.order_ref, o.importer_id, COALESCE(o.order_type, 'original') AS order_type
    INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found: %', p_order_id; END IF;
  IF v_order.order_type <> 'original' THEN RAISE EXCEPTION 'Completion loyalty can only be staged for original orders.'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.completion_loyalty_reward_rejections r
    WHERE r.order_id = p_order_id AND r.active = true
  ) THEN
    RAISE EXCEPTION 'Completion loyalty reward has been rejected in principle for order %.', p_order_id;
  END IF;

  SELECT * INTO v_existing_match
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.completed_order_id = p_order_id
    AND lm.match_status IN ('confirmed','released_available_dashboard_credit')
  ORDER BY lm.created_at DESC, lm.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_match.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_staged_or_released', true,
      'loyalty_match_id', v_existing_match.id,
      'approval_id', v_existing_match.approval_id,
      'order_id', p_order_id,
      'order_ref', v_order.order_ref,
      'matched_gbp_amount', v_existing_match.matched_gbp_amount,
      'match_status', v_existing_match.match_status,
      'transfer_pair_status', COALESCE(v_existing_match.transfer_pair_status, 'legacy_or_unknown'),
      'credit_available_now', v_existing_match.match_status = 'released_available_dashboard_credit'
    );
  END IF;

  SELECT a.* INTO v_existing_approval
  FROM public.completion_loyalty_reward_approvals a
  WHERE a.order_id = p_order_id
    AND a.approval_status IN ('approved_pending_funding','funding_submitted_pending_match','funding_confirmed_ready_to_release')
  ORDER BY a.created_at DESC, a.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_approval.id IS NULL THEN
    SELECT * INTO v_target
    FROM public.internal_main_bank_completion_loyalty_targets_v1(NULL, 300, 0) t
    WHERE t.order_id = p_order_id
    LIMIT 1;

    IF v_target.order_id IS NULL THEN
      RAISE EXCEPTION 'Completion loyalty target is not available for main-bank staging: %', p_order_id;
    END IF;

    v_amount := round(COALESCE(p_reward_amount_gbp, v_target.suggested_reward_gbp, 0)::numeric, 2);
    IF v_amount <= 0 THEN RAISE EXCEPTION 'Completion loyalty staging amount must be greater than zero.'; END IF;
    IF v_amount > round(COALESCE(v_target.suggested_reward_gbp, 0)::numeric, 2) + 0.01 THEN
      RAISE EXCEPTION 'Stage amount % cannot exceed suggested reward amount %.', v_amount, v_target.suggested_reward_gbp;
    END IF;

    v_approval_result := public.staff_approve_completion_loyalty_reward_v1(
      p_order_id,
      v_amount,
      10,
      'completion_loyalty_reward',
      p_notes
    );
    v_approval_id := (v_approval_result->>'approval_id')::uuid;
  ELSE
    v_approval_id := v_existing_approval.id;
    v_amount := round(COALESCE(p_reward_amount_gbp, v_existing_approval.approved_amount_gbp, 0)::numeric, 2);
    IF v_amount <= 0 THEN RAISE EXCEPTION 'Completion loyalty staging amount must be greater than zero.'; END IF;
    IF v_amount > round(COALESCE(v_existing_approval.approved_amount_gbp, 0)::numeric, 2) + 0.01 THEN
      RAISE EXCEPTION 'Stage amount % cannot exceed approved reward amount %.', v_amount, v_existing_approval.approved_amount_gbp;
    END IF;
  END IF;

  IF v_approval_id IS NULL THEN RAISE EXCEPTION 'Approval was not resolved for completion loyalty staging.'; END IF;

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

  IF v_amount > v_line_remaining + 0.01 THEN
    RAISE EXCEPTION 'Stage amount % exceeds remaining main-bank line amount %.', v_amount, v_line_remaining;
  END IF;

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
    created_by_auth_user_id,
    activation_route,
    card_used_by,
    transfer_pair_status
  ) VALUES (
    p_dva_statement_line_id,
    p_order_id,
    v_order.importer_id,
    v_approval_id,
    NULL,
    NULL,
    v_amount,
    'confirmed',
    p_notes,
    v_staff.id,
    v_auth_uid,
    v_activation_route,
    v_card_used_by,
    'source_out_reserved'
  ) RETURNING id INTO v_match_id;

  RETURN jsonb_build_object(
    'ok', true,
    'loyalty_match_id', v_match_id,
    'approval_id', v_approval_id,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'matched_gbp_amount', v_amount,
    'match_status', 'confirmed',
    'transfer_pair_status', 'source_out_reserved',
    'credit_available_now', false,
    'next_step', 'pair_destination_dva_or_virtual_card_in_line'
  );
END;
$$;

-- Backward-compatible name now stages only. It no longer releases dashboard credit from OUT alone.
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
BEGIN
  RETURN public.staff_stage_main_bank_line_to_completion_loyalty_v2(
    p_dva_statement_line_id,
    p_order_id,
    p_reward_amount_gbp,
    p_notes,
    'dva_account_top_up',
    'staff'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_destination_in_candidates_v1(
  p_importer_id uuid DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_id uuid,
  importer_id uuid,
  statement_date date,
  reference_raw text,
  direction text,
  amount_gbp numeric,
  remaining_gbp numeric,
  statement_account_label text,
  source_bank text,
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
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: loyalty destination IN candidates require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for loyalty destination IN candidates.'; END IF;

  RETURN QUERY
  WITH consumed_reconciliation AS (
    SELECT dr.dva_statement_line_id, round(COALESCE(sum(dr.reconciled_gbp_amount), 0)::numeric, 2) AS consumed_gbp
    FROM public.dva_reconciliation dr
    WHERE dr.dva_statement_line_id IS NOT NULL
    GROUP BY dr.dva_statement_line_id
  ), consumed_allocations AS (
    SELECT a.dva_statement_line_id, round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2) AS consumed_gbp
    FROM public.dva_statement_line_allocations a
    GROUP BY a.dva_statement_line_id
  ), consumed_loyalty_in AS (
    SELECT lm.destination_in_statement_line_id AS dva_statement_line_id,
           round(COALESCE(sum(lm.matched_gbp_amount) FILTER (WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit')), 0)::numeric, 2) AS consumed_gbp
    FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE lm.destination_in_statement_line_id IS NOT NULL
    GROUP BY lm.destination_in_statement_line_id
  ), base AS (
    SELECT
      dsl.id AS statement_line_id,
      ds.id AS statement_id,
      ds.importer_id,
      dsl.statement_date,
      dsl.reference_raw::text,
      dsl.direction::text,
      round(COALESCE(dsl.amount_gbp_equivalent, 0)::numeric, 2) AS amount_gbp,
      greatest(round((COALESCE(dsl.amount_gbp_equivalent, 0) - COALESCE(cr.consumed_gbp, 0) - COALESCE(ca.consumed_gbp, 0) - COALESCE(cli.consumed_gbp, 0))::numeric, 2), 0::numeric) AS remaining_gbp,
      ds.statement_account_label::text,
      ds.source_bank::text
    FROM public.dva_statement_lines dsl
    JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
    LEFT JOIN consumed_reconciliation cr ON cr.dva_statement_line_id = dsl.id
    LEFT JOIN consumed_allocations ca ON ca.dva_statement_line_id = dsl.id
    LEFT JOIN consumed_loyalty_in cli ON cli.dva_statement_line_id = dsl.id
    WHERE COALESCE(ds.statement_account_context, 'importer_dva_card_account') = 'importer_dva_card_account'
      AND dsl.direction = 'in'
      AND ds.importer_id IS NOT NULL
      AND (p_importer_id IS NULL OR ds.importer_id = p_importer_id)
  ), filtered AS (
    SELECT b.*
    FROM base b
    WHERE b.remaining_gbp > 0.01
      AND (v_search IS NULL OR lower(concat_ws(' ', b.reference_raw, b.statement_date::text, b.amount_gbp::text, b.source_bank, b.statement_account_label)) LIKE '%' || v_search || '%')
  )
  SELECT
    f.statement_line_id,
    f.statement_id,
    f.importer_id,
    f.statement_date,
    f.reference_raw,
    f.direction,
    f.amount_gbp,
    f.remaining_gbp,
    f.statement_account_label,
    f.source_bank,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date DESC, f.statement_line_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

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

  UPDATE public.main_bank_completion_loyalty_funding_matches
     SET destination_in_statement_line_id = p_destination_in_statement_line_id,
         transfer_pair_status = 'paired_ready_to_release',
         paired_at = now(),
         paired_by_staff_id = v_staff.id,
         paired_by_auth_user_id = v_auth_uid,
         variance_gbp = round((v_remaining_dest - v_match.matched_gbp_amount)::numeric, 2),
         notes = COALESCE(p_notes, notes)
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
         notes = COALESCE(p_notes, notes)
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
    'match_status', 'released_available_dashboard_credit',
    'transfer_pair_status', 'paired_released',
    'credit_available_now', true
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_staged_completion_loyalty_pairs_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  loyalty_match_id uuid,
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  source_out_statement_line_id uuid,
  source_out_reference text,
  source_out_date date,
  matched_gbp_amount numeric,
  match_status text,
  transfer_pair_status text,
  destination_in_statement_line_id uuid,
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
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: staged loyalty pairs require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for staged loyalty pairs.'; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      lm.id AS loyalty_match_id,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      lm.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      lm.dva_statement_line_id AS source_out_statement_line_id,
      dsl.reference_raw::text AS source_out_reference,
      dsl.statement_date AS source_out_date,
      lm.matched_gbp_amount,
      lm.match_status::text,
      COALESCE(lm.transfer_pair_status, 'source_out_reserved')::text AS transfer_pair_status,
      lm.destination_in_statement_line_id
    FROM public.main_bank_completion_loyalty_funding_matches lm
    JOIN public.orders o ON o.id = lm.completed_order_id
    LEFT JOIN public.importers i ON i.id = lm.importer_id
    LEFT JOIN public.dva_statement_lines dsl ON dsl.id = lm.dva_statement_line_id
    WHERE lm.match_status = 'confirmed'
      AND COALESCE(lm.transfer_pair_status, 'source_out_reserved') IN ('source_out_reserved','paired_ready_to_release')
  ), filtered AS (
    SELECT b.*
    FROM base b
    WHERE v_search IS NULL OR lower(concat_ws(' ', b.order_ref, b.importer_name, b.source_out_reference, b.matched_gbp_amount::text)) LIKE '%' || v_search || '%'
  )
  SELECT f.*, count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.source_out_date DESC NULLS LAST, f.loyalty_match_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_pair_loyalty_by_order_and_destination_v1(
  p_order_id uuid,
  p_destination_in_statement_line_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_match_id uuid;
BEGIN
  SELECT lm.id INTO v_match_id
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.completed_order_id = p_order_id
    AND lm.match_status = 'confirmed'
    AND COALESCE(lm.transfer_pair_status, 'source_out_reserved') IN ('source_out_reserved','paired_ready_to_release')
  ORDER BY lm.created_at DESC, lm.id DESC
  LIMIT 1;

  IF v_match_id IS NULL THEN
    RAISE EXCEPTION 'No staged completion loyalty OUT match found for order %.', p_order_id;
  END IF;

  RETURN public.staff_pair_loyalty_destination_in_and_release_v1(v_match_id, p_destination_in_statement_line_id, p_notes);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_apply_completion_loyalty_to_order_v1(
  p_order_id uuid,
  p_amount_gbp numeric DEFAULT NULL,
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
  v_existing_applied numeric(18,2) := 0;
  v_cash_funded numeric(18,2) := 0;
  v_gap numeric(18,2) := 0;
  v_available numeric(18,2) := 0;
  v_remaining_to_apply numeric(18,2) := 0;
  v_take numeric(18,2) := 0;
  v_total_applied numeric(18,2) := 0;
  v_lot record;
  v_debit_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: staff loyalty application requires auth.uid()'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Only admin or supervisor staff can apply completion loyalty to an order.'; END IF;

  SELECT
    o.id,
    o.order_ref,
    o.importer_id,
    COALESCE(o.order_total_gbp_declared, 0)::numeric AS order_total_gbp_declared,
    COALESCE(o.order_type, 'original') AS order_type,
    o.status
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found: %', p_order_id; END IF;
  IF v_order.order_type <> 'original' THEN RAISE EXCEPTION 'Completion loyalty can only be applied to original orders.'; END IF;
  IF v_order.status IN ('archived','cancelled') THEN RAISE EXCEPTION 'Cannot apply loyalty to order status %.', v_order.status; END IF;

  PERFORM 1
  FROM public.importer_credit_ledger c
  WHERE c.importer_id = v_order.importer_id
    AND c.lock_reason IS NULL
  ORDER BY c.created_at, c.id
  FOR UPDATE;

  SELECT ROUND(COALESCE(SUM(amount_gbp) FILTER (WHERE event_type = 'credit_applied'), 0)::numeric, 2),
         ROUND(COALESCE(SUM(amount_gbp) FILTER (WHERE event_type IN ('funding_contribution', 'manual_adjustment')), 0)::numeric, 2)
  INTO v_existing_applied, v_cash_funded
  FROM public.order_funding_events
  WHERE order_id = p_order_id;

  v_gap := ROUND(GREATEST(v_order.order_total_gbp_declared - COALESCE(v_existing_applied, 0) - COALESCE(v_cash_funded, 0), 0)::numeric, 2);

  IF v_gap <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'applied_gbp', 0, 'already_funded_or_applied', true, 'gap_before_gbp', v_gap, 'remaining_cash_due_gbp', 0);
  END IF;

  SELECT ROUND(COALESCE(SUM(l.available_amount_gbp), 0)::numeric, 2)
  INTO v_available
  FROM public.internal_importer_available_completion_loyalty_lots_v1(v_order.importer_id) l;

  v_remaining_to_apply := ROUND(LEAST(COALESCE(v_available, 0), v_gap, COALESCE(NULLIF(p_amount_gbp, 0), v_gap))::numeric, 2);

  IF v_remaining_to_apply <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'applied_gbp', 0, 'available_loyalty_before_gbp', v_available, 'gap_before_gbp', v_gap, 'remaining_cash_due_gbp', v_gap);
  END IF;

  FOR v_lot IN
    SELECT *
    FROM public.internal_importer_available_completion_loyalty_lots_v1(v_order.importer_id)
    ORDER BY effective_at, created_at, credit_ledger_id
  LOOP
    EXIT WHEN v_remaining_to_apply <= 0;
    v_take := ROUND(LEAST(v_lot.available_amount_gbp, v_remaining_to_apply)::numeric, 2);
    IF v_take <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.importer_credit_ledger(
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
      created_by_staff_id,
      notes
    ) VALUES (
      v_order.importer_id,
      'applied_to_order',
      'importer_credit_ledger',
      v_lot.credit_ledger_id,
      p_order_id,
      NULL,
      'debit',
      v_take,
      v_take,
      'GBP',
      now(),
      'credit_application',
      'importer_credit_ledger',
      v_lot.credit_ledger_id,
      p_order_id,
      v_staff.id,
      COALESCE(p_notes, 'Staff-applied completion loyalty reward to order.')
    ) RETURNING id INTO v_debit_id;

    INSERT INTO public.order_funding_events(
      order_id,
      event_type,
      amount_gbp,
      source_ref,
      source_entity_type,
      source_entity_id,
      created_at,
      notes
    ) VALUES (
      p_order_id,
      'credit_applied',
      v_take,
      CONCAT('importer_credit_ledger:', v_debit_id::text),
      'importer_credit_ledger',
      v_debit_id,
      now(),
      COALESCE(p_notes, 'Staff-applied completion loyalty reward to order.')
    )
    ON CONFLICT (event_type, source_entity_type, source_entity_id)
    WHERE source_entity_id IS NOT NULL
    DO UPDATE
      SET amount_gbp = EXCLUDED.amount_gbp,
          source_ref = EXCLUDED.source_ref,
          notes = EXCLUDED.notes;

    v_total_applied := ROUND((v_total_applied + v_take)::numeric, 2);
    v_remaining_to_apply := ROUND((v_remaining_to_apply - v_take)::numeric, 2);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'applied_gbp', v_total_applied,
    'available_loyalty_before_gbp', v_available,
    'gap_before_gbp', v_gap,
    'remaining_cash_due_gbp', ROUND(GREATEST(v_gap - v_total_applied, 0)::numeric, 2)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_loyalty_accounting_control_rows_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  queue_row_id text,
  source_type text,
  source_id uuid,
  category text,
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  amount_gbp numeric,
  accounting_treatment text,
  control_status text,
  blocker text,
  selectable boolean,
  detail_json jsonb,
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
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: loyalty accounting controls require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for loyalty accounting controls.'; END IF;

  RETURN QUERY
  WITH internal_transfer AS (
    SELECT
      ('loyalty_control:bank_internal_transfer:' || lm.id::text)::text AS queue_row_id,
      'main_bank_completion_loyalty_funding_matches'::text AS source_type,
      lm.id AS source_id,
      'bank_internal_transfer'::text AS category,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      lm.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      round(lm.matched_gbp_amount::numeric, 2) AS amount_gbp,
      'Dr DVA/card/virtual-card bank; Cr main bank'::text AS accounting_treatment,
      COALESCE(lm.transfer_pair_status, lm.match_status)::text AS control_status,
      CASE WHEN lm.destination_in_statement_line_id IS NULL THEN 'Destination DVA/card/virtual-card IN line not paired yet' ELSE NULL::text END AS blocker,
      false AS selectable,
      jsonb_build_object(
        'source_out_statement_line_id', lm.dva_statement_line_id,
        'destination_in_statement_line_id', lm.destination_in_statement_line_id,
        'activation_route', lm.activation_route,
        'card_used_by', lm.card_used_by,
        'match_status', lm.match_status,
        'transfer_pair_status', lm.transfer_pair_status,
        'posting_note', 'Read-only control row. Do not post through cash freeze/batch.'
      ) AS detail_json
    FROM public.main_bank_completion_loyalty_funding_matches lm
    JOIN public.orders o ON o.id = lm.completed_order_id
    LEFT JOIN public.importers i ON i.id = lm.importer_id
    WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit')
  ), non_cash_settlement AS (
    SELECT
      ('loyalty_control:non_cash_loyalty_customer_balance_settlement:' || d.id::text)::text AS queue_row_id,
      'importer_credit_ledger'::text AS source_type,
      d.id AS source_id,
      'non_cash_loyalty_customer_balance_settlement'::text AS category,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      d.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      round(abs(d.amount_gbp)::numeric, 2) AS amount_gbp,
      'Dr loyalty cost / reward expense / loyalty liability; Cr customer account / receivable'::text AS accounting_treatment,
      'applied_to_order'::text AS control_status,
      NULL::text AS blocker,
      false AS selectable,
      jsonb_build_object(
        'source_credit_ledger_id', COALESCE(d.source_id, d.source_entity_id),
        'debit_ledger_id', d.id,
        'applied_to_order_id', d.applied_to_order_id,
        'posting_note', 'Read-only accounting control row. Posting adapter not enabled in MVP.'
      ) AS detail_json
    FROM public.importer_credit_ledger d
    JOIN public.orders o ON o.id = d.applied_to_order_id
    LEFT JOIN public.importers i ON i.id = d.importer_id
    WHERE d.direction = 'debit'
      AND d.entry_type = 'applied_to_order'
      AND d.lock_reason IS NULL
      AND EXISTS (
        SELECT 1
        FROM public.importer_credit_ledger c
        WHERE c.id = COALESCE(d.source_id, d.source_entity_id)
          AND c.source_type = 'completion_loyalty_reward'
      )
  ), released_unused AS (
    SELECT
      ('loyalty_control:released_unused_loyalty_control_balance:' || c.credit_ledger_id::text)::text AS queue_row_id,
      'importer_credit_ledger'::text AS source_type,
      c.credit_ledger_id AS source_id,
      'released_unused_loyalty_control_balance'::text AS category,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      icl.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      round(c.available_amount_gbp::numeric, 2) AS amount_gbp,
      'Control balance only in MVP; no automatic P&L accrual/posting'::text AS accounting_treatment,
      'released_unused'::text AS control_status,
      NULL::text AS blocker,
      false AS selectable,
      jsonb_build_object(
        'credit_ledger_id', c.credit_ledger_id,
        'source_order_id', c.source_order_id,
        'posting_note', 'Read-only month-end control row.'
      ) AS detail_json
    FROM public.importer_credit_ledger icl
    JOIN LATERAL public.internal_importer_available_completion_loyalty_lots_v1(icl.importer_id) c ON c.credit_ledger_id = icl.id
    LEFT JOIN public.orders o ON o.id = c.source_order_id
    LEFT JOIN public.importers i ON i.id = icl.importer_id
  ), unioned AS (
    SELECT * FROM internal_transfer
    UNION ALL
    SELECT * FROM non_cash_settlement
    UNION ALL
    SELECT * FROM released_unused
  ), filtered AS (
    SELECT u.*
    FROM unioned u
    WHERE v_search IS NULL OR lower(concat_ws(' ', u.order_ref, u.importer_name, u.category, u.control_status, u.amount_gbp::text)) LIKE '%' || v_search || '%'
  )
  SELECT f.*, count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.category, f.order_ref DESC NULLS LAST, f.source_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

-- Loyalty-aware statement summary now recognises both the source OUT line and destination IN line.
CREATE OR REPLACE VIEW public.dva_statement_line_allocation_summary_vw AS
WITH allocation_totals AS (
  SELECT
    a.dva_statement_line_id,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric AS normal_confirmed_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status IN ('draft', 'held')), 0)::numeric AS open_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type = 'supplier_invoice'), 0)::numeric AS supplier_invoice_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type = 'retailer_refund'), 0)::numeric AS retailer_refund_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type IN ('fx_card_difference', 'bank_fee')), 0)::numeric AS fx_card_or_fee_allocated_gbp,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type IN ('exception_hold', 'not_charged_closure', 'unmatched_hold')), 0)::numeric AS exception_or_hold_allocated_gbp,
    COUNT(a.id) FILTER (WHERE a.allocation_status <> 'reversed') AS active_allocation_count,
    COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type = 'final_balance_payment'), 0)::numeric AS final_balance_payment_allocated_gbp
  FROM public.dva_statement_line_allocations a
  GROUP BY a.dva_statement_line_id
), loyalty_line_totals AS (
  SELECT
    x.dva_statement_line_id,
    ROUND(COALESCE(SUM(x.matched_gbp_amount), 0)::numeric, 2) AS loyalty_credit_funding_allocated_gbp,
    COUNT(*) FILTER (WHERE x.side = 'source_out') AS main_bank_loyalty_match_count,
    ROUND(COALESCE(SUM(x.matched_gbp_amount) FILTER (WHERE x.side = 'source_out'), 0)::numeric, 2) AS loyalty_internal_transfer_out_gbp,
    ROUND(COALESCE(SUM(x.matched_gbp_amount) FILTER (WHERE x.side = 'destination_in'), 0)::numeric, 2) AS loyalty_internal_transfer_in_gbp,
    COUNT(*) FILTER (WHERE x.side = 'destination_in') AS loyalty_internal_transfer_in_count
  FROM (
    SELECT lm.dva_statement_line_id, lm.matched_gbp_amount, 'source_out'::text AS side
    FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE lm.match_status IN ('confirmed', 'released_available_dashboard_credit')
    UNION ALL
    SELECT lm.destination_in_statement_line_id, lm.matched_gbp_amount, 'destination_in'::text AS side
    FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE lm.destination_in_statement_line_id IS NOT NULL
      AND lm.match_status IN ('confirmed', 'released_available_dashboard_credit')
  ) x
  WHERE x.dva_statement_line_id IS NOT NULL
  GROUP BY x.dva_statement_line_id
), base AS (
  SELECT
    l.id AS dva_statement_line_id,
    l.dva_statement_id,
    s.importer_id,
    l.statement_date,
    l.reference_raw,
    l.direction,
    l.amount_local_ccy,
    l.local_ccy,
    l.fx_rate_applied,
    l.card_markup_pct_applied,
    l.amount_gbp_equivalent AS statement_gbp_amount,
    l.auth_id_ref,
    l.retailer_name_ref,
    l.match_status,
    COALESCE(a.normal_confirmed_allocated_gbp, 0) AS normal_confirmed_allocated_gbp,
    COALESCE(a.open_allocated_gbp, 0) AS open_allocated_gbp,
    COALESCE(a.supplier_invoice_allocated_gbp, 0) AS supplier_invoice_allocated_gbp,
    COALESCE(a.retailer_refund_allocated_gbp, 0) AS retailer_refund_allocated_gbp,
    COALESCE(a.fx_card_or_fee_allocated_gbp, 0) AS fx_card_or_fee_allocated_gbp,
    COALESCE(a.exception_or_hold_allocated_gbp, 0) AS exception_or_hold_allocated_gbp,
    COALESCE(a.active_allocation_count, 0) AS active_allocation_count,
    COALESCE(a.final_balance_payment_allocated_gbp, 0) AS final_balance_payment_allocated_gbp,
    COALESCE(loyalty.loyalty_credit_funding_allocated_gbp, 0) AS loyalty_credit_funding_allocated_gbp,
    COALESCE(loyalty.main_bank_loyalty_match_count, 0) AS main_bank_loyalty_match_count,
    COALESCE(loyalty.loyalty_internal_transfer_out_gbp, 0) AS loyalty_internal_transfer_out_gbp,
    COALESCE(loyalty.loyalty_internal_transfer_in_gbp, 0) AS loyalty_internal_transfer_in_gbp,
    COALESCE(loyalty.loyalty_internal_transfer_in_count, 0) AS loyalty_internal_transfer_in_count,
    COALESCE(s.statement_account_context, 'importer_dva_card_account') AS statement_account_context,
    s.statement_account_label,
    s.source_bank
  FROM public.dva_statement_lines l
  JOIN public.dva_statements s ON s.id = l.dva_statement_id
  LEFT JOIN allocation_totals a ON a.dva_statement_line_id = l.id
  LEFT JOIN loyalty_line_totals loyalty ON loyalty.dva_statement_line_id = l.id
)
SELECT
  dva_statement_line_id,
  dva_statement_id,
  importer_id,
  statement_date,
  reference_raw,
  direction,
  amount_local_ccy,
  local_ccy,
  fx_rate_applied,
  card_markup_pct_applied,
  statement_gbp_amount,
  auth_id_ref,
  retailer_name_ref,
  match_status,
  (normal_confirmed_allocated_gbp + loyalty_credit_funding_allocated_gbp) AS confirmed_allocated_gbp,
  open_allocated_gbp,
  supplier_invoice_allocated_gbp,
  retailer_refund_allocated_gbp,
  fx_card_or_fee_allocated_gbp,
  exception_or_hold_allocated_gbp,
  active_allocation_count,
  (statement_gbp_amount - normal_confirmed_allocated_gbp - loyalty_credit_funding_allocated_gbp) AS confirmed_unallocated_gbp,
  (ABS(statement_gbp_amount - normal_confirmed_allocated_gbp - loyalty_credit_funding_allocated_gbp) < 0.01) AS confirmed_balanced_yn,
  final_balance_payment_allocated_gbp,
  statement_account_context,
  statement_account_label,
  source_bank,
  loyalty_credit_funding_allocated_gbp,
  main_bank_loyalty_match_count,
  CASE
    WHEN loyalty_internal_transfer_out_gbp > 0 THEN 'loyalty_internal_transfer_out'
    WHEN loyalty_internal_transfer_in_gbp > 0 THEN 'loyalty_internal_transfer_in'
    WHEN final_balance_payment_allocated_gbp > 0 THEN 'final_balance_payment'
    WHEN supplier_invoice_allocated_gbp > 0 THEN 'supplier_invoice'
    WHEN retailer_refund_allocated_gbp > 0 THEN 'retailer_refund'
    WHEN fx_card_or_fee_allocated_gbp > 0 THEN 'fx_card_or_fee'
    WHEN exception_or_hold_allocated_gbp > 0 THEN 'exception_or_hold'
    ELSE NULL
  END AS control_match_reason,
  loyalty_internal_transfer_out_gbp,
  loyalty_internal_transfer_in_gbp,
  loyalty_internal_transfer_in_count
FROM base;

COMMENT ON VIEW public.dva_statement_line_allocation_summary_vw IS
'Read model showing allocation totals and remaining balance for each DVA/card/bank statement line. Includes supplier, refund, final-balance, FX/card, fee, hold allocations, and source/destination completion-loyalty internal-transfer control without creating fake allocation rows.';

NOTIFY pgrst, 'reload schema';

COMMIT;
