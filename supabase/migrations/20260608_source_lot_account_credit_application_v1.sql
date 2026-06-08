BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Source-lot account credit application.
-- Customer-facing balance stays one account-credit pot.
-- Internal ledger consumption is source-aware for audit and prevents hidden VAT/cashback wording leaks.
-- Balance compatibility rule: unlocked debit rows still reduce the account-credit pot, even when legacy rows were not source-lot linked.

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
      ('completion_loyalty_reward'::text, 6),
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

REVOKE ALL ON FUNCTION public.internal_importer_available_account_credit_lots_v1(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.customer_importer_credit_balance_v1()
RETURNS TABLE(importer_id uuid, available_credit_gbp numeric)
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
  )
  SELECT
    ci.importer_id,
    ROUND(COALESCE(SUM(lot.available_amount_gbp), 0)::numeric, 2) AS available_credit_gbp
  FROM current_importer ci
  LEFT JOIN LATERAL public.internal_importer_available_account_credit_lots_v1(ci.importer_id) lot ON true
  GROUP BY ci.importer_id;
$$;

CREATE OR REPLACE FUNCTION public.customer_apply_available_credit_to_order_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator record;
  v_order record;
  v_available numeric := 0;
  v_existing_applied numeric := 0;
  v_cash_funded numeric := 0;
  v_gap numeric := 0;
  v_remaining_to_apply numeric := 0;
  v_take numeric := 0;
  v_total_applied numeric := 0;
  v_credit_ledger_id uuid;
  v_funding_event_id uuid;
  v_lot record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT
    op.id AS operator_id,
    oi.importer_id
  INTO v_operator
  FROM public.operators op
  JOIN public.operator_importers oi
    ON oi.operator_id = op.id
   AND oi.revoked_at IS NULL
  WHERE op.auth_user_id = auth.uid()
    AND COALESCE(op.active, true) = true
  ORDER BY oi.granted_at DESC NULLS LAST, oi.id DESC
  LIMIT 1;

  IF v_operator.operator_id IS NULL THEN
    RAISE EXCEPTION 'Active customer/operator assignment not found.';
  END IF;

  SELECT
    o.id,
    o.importer_id,
    o.operator_id,
    COALESCE(o.order_total_gbp_declared, 0)::numeric AS order_total_gbp_declared,
    COALESCE(o.order_type, 'original') AS order_type,
    o.status
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_order.importer_id IS DISTINCT FROM v_operator.importer_id THEN RAISE EXCEPTION 'Order/importer mismatch.'; END IF;
  IF v_order.operator_id IS DISTINCT FROM v_operator.operator_id THEN RAISE EXCEPTION 'Order/operator mismatch.'; END IF;
  IF v_order.order_type <> 'original' THEN RAISE EXCEPTION 'Credit can only auto-apply to original orders.'; END IF;
  IF v_order.status IN ('archived', 'cancelled') THEN RAISE EXCEPTION 'Cannot apply credit to order status %.', v_order.status; END IF;

  -- Lock all unlocked account-credit rows and debits for this importer so concurrent applications cannot double-spend.
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
  FROM public.internal_importer_available_account_credit_lots_v1(v_order.importer_id) l;

  v_remaining_to_apply := ROUND(LEAST(COALESCE(v_available, 0), v_gap)::numeric, 2);

  IF v_remaining_to_apply <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'applied_gbp', 0, 'available_credit_before_gbp', v_available, 'gap_before_gbp', v_gap, 'remaining_cash_due_gbp', v_gap);
  END IF;

  FOR v_lot IN
    SELECT *
    FROM public.internal_importer_available_account_credit_lots_v1(v_order.importer_id)
    ORDER BY priority, effective_at, created_at, credit_ledger_id
  LOOP
    EXIT WHEN v_remaining_to_apply <= 0;

    v_take := ROUND(LEAST(v_lot.available_amount_gbp, v_remaining_to_apply)::numeric, 2);
    IF v_take <= 0 THEN
      CONTINUE;
    END IF;

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
      'Applied account credit to order.'
    ) RETURNING id INTO v_credit_ledger_id;

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
      CONCAT('importer_credit_ledger:', v_credit_ledger_id::text),
      'importer_credit_ledger',
      v_credit_ledger_id,
      now(),
      'Applied account credit to order.'
    )
    ON CONFLICT (event_type, source_entity_type, source_entity_id)
    WHERE source_entity_id IS NOT NULL
    DO UPDATE
      SET amount_gbp = EXCLUDED.amount_gbp,
          source_ref = EXCLUDED.source_ref,
          notes = EXCLUDED.notes
    RETURNING id INTO v_funding_event_id;

    v_total_applied := ROUND((v_total_applied + v_take)::numeric, 2);
    v_remaining_to_apply := ROUND((v_remaining_to_apply - v_take)::numeric, 2);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'applied_gbp', v_total_applied,
    'available_credit_before_gbp', v_available,
    'gap_before_gbp', v_gap,
    'remaining_cash_due_gbp', ROUND(GREATEST(v_gap - v_total_applied, 0)::numeric, 2)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.customer_importer_credit_balance_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_apply_available_credit_to_order_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_importer_credit_balance_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_apply_available_credit_to_order_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
