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
-- Historical unlinked debits continue to reduce legacy normal-credit lots that
-- existed by the importer's latest unlinked-debit timestamp. Any excess legacy
-- deficit is not carried into later-created credit lots. This keeps the legacy
-- record auditable and fail-closed without suppressing subsequent real credits.

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
      ROUND(COALESCE(SUM(ABS(d.amount_gbp)), 0)::numeric, 2) AS amount_gbp,
      MAX(d.created_at) AS latest_created_at
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
      lud.amount_gbp AS legacy_unlinked_debit_gbp,
      lud.latest_created_at AS latest_legacy_unlinked_debit_created_at,
      COALESCE(SUM(
        CASE
          WHEN lud.latest_created_at IS NOT NULL
           AND lb.created_at <= lud.latest_created_at
          THEN lb.amount_after_linked_debits_gbp
          ELSE 0::numeric
        END
      ) OVER (
        ORDER BY lb.priority, lb.effective_at, lb.created_at, lb.credit_ledger_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0)::numeric AS prior_legacy_eligible_lot_amount_gbp
    FROM lot_base lb
    CROSS JOIN legacy_unlinked_debits lud
    WHERE lb.amount_after_linked_debits_gbp > 0
  ), available_lots AS (
    SELECT
      ol.*,
      CASE
        WHEN ol.latest_legacy_unlinked_debit_created_at IS NULL THEN 0::numeric
        WHEN ol.created_at > ol.latest_legacy_unlinked_debit_created_at THEN 0::numeric
        ELSE LEAST(
          ol.amount_after_linked_debits_gbp,
          GREATEST(
            ol.legacy_unlinked_debit_gbp - ol.prior_legacy_eligible_lot_amount_gbp,
            0
          )
        )
      END AS virtual_legacy_consumed_gbp
    FROM ordered_lots ol
  )
  SELECT
    al.credit_ledger_id,
    al.source_type,
    ROUND(GREATEST(
      al.amount_after_linked_debits_gbp - al.virtual_legacy_consumed_gbp,
      0
    )::numeric, 2) AS available_amount_gbp,
    al.priority,
    al.effective_at,
    al.created_at
  FROM available_lots al
  WHERE ROUND(GREATEST(
    al.amount_after_linked_debits_gbp - al.virtual_legacy_consumed_gbp,
    0
  )::numeric, 2) > 0
  ORDER BY al.priority, al.effective_at, al.created_at, al.credit_ledger_id;
$$;

COMMENT ON FUNCTION public.internal_importer_available_account_credit_lots_v1(uuid) IS
'Canonical normal account-credit source-lot balance. Exact linked debits consume their source lots. Legacy unlinked debits consume only residual normal-credit lots created no later than the importer latest legacy-unlinked debit, so historical aggregate deficits cannot consume subsequently created credits. Completion loyalty remains separate.';

REVOKE ALL ON FUNCTION public.internal_importer_available_account_credit_lots_v1(uuid) FROM PUBLIC;

-- Structural non-regression assertions: no row rewrite and no function contract change.
DO $$
DECLARE
  v_return_signature text;
BEGIN
  SELECT pg_get_function_result('public.internal_importer_available_account_credit_lots_v1(uuid)'::regprocedure)
    INTO v_return_signature;

  IF v_return_signature IS DISTINCT FROM
     'TABLE(credit_ledger_id uuid, source_type text, available_amount_gbp numeric, priority integer, effective_at timestamp with time zone, created_at timestamp with time zone)' THEN
    RAISE EXCEPTION 'Unexpected source-lot function return contract after chronology fence: %', v_return_signature;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.internal_importer_available_account_credit_lots_v1(
      '18bb852a-7983-4ea1-82e1-70fb668241d9'::uuid
    ) l
    WHERE l.available_amount_gbp < 0
  ) THEN
    RAISE EXCEPTION 'Chronology-fenced account-credit function returned a negative lot amount';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
