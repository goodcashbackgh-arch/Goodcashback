BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Neutral pending-funding-surplus reservation.
--
-- This migration is deliberately additive:
--   * order_surplus_evidence_position_v2 remains byte-for-byte compatible;
--   * the established confirmation RPC keeps its v2 branch for ordinary rows;
--   * pending residuals extend the existing statement-line usage/position resolver;
--   * the physical statement row and amount remain immutable.

DO $$
BEGIN
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing exact staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text) prerequisite';
  END IF;
  IF to_regprocedure('public.internal_statement_line_control_resolver_v2(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing amount-aware statement-line control resolver v2 prerequisite';
  END IF;
  IF to_regclass('public.statement_line_control_usage_v1') IS NULL
     OR to_regclass('public.statement_line_control_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing shared amount-aware statement-line control views';
  END IF;
  IF to_regclass('public.order_surplus_evidence_position_v2') IS NULL THEN
    RAISE EXCEPTION 'Missing established order_surplus_evidence_position_v2 prerequisite';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing importer_credit_ledger prerequisite';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.order_pending_funding_surplus (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_reconciliation_id uuid NOT NULL,
  dva_statement_line_id uuid NOT NULL REFERENCES public.dva_statement_lines(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  importer_id uuid NOT NULL REFERENCES public.importers(id),
  entered_gbp_amount numeric(12,2) NOT NULL CHECK (entered_gbp_amount > 0),
  funding_gbp_amount numeric(12,2) NOT NULL CHECK (funding_gbp_amount > 0),
  pending_surplus_gbp numeric(12,2) NOT NULL CHECK (pending_surplus_gbp > 0),
  status text NOT NULL DEFAULT 'pending_evidence'
    CHECK (status IN ('pending_evidence','credit_confirmed','reversed')),
  created_by_staff_id uuid NOT NULL REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  confirmed_credit_ledger_id uuid REFERENCES public.importer_credit_ledger(id),
  confirmed_by_staff_id uuid REFERENCES public.staff(id),
  confirmed_at timestamptz,
  reversed_at timestamptz,
  notes text,
  CONSTRAINT order_pending_funding_surplus_amounts_ck CHECK (
    entered_gbp_amount = funding_gbp_amount + pending_surplus_gbp
  )
);

-- Correct the unsafe cardinality/FK shape if this PR migration was evaluated on a
-- disposable target before being amended. Historical reversed rows must survive.
ALTER TABLE public.order_pending_funding_surplus
  ADD COLUMN IF NOT EXISTS reversed_at timestamptz;

ALTER TABLE public.order_pending_funding_surplus
  DROP CONSTRAINT IF EXISTS order_pending_funding_surplus_dva_reconciliation_id_key,
  DROP CONSTRAINT IF EXISTS order_pending_funding_surplus_dva_statement_line_id_key,
  DROP CONSTRAINT IF EXISTS order_pending_funding_surplus_order_id_key,
  DROP CONSTRAINT IF EXISTS order_pending_funding_surplus_confirmed_credit_ledger_id_key,
  DROP CONSTRAINT IF EXISTS order_pending_funding_surplus_dva_reconciliation_id_fkey;

CREATE UNIQUE INDEX IF NOT EXISTS uq_order_pending_funding_surplus_active_line_v1
  ON public.order_pending_funding_surplus(dva_statement_line_id)
  WHERE status IN ('pending_evidence','credit_confirmed');

CREATE UNIQUE INDEX IF NOT EXISTS uq_order_pending_funding_surplus_active_reconciliation_v1
  ON public.order_pending_funding_surplus(dva_reconciliation_id)
  WHERE status IN ('pending_evidence','credit_confirmed');

CREATE INDEX IF NOT EXISTS idx_order_pending_funding_surplus_order_status_v1
  ON public.order_pending_funding_surplus(order_id, status, created_at);

CREATE INDEX IF NOT EXISTS idx_order_pending_funding_surplus_credit_v1
  ON public.order_pending_funding_surplus(confirmed_credit_ledger_id)
  WHERE confirmed_credit_ledger_id IS NOT NULL;

ALTER TABLE public.order_pending_funding_surplus ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_pending_funding_surplus FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_pending_funding_surplus TO authenticated;

DROP POLICY IF EXISTS order_pending_funding_surplus_staff_select_v1
  ON public.order_pending_funding_surplus;
CREATE POLICY order_pending_funding_surplus_staff_select_v1
  ON public.order_pending_funding_surplus
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.staff s
      WHERE s.auth_user_id = auth.uid()
        AND COALESCE(s.active, true) = true
    )
  );

-- Keep the original usage resolver as a non-authoritative source view and put the
-- pending lane into the existing public statement_line_control_usage_v1 contract.
DO $$
BEGIN
  IF to_regclass('public.statement_line_control_usage_without_pending_v1') IS NULL THEN
    ALTER VIEW public.statement_line_control_usage_v1
      RENAME TO statement_line_control_usage_without_pending_v1;
  END IF;
END $$;

CREATE OR REPLACE VIEW public.statement_line_control_usage_v1 AS
SELECT
  b.statement_line_id,
  b.raw_family,
  b.economic_lane,
  b.principal_lane,
  b.documentary_only,
  b.evidence_state,
  b.consumed_gbp,
  b.reserved_gbp,
  b.evidence_id,
  b.evidence_json
FROM public.statement_line_control_usage_without_pending_v1 b
UNION ALL
SELECT
  p.dva_statement_line_id AS statement_line_id,
  'pending_funding_surplus'::text AS raw_family,
  'pending_surplus_determination'::text AS economic_lane,
  true AS principal_lane,
  false AS documentary_only,
  CASE WHEN p.status = 'reversed' THEN 'historical' ELSE 'active' END::text AS evidence_state,
  CASE WHEN p.status = 'credit_confirmed'
    THEN ROUND(ABS(p.pending_surplus_gbp)::numeric, 2)
    ELSE 0::numeric
  END AS consumed_gbp,
  CASE WHEN p.status = 'pending_evidence'
    THEN ROUND(ABS(p.pending_surplus_gbp)::numeric, 2)
    ELSE 0::numeric
  END AS reserved_gbp,
  p.id AS evidence_id,
  jsonb_build_object(
    'table', 'order_pending_funding_surplus',
    'id', p.id,
    'status', p.status,
    'order_id', p.order_id,
    'dva_reconciliation_id', p.dva_reconciliation_id,
    'pending_surplus_gbp', p.pending_surplus_gbp,
    'confirmed_credit_ledger_id', p.confirmed_credit_ledger_id
  ) AS evidence_json
FROM public.order_pending_funding_surplus p;

-- Pending surplus is a principal economic use, but it is the compatible residual
-- half of the same customer-funding receipt. Normalise that pair only for the
-- principal-lane count; keep both explicit lanes in evidence and lane arrays.
CREATE OR REPLACE VIEW public.statement_line_control_position_v1 AS
WITH active_usage AS (
  SELECT
    u.statement_line_id,
    ROUND(COALESCE(SUM(u.consumed_gbp) FILTER (
      WHERE u.evidence_state = 'active' AND NOT u.documentary_only
    ), 0)::numeric, 2) AS active_consumed_gbp,
    ROUND(COALESCE(SUM(u.reserved_gbp) FILTER (
      WHERE u.evidence_state = 'active' AND NOT u.documentary_only
    ), 0)::numeric, 2) AS active_reserved_gbp,
    ARRAY_AGG(DISTINCT u.raw_family ORDER BY u.raw_family)
      FILTER (WHERE u.evidence_state = 'active') AS raw_active_families,
    ARRAY_AGG(DISTINCT u.economic_lane ORDER BY u.economic_lane)
      FILTER (WHERE u.evidence_state = 'active' AND NOT u.documentary_only) AS active_economic_lanes,
    COUNT(DISTINCT CASE
      WHEN u.economic_lane = 'pending_surplus_determination'
        THEN 'customer_order_funding'
      ELSE u.economic_lane
    END) FILTER (
      WHERE u.evidence_state = 'active'
        AND u.principal_lane
        AND NOT u.documentary_only
    ) AS principal_lane_count,
    COUNT(*) FILTER (WHERE u.evidence_state = 'historical') AS historical_row_count,
    JSONB_AGG(u.evidence_json ORDER BY u.raw_family, u.evidence_id) AS usage_evidence
  FROM public.statement_line_control_usage_v1 u
  GROUP BY u.statement_line_id
)
SELECT
  l.id AS statement_line_id,
  l.dva_statement_id AS statement_id,
  s.importer_id,
  COALESCE(s.statement_account_context, 'importer_dva_card_account')::text AS statement_account_context,
  s.statement_account_label::text,
  s.source_bank::text,
  l.statement_date,
  l.reference_raw::text,
  l.direction::text,
  ROUND(COALESCE(l.amount_gbp_equivalent, 0)::numeric, 2) AS statement_gbp_amount,
  COALESCE(u.active_consumed_gbp, 0)::numeric AS active_consumed_gbp,
  COALESCE(u.active_reserved_gbp, 0)::numeric AS active_reserved_gbp,
  ROUND(GREATEST(
    COALESCE(l.amount_gbp_equivalent, 0)
      - COALESCE(u.active_consumed_gbp, 0)
      - COALESCE(u.active_reserved_gbp, 0),
    0
  )::numeric, 2) AS remaining_unconsumed_gbp,
  ROUND(GREATEST(
    COALESCE(u.active_consumed_gbp, 0)
      + COALESCE(u.active_reserved_gbp, 0)
      - COALESCE(l.amount_gbp_equivalent, 0),
    0
  )::numeric, 2) AS overconsumed_gbp,
  COALESCE(u.raw_active_families, ARRAY[]::text[]) AS raw_active_families,
  COALESCE(u.active_economic_lanes, ARRAY[]::text[]) AS active_economic_lanes,
  COALESCE(u.principal_lane_count, 0)::integer AS principal_lane_count,
  COALESCE(u.historical_row_count, 0)::integer AS historical_row_count,
  COALESCE(u.usage_evidence, '[]'::jsonb) AS usage_evidence
FROM public.dva_statement_lines l
JOIN public.dva_statements s ON s.id = l.dva_statement_id
LEFT JOIN active_usage u ON u.statement_line_id = l.id;

GRANT SELECT ON public.statement_line_control_usage_v1 TO authenticated;
GRANT SELECT ON public.statement_line_control_position_v1 TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reconciled_gbp_amount numeric,
  p_match_suggestion_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_line record;
  v_order record;
  v_match record;
  v_control record;
  v_existing_pending record;
  v_entered numeric(12,2) := ROUND(COALESCE(p_reconciled_gbp_amount, 0)::numeric, 2);
  v_physical numeric(12,2);
  v_gap numeric(12,2);
  v_pending numeric(12,2);
  v_remaining_after_funding numeric(12,2);
  v_result jsonb;
  v_reconciliation_id uuid;
  v_pending_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can reconcile DVA funding lines.';
  END IF;

  IF v_entered <= 0 THEN
    RAISE EXCEPTION 'Reconciled GBP amount must be greater than zero. Received: %', v_entered;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('pending_funding_surplus|' || p_dva_statement_line_id::text)
  );

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    ds.importer_id,
    COALESCE(ds.statement_account_context, 'importer_dva_card_account') AS statement_account_context
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  SELECT
    o.id,
    o.importer_id,
    COALESCE(o.order_type, 'original') AS order_type,
    o.status,
    o.order_ref
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_line.id IS NULL OR v_order.id IS NULL THEN
    RAISE EXCEPTION 'Statement line or order not found.';
  END IF;
  IF v_line.direction <> 'in'
     OR v_line.statement_account_context <> 'importer_dva_card_account' THEN
    RAISE EXCEPTION 'Pending surplus funding requires importer DVA/card IN.';
  END IF;
  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Importer mismatch.';
  END IF;
  IF v_order.order_type <> 'original' THEN
    RAISE EXCEPTION 'DVA funding can only target original orders.';
  END IF;
  IF v_order.status IN ('archived','cancelled') THEN
    RAISE EXCEPTION 'DVA funding cannot target order % with status %.', p_order_id, v_order.status;
  END IF;

  SELECT p.*
  INTO v_existing_pending
  FROM public.order_pending_funding_surplus p
  WHERE p.dva_statement_line_id = p_dva_statement_line_id
    AND p.status IN ('pending_evidence','credit_confirmed')
  ORDER BY p.created_at, p.id
  LIMIT 1
  FOR UPDATE;

  IF v_existing_pending.id IS NOT NULL THEN
    IF v_existing_pending.order_id IS DISTINCT FROM p_order_id
       OR ABS(v_existing_pending.entered_gbp_amount - v_entered) > 0.005 THEN
      RAISE EXCEPTION 'Statement line already has an incompatible active pending-surplus position.';
    END IF;

    RETURN jsonb_build_object(
      'ok', true,
      'already_exists', true,
      'dva_reconciliation_id', v_existing_pending.dva_reconciliation_id,
      'dva_statement_line_id', v_existing_pending.dva_statement_line_id,
      'order_id', v_existing_pending.order_id,
      'funding_amount_gbp', v_existing_pending.funding_gbp_amount,
      'pending_surplus_gbp', v_existing_pending.pending_surplus_gbp,
      'pending_surplus_id', v_existing_pending.id,
      'credit_created_yn', v_existing_pending.status = 'credit_confirmed',
      'fx_gain_gbp', 0
    );
  END IF;

  v_physical := ROUND(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2);
  IF v_physical <= 0 THEN
    RAISE EXCEPTION 'Physical statement amount must be positive.';
  END IF;
  IF v_entered > v_physical + 0.005 THEN
    RAISE EXCEPTION 'Entered amount % exceeds immutable physical statement amount %.', v_entered, v_physical;
  END IF;

  SELECT *
  INTO v_control
  FROM public.internal_statement_line_control_resolver_v2(p_dva_statement_line_id)
  LIMIT 1;

  IF v_control.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Statement-line control position is missing.';
  END IF;
  IF v_entered > v_control.remaining_unconsumed_gbp + 0.005 THEN
    RAISE EXCEPTION 'Entered amount % exceeds current statement-line available balance %.', v_entered, v_control.remaining_unconsumed_gbp;
  END IF;
  IF v_control.overconsumed_gbp > 0.005
     OR v_control.incompatible_principal_lanes_yn
     OR v_control.funding_action_allowed_yn IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Statement line has an incompatible active economic use: %.', COALESCE(v_control.blocker, v_control.next_action);
  END IF;

  v_gap := ROUND(COALESCE(public.order_funding_gap_gbp(p_order_id), 0)::numeric, 2);
  IF v_gap <= 0 OR v_entered <= v_gap THEN
    RAISE EXCEPTION 'Pending surplus requires an entered amount above a positive order gap.';
  END IF;
  v_pending := ROUND(v_entered - v_gap, 2);

  IF p_match_suggestion_id IS NOT NULL THEN
    SELECT ms.*
    INTO v_match
    FROM public.match_suggestions ms
    WHERE ms.id = p_match_suggestion_id
    FOR UPDATE;

    IF v_match.id IS NULL
       OR v_match.dva_statement_line_id IS DISTINCT FROM p_dva_statement_line_id
       OR v_match.suggested_match_type IS DISTINCT FROM 'order'
       OR v_match.suggested_match_id IS DISTINCT FROM p_order_id THEN
      RAISE EXCEPTION 'Match suggestion does not belong to this statement line and order.';
    END IF;
  END IF;

  v_result := public.staff_reconcile_dva_line_to_order(
    p_dva_statement_line_id,
    p_order_id,
    v_gap,
    false,
    p_match_suggestion_id,
    concat_ws(
      E'\n',
      p_notes,
      'Residual reserved as neutral pending surplus until downstream evidence and supervisor classification.'
    )
  );
  v_reconciliation_id := NULLIF(v_result->>'dva_reconciliation_id', '')::uuid;

  SELECT p.remaining_unconsumed_gbp
  INTO v_remaining_after_funding
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_reconciliation_id IS NULL THEN
    RAISE EXCEPTION 'Base funding reconciliation did not return an identity.';
  END IF;
  IF v_pending > COALESCE(v_remaining_after_funding, 0) + 0.005 THEN
    RAISE EXCEPTION 'Pending residual % exceeds post-funding statement balance %.', v_pending, v_remaining_after_funding;
  END IF;

  INSERT INTO public.order_pending_funding_surplus (
    dva_reconciliation_id,
    dva_statement_line_id,
    order_id,
    importer_id,
    entered_gbp_amount,
    funding_gbp_amount,
    pending_surplus_gbp,
    created_by_staff_id,
    notes
  ) VALUES (
    v_reconciliation_id,
    p_dva_statement_line_id,
    p_order_id,
    v_order.importer_id,
    v_entered,
    v_gap,
    v_pending,
    v_staff.id,
    p_notes
  )
  RETURNING id INTO v_pending_id;

  RETURN v_result || jsonb_build_object(
    'funding_amount_gbp', v_gap,
    'pending_surplus_gbp', v_pending,
    'pending_surplus_id', v_pending_id,
    'credit_created_yn', false,
    'fx_gain_gbp', 0
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)
  TO authenticated;

-- The established reversal path deletes or changes a funding reconciliation.
-- Mark an unclassified reservation historical in the same transaction; once a
-- customer credit exists, fail closed until that credit is separately reversed.
CREATE OR REPLACE FUNCTION public.internal_reverse_pending_surplus_with_funding_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.reconciliation_type = 'order_funding' THEN
      IF EXISTS (
        SELECT 1
        FROM public.order_pending_funding_surplus p
        WHERE p.dva_reconciliation_id = OLD.id
          AND p.status = 'credit_confirmed'
      ) THEN
        RAISE EXCEPTION 'Reverse the confirmed customer credit before reversing funding reconciliation %.', OLD.id;
      END IF;

      UPDATE public.order_pending_funding_surplus p
      SET
        status = 'reversed',
        reversed_at = COALESCE(p.reversed_at, now()),
        notes = concat_ws(
          E'\n',
          p.notes,
          'Pending surplus reversed with linked funding reconciliation.'
        )
      WHERE p.dva_reconciliation_id = OLD.id
        AND p.status = 'pending_evidence';
    END IF;

    RETURN OLD;
  END IF;

  IF OLD.reconciliation_type = 'order_funding'
     AND (
       NEW.reconciliation_type IS DISTINCT FROM 'order_funding'
       OR NEW.order_id IS DISTINCT FROM OLD.order_id
       OR NEW.dva_statement_line_id IS DISTINCT FROM OLD.dva_statement_line_id
       OR NEW.reconciled_gbp_amount IS DISTINCT FROM OLD.reconciled_gbp_amount
     ) THEN
    IF EXISTS (
      SELECT 1
      FROM public.order_pending_funding_surplus p
      WHERE p.dva_reconciliation_id = OLD.id
        AND p.status = 'credit_confirmed'
    ) THEN
      RAISE EXCEPTION 'Reverse the confirmed customer credit before changing funding reconciliation %.', OLD.id;
    END IF;

    UPDATE public.order_pending_funding_surplus p
    SET
      status = 'reversed',
      reversed_at = COALESCE(p.reversed_at, now()),
      notes = concat_ws(
        E'\n',
        p.notes,
        'Pending surplus reversed with linked funding reconciliation.'
      )
    WHERE p.dva_reconciliation_id = OLD.id
      AND p.status = 'pending_evidence';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reverse_pending_surplus_with_funding_v1
  ON public.dva_reconciliation;
CREATE TRIGGER trg_reverse_pending_surplus_with_funding_v1
BEFORE UPDATE OF reconciliation_type, order_id, dva_statement_line_id, reconciled_gbp_amount OR DELETE
ON public.dva_reconciliation
FOR EACH ROW
EXECUTE FUNCTION public.internal_reverse_pending_surplus_with_funding_v1();

CREATE OR REPLACE VIEW public.order_surplus_evidence_position_v3 AS
WITH pending AS (
  SELECT
    p.order_id,
    ROUND(SUM(p.pending_surplus_gbp)::numeric, 2) AS pending_surplus_gbp,
    COUNT(*)::integer AS pending_position_count,
    COUNT(*) FILTER (WHERE p.status = 'credit_confirmed')::integer AS pending_credit_confirmed_count
  FROM public.order_pending_funding_surplus p
  WHERE p.status IN ('pending_evidence','credit_confirmed')
  GROUP BY p.order_id
), calculated AS (
  SELECT
    v.*,
    COALESCE(p.pending_surplus_gbp, 0)::numeric AS pending_surplus_gbp,
    COALESCE(p.pending_position_count, 0)::integer AS pending_position_count,
    COALESCE(p.pending_credit_confirmed_count, 0)::integer AS pending_credit_confirmed_count,
    ROUND((v.funding_total_gbp + COALESCE(p.pending_surplus_gbp, 0))::numeric, 2) AS effective_receipt_gbp,
    ROUND((
      v.funding_total_gbp
        + COALESCE(p.pending_surplus_gbp, 0)
        - v.evidence_value_gbp
    )::numeric, 2) AS pending_aware_evidence_surplus_gbp
  FROM public.order_surplus_evidence_position_v2 v
  LEFT JOIN pending p ON p.order_id = v.order_id
)
SELECT
  c.order_id,
  c.order_ref,
  c.importer_id,
  c.payment_auth_id,
  c.declared_order_gbp,
  c.funding_total_gbp,
  c.supplier_out_gbp,
  c.supplier_out_count,
  c.posted_invoice_gbp,
  c.posted_invoice_count,
  c.draft_invoice_gbp,
  c.draft_invoice_count,
  c.credit_created_gbp,
  c.open_dispute_count,
  c.active_hold_count,
  c.evidence_value_gbp,
  CASE
    WHEN c.pending_position_count > 0 THEN c.pending_aware_evidence_surplus_gbp
    ELSE c.evidence_surplus_gbp
  END::numeric AS evidence_surplus_gbp,
  CASE
    WHEN c.pending_position_count = 0 THEN c.evidence_status
    WHEN c.credit_created_gbp > 0 THEN 'credit_created'
    WHEN c.open_dispute_count > 0 OR c.active_hold_count > 0 THEN 'blocked_by_open_issue'
    WHEN c.effective_receipt_gbp <= 0 THEN 'no_confirmed_funding'
    WHEN c.evidence_basis = 'posted_customer_invoice'
      AND c.pending_aware_evidence_surplus_gbp > 0 THEN 'ready_posted_invoice_surplus'
    WHEN c.evidence_basis = 'draft_customer_invoice'
      AND c.pending_aware_evidence_surplus_gbp > 0 THEN 'ready_draft_invoice_surplus'
    WHEN c.evidence_basis = 'matched_supplier_out'
      AND c.pending_aware_evidence_surplus_gbp > 0 THEN 'ready_strong_in_out_surplus'
    WHEN c.evidence_basis = 'matched_supplier_out' THEN 'in_out_no_surplus'
    ELSE 'pending_insufficient_evidence'
  END::text AS evidence_status,
  c.evidence_basis,
  c.effective_receipt_gbp,
  c.pending_surplus_gbp,
  c.pending_position_count,
  c.pending_credit_confirmed_count
FROM calculated c;

GRANT SELECT ON public.order_surplus_evidence_position_v3 TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(
  p_order_id uuid,
  p_reason text DEFAULT 'supervisor_confirmed_credit',
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s record;
  o record;
  e record;
  new_id uuid;
  existing_credit_id uuid;
  existing_credit_gbp numeric := 0;
  pending_count integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT id, role_type
  INTO s
  FROM public.staff
  WHERE auth_user_id = auth.uid()
    AND COALESCE(active, true) = true
  LIMIT 1;

  IF s.id IS NULL OR s.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Supervisor/admin required.';
  END IF;

  SELECT id, importer_id, COALESCE(order_type, 'original') AS order_type
  INTO o
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF o.id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;
  IF o.order_type <> 'original' THEN
    RAISE EXCEPTION 'Original order required.';
  END IF;

  PERFORM 1
  FROM public.order_pending_funding_surplus p
  WHERE p.order_id = p_order_id
    AND p.status IN ('pending_evidence','credit_confirmed')
  ORDER BY p.created_at, p.id
  FOR UPDATE;

  SELECT COUNT(*)::integer
  INTO pending_count
  FROM public.order_pending_funding_surplus p
  WHERE p.order_id = p_order_id
    AND p.status IN ('pending_evidence','credit_confirmed');

  SELECT
    (ARRAY_AGG(id ORDER BY created_at, id)
      FILTER (WHERE direction = 'credit'))[1],
    COALESCE(SUM(
      CASE WHEN direction = 'credit' THEN ABS(amount_gbp) ELSE -ABS(amount_gbp) END
    ), 0)
  INTO existing_credit_id, existing_credit_gbp
  FROM public.importer_credit_ledger
  WHERE importer_id = o.importer_id
    AND source_type IN ('overfunding','settlement_credit')
    AND source_entity_type = 'order'
    AND source_entity_id = p_order_id;

  IF existing_credit_gbp > 0 THEN
    IF pending_count = 0 THEN
      -- Keep the established ordinary-row idempotent response unchanged.
      RETURN jsonb_build_object(
        'ok', true,
        'already_confirmed', true,
        'credit_gbp', ROUND(existing_credit_gbp::numeric, 2)
      );
    END IF;

    IF pending_count > 0 AND EXISTS (
      SELECT 1
      FROM public.order_pending_funding_surplus p
      WHERE p.order_id = p_order_id
        AND p.status = 'pending_evidence'
    ) THEN
      RAISE EXCEPTION 'Order already has an unlinked customer credit; pending surplus cannot be auto-linked.';
    END IF;

    RETURN jsonb_build_object(
      'ok', true,
      'already_confirmed', true,
      'credit_ledger_id', existing_credit_id,
      'credit_gbp', ROUND(existing_credit_gbp::numeric, 2)
    );
  END IF;

  IF pending_count = 0 THEN
    -- Exact established v2 behaviour for ordinary surplus rows.
    SELECT *
    INTO e
    FROM public.order_surplus_evidence_position_v2
    WHERE order_id = p_order_id;

    IF e.evidence_status NOT IN (
      'ready_posted_invoice_surplus',
      'ready_draft_invoice_surplus',
      'ready_strong_in_out_surplus'
    ) THEN
      RAISE EXCEPTION 'Not ready: %', e.evidence_status;
    END IF;
    IF e.open_dispute_count > 0 OR e.active_hold_count > 0 THEN
      RAISE EXCEPTION 'Open issue blocks confirmation.';
    END IF;
    IF e.evidence_surplus_gbp <= 0 THEN
      RAISE EXCEPTION 'No surplus.';
    END IF;

    INSERT INTO public.importer_credit_ledger (
      importer_id,
      entry_type,
      source_table,
      source_id,
      linked_order_id,
      direction,
      amount_gbp,
      amount_local_ccy,
      local_ccy,
      effective_at,
      source_type,
      source_entity_type,
      source_entity_id,
      created_by_staff_id,
      notes
    ) VALUES (
      o.importer_id,
      'manual_credit',
      'orders',
      p_order_id,
      p_order_id,
      'credit',
      e.evidence_surplus_gbp,
      e.evidence_surplus_gbp,
      'GBP',
      now(),
      'overfunding',
      'order',
      p_order_id,
      s.id,
      COALESCE(p_notes, 'Surplus confirmed from evidence')
    )
    RETURNING id INTO new_id;

    RETURN jsonb_build_object(
      'ok', true,
      'credit_ledger_id', new_id,
      'credit_gbp', e.evidence_surplus_gbp,
      'basis', e.evidence_basis
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_pending_funding_surplus p
    WHERE p.order_id = p_order_id
      AND p.status = 'pending_evidence'
      AND NOT EXISTS (
        SELECT 1
        FROM public.dva_reconciliation dr
        WHERE dr.id = p.dva_reconciliation_id
          AND dr.order_id = p.order_id
          AND dr.dva_statement_line_id = p.dva_statement_line_id
          AND dr.reconciliation_type = 'order_funding'
      )
  ) THEN
    RAISE EXCEPTION 'Pending surplus funding has been reversed.';
  END IF;

  SELECT *
  INTO e
  FROM public.order_surplus_evidence_position_v3
  WHERE order_id = p_order_id;

  IF e.evidence_status NOT IN (
    'ready_posted_invoice_surplus',
    'ready_draft_invoice_surplus',
    'ready_strong_in_out_surplus'
  ) THEN
    RAISE EXCEPTION 'Not ready: %', e.evidence_status;
  END IF;
  IF e.open_dispute_count > 0 OR e.active_hold_count > 0 THEN
    RAISE EXCEPTION 'Open issue blocks confirmation.';
  END IF;
  IF e.evidence_surplus_gbp <= 0 THEN
    RAISE EXCEPTION 'No surplus.';
  END IF;

  INSERT INTO public.importer_credit_ledger (
    importer_id,
    entry_type,
    source_table,
    source_id,
    linked_order_id,
    direction,
    amount_gbp,
    amount_local_ccy,
    local_ccy,
    effective_at,
    source_type,
    source_entity_type,
    source_entity_id,
    created_by_staff_id,
    notes
  ) VALUES (
    o.importer_id,
    'manual_credit',
    'orders',
    p_order_id,
    p_order_id,
    'credit',
    e.evidence_surplus_gbp,
    e.evidence_surplus_gbp,
    'GBP',
    now(),
    'overfunding',
    'order',
    p_order_id,
    s.id,
    concat_ws(
      E'\n',
      p_notes,
      'Pending receipt classified only after downstream evidence.',
      'Reason: ' || COALESCE(p_reason, 'supervisor_confirmed_credit')
    )
  )
  RETURNING id INTO new_id;

  UPDATE public.order_pending_funding_surplus
  SET
    status = 'credit_confirmed',
    confirmed_credit_ledger_id = new_id,
    confirmed_by_staff_id = s.id,
    confirmed_at = now()
  WHERE order_id = p_order_id
    AND status = 'pending_evidence';

  RETURN jsonb_build_object(
    'ok', true,
    'already_confirmed', false,
    'credit_ledger_id', new_id,
    'credit_gbp', e.evidence_surplus_gbp,
    'basis', e.evidence_basis,
    'effective_receipt_gbp', e.effective_receipt_gbp
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text)
  TO authenticated;

COMMENT ON TABLE public.order_pending_funding_surplus IS
'Neutral order-linked receipt residual. It reserves statement value but is not funding, FX or customer credit; evidence and supervisor classification precede credit creation.';

COMMENT ON VIEW public.statement_line_control_usage_v1 IS
'Authoritative shared statement-line usage resolver, including neutral pending-surplus reservation and confirmed-classification consumption without double use.';

COMMENT ON VIEW public.order_surplus_evidence_position_v3 IS
'Pending-aware wrapper over the established v2 surplus lifecycle. Ordinary v2 rows are unchanged; pending receipts use effective funding receipt minus authoritative downstream evidence.';

COMMENT ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text) IS
'Atomically funds only the positive order gap and reserves the entered receipt residual in the shared statement-line control, without FX or automatic credit.';

COMMENT ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text) IS
'Preserves established v2 confirmation for ordinary surplus rows and uses pending-aware effective receipt evidence only when an active pending position exists.';

NOTIFY pgrst, 'reload schema';
COMMIT;
