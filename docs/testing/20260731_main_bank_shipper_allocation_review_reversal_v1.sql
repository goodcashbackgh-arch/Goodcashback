-- Main-bank shipper allocation review + reversal v1
-- Post-migration structural and live-control checks.
-- Read-only except for the explicitly marked NON-PRODUCTION two-session harness.
-- Run after 20260731_main_bank_shipper_allocation_review_reversal_v1.sql is deployed.

-- 1. Required objects exist.
DO $$
BEGIN
  IF to_regclass('public.statement_line_matching_review_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing statement_line_matching_review_v1';
  END IF;
  IF to_regprocedure('public.internal_statement_line_matching_review_v1(text,text,uuid,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_statement_line_matching_review_v1(text,text,uuid,integer)';
  END IF;
  IF to_regprocedure('public.guard_main_bank_shipper_cash_snapshot_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing guard_main_bank_shipper_cash_snapshot_v1()';
  END IF;
  IF to_regprocedure('public.staff_reverse_main_bank_shipper_ap_allocation_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_reverse_main_bank_shipper_ap_allocation_v1(uuid,text)';
  END IF;
  IF to_regprocedure('public.staff_allocate_main_bank_line_to_shipper_ap_v1(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_allocate_main_bank_line_to_shipper_ap_v1(uuid,uuid,numeric,text)';
  END IF;
END $$;

-- 2. Record transaction isolation used by the validation environment.
SELECT current_setting('transaction_isolation') AS transaction_isolation;
-- Expected production-compatible result for this concurrency contract: read committed.

-- 3. Unified review exposes both storage families when rows exist.
SELECT
  allocation_family,
  allocation_status,
  count(*) AS row_count
FROM public.statement_line_matching_review_v1
GROUP BY allocation_family, allocation_status
ORDER BY allocation_family, allocation_status;

-- 4. No duplicate review identity within a family.
SELECT allocation_family, allocation_id, count(*) AS duplicate_count
FROM public.statement_line_matching_review_v1
GROUP BY allocation_family, allocation_id
HAVING count(*) > 1;
-- Expected: zero rows.

-- 5. Review access is through the staff-guarded RPC, not a direct authenticated view grant.
SELECT
  has_function_privilege('authenticated', 'public.internal_statement_line_matching_review_v1(text,text,uuid,integer)', 'EXECUTE') AS authenticated_can_execute_review_rpc,
  has_table_privilege('authenticated', 'public.statement_line_matching_review_v1', 'SELECT') AS authenticated_can_select_private_review_view;
-- Expected: true, false.

-- 6. Confirm the reversal function contains the active frozen-cash boundary.
SELECT
  position('cash_posting_snapshots' in pg_get_functiondef(p.oid)) > 0 AS checks_cash_snapshots,
  position('main_bank_shipper_ap_allocation' in pg_get_functiondef(p.oid)) > 0 AS checks_source_type,
  position('shipper_invoice_payment' in pg_get_functiondef(p.oid)) > 0 AS checks_posting_category,
  position('cps.active = true' in pg_get_functiondef(p.oid)) > 0 AS checks_active_snapshot,
  position('FOR UPDATE' in pg_get_functiondef(p.oid)) > 0 AS locks_source_allocation
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'staff_reverse_main_bank_shipper_ap_allocation_v1';
-- Expected: all true.

-- 7. Confirm the freeze-side trigger exists and locks/revalidates the source allocation.
SELECT
  t.tgname,
  pg_get_triggerdef(t.oid) AS trigger_definition
FROM pg_trigger t
WHERE t.tgrelid = 'public.cash_posting_snapshots'::regclass
  AND t.tgname = 'trg_guard_main_bank_shipper_cash_snapshot_v1'
  AND NOT t.tgisinternal;
-- Expected: one row.

SELECT
  position('main_bank_shipper_ap_allocations' in pg_get_functiondef(p.oid)) > 0 AS checks_source_table,
  position('FOR UPDATE' in pg_get_functiondef(p.oid)) > 0 AS locks_source_allocation,
  position('confirmed' in pg_get_functiondef(p.oid)) > 0 AS rechecks_confirmed_status
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'guard_main_bank_shipper_cash_snapshot_v1';
-- Expected: all true.

-- 8. Confirm the corrected allocator consumes the amount-aware control position.
SELECT
  position('statement_line_control_position_v1' in pg_get_functiondef(p.oid)) > 0 AS uses_amount_aware_position,
  position('remaining_unconsumed_gbp' in pg_get_functiondef(p.oid)) > 0 AS uses_true_remaining,
  position('FOR UPDATE OF dsl' in pg_get_functiondef(p.oid)) > 0 AS locks_statement_line
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'staff_allocate_main_bank_line_to_shipper_ap_v1';
-- Expected: all true.

-- 9. Find mixed main-bank rows for functional verification.
SELECT
  p.statement_line_id,
  p.statement_date,
  p.reference_raw,
  p.statement_gbp_amount,
  p.active_consumed_gbp,
  p.active_reserved_gbp,
  p.remaining_unconsumed_gbp,
  p.overconsumed_gbp,
  p.raw_active_families
FROM public.statement_line_control_position_v1 p
WHERE p.statement_account_context = 'main_company_bank_account'
  AND 'main_bank_shipper_ap' = ANY(p.raw_active_families)
  AND cardinality(p.raw_active_families) > 1
ORDER BY p.statement_date DESC
LIMIT 50;

-- 10. Cross-check review rows against canonical source position.
SELECT
  r.allocation_family,
  r.allocation_id,
  r.dva_statement_line_id,
  r.allocated_gbp_amount AS this_row_gbp,
  p.statement_gbp_amount,
  p.active_consumed_gbp,
  p.active_reserved_gbp,
  p.remaining_unconsumed_gbp,
  p.overconsumed_gbp
FROM public.statement_line_matching_review_v1 r
JOIN public.statement_line_control_position_v1 p
  ON p.statement_line_id = r.dva_statement_line_id
WHERE r.allocation_status = 'confirmed'
ORDER BY r.created_at DESC
LIMIT 100;

-- 11. Identify shipper allocations that MUST be blocked from review reversal.
SELECT
  a.id AS allocation_id,
  a.dva_statement_line_id,
  a.shipping_document_id,
  a.allocated_gbp_amount,
  cps.id AS cash_snapshot_id,
  cps.freeze_status,
  cps.validation_status,
  cps.sage_posting_status
FROM public.main_bank_shipper_ap_allocations a
JOIN public.cash_posting_snapshots cps
  ON cps.active = true
 AND cps.source_type = 'main_bank_shipper_ap_allocation'
 AND cps.source_id = a.id
 AND cps.posting_category = 'shipper_invoice_payment'
WHERE a.allocation_status = 'confirmed'
ORDER BY cps.created_at DESC;

-- 12. Invalid committed state must not exist.
SELECT
  a.id AS reversed_allocation_id,
  cps.id AS active_cash_snapshot_id
FROM public.main_bank_shipper_ap_allocations a
JOIN public.cash_posting_snapshots cps
  ON cps.active = true
 AND cps.source_type = 'main_bank_shipper_ap_allocation'
 AND cps.source_id = a.id
 AND cps.posting_category = 'shipper_invoice_payment'
WHERE a.allocation_status = 'reversed';
-- Expected: zero rows after rollout/remediation.

-- 13. Identify unfrozen confirmed shipper allocations eligible for controlled concurrency testing.
SELECT
  a.id AS allocation_id,
  a.dva_statement_line_id,
  a.shipping_document_id,
  a.allocated_gbp_amount,
  p.statement_gbp_amount,
  p.active_consumed_gbp,
  p.remaining_unconsumed_gbp
FROM public.main_bank_shipper_ap_allocations a
JOIN public.statement_line_control_position_v1 p
  ON p.statement_line_id = a.dva_statement_line_id
WHERE a.allocation_status = 'confirmed'
  AND NOT EXISTS (
    SELECT 1
    FROM public.cash_posting_snapshots cps
    WHERE cps.active = true
      AND cps.source_type = 'main_bank_shipper_ap_allocation'
      AND cps.source_id = a.id
      AND cps.posting_category = 'shipper_invoice_payment'
  )
ORDER BY a.created_at DESC
LIMIT 50;

-- ============================================================================
-- 14. NON-PRODUCTION TWO-SESSION CONCURRENCY HARNESS
-- ============================================================================
-- Run only on a disposable/non-production database using one allocation returned
-- by section 13. Replace <ALLOCATION_UUID> in BOTH sessions with the same UUID.
-- These statements test the database lock invariant directly and do not call Sage.
--
-- A structurally complete snapshot row is created by cloning an existing test
-- snapshot. Pick any existing cash_posting_snapshots row as <TEMPLATE_SNAPSHOT_UUID>.
-- The harness overrides all identity fields used by the shipper guard and rolls
-- back/deletes its test snapshot as instructed.
--
-- First verify isolation in BOTH sessions:
--   SELECT current_setting('transaction_isolation');
-- Expected: read committed.

-- ---------------------------------------------------------------------------
-- ORDERING A: REVERSAL-SIDE LOCK WINS
-- ---------------------------------------------------------------------------
-- SESSION A:
-- BEGIN;
-- SELECT id, allocation_status
-- FROM public.main_bank_shipper_ap_allocations
-- WHERE id = '<ALLOCATION_UUID>'::uuid
-- FOR UPDATE;
--
-- UPDATE public.main_bank_shipper_ap_allocations
-- SET allocation_status = 'reversed',
--     reversed_at = now(),
--     reversal_reason = 'non-production concurrency test'
-- WHERE id = '<ALLOCATION_UUID>'::uuid;
-- -- STOP HERE. Do not commit yet.
--
-- SESSION B, while Session A is paused:
-- BEGIN;
-- INSERT INTO public.cash_posting_snapshots (
--   active, posting_category, source_type, source_id, statement_line_id,
--   order_id, order_ref, counterparty_type, counterparty_id, counterparty_name,
--   sage_contact_id, sage_contact_name, sage_bank_account_id, amount_gbp,
--   posting_date, short_reference, idempotency_key, request_payload,
--   internal_reference_json, freeze_status, validation_status,
--   validation_errors, sage_posting_status, notes, created_by_staff_id
-- )
-- SELECT
--   true,
--   'shipper_invoice_payment',
--   'main_bank_shipper_ap_allocation',
--   '<ALLOCATION_UUID>'::uuid,
--   a.dva_statement_line_id,
--   t.order_id, t.order_ref, t.counterparty_type, t.counterparty_id, t.counterparty_name,
--   t.sage_contact_id, t.sage_contact_name, t.sage_bank_account_id,
--   a.allocated_gbp_amount,
--   CURRENT_DATE,
--   'TEST-SHIPPER-RACE-A',
--   'test:shipper-race-a:' || gen_random_uuid()::text,
--   t.request_payload,
--   jsonb_build_object('test', true, 'allocation_id', a.id),
--   'frozen', 'validated', '[]'::jsonb, 'not_posted',
--   'NON-PRODUCTION concurrency test A', t.created_by_staff_id
-- FROM public.cash_posting_snapshots t
-- CROSS JOIN public.main_bank_shipper_ap_allocations a
-- WHERE t.id = '<TEMPLATE_SNAPSHOT_UUID>'::uuid
--   AND a.id = '<ALLOCATION_UUID>'::uuid;
-- -- Expected now: Session B WAITS on the allocation row lock.
--
-- SESSION A:
-- COMMIT;
--
-- SESSION B:
-- -- Expected after Session A commits: INSERT fails with
-- -- "Main-bank shipper allocation ... is reversed and cannot be frozen into cash posting."
-- ROLLBACK;
--
-- FINAL ASSERTION:
-- SELECT a.id, a.allocation_status, count(cps.id) AS active_shipper_snapshots
-- FROM public.main_bank_shipper_ap_allocations a
-- LEFT JOIN public.cash_posting_snapshots cps
--   ON cps.active = true
--  AND cps.source_type = 'main_bank_shipper_ap_allocation'
--  AND cps.source_id = a.id
--  AND cps.posting_category = 'shipper_invoice_payment'
-- WHERE a.id = '<ALLOCATION_UUID>'::uuid
-- GROUP BY a.id, a.allocation_status;
-- Expected: allocation_status = reversed, active_shipper_snapshots = 0.
--
-- IMPORTANT: restore/reset this disposable fixture before ORDERING B, or choose a
-- separate eligible confirmed allocation. Do not rewrite production history.

-- ---------------------------------------------------------------------------
-- ORDERING B: FREEZE-SIDE LOCK WINS
-- ---------------------------------------------------------------------------
-- Use a fresh eligible confirmed allocation with no active shipper snapshot.
--
-- SESSION A:
-- BEGIN;
-- INSERT INTO public.cash_posting_snapshots (
--   active, posting_category, source_type, source_id, statement_line_id,
--   order_id, order_ref, counterparty_type, counterparty_id, counterparty_name,
--   sage_contact_id, sage_contact_name, sage_bank_account_id, amount_gbp,
--   posting_date, short_reference, idempotency_key, request_payload,
--   internal_reference_json, freeze_status, validation_status,
--   validation_errors, sage_posting_status, notes, created_by_staff_id
-- )
-- SELECT
--   true,
--   'shipper_invoice_payment',
--   'main_bank_shipper_ap_allocation',
--   '<ALLOCATION_UUID>'::uuid,
--   a.dva_statement_line_id,
--   t.order_id, t.order_ref, t.counterparty_type, t.counterparty_id, t.counterparty_name,
--   t.sage_contact_id, t.sage_contact_name, t.sage_bank_account_id,
--   a.allocated_gbp_amount,
--   CURRENT_DATE,
--   'TEST-SHIPPER-RACE-B',
--   'test:shipper-race-b:' || gen_random_uuid()::text,
--   t.request_payload,
--   jsonb_build_object('test', true, 'allocation_id', a.id),
--   'frozen', 'validated', '[]'::jsonb, 'not_posted',
--   'NON-PRODUCTION concurrency test B', t.created_by_staff_id
-- FROM public.cash_posting_snapshots t
-- CROSS JOIN public.main_bank_shipper_ap_allocations a
-- WHERE t.id = '<TEMPLATE_SNAPSHOT_UUID>'::uuid
--   AND a.id = '<ALLOCATION_UUID>'::uuid
-- RETURNING id;
-- -- Expected: INSERT succeeds and the trigger holds the allocation-row lock.
-- -- STOP HERE. Do not commit yet.
--
-- SESSION B, while Session A is paused:
-- BEGIN;
-- SELECT a.*
-- FROM public.main_bank_shipper_ap_allocations a
-- WHERE a.id = '<ALLOCATION_UUID>'::uuid
-- FOR UPDATE;
-- -- Expected now: Session B WAITS on the allocation row lock.
--
-- SESSION A:
-- COMMIT;
--
-- SESSION B, after lock acquisition:
-- DO $$
-- BEGIN
--   IF EXISTS (
--     SELECT 1
--     FROM public.cash_posting_snapshots cps
--     WHERE cps.active = true
--       AND cps.source_type = 'main_bank_shipper_ap_allocation'
--       AND cps.source_id = '<ALLOCATION_UUID>'::uuid
--       AND cps.posting_category = 'shipper_invoice_payment'
--   ) THEN
--     RAISE EXCEPTION 'EXPECTED REVERSAL BLOCK: active cash-posting snapshot exists';
--   END IF;
-- END $$;
-- -- Expected: exception raised; no reversal UPDATE is executed.
-- ROLLBACK;
--
-- FINAL ASSERTION:
-- SELECT a.id, a.allocation_status, count(cps.id) AS active_shipper_snapshots
-- FROM public.main_bank_shipper_ap_allocations a
-- LEFT JOIN public.cash_posting_snapshots cps
--   ON cps.active = true
--  AND cps.source_type = 'main_bank_shipper_ap_allocation'
--  AND cps.source_id = a.id
--  AND cps.posting_category = 'shipper_invoice_payment'
-- WHERE a.id = '<ALLOCATION_UUID>'::uuid
-- GROUP BY a.id, a.allocation_status;
-- Expected: allocation_status = confirmed, active_shipper_snapshots = 1.
--
-- CLEANUP FOR DISPOSABLE TEST DATABASE ONLY:
-- UPDATE public.cash_posting_snapshots
-- SET active = false,
--     notes = concat_ws(E'\n', notes, 'Deactivated after non-production concurrency test')
-- WHERE active = true
--   AND source_type = 'main_bank_shipper_ap_allocation'
--   AND source_id = '<ALLOCATION_UUID>'::uuid
--   AND posting_category = 'shipper_invoice_payment'
--   AND idempotency_key LIKE 'test:shipper-race-b:%';

-- 15. Final global invariant after either test ordering and cleanup/remediation.
SELECT
  a.id AS reversed_allocation_id,
  cps.id AS active_cash_snapshot_id
FROM public.main_bank_shipper_ap_allocations a
JOIN public.cash_posting_snapshots cps
  ON cps.active = true
 AND cps.source_type = 'main_bank_shipper_ap_allocation'
 AND cps.source_id = a.id
 AND cps.posting_category = 'shipper_invoice_payment'
WHERE a.allocation_status = 'reversed';
-- Expected: zero rows.
