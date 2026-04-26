-- =============================================================================
-- staff_dva_reconciliation_wrapper_v1.sql
-- Multi Tenant Platform Build — staff-safe DVA order-funding reconciliation RPC
--
-- Purpose:
--   Add a narrow SECURITY DEFINER wrapper for staff UI DVA reconciliation.
--   This does not replace the proven backend path. It inserts into
--   dva_reconciliation and lets the existing trigger/helper path sync:
--     dva_reconciliation
--       -> order_funding_events
--       -> orders.funded_at recompute
--       -> importer overfunding credit mirroring
--
-- Governing contract:
--   docs/governing-pack/ui/DVA_RECONCILIATION_ACTION_CONTRACT.md
--
-- Install after:
--   1. goodcashback-complete.v4.sql
--   2. closure_v2_migration_v2.sql
--   3. closure_v2_functions_final_day6_8_clarified.sql
--   4. closure_v2_seed.sql
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. PREREQUISITE ASSERTIONS
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.dva_reconciliation') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_reconciliation';
  END IF;

  IF to_regclass('public.dva_statement_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_lines';
  END IF;

  IF to_regclass('public.dva_statements') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statements';
  END IF;

  IF to_regclass('public.order_funding_events') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_funding_events. Run closure_v2_migration_v2.sql first';
  END IF;

  IF to_regprocedure('public.order_funding_gap_gbp(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_funding_gap_gbp(uuid). Run closure_v2_functions_final_day6_8_clarified.sql first';
  END IF;

  IF to_regprocedure('public.order_funding_total_gbp(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_funding_total_gbp(uuid). Run closure_v2_functions_final_day6_8_clarified.sql first';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'staff'
      AND column_name IN ('id', 'auth_user_id', 'role_type', 'active')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 4
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: expected staff identity columns';
  END IF;
END $$;

-- =============================================================================
-- 1. STAFF-SAFE DVA ORDER-FUNDING WRAPPER
-- =============================================================================

CREATE OR REPLACE FUNCTION public.staff_reconcile_dva_line_to_order(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reconciled_gbp_amount numeric DEFAULT NULL,
  p_allow_overfunding boolean DEFAULT false,
  p_match_suggestion_id uuid DEFAULT NULL,
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
  v_order record;
  v_match record;
  v_existing_reconciliation_id uuid;
  v_reconciliation_id uuid;
  v_funding_event_id uuid;
  v_effective_amount numeric(12,2);
  v_gap_before numeric(12,2);
  v_gap_after numeric(12,2);
  v_total_after numeric(12,2);
  v_overfunding_amount numeric(12,2);
  v_overfunding_credit_after numeric(12,2);
  v_funded_at timestamptz;
BEGIN
  -- ---------------------------------------------------------------------------
  -- Staff validation. The browser must not pass a staff id; identity is derived
  -- from auth.uid() so RLS/session boundaries are auditable.
  -- ---------------------------------------------------------------------------
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff DVA reconciliation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can reconcile DVA funding lines. Current role: %', v_staff.role_type;
  END IF;

  -- ---------------------------------------------------------------------------
  -- DVA statement line validation.
  -- ---------------------------------------------------------------------------
  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.match_status,
    dsl.auth_id_ref,
    dsl.reference_raw,
    ds.importer_id
  INTO v_line
  FROM dva_statement_lines dsl
  JOIN dva_statements ds
    ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'DVA statement line not found: %', p_dva_statement_line_id;
  END IF;

  IF v_line.direction <> 'in' THEN
    RAISE EXCEPTION 'DVA statement line % is direction %, expected inbound funding line', p_dva_statement_line_id, v_line.direction;
  END IF;

  SELECT dr.id
    INTO v_existing_reconciliation_id
  FROM dva_reconciliation dr
  WHERE dr.dva_statement_line_id = p_dva_statement_line_id
  LIMIT 1;

  IF v_existing_reconciliation_id IS NOT NULL THEN
    RAISE EXCEPTION 'DVA statement line % is already reconciled by dva_reconciliation %', p_dva_statement_line_id, v_existing_reconciliation_id;
  END IF;

  v_effective_amount := ROUND(COALESCE(p_reconciled_gbp_amount, v_line.amount_gbp_equivalent)::numeric, 2);

  IF v_effective_amount IS NULL OR v_effective_amount <= 0 THEN
    RAISE EXCEPTION 'Reconciled GBP amount must be greater than zero. Received: %', v_effective_amount;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Order validation.
  -- ---------------------------------------------------------------------------
  SELECT
    o.id,
    o.order_ref,
    o.importer_id,
    COALESCE(o.order_type, 'original') AS order_type,
    o.status
  INTO v_order
  FROM orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Importer mismatch: DVA line importer % cannot fund order % importer %', v_line.importer_id, p_order_id, v_order.importer_id;
  END IF;

  IF v_order.order_type <> 'original' THEN
    RAISE EXCEPTION 'DVA funding can only target original orders. Order % has order_type %', p_order_id, v_order.order_type;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'DVA funding cannot target order % with status %', p_order_id, v_order.status;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Optional match suggestion validation.
  -- ---------------------------------------------------------------------------
  IF p_match_suggestion_id IS NOT NULL THEN
    SELECT ms.*
      INTO v_match
    FROM match_suggestions ms
    WHERE ms.id = p_match_suggestion_id
    FOR UPDATE;

    IF v_match.id IS NULL THEN
      RAISE EXCEPTION 'Match suggestion not found: %', p_match_suggestion_id;
    END IF;

    IF v_match.dva_statement_line_id IS DISTINCT FROM p_dva_statement_line_id THEN
      RAISE EXCEPTION 'Match suggestion % does not belong to DVA statement line %', p_match_suggestion_id, p_dva_statement_line_id;
    END IF;

    IF v_match.suggested_match_type <> 'order' THEN
      RAISE EXCEPTION 'Match suggestion % has type %, expected order', p_match_suggestion_id, v_match.suggested_match_type;
    END IF;

    IF v_match.suggested_match_id IS DISTINCT FROM p_order_id THEN
      RAISE EXCEPTION 'Match suggestion % points to %, not order %', p_match_suggestion_id, v_match.suggested_match_id, p_order_id;
    END IF;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Overfunding guard. Overfunding is proven Day 2 behaviour, but the UI must
  -- make it explicit to prevent accidental surplus application.
  -- ---------------------------------------------------------------------------
  v_gap_before := ROUND(COALESCE(order_funding_gap_gbp(p_order_id), 0)::numeric, 2);
  v_overfunding_amount := ROUND(GREATEST(v_effective_amount - v_gap_before, 0)::numeric, 2);

  IF v_gap_before = 0 AND COALESCE(p_allow_overfunding, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Order % is already funded. DVA overfunding requires p_allow_overfunding = true', p_order_id;
  END IF;

  IF v_effective_amount > v_gap_before AND COALESCE(p_allow_overfunding, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Proposed DVA amount % exceeds remaining funding gap % for order %. Set p_allow_overfunding = true to confirm intentional overfunding', v_effective_amount, v_gap_before, p_order_id;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Insert only into the proven table path. Existing triggers/helpers own the
  -- funding event sync, funded_at recompute, and overfunding credit mirroring.
  -- ---------------------------------------------------------------------------
  INSERT INTO dva_reconciliation (
    dva_statement_line_id,
    reconciliation_type,
    order_id,
    supplier_invoice_id,
    dispute_id,
    reconciled_gbp_amount,
    reconciled_by_staff_id,
    reconciled_at,
    notes
  )
  VALUES (
    p_dva_statement_line_id,
    'order_funding',
    p_order_id,
    NULL,
    NULL,
    v_effective_amount,
    v_staff.id,
    now(),
    p_notes
  )
  RETURNING id INTO v_reconciliation_id;

  IF p_match_suggestion_id IS NOT NULL THEN
    UPDATE match_suggestions
    SET accepted_by_staff_id = COALESCE(accepted_by_staff_id, v_staff.id),
        accepted_at = COALESCE(accepted_at, now())
    WHERE id = p_match_suggestion_id;
  END IF;

  SELECT ofe.id
    INTO v_funding_event_id
  FROM order_funding_events ofe
  WHERE ofe.event_type = 'funding_contribution'
    AND ofe.source_entity_type = 'dva_reconciliation'
    AND ofe.source_entity_id = v_reconciliation_id
  LIMIT 1;

  SELECT
    ROUND(COALESCE(order_funding_total_gbp(p_order_id), 0)::numeric, 2),
    ROUND(COALESCE(order_funding_gap_gbp(p_order_id), 0)::numeric, 2),
    o.funded_at
  INTO v_total_after, v_gap_after, v_funded_at
  FROM orders o
  WHERE o.id = p_order_id;

  SELECT ROUND(COALESCE(SUM(ABS(icl.amount_gbp)), 0)::numeric, 2)
    INTO v_overfunding_credit_after
  FROM importer_credit_ledger icl
  WHERE icl.importer_id = v_order.importer_id
    AND icl.direction = 'credit'
    AND icl.source_type = 'overfunding'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id = p_order_id
    AND icl.linked_order_id = p_order_id;

  RETURN jsonb_build_object(
    'ok', true,
    'dva_reconciliation_id', v_reconciliation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'reconciled_gbp_amount', v_effective_amount,
    'gap_before_gbp', v_gap_before,
    'funding_total_after_gbp', v_total_after,
    'gap_after_gbp', v_gap_after,
    'overfunding_gbp', v_overfunding_amount,
    'overfunding_credit_expected_yn', v_overfunding_amount > 0,
    'overfunding_credit_after_gbp', v_overfunding_credit_after,
    'funding_event_id', v_funding_event_id,
    'funded_at', v_funded_at
  );
END;
$$;

COMMENT ON FUNCTION public.staff_reconcile_dva_line_to_order(uuid, uuid, numeric, boolean, uuid, text) IS
'Staff-safe SECURITY DEFINER wrapper for DVA order-funding reconciliation. Inserts into dva_reconciliation only and preserves existing trigger/helper funding-event and overfunding-credit behaviour.';

REVOKE ALL ON FUNCTION public.staff_reconcile_dva_line_to_order(uuid, uuid, numeric, boolean, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reconcile_dva_line_to_order(uuid, uuid, numeric, boolean, uuid, text) TO authenticated;

COMMIT;
