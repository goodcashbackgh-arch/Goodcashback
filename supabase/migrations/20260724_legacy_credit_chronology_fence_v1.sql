BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Legacy aggregate debit chronology fence.
--
-- Scope is deliberately narrow:
-- - preserve every historical importer_credit_ledger row unchanged;
-- - preserve normal-credit source priorities and exact linked-debit handling;
-- - preserve completion-loyalty separation;
-- - preserve customer/staff write paths and supplier-payment provenance gates;
-- - stop an old unlinked aggregate debit from consuming a normal credit that did
--   not yet exist when that legacy debit was created.
--
-- Each legacy unlinked debit is replayed independently, in creation order,
-- against only the residual normal-credit lots that already existed at that
-- debit's creation time. Any unmatched legacy debit remainder is not carried
-- into later-created credits. The historical debit remains unchanged and any
-- order using it remains subject to the existing provenance fail-closed gate.

DO $$
BEGIN
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing public.importer_credit_ledger';
  END IF;

  IF to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_importer_available_account_credit_lots_v1(uuid)';
  END IF;
END $$;

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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_credit_ledger_ids uuid[] := ARRAY[]::uuid[];
  v_source_types text[] := ARRAY[]::text[];
  v_available_amounts numeric[] := ARRAY[]::numeric[];
  v_priorities integer[] := ARRAY[]::integer[];
  v_effective_ats timestamptz[] := ARRAY[]::timestamptz[];
  v_created_ats timestamptz[] := ARRAY[]::timestamptz[];
  v_lot_count integer := 0;
  v_idx integer;
  v_debit record;
  v_debit_remaining numeric := 0;
  v_take numeric := 0;
BEGIN
  WITH normal_credit_types AS (
    SELECT *
    FROM (VALUES
      ('settlement_credit'::text, 1),
      ('overfunding'::text, 2),
      ('refund_resolution'::text, 3),
      ('liability_settlement'::text, 4),
      ('payout_reversal'::text, 5),
      ('manual'::text, 7)
    ) AS v(source_type, priority)
  ), lot_base AS (
    SELECT
      c.id AS credit_ledger_id,
      c.source_type::text AS lot_source_type,
      nct.priority AS lot_priority,
      COALESCE(c.effective_at, c.created_at) AS lot_effective_at,
      c.created_at AS lot_created_at,
      ROUND(GREATEST(
        ABS(COALESCE(c.amount_gbp, 0)) - COALESCE(linked.linked_debit_gbp, 0),
        0
      )::numeric, 2) AS residual_amount_gbp
    FROM public.importer_credit_ledger c
    JOIN normal_credit_types nct
      ON nct.source_type = c.source_type::text
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
  )
  SELECT
    ARRAY_AGG(lb.credit_ledger_id ORDER BY lb.lot_priority, lb.lot_effective_at, lb.lot_created_at, lb.credit_ledger_id),
    ARRAY_AGG(lb.lot_source_type ORDER BY lb.lot_priority, lb.lot_effective_at, lb.lot_created_at, lb.credit_ledger_id),
    ARRAY_AGG(lb.residual_amount_gbp ORDER BY lb.lot_priority, lb.lot_effective_at, lb.lot_created_at, lb.credit_ledger_id),
    ARRAY_AGG(lb.lot_priority ORDER BY lb.lot_priority, lb.lot_effective_at, lb.lot_created_at, lb.credit_ledger_id),
    ARRAY_AGG(lb.lot_effective_at ORDER BY lb.lot_priority, lb.lot_effective_at, lb.lot_created_at, lb.credit_ledger_id),
    ARRAY_AGG(lb.lot_created_at ORDER BY lb.lot_priority, lb.lot_effective_at, lb.lot_created_at, lb.credit_ledger_id)
  INTO
    v_credit_ledger_ids,
    v_source_types,
    v_available_amounts,
    v_priorities,
    v_effective_ats,
    v_created_ats
  FROM lot_base lb
  WHERE lb.residual_amount_gbp > 0;

  v_lot_count := COALESCE(ARRAY_LENGTH(v_credit_ledger_ids, 1), 0);
  IF v_lot_count = 0 THEN
    RETURN;
  END IF;

  FOR v_debit IN
    SELECT
      d.id,
      ROUND(ABS(COALESCE(d.amount_gbp, 0))::numeric, 2) AS debit_amount_gbp,
      d.created_at AS debit_created_at
    FROM public.importer_credit_ledger d
    WHERE d.importer_id = p_importer_id
      AND d.direction = 'debit'
      AND d.lock_reason IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.importer_credit_ledger c
        WHERE c.importer_id = p_importer_id
          AND c.direction = 'credit'
          AND c.lock_reason IS NULL
          AND COALESCE(d.source_table, '') = 'importer_credit_ledger'
          AND d.source_id = c.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.importer_credit_ledger c
        WHERE c.importer_id = p_importer_id
          AND c.direction = 'credit'
          AND c.lock_reason IS NULL
          AND COALESCE(d.source_entity_type, '') = 'importer_credit_ledger'
          AND d.source_entity_id = c.id
      )
      AND ROUND(ABS(COALESCE(d.amount_gbp, 0))::numeric, 2) > 0
    ORDER BY d.created_at, d.id
  LOOP
    v_debit_remaining := v_debit.debit_amount_gbp;

    FOR v_idx IN 1..v_lot_count LOOP
      EXIT WHEN v_debit_remaining <= 0;

      IF v_created_ats[v_idx] <= v_debit.debit_created_at
         AND COALESCE(v_available_amounts[v_idx], 0) > 0 THEN
        v_take := ROUND(LEAST(v_available_amounts[v_idx], v_debit_remaining)::numeric, 2);
        v_available_amounts[v_idx] := ROUND((v_available_amounts[v_idx] - v_take)::numeric, 2);
        v_debit_remaining := ROUND((v_debit_remaining - v_take)::numeric, 2);
      END IF;
    END LOOP;

    -- Deliberately discard only the unmatched virtual remainder. The ledger row
    -- itself is retained unchanged for audit and supplier-payment provenance.
  END LOOP;

  FOR v_idx IN 1..v_lot_count LOOP
    IF ROUND(GREATEST(COALESCE(v_available_amounts[v_idx], 0), 0)::numeric, 2) > 0 THEN
      credit_ledger_id := v_credit_ledger_ids[v_idx];
      source_type := v_source_types[v_idx];
      available_amount_gbp := ROUND(GREATEST(v_available_amounts[v_idx], 0)::numeric, 2);
      priority := v_priorities[v_idx];
      effective_at := v_effective_ats[v_idx];
      created_at := v_created_ats[v_idx];
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.internal_importer_available_account_credit_lots_v1(uuid) IS
'Canonical normal account-credit source-lot balance. Exact linked debits consume their source lots. Each legacy unlinked debit is replayed chronologically only against residual normal-credit lots already created at that debit time; unmatched legacy remainder cannot consume subsequently created credits. Completion loyalty remains separate.';

REVOKE ALL ON FUNCTION public.internal_importer_available_account_credit_lots_v1(uuid) FROM PUBLIC;

-- Contract-only assertion. The migration performs no importer-credit data write.
DO $$
BEGIN
  IF to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Chronology-fenced account-credit function was not installed';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
