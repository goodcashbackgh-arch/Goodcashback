-- Main-bank shipper cash workbench restoration v1 regression.
-- Read-only unless the optional rollback-only freeze section is explicitly run.
-- Target: restore the historical shipper row family while proving preservation
-- of every existing category-specific workbench request.

-- ---------------------------------------------------------------------------
-- 1. Required function chain exists after migration.
-- ---------------------------------------------------------------------------
SELECT
  to_regprocedure('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)') AS canonical_workbench,
  to_regprocedure('public.internal_cash_posting_workbench_rows_pre_shipper_restoration_v1(text,text,text,text,integer,integer)') AS preserved_workbench,
  to_regprocedure('public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(text,text,text,text,integer,integer)') AS preserved_pre_refund,
  to_regprocedure('public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer)') AS restored_shipper_helper,
  to_regprocedure('public.internal_freeze_cash_posting_rows_v2(text[],text)') AS existing_freeze_rpc,
  to_regprocedure('public.staff_reverse_main_bank_shipper_ap_allocation_v1(uuid,text)') AS existing_shipper_reversal_rpc;

-- Expected: all six values are non-null.

-- ---------------------------------------------------------------------------
-- 2. Structural preservation proof.
-- ---------------------------------------------------------------------------
SELECT
  position(
    'internal_cash_posting_workbench_rows_pre_refund_readiness_v1'
    in pg_get_functiondef('public.internal_cash_posting_workbench_rows_pre_shipper_restoration_v1(text,text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS preserved_still_delegates_to_pre_refund,
  position(
    'internal_retailer_refund_has_posted_settlement_v1'
    in pg_get_functiondef('public.internal_cash_posting_workbench_rows_pre_shipper_restoration_v1(text,text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS preserved_still_uses_refund_settlement_gate,
  position(
    'internal_main_bank_shipper_cash_workbench_rows_v1'
    in pg_get_functiondef('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS canonical_adds_shipper_through_helper,
  position(
    'internal_cash_posting_workbench_rows_pre_shipper_restoration_v1'
    in pg_get_functiondef('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS canonical_uses_preserved_workbench,
  pg_get_functiondef('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)'::regprocedure)
    ~ 'pre_shipper_restoration_v1[[:space:]]*\([[:space:]]*p_direction[[:space:]]*,[[:space:]]*p_category[[:space:]]*,[[:space:]]*p_status' AS preserved_receives_original_status;

-- Expected: true, true, true, true, true.

-- ---------------------------------------------------------------------------
-- 3. Restored helper retains historical identifiers and dynamic mappings.
-- ---------------------------------------------------------------------------
SELECT
  position(
    'main_bank_shipper_ap_allocation'
    in pg_get_functiondef('public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS contains_historical_source_type,
  position(
    'shipper_invoice_payment'
    in pg_get_functiondef('public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS contains_historical_category,
  position(
    'DVA_CASH_BANK_ACCOUNT'
    in pg_get_functiondef('public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS resolves_named_bank_mapping,
  position(
    '1d21e52bed0a4fedb1b1dc21044b7d07'
    in pg_get_functiondef('public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer)'::regprocedure)
  ) = 0 AS does_not_hardcode_live_bank_uuid;

-- Expected: true, true, true, true.

-- ---------------------------------------------------------------------------
-- 4. Current confirmed/unfrozen shipper backlog. Read-only.
-- ---------------------------------------------------------------------------
SELECT
  a.id AS allocation_id,
  a.dva_statement_line_id,
  a.shipping_document_id,
  sd.document_ref AS shipper_invoice_ref,
  a.allocated_gbp_amount,
  a.sage_purchase_invoice_id,
  pm.sage_contact_id,
  bank.sage_external_id AS sage_bank_account_id,
  cps.id AS active_cash_snapshot_id
FROM public.main_bank_shipper_ap_allocations a
JOIN public.shipping_documents sd ON sd.id = a.shipping_document_id
LEFT JOIN LATERAL (
  SELECT spm.sage_contact_id
  FROM public.sage_party_mappings spm
  WHERE spm.platform_party_type = 'shipper'
    AND spm.platform_party_id = sd.shipper_id
    AND spm.active = true
  ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST
  LIMIT 1
) pm ON true
LEFT JOIN LATERAL (
  SELECT sms.sage_external_id
  FROM public.sage_mapping_settings sms
  WHERE sms.mapping_code = 'DVA_CASH_BANK_ACCOUNT'
    AND sms.is_active = true
  ORDER BY sms.updated_at DESC NULLS LAST
  LIMIT 1
) bank ON true
LEFT JOIN public.cash_posting_snapshots cps
  ON cps.active = true
 AND cps.source_type = 'main_bank_shipper_ap_allocation'
 AND cps.source_id = a.id
 AND cps.posting_category = 'shipper_invoice_payment'
WHERE a.allocation_status = 'confirmed'
  AND cps.id IS NULL
ORDER BY a.created_at DESC;

SELECT
  count(*) AS confirmed_unfrozen_count,
  COALESCE(sum(a.allocated_gbp_amount), 0) AS confirmed_unfrozen_amount_gbp
FROM public.main_bank_shipper_ap_allocations a
WHERE a.allocation_status = 'confirmed'
  AND NOT EXISTS (
    SELECT 1
    FROM public.cash_posting_snapshots cps
    WHERE cps.active = true
      AND cps.source_type = 'main_bank_shipper_ap_allocation'
      AND cps.source_id = a.id
      AND cps.posting_category = 'shipper_invoice_payment'
  );

-- Baseline observed before restoration: five rows / GBP 102.00. This may change
-- legitimately if accounting processes rows before the regression is rerun.

-- ---------------------------------------------------------------------------
-- 5. Reversed allocations remain history only.
-- ---------------------------------------------------------------------------
SELECT
  id,
  allocation_status,
  reversed_at,
  reversal_reason
FROM public.main_bank_shipper_ap_allocations
WHERE allocation_status = 'reversed'
ORDER BY reversed_at DESC NULLS LAST, created_at DESC;

SELECT
  position(
    'WHERE a.allocation_status = ''confirmed'''
    in pg_get_functiondef('public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer)'::regprocedure)
  ) > 0 AS helper_is_confirmed_only;

-- ---------------------------------------------------------------------------
-- 6. AUTHENTICATED preservation + restoration runtime proof.
-- ---------------------------------------------------------------------------
BEGIN;

SELECT set_config(
  'request.jwt.claim.sub',
  '6130769e-3afa-4bd4-94cf-b9ddfc349561',
  true
);

SELECT
  auth.uid() AS auth_uid,
  public.internal_has_accounting_admin_access_v1() AS accounting_admin_access;

-- 6A. Bidirectional exact-row equivalence for existing category-specific calls.
-- Full row comparison includes total_count, so status/filter/pagination semantics
-- are protected as well as business fields.
CREATE TEMP TABLE _shipper_restore_equivalence (
  case_name text,
  preserved_minus_canonical bigint,
  canonical_minus_preserved bigint
) ON COMMIT DROP;

DO $equivalence$
DECLARE
  c record;
  v_preserved_minus bigint;
  v_canonical_minus bigint;
BEGIN
  FOR c IN
    SELECT * FROM (VALUES
      ('customer_all',   'in',  'customer_receipt_on_account', 'all',     NULL::text, 100, 0),
      ('customer_ready', 'in',  'customer_receipt_on_account', 'ready',   NULL::text, 100, 0),
      ('final_balance_all', 'in', 'customer_receipt_on_account', 'all',   NULL::text, 300, 0),
      ('supplier_all',   'out', 'supplier_invoice_payment',     'all',     NULL::text, 100, 0),
      ('supplier_ready', 'out', 'supplier_invoice_payment',     'ready',   NULL::text, 100, 0),
      ('refund_all',     'in',  'retailer_refund_received',     'all',     NULL::text, 100, 0),
      ('refund_blocked', 'in',  'retailer_refund_received',     'blocked', NULL::text, 100, 0),
      ('fx_all',         'all', 'fx_card_difference',           'all',     NULL::text, 100, 0),
      ('fee_all',        'all', 'bank_fee',                     'all',     NULL::text, 100, 0),
      ('hold_all',       'all', 'unmatched_hold',               'all',     NULL::text, 100, 0)
    ) AS t(case_name, direction, category, status, search_text, row_limit, row_offset)
  LOOP
    SELECT count(*) INTO v_preserved_minus
    FROM (
      SELECT *
      FROM public.internal_cash_posting_workbench_rows_pre_shipper_restoration_v1(
        c.direction, c.category, c.status, c.search_text, c.row_limit, c.row_offset
      )
      EXCEPT
      SELECT *
      FROM public.internal_cash_posting_workbench_rows_v1(
        c.direction, c.category, c.status, c.search_text, c.row_limit, c.row_offset
      )
    ) d;

    SELECT count(*) INTO v_canonical_minus
    FROM (
      SELECT *
      FROM public.internal_cash_posting_workbench_rows_v1(
        c.direction, c.category, c.status, c.search_text, c.row_limit, c.row_offset
      )
      EXCEPT
      SELECT *
      FROM public.internal_cash_posting_workbench_rows_pre_shipper_restoration_v1(
        c.direction, c.category, c.status, c.search_text, c.row_limit, c.row_offset
      )
    ) d;

    INSERT INTO _shipper_restore_equivalence
      (case_name, preserved_minus_canonical, canonical_minus_preserved)
    VALUES
      (c.case_name, v_preserved_minus, v_canonical_minus);
  END LOOP;
END
$equivalence$;

SELECT *
FROM _shipper_restore_equivalence
ORDER BY case_name;

-- Final-balance is emitted under customer_receipt_on_account with
-- source_type = 'dva_final_balance_allocation'. Assert exact preservation for
-- that subset as well, matching the deployment check already exercised live.
WITH preserved AS (
  SELECT *
  FROM public.internal_cash_posting_workbench_rows_pre_shipper_restoration_v1(
    'in', 'customer_receipt_on_account', 'all', NULL, 300, 0
  )
  WHERE source_type = 'dva_final_balance_allocation'
), canonical AS (
  SELECT *
  FROM public.internal_cash_posting_workbench_rows_v1(
    'in', 'customer_receipt_on_account', 'all', NULL, 300, 0
  )
  WHERE source_type = 'dva_final_balance_allocation'
)
SELECT
  (
    SELECT count(*)
    FROM (
      SELECT * FROM preserved
      EXCEPT
      SELECT * FROM canonical
    ) d
  ) AS final_balance_preserved_minus_canonical,
  (
    SELECT count(*)
    FROM (
      SELECT * FROM canonical
      EXCEPT
      SELECT * FROM preserved
    ) d
  ) AS final_balance_canonical_minus_preserved;

-- Expected: both final-balance difference counts = 0.
-- DEPLOYMENT BLOCKER: every difference count must be zero.

-- 6B. Restored shipper category contract.
SELECT
  queue_row_id,
  source_type,
  source_id,
  statement_line_id,
  statement_date_text,
  direction,
  category,
  counterparty_type,
  counterparty_id,
  counterparty_name,
  amount_gbp,
  matched_target_type,
  matched_target_id,
  matched_target_ref,
  sage_contact_id,
  sage_bank_account_id,
  target_sage_object_id,
  posting_status,
  blocker,
  selectable,
  detail_json->>'short_reference' AS short_reference,
  total_count
FROM public.internal_cash_posting_workbench_rows_v1(
  'out', 'shipper_invoice_payment', 'all', NULL, 300, 0
)
ORDER BY statement_date_text DESC, queue_row_id;

WITH shipper_rows AS (
  SELECT *
  FROM public.internal_cash_posting_workbench_rows_v1(
    'out', 'shipper_invoice_payment', 'all', NULL, 300, 0
  )
)
SELECT
  count(*) AS returned_shipper_rows,
  count(*) FILTER (
    WHERE source_type <> 'main_bank_shipper_ap_allocation'
       OR category <> 'shipper_invoice_payment'
       OR direction <> 'out'
       OR counterparty_type <> 'shipper'
       OR queue_row_id <> ('cash:shipper_invoice_payment:' || source_id::text)
  ) AS contract_violations,
  count(*) FILTER (
    WHERE sage_contact_id IS NULL
       OR sage_bank_account_id IS NULL
       OR target_sage_object_id IS NULL
  ) AS missing_sage_prerequisites
FROM shipper_rows;

-- Expected: contract_violations = 0. Current known backlog should also have
-- missing_sage_prerequisites = 0.

WITH expected AS (
  SELECT a.id
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.allocation_status = 'confirmed'
    AND NOT EXISTS (
      SELECT 1
      FROM public.cash_posting_snapshots cps
      WHERE cps.active = true
        AND cps.source_type = 'main_bank_shipper_ap_allocation'
        AND cps.source_id = a.id
        AND cps.posting_category = 'shipper_invoice_payment'
    )
), actual AS (
  SELECT source_id
  FROM public.internal_cash_posting_workbench_rows_v1(
    'out', 'shipper_invoice_payment', 'all', NULL, 300, 0
  )
)
SELECT e.id AS missing_allocation_id
FROM expected e
LEFT JOIN actual a ON a.source_id = e.id
WHERE a.source_id IS NULL;

-- Expected: zero rows.

ROLLBACK;

-- ---------------------------------------------------------------------------
-- 7. OPTIONAL rollback-only freeze proof.
-- Do not run unless intentionally exercising the real freeze RPC.
-- ---------------------------------------------------------------------------
-- BEGIN;
-- SELECT set_config('request.jwt.claim.sub','6130769e-3afa-4bd4-94cf-b9ddfc349561',true);
-- SELECT *
-- FROM public.internal_freeze_cash_posting_rows_v2(
--   ARRAY['cash:shipper_invoice_payment:<ALLOCATION_UUID>'],
--   'Rollback-only shipper cash restoration regression.'
-- );
-- SELECT
--   source_type,
--   source_id,
--   posting_category,
--   idempotency_key,
--   short_reference,
--   request_payload,
--   internal_reference_json
-- FROM public.cash_posting_snapshots
-- WHERE active = true
--   AND source_type = 'main_bank_shipper_ap_allocation'
--   AND source_id = '<ALLOCATION_UUID>'::uuid
--   AND posting_category = 'shipper_invoice_payment';
-- -- Expected idempotency:
-- -- cash:shipper_invoice_payment:main_bank_shipper_ap_allocation:<ALLOCATION_UUID>
-- ROLLBACK;
