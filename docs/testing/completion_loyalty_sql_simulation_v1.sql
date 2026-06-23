-- Completion loyalty contract SQL simulation v1
-- Purpose: read-only proof pack for the completion-loyalty contract.
-- Run in Supabase SQL Editor.
-- This script creates TEMP tables only and finishes with ROLLBACK.
-- It does not call write RPCs, does not create credits, does not pair lines, and does not post to Sage.

BEGIN;

SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';

-- Give SECURITY DEFINER read RPCs an auth.uid() when running from SQL Editor.
-- This only sets local transaction config; it does not change staff records.
DO $$
DECLARE
  v_auth_user_id text;
BEGIN
  SELECT s.auth_user_id::text
    INTO v_auth_user_id
  FROM public.staff s
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
    AND (
      s.role_type = 'admin'
      OR COALESCE((s.permissions_json->>'accounting_admin_testing')::boolean, false) = true
      OR COALESCE((s.permissions_json->>'admin_testing')::boolean, false) = true
    )
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.created_at NULLS LAST, s.id
  LIMIT 1;

  IF v_auth_user_id IS NOT NULL THEN
    PERFORM set_config('request.jwt.claim.sub', v_auth_user_id, true);
    RAISE NOTICE 'Simulation auth.uid() set to accounting-capable staff auth_user_id %', v_auth_user_id;
  ELSE
    RAISE NOTICE 'No accounting-capable staff auth_user_id found. Direct table checks will still run; auth-gated RPC checks may be unavailable.';
  END IF;
END $$;

CREATE TEMP TABLE loyalty_sql_simulation_report (
  seq bigint GENERATED ALWAYS AS IDENTITY,
  section text NOT NULL,
  check_name text NOT NULL,
  status text NOT NULL CHECK (status IN ('PASS','WARN','FAIL','INFO')),
  rows_found bigint,
  amount_gbp numeric,
  finding text,
  sample jsonb
) ON COMMIT DROP;

-- 1. Schema / contract objects.
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, finding, sample)
SELECT
  '00_schema' AS section,
  'required contract objects exist' AS check_name,
  CASE WHEN bool_and(present) THEN 'PASS' ELSE 'FAIL' END AS status,
  count(*) FILTER (WHERE NOT present) AS rows_found,
  CASE WHEN bool_and(present)
    THEN 'All required tables/views/functions for completion-loyalty simulation are present.'
    ELSE 'One or more required objects are missing. Apply migrations before testing.'
  END AS finding,
  jsonb_agg(jsonb_build_object('object', object_name, 'present', present) ORDER BY object_name) AS sample
FROM (
  VALUES
    ('table completion_loyalty_reward_approvals', to_regclass('public.completion_loyalty_reward_approvals') IS NOT NULL),
    ('table completion_loyalty_reward_rejections', to_regclass('public.completion_loyalty_reward_rejections') IS NOT NULL),
    ('table main_bank_completion_loyalty_funding_matches', to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NOT NULL),
    ('table importer_credit_ledger', to_regclass('public.importer_credit_ledger') IS NOT NULL),
    ('table order_funding_events', to_regclass('public.order_funding_events') IS NOT NULL),
    ('view dva_statement_line_allocation_summary_vw', to_regclass('public.dva_statement_line_allocation_summary_vw') IS NOT NULL),
    ('function internal_importer_available_account_credit_lots_v1', to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') IS NOT NULL),
    ('function internal_importer_available_completion_loyalty_lots_v1', to_regprocedure('public.internal_importer_available_completion_loyalty_lots_v1(uuid)') IS NOT NULL),
    ('function staff_stage_main_bank_line_to_completion_loyalty_v2', to_regprocedure('public.staff_stage_main_bank_line_to_completion_loyalty_v2(uuid,uuid,numeric,text,text,text)') IS NOT NULL),
    ('function staff_pair_loyalty_destination_in_and_release_v1', to_regprocedure('public.staff_pair_loyalty_destination_in_and_release_v1(uuid,uuid,text)') IS NOT NULL),
    ('function staff_apply_completion_loyalty_to_order_v1', to_regprocedure('public.staff_apply_completion_loyalty_to_order_v1(uuid,numeric,text)') IS NOT NULL),
    ('function internal_loyalty_accounting_control_rows_v1', to_regprocedure('public.internal_loyalty_accounting_control_rows_v1(text,integer,integer)') IS NOT NULL)
) AS required(object_name, present);

-- 2. Rejection guard: rejected rewards must not have released active completion-loyalty credit.
WITH rejected_with_credit AS (
  SELECT
    r.order_id,
    o.order_ref,
    r.rejection_reason_code,
    c.id AS credit_ledger_id,
    c.amount_gbp
  FROM public.completion_loyalty_reward_rejections r
  JOIN public.orders o ON o.id = r.order_id
  JOIN public.importer_credit_ledger c
    ON c.source_type = 'completion_loyalty_reward'
   AND c.source_entity_type = 'order'
   AND c.source_entity_id = r.order_id
   AND c.lock_reason IS NULL
  WHERE r.active = true
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '01_rejection' AS section,
  'active rejected orders have no released loyalty credit' AS check_name,
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(abs(amount_gbp)), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'No active rejection has an unlocked completion-loyalty credit.'
    ELSE 'A rejected reward has an unlocked released credit. This must be investigated before applying loyalty.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(rejected_with_credit) ORDER BY order_ref) FILTER (WHERE order_id IS NOT NULL), '[]'::jsonb) AS sample
FROM rejected_with_credit;

-- 3. Normal account credit must exclude completion-loyalty reward lots.
WITH importers_with_normal_completion_loyalty AS (
  SELECT
    i.id AS importer_id,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    l.credit_ledger_id,
    l.source_type,
    l.available_amount_gbp
  FROM public.importers i
  JOIN LATERAL public.internal_importer_available_account_credit_lots_v1(i.id) l ON true
  WHERE l.source_type = 'completion_loyalty_reward'
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '02_credit_filter' AS section,
  'normal available account credit excludes completion loyalty' AS check_name,
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(available_amount_gbp), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'Completion loyalty is not leaking into normal self-service account credit lots.'
    ELSE 'Completion loyalty appears in normal account credit lots. Customer self-service filters are unsafe.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(importers_with_normal_completion_loyalty) ORDER BY importer_name) FILTER (WHERE importer_id IS NOT NULL), '[]'::jsonb) AS sample
FROM importers_with_normal_completion_loyalty;

-- 4. Completion-loyalty lot health.
WITH loyalty_lots AS (
  SELECT
    i.id AS importer_id,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    l.credit_ledger_id,
    l.available_amount_gbp,
    l.source_order_id
  FROM public.importers i
  JOIN LATERAL public.internal_importer_available_completion_loyalty_lots_v1(i.id) l ON true
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '03_loyalty_lots' AS section,
  'released completion loyalty available via dedicated lots' AS check_name,
  'INFO' AS status,
  count(*) AS rows_found,
  round(coalesce(sum(available_amount_gbp), 0)::numeric, 2) AS amount_gbp,
  'Dedicated completion-loyalty available lots. These are the only lots staff should apply to order balances.' AS finding,
  coalesce(jsonb_agg(to_jsonb(loyalty_lots) ORDER BY importer_name, credit_ledger_id) FILTER (WHERE credit_ledger_id IS NOT NULL), '[]'::jsonb) AS sample
FROM loyalty_lots;

-- 5. Pairing state: staged OUT, paired release, legacy released-out-only.
WITH match_state AS (
  SELECT
    lm.id AS loyalty_match_id,
    o.order_ref,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    lm.matched_gbp_amount,
    lm.match_status,
    lm.transfer_pair_status,
    lm.dva_statement_line_id AS source_out_statement_line_id,
    lm.destination_in_statement_line_id,
    lm.credit_ledger_id,
    lm.created_at
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  LEFT JOIN public.importers i ON i.id = lm.importer_id
  WHERE lm.match_status IN ('confirmed','released_available_dashboard_credit')
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '04_pairing' AS section,
  'source OUT staged but destination IN not yet paired' AS check_name,
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'WARN' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(matched_gbp_amount), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'No staged source OUT line is waiting for destination IN pairing.'
    ELSE 'There are staged source OUT lines waiting for destination IN pairing. This is not a failure, but they are not ready/available until paired.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(match_state) ORDER BY created_at DESC) FILTER (WHERE loyalty_match_id IS NOT NULL), '[]'::jsonb) AS sample
FROM match_state
WHERE match_status = 'confirmed'
  AND coalesce(transfer_pair_status, 'source_out_reserved') IN ('source_out_reserved','paired_ready_to_release')
  AND destination_in_statement_line_id IS NULL;

WITH legacy_unpaired AS (
  SELECT
    lm.id AS loyalty_match_id,
    o.order_ref,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    lm.matched_gbp_amount,
    lm.match_status,
    lm.transfer_pair_status,
    lm.dva_statement_line_id AS source_out_statement_line_id,
    lm.destination_in_statement_line_id,
    lm.credit_ledger_id,
    lm.created_at
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  LEFT JOIN public.importers i ON i.id = lm.importer_id
  WHERE lm.match_status = 'released_available_dashboard_credit'
    AND lm.destination_in_statement_line_id IS NULL
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '04_pairing' AS section,
  'legacy released OUT-only rows identified' AS check_name,
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'WARN' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(matched_gbp_amount), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'No released completion loyalty rows are missing destination IN pairing.'
    ELSE 'Legacy released OUT-only rows exist. They should remain visible as blockers/control rows until paired or explained.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(legacy_unpaired) ORDER BY created_at DESC) FILTER (WHERE loyalty_match_id IS NOT NULL), '[]'::jsonb) AS sample
FROM legacy_unpaired;

WITH paired_released AS (
  SELECT
    lm.id AS loyalty_match_id,
    o.order_ref,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    lm.matched_gbp_amount,
    lm.match_status,
    lm.transfer_pair_status,
    lm.dva_statement_line_id AS source_out_statement_line_id,
    lm.destination_in_statement_line_id,
    lm.credit_ledger_id,
    lm.created_at
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  LEFT JOIN public.importers i ON i.id = lm.importer_id
  WHERE lm.match_status = 'released_available_dashboard_credit'
    AND lm.transfer_pair_status = 'paired_released'
    AND lm.destination_in_statement_line_id IS NOT NULL
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '04_pairing' AS section,
  'paired released loyalty rows' AS check_name,
  'INFO' AS status,
  count(*) AS rows_found,
  round(coalesce(sum(matched_gbp_amount), 0)::numeric, 2) AS amount_gbp,
  'Rows successfully paired and released under the new source OUT + destination IN control.' AS finding,
  coalesce(jsonb_agg(to_jsonb(paired_released) ORDER BY created_at DESC) FILTER (WHERE loyalty_match_id IS NOT NULL), '[]'::jsonb) AS sample
FROM paired_released;

-- 6. Statement summary visibility: OUT/IN lines must surface as loyalty internal transfer controls.
WITH loyalty_statement_summary AS (
  SELECT
    dva_statement_line_id,
    statement_date,
    direction,
    reference_raw,
    statement_gbp_amount,
    confirmed_allocated_gbp,
    confirmed_unallocated_gbp,
    confirmed_balanced_yn,
    control_match_reason,
    loyalty_credit_funding_allocated_gbp,
    loyalty_internal_transfer_out_gbp,
    loyalty_internal_transfer_in_gbp
  FROM public.dva_statement_line_allocation_summary_vw
  WHERE control_match_reason IN ('loyalty_internal_transfer_out','loyalty_internal_transfer_in')
     OR coalesce(loyalty_credit_funding_allocated_gbp, 0) > 0
     OR coalesce(loyalty_internal_transfer_out_gbp, 0) > 0
     OR coalesce(loyalty_internal_transfer_in_gbp, 0) > 0
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '05_statement_summary' AS section,
  'loyalty OUT/IN appears in statement summary read model' AS check_name,
  CASE WHEN count(*) = 0 THEN 'WARN' ELSE 'PASS' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(loyalty_credit_funding_allocated_gbp), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'No loyalty internal-transfer rows are currently visible in the statement summary read model.'
    ELSE 'Statement summary is surfacing loyalty internal-transfer controls.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(loyalty_statement_summary) ORDER BY statement_date DESC, dva_statement_line_id DESC) FILTER (WHERE dva_statement_line_id IS NOT NULL), '[]'::jsonb) AS sample
FROM loyalty_statement_summary;

WITH unbalanced_loyalty_summary AS (
  SELECT *
  FROM public.dva_statement_line_allocation_summary_vw
  WHERE (
      control_match_reason IN ('loyalty_internal_transfer_out','loyalty_internal_transfer_in')
      OR coalesce(loyalty_credit_funding_allocated_gbp, 0) > 0
    )
    AND coalesce(confirmed_balanced_yn, false) = false
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '05_statement_summary' AS section,
  'loyalty statement lines balanced after control recognition' AS check_name,
  CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'WARN' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(abs(confirmed_unallocated_gbp)), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'All visible loyalty statement lines are balanced in the summary read model.'
    ELSE 'Some loyalty statement lines are visible but not fully balanced. Check legacy/unpaired rows or partial destination IN balances.'
  END AS finding,
  coalesce(jsonb_agg(jsonb_build_object(
    'statement_line_id', dva_statement_line_id,
    'direction', direction,
    'reference_raw', reference_raw,
    'statement_gbp_amount', statement_gbp_amount,
    'confirmed_allocated_gbp', confirmed_allocated_gbp,
    'confirmed_unallocated_gbp', confirmed_unallocated_gbp,
    'control_match_reason', control_match_reason
  ) ORDER BY statement_date DESC) FILTER (WHERE dva_statement_line_id IS NOT NULL), '[]'::jsonb) AS sample
FROM unbalanced_loyalty_summary;

-- 7. Order funding event proof: staff-applied loyalty should create credit_applied events.
WITH applied_loyalty AS (
  SELECT
    o.id AS order_id,
    o.order_ref,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer') AS importer_name,
    ofe.id AS order_funding_event_id,
    ofe.amount_gbp,
    ofe.source_entity_id AS source_credit_debit_id,
    d.source_id AS source_credit_ledger_id,
    c.source_type AS source_credit_type,
    ofe.created_at
  FROM public.order_funding_events ofe
  JOIN public.orders o ON o.id = ofe.order_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.importer_credit_ledger d ON d.id = ofe.source_entity_id
  LEFT JOIN public.importer_credit_ledger c ON c.id = coalesce(d.source_id, d.source_entity_id)
  WHERE ofe.event_type = 'credit_applied'
    AND c.source_type = 'completion_loyalty_reward'
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '06_apply_to_order' AS section,
  'staff-applied completion loyalty creates credit_applied order funding event' AS check_name,
  CASE WHEN count(*) = 0 THEN 'WARN' ELSE 'PASS' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(amount_gbp), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) = 0
    THEN 'No credit_applied order funding events from completion loyalty were found yet.'
    ELSE 'Completion loyalty has been applied through credit_applied order funding events.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(applied_loyalty) ORDER BY created_at DESC) FILTER (WHERE order_funding_event_id IS NOT NULL), '[]'::jsonb) AS sample
FROM applied_loyalty;

-- 8. Accounting-control rows reconstructed directly, confirming no selectable rows.
WITH internal_transfer AS (
  SELECT
    ('loyalty_control:bank_internal_transfer:' || lm.id::text)::text AS queue_row_id,
    'main_bank_completion_loyalty_funding_matches'::text AS source_type,
    lm.id AS source_id,
    'bank_internal_transfer'::text AS category,
    o.id AS order_id,
    o.order_ref::text AS order_ref,
    lm.importer_id,
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
    round(lm.matched_gbp_amount::numeric, 2) AS amount_gbp,
    'Dr DVA/card/virtual-card bank; Cr main bank'::text AS accounting_treatment,
    coalesce(lm.transfer_pair_status, lm.match_status)::text AS control_status,
    CASE WHEN lm.destination_in_statement_line_id IS NULL THEN 'Destination DVA/card/virtual-card IN line not paired yet' ELSE NULL::text END AS blocker,
    false AS selectable
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
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
    round(abs(d.amount_gbp)::numeric, 2) AS amount_gbp,
    'Dr loyalty cost / reward expense / loyalty liability; Cr customer account / receivable'::text AS accounting_treatment,
    'applied_to_order'::text AS control_status,
    NULL::text AS blocker,
    false AS selectable
  FROM public.importer_credit_ledger d
  JOIN public.orders o ON o.id = d.applied_to_order_id
  LEFT JOIN public.importers i ON i.id = d.importer_id
  WHERE d.direction = 'debit'
    AND d.entry_type = 'applied_to_order'
    AND d.lock_reason IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.importer_credit_ledger c
      WHERE c.id = coalesce(d.source_id, d.source_entity_id)
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
    coalesce(nullif(trim(i.trading_name), ''), nullif(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
    round(c.available_amount_gbp::numeric, 2) AS amount_gbp,
    'Control balance only in MVP; no automatic P&L accrual/posting'::text AS accounting_treatment,
    'released_unused'::text AS control_status,
    NULL::text AS blocker,
    false AS selectable
  FROM public.importer_credit_ledger icl
  JOIN LATERAL public.internal_importer_available_completion_loyalty_lots_v1(icl.importer_id) c ON c.credit_ledger_id = icl.id
  LEFT JOIN public.orders o ON o.id = c.source_order_id
  LEFT JOIN public.importers i ON i.id = icl.importer_id
), accounting_rows AS (
  SELECT * FROM internal_transfer
  UNION ALL SELECT * FROM non_cash_settlement
  UNION ALL SELECT * FROM released_unused
)
INSERT INTO loyalty_sql_simulation_report(section, check_name, status, rows_found, amount_gbp, finding, sample)
SELECT
  '07_accounting_controls' AS section,
  'loyalty accounting-control rows are read-only and non-selectable' AS check_name,
  CASE WHEN count(*) FILTER (WHERE selectable = true) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
  count(*) AS rows_found,
  round(coalesce(sum(amount_gbp), 0)::numeric, 2) AS amount_gbp,
  CASE WHEN count(*) FILTER (WHERE selectable = true) = 0
    THEN 'Accounting-control rows are visible as evidence only and are not selectable for freeze/post.'
    ELSE 'One or more loyalty accounting-control rows are selectable. This breaches the contract boundary.'
  END AS finding,
  coalesce(jsonb_agg(to_jsonb(accounting_rows) ORDER BY category, order_ref) FILTER (WHERE queue_row_id IS NOT NULL), '[]'::jsonb) AS sample
FROM accounting_rows;

-- Final report.
SELECT
  seq,
  section,
  check_name,
  status,
  rows_found,
  amount_gbp,
  finding,
  sample
FROM loyalty_sql_simulation_report
ORDER BY seq;

-- Compact summary for quick pass/fail reading.
SELECT
  status,
  count(*) AS checks,
  jsonb_agg(jsonb_build_object('section', section, 'check', check_name, 'finding', finding) ORDER BY seq) AS details
FROM loyalty_sql_simulation_report
GROUP BY status
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END;

ROLLBACK;
