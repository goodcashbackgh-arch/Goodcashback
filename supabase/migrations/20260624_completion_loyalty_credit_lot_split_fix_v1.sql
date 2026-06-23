BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Ordered completion loyalty credit split fix.
-- Runs after the 20260623 completion-loyalty control migration.
-- Normal customer self-service credit excludes completion_loyalty_reward.
-- Debits linked to any unlocked credit lot, including loyalty, are not treated as legacy unlinked debits.

DO $$
BEGIN
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing importer_credit_ledger';
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
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
  ), all_unlocked_credit_ids AS (
    SELECT c.id
    FROM public.importer_credit_ledger c
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
        AND d.source_id IN (SELECT id FROM all_unlocked_credit_ids)
      )
      AND NOT (
        COALESCE(d.source_entity_type, '') = 'importer_credit_ledger'
        AND d.source_entity_id IN (SELECT id FROM all_unlocked_credit_ids)
      )
  ), lot_base AS (
    SELECT
      c.id AS credit_ledger_id,
      c.source_type::text AS source_type,
      nct.priority,
      COALESCE(c.effective_at, c.created_at) AS effective_at,
      c.created_at,
      ROUND(GREATEST(
        ABS(COALESCE(c.amount_gbp, 0)) - COALESCE(linked.linked_debit_gbp, 0),
        0
      )::numeric, 2) AS amount_after_linked_debits_gbp
    FROM public.importer_credit_ledger c
    JOIN normal_credit_types nct ON nct.source_type = c.source_type::text
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

NOTIFY pgrst, 'reload schema';

COMMIT;
