BEGIN;

SET TRANSACTION READ ONLY;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_auth_uid uuid;
  v_order record;
  v_q record;
  v_p record;
  v_w record;
  v_s record;
  v_count integer;
BEGIN
  IF to_regprocedure('public.internal_order_final_sale_settlement_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: settlement v1 is missing.';
  END IF;
  IF to_regprocedure('public.internal_order_final_sale_settlement_v2(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: settlement v2 is missing.';
  END IF;
  IF to_regprocedure('public.internal_order_qualifying_net_spend_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: qualifying net spend v1 is missing.';
  END IF;
  IF to_regprocedure('public.internal_completion_loyalty_reward_proposals_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: completion loyalty proposal v1 is missing.';
  END IF;
  IF to_regprocedure('public.internal_completion_loyalty_reward_funding_workbench_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: completion loyalty funding workbench v1 is missing.';
  END IF;

  -- The implementation contract is a dependency substitution only.
  IF pg_get_functiondef('public.internal_order_qualifying_net_spend_v1(uuid)'::regprocedure)
       NOT ILIKE '%internal_order_final_sale_settlement_v2(p_order_id)%' THEN
    RAISE EXCEPTION 'FAIL: qualifying net spend is not connected to settlement v2.';
  END IF;

  IF pg_get_functiondef('public.internal_order_qualifying_net_spend_v1(uuid)'::regprocedure)
       ILIKE '%internal_order_final_sale_settlement_v1(p_order_id)%' THEN
    RAISE EXCEPTION 'FAIL: qualifying net spend still calls settlement v1 directly.';
  END IF;

  SELECT s.auth_user_id INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin', 'supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.id
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active admin/supervisor auth user is available for read-model regression.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );

  -- Estate-wide contract: v2 must preserve the v1 population and every field
  -- except the fields deliberately derived from final-balance-aware receipts.
  IF EXISTS (
    WITH v1 AS (
      SELECT * FROM public.internal_order_final_sale_settlement_v1(NULL)
    ), v2 AS (
      SELECT * FROM public.internal_order_final_sale_settlement_v2(NULL)
    )
    SELECT 1
    FROM v1
    FULL OUTER JOIN v2 USING (order_id)
    WHERE v1.order_id IS NULL OR v2.order_id IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: settlement v1/v2 row population mismatch.';
  END IF;

  IF EXISTS (
    WITH v1 AS (
      SELECT * FROM public.internal_order_final_sale_settlement_v1(NULL)
    ), v2 AS (
      SELECT * FROM public.internal_order_final_sale_settlement_v2(NULL)
    )
    SELECT 1
    FROM v1
    JOIN v2 USING (order_id)
    WHERE (
      to_jsonb(v1)
      - ARRAY[
          'amount_received_gbp',
          'final_balance_due_gbp',
          'raw_potential_credit_gbp',
          'potential_credit_pending_review_gbp',
          'final_settlement_state',
          'completion_state',
          'completion_blocker',
          'show_balance_due_yn',
          'show_potential_credit_yn'
        ]::text[]
    ) IS DISTINCT FROM (
      to_jsonb(v2)
      - ARRAY[
          'amount_received_gbp',
          'final_balance_due_gbp',
          'raw_potential_credit_gbp',
          'potential_credit_pending_review_gbp',
          'final_settlement_state',
          'completion_state',
          'completion_blocker',
          'show_balance_due_yn',
          'show_potential_credit_yn'
        ]::text[]
    )
  ) THEN
    RAISE EXCEPTION 'FAIL: settlement v2 changed an inherited/non-settlement field.';
  END IF;

  IF EXISTS (
    WITH fb AS (
      SELECT
        a.order_id,
        ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) AS final_balance_payment_gbp
      FROM public.dva_statement_line_allocations a
      WHERE a.allocation_type = 'final_balance_payment'
        AND a.allocation_status = 'confirmed'
        AND a.order_id IS NOT NULL
      GROUP BY a.order_id
    )
    SELECT 1
    FROM public.internal_order_final_sale_settlement_v1(NULL) v1
    JOIN public.internal_order_final_sale_settlement_v2(NULL) v2 USING (order_id)
    LEFT JOIN fb USING (order_id)
    WHERE ROUND(
      COALESCE(v2.amount_received_gbp, 0)
      - (COALESCE(v1.amount_received_gbp, 0) + COALESCE(fb.final_balance_payment_gbp, 0)),
      2
    ) <> 0
  ) THEN
    RAISE EXCEPTION 'FAIL: settlement v2 received amount is not v1 plus confirmed final-balance payments.';
  END IF;

  IF EXISTS (
    WITH fb AS (
      SELECT
        a.order_id,
        ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) AS final_balance_payment_gbp
      FROM public.dva_statement_line_allocations a
      WHERE a.allocation_type = 'final_balance_payment'
        AND a.allocation_status = 'confirmed'
        AND a.order_id IS NOT NULL
      GROUP BY a.order_id
    )
    SELECT 1
    FROM public.internal_order_final_sale_settlement_v1(NULL) v1
    JOIN public.internal_order_final_sale_settlement_v2(NULL) v2 USING (order_id)
    LEFT JOIN fb USING (order_id)
    WHERE COALESCE(fb.final_balance_payment_gbp, 0) = 0
      AND (
        v1.amount_received_gbp IS DISTINCT FROM v2.amount_received_gbp
        OR v1.final_balance_due_gbp IS DISTINCT FROM v2.final_balance_due_gbp
        OR v1.raw_potential_credit_gbp IS DISTINCT FROM v2.raw_potential_credit_gbp
        OR v1.potential_credit_pending_review_gbp IS DISTINCT FROM v2.potential_credit_pending_review_gbp
        OR v1.final_settlement_state IS DISTINCT FROM v2.final_settlement_state
        OR v1.completion_state IS DISTINCT FROM v2.completion_state
        OR v1.completion_blocker IS DISTINCT FROM v2.completion_blocker
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: an order without confirmed final-balance payment drifted between settlement v1 and v2.';
  END IF;

  -- Every current genuine final-balance blocker exposed by v2 must remain a
  -- final-balance blocker in qualifying net spend.
  IF EXISTS (
    SELECT 1
    FROM public.internal_order_final_sale_settlement_v2(NULL) s
    JOIN public.internal_order_qualifying_net_spend_v1(NULL) q USING (order_id)
    WHERE s.completion_blocker = 'final_balance_due'
      AND q.basis_blocker IS DISTINCT FROM 'final_balance_due'
  ) THEN
    RAISE EXCEPTION 'FAIL: a genuine final-balance blocker was cleared by the loyalty integration.';
  END IF;

  -- Estate-wide corrected-settlement contract: whenever v2 says an order is
  -- complete with no final balance due, no final_balance_due blocker may survive
  -- anywhere in the current completion-loyalty chain.
  IF EXISTS (
    SELECT 1
    FROM public.internal_order_final_sale_settlement_v2(NULL) s
    JOIN public.internal_order_qualifying_net_spend_v1(NULL) q USING (order_id)
    JOIN public.internal_completion_loyalty_reward_proposals_v1(NULL) p USING (order_id)
    JOIN public.internal_completion_loyalty_reward_funding_workbench_v1(NULL) w USING (order_id)
    WHERE ROUND(COALESCE(s.final_balance_due_gbp, 0), 2) = 0.00
      AND s.completion_state = 'complete'
      AND (
        q.completion_blocker = 'final_balance_due'
        OR q.basis_blocker = 'final_balance_due'
        OR p.completion_blocker = 'final_balance_due'
        OR p.basis_blocker = 'final_balance_due'
        OR p.approval_blocker = 'final_balance_due'
        OR w.completion_blocker = 'final_balance_due'
        OR w.basis_blocker = 'final_balance_due'
        OR w.approval_blocker = 'final_balance_due'
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: a v2-complete zero-balance order still carries final_balance_due in the loyalty chain.';
  END IF;

  -- Partial/no-final-sale states must not become reward-ready.
  IF EXISTS (
    SELECT 1
    FROM public.internal_order_final_sale_settlement_v2(NULL) s
    JOIN public.internal_order_qualifying_net_spend_v1(NULL) q USING (order_id)
    WHERE (
      s.final_settlement_state IN ('no_final_sale_documents', 'partial_final_sale_posted')
      OR s.final_sale_value_exists IS DISTINCT FROM true
      OR s.customer_sales_state = 'partial_posted'
    )
      AND q.basis_status = 'ready'
  ) THEN
    RAISE EXCEPTION 'FAIL: partial/no-final-sale order became loyalty basis ready.';
  END IF;

  -- Three proven affected orders: corrected settlement/completion values and no
  -- false final_balance_due blocker may survive into the loyalty chain.
  FOR v_order IN
    SELECT *
    FROM (VALUES
      ('ORD-1777736251155'::text, 211.99::numeric, 'credit_added_to_account'::text),
      ('ORD-1781443253680'::text, 120.00::numeric, 'settled_nil'::text),
      ('ORD-1786093662671'::text, 620.00::numeric, 'credit_added_to_account'::text)
    ) AS t(order_ref, expected_received_gbp, expected_settlement_state)
  LOOP
    SELECT * INTO v_s
    FROM public.internal_order_final_sale_settlement_v2(NULL) s
    WHERE s.order_ref = v_order.order_ref;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'FAIL: expected affected order % missing from settlement v2.', v_order.order_ref;
    END IF;

    IF ROUND(v_s.amount_received_gbp, 2) <> v_order.expected_received_gbp
       OR ROUND(v_s.final_balance_due_gbp, 2) <> 0.00
       OR v_s.final_settlement_state <> v_order.expected_settlement_state
       OR v_s.completion_state <> 'complete'
       OR v_s.completion_blocker IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL: settlement v2 fingerprint mismatch for %: %', v_order.order_ref, to_jsonb(v_s);
    END IF;

    SELECT * INTO v_q
    FROM public.internal_order_qualifying_net_spend_v1(v_s.order_id) q;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'FAIL: qualifying net spend missing for %.', v_order.order_ref;
    END IF;

    IF ROUND(v_q.final_balance_due_gbp, 2) <> 0.00
       OR v_q.completion_state <> 'complete'
       OR v_q.completion_blocker = 'final_balance_due'
       OR v_q.basis_blocker = 'final_balance_due' THEN
      RAISE EXCEPTION 'FAIL: false final-balance blocker remains in qualifying net spend for %: %', v_order.order_ref, to_jsonb(v_q);
    END IF;

    SELECT * INTO v_p
    FROM public.internal_completion_loyalty_reward_proposals_v1(v_s.order_id) p;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'FAIL: loyalty proposal missing for %.', v_order.order_ref;
    END IF;

    IF v_p.completion_blocker = 'final_balance_due'
       OR v_p.basis_blocker = 'final_balance_due'
       OR v_p.approval_blocker = 'final_balance_due' THEN
      RAISE EXCEPTION 'FAIL: false final-balance blocker remains in loyalty proposal for %: %', v_order.order_ref, to_jsonb(v_p);
    END IF;

    SELECT * INTO v_w
    FROM public.internal_completion_loyalty_reward_funding_workbench_v1(v_s.order_id) w;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'FAIL: loyalty workbench row missing for %.', v_order.order_ref;
    END IF;

    IF v_w.completion_blocker = 'final_balance_due'
       OR v_w.basis_blocker = 'final_balance_due'
       OR v_w.approval_blocker = 'final_balance_due' THEN
      RAISE EXCEPTION 'FAIL: false final-balance blocker remains in loyalty workbench for %: %', v_order.order_ref, to_jsonb(v_w);
    END IF;
  END LOOP;

  -- Existing reward protection: this historical order must not become eligible
  -- for a duplicate completion-loyalty reward after its false settlement blocker clears.
  SELECT * INTO v_p
  FROM public.internal_completion_loyalty_reward_proposals_v1(NULL) p
  WHERE p.order_ref = 'ORD-1777736251155';

  IF NOT FOUND OR v_p.approval_blocker IS DISTINCT FROM 'completion_loyalty_reward_already_exists' THEN
    RAISE EXCEPTION 'FAIL: existing reward duplicate protection changed for ORD-1777736251155: %', to_jsonb(v_p);
  END IF;

  -- Target order: the existing £0.79 approved customer settlement credit remains
  -- separate from the £620 payment receipt and must stay exactly £0.79.
  SELECT * INTO v_s
  FROM public.internal_order_final_sale_settlement_v2(NULL) s
  WHERE s.order_ref = 'ORD-1786093662671';

  IF NOT FOUND
     OR ROUND(v_s.amount_received_gbp, 2) <> 620.00
     OR ROUND(v_s.approved_account_credit_gbp, 2) <> 0.79
     OR ROUND(v_s.final_balance_due_gbp, 2) <> 0.00
     OR v_s.final_settlement_state <> 'credit_added_to_account' THEN
    RAISE EXCEPTION 'FAIL: target settlement/payment-credit separation changed: %', to_jsonb(v_s);
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM public.dva_statement_line_allocations a
  JOIN public.orders o ON o.id = a.order_id
  WHERE o.order_ref = 'ORD-1786093662671'
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed'
    AND ROUND(a.allocated_gbp_amount, 2) = 20.00;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: target confirmed £20 final-balance allocation fingerprint changed; found % rows.', v_count;
  END IF;
END;
$regression$;

ROLLBACK;
