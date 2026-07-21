-- Amount-aware statement-line control regression v1.
-- Read-only checks. Run after 20260721_amount_aware_statement_line_control_v1.sql.

BEGIN;
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.statement_line_control_usage_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: statement_line_control_usage_v1 missing';
  END IF;
  IF to_regclass('public.statement_line_control_position_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: statement_line_control_position_v1 missing';
  END IF;
  IF to_regprocedure('public.internal_statement_line_control_resolver_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: internal_statement_line_control_resolver_v1(uuid) missing';
  END IF;
  IF to_regprocedure('public.internal_guard_order_funding_statement_line_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: internal_guard_order_funding_statement_line_v1() missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'trg_guard_order_funding_statement_line_v1'
      AND tgrelid = 'public.dva_reconciliation'::regclass
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL: order-funding statement-line guard trigger missing';
  END IF;
END $$;

-- Every statement line must produce exactly one position row.
DO $$
DECLARE
  v_lines bigint;
  v_positions bigint;
  v_duplicates bigint;
BEGIN
  SELECT count(*) INTO v_lines FROM public.dva_statement_lines;
  SELECT count(*) INTO v_positions FROM public.statement_line_control_position_v1;
  SELECT count(*) INTO v_duplicates
  FROM (
    SELECT statement_line_id
    FROM public.statement_line_control_position_v1
    GROUP BY statement_line_id
    HAVING count(*) <> 1
  ) x;

  IF v_lines <> v_positions OR v_duplicates <> 0 THEN
    RAISE EXCEPTION 'FAIL: statement-line position cardinality mismatch. lines %, positions %, duplicate groups %', v_lines, v_positions, v_duplicates;
  END IF;
END $$;

-- Resolver arithmetic must be internally consistent.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.statement_line_control_position_v1 p
  WHERE ABS(
    p.statement_gbp_amount
    - p.active_consumed_gbp
    - p.active_reserved_gbp
    - p.remaining_unconsumed_gbp
    + p.overconsumed_gbp
  ) > 0.01;

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % statement-line positions violate amount equation', v_bad;
  END IF;
END $$;

-- Linked loyalty funding confirmations must be documentary only and must not consume twice.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.statement_line_control_usage_v1 u
  WHERE u.raw_family = 'completion_loyalty_funding_confirmation'
    AND u.documentary_only = true
    AND (u.consumed_gbp <> 0 OR u.reserved_gbp <> 0);

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: linked loyalty confirmations consume amount on % rows', v_bad;
  END IF;
END $$;

-- Reversed allocation and loyalty rows must not consume current amount.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.statement_line_control_usage_v1 u
  WHERE u.evidence_state = 'historical'
    AND (u.consumed_gbp <> 0 OR u.reserved_gbp <> 0);

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: historical evidence consumes current amount on % rows', v_bad;
  END IF;
END $$;

-- Known valid funding + FX/card split must remain one principal lane.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.statement_line_control_position_v1 p
  WHERE p.active_economic_lanes @> ARRAY['customer_order_funding','fx_card_difference']::text[]
    AND (
      p.principal_lane_count <> 1
      OR p.overconsumed_gbp > 0.01
    );

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % funding + FX/card splits are incorrectly blocked', v_bad;
  END IF;
END $$;

-- Multi-invoice supplier bundles remain one economic lane.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM (
    SELECT u.statement_line_id
    FROM public.statement_line_control_usage_v1 u
    WHERE u.raw_family = 'dva_allocation'
      AND u.economic_lane = 'supplier_payment'
      AND u.evidence_state = 'active'
    GROUP BY u.statement_line_id
    HAVING count(*) > 1
  ) bundles
  JOIN public.statement_line_control_position_v1 p USING (statement_line_id)
  WHERE p.principal_lane_count <> 1;

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % multi-invoice supplier bundles count as multiple principal lanes', v_bad;
  END IF;
END $$;

-- Multiple rewards on one loyalty source/destination pot remain one principal lane per physical side.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM (
    SELECT u.statement_line_id, u.economic_lane
    FROM public.statement_line_control_usage_v1 u
    WHERE u.economic_lane IN ('completion_loyalty_source_transfer','completion_loyalty_destination_transfer')
      AND u.evidence_state = 'active'
      AND NOT u.documentary_only
    GROUP BY u.statement_line_id, u.economic_lane
    HAVING count(*) > 1
  ) pots
  JOIN public.statement_line_control_position_v1 p USING (statement_line_id)
  WHERE p.principal_lane_count <> 1;

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % loyalty pots count reward rows as conflicting principal uses', v_bad;
  END IF;
END $$;

-- Resolver must block actual multiple-principal collisions.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.statement_line_control_position_v1 p
  CROSS JOIN LATERAL public.internal_statement_line_control_resolver_v1(p.statement_line_id) r
  WHERE p.principal_lane_count > 1
    AND (
      r.incompatible_principal_lanes_yn IS DISTINCT FROM true
      OR r.control_status <> 'blocked'
      OR r.blocker <> 'incompatible_principal_economic_lanes'
    );

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % multiple-principal collisions are not blocked', v_bad;
  END IF;
END $$;

-- Resolver must block overconsumption.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.statement_line_control_position_v1 p
  CROSS JOIN LATERAL public.internal_statement_line_control_resolver_v1(p.statement_line_id) r
  WHERE p.overconsumed_gbp > 0.01
    AND (
      r.control_status <> 'blocked'
      OR r.blocker <> 'statement_line_overconsumed'
    );

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % overconsumed statement lines are not blocked', v_bad;
  END IF;
END $$;

-- Funding action must never be allowed for OUT, main-bank, refund, final balance or loyalty-transfer lines.
DO $$
DECLARE
  v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.statement_line_control_position_v1 p
  CROSS JOIN LATERAL public.internal_statement_line_control_resolver_v1(p.statement_line_id) r
  WHERE r.funding_action_allowed_yn
    AND (
      p.direction <> 'in'
      OR p.statement_account_context <> 'importer_dva_card_account'
      OR p.active_economic_lanes && ARRAY[
        'retailer_refund',
        'final_balance_payment',
        'completion_loyalty_destination_transfer',
        'legacy_completion_loyalty_funding',
        'supplier_payment',
        'main_bank_shipper_ap',
        'completion_loyalty_source_transfer'
      ]::text[]
    );

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % non-funding lines are exposed as funding actions', v_bad;
  END IF;
END $$;

-- Audit output for human review. This does not fail the transaction.
SELECT
  control_status,
  blocker,
  next_action,
  count(*) AS line_count,
  ROUND(sum(statement_gbp_amount)::numeric, 2) AS statement_gbp,
  ROUND(sum(active_consumed_gbp)::numeric, 2) AS consumed_gbp,
  ROUND(sum(active_reserved_gbp)::numeric, 2) AS reserved_gbp,
  ROUND(sum(remaining_unconsumed_gbp)::numeric, 2) AS remaining_gbp,
  ROUND(sum(overconsumed_gbp)::numeric, 2) AS overconsumed_gbp
FROM public.statement_line_control_position_v1 p
CROSS JOIN LATERAL public.internal_statement_line_control_resolver_v1(p.statement_line_id) r
GROUP BY control_status, blocker, next_action
ORDER BY control_status, blocker NULLS LAST, next_action;

SELECT 'PASS: amount-aware statement-line control regression completed'::text AS regression_result;

ROLLBACK;
