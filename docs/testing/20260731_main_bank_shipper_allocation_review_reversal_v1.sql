-- Main-bank shipper allocation review + reversal v1
-- Post-migration structural and live-control checks.
-- Read-only except for the explicitly marked NON-PRODUCTION concurrency harnesses.
-- Run after 20260731_main_bank_shipper_allocation_review_reversal_v1.sql is deployed.

-- 1. Required objects exist.
DO $$
BEGIN
  IF to_regclass('public.statement_line_matching_review_v1') IS NULL THEN RAISE EXCEPTION 'Missing statement_line_matching_review_v1'; END IF;
  IF to_regprocedure('public.internal_statement_line_matching_review_v1(text,text,uuid,integer)') IS NULL THEN RAISE EXCEPTION 'Missing internal_statement_line_matching_review_v1(text,text,uuid,integer)'; END IF;
  IF to_regprocedure('public.guard_main_bank_shipper_cash_snapshot_v1()') IS NULL THEN RAISE EXCEPTION 'Missing guard_main_bank_shipper_cash_snapshot_v1()'; END IF;
  IF to_regprocedure('public.staff_reverse_main_bank_shipper_ap_allocation_v1(uuid,text)') IS NULL THEN RAISE EXCEPTION 'Missing staff_reverse_main_bank_shipper_ap_allocation_v1(uuid,text)'; END IF;
  IF to_regprocedure('public.staff_allocate_main_bank_line_to_shipper_ap_v1(uuid,uuid,numeric,text)') IS NULL THEN RAISE EXCEPTION 'Missing staff_allocate_main_bank_line_to_shipper_ap_v1(uuid,uuid,numeric,text)'; END IF;
  IF to_regprocedure('public.internal_freeze_cash_posting_rows_v2(text[],text)') IS NULL THEN RAISE EXCEPTION 'Missing internal_freeze_cash_posting_rows_v2(text[],text)'; END IF;
END $$;

-- 2. Record validation isolation. The concurrency contract below is for the
-- production-compatible default READ COMMITTED behavior.
SELECT current_setting('transaction_isolation') AS transaction_isolation;

-- 3. Unified review identity and family coverage.
SELECT allocation_family, allocation_status, count(*) AS row_count
FROM public.statement_line_matching_review_v1
GROUP BY allocation_family, allocation_status
ORDER BY allocation_family, allocation_status;

SELECT allocation_family, allocation_id, count(*) AS duplicate_count
FROM public.statement_line_matching_review_v1
GROUP BY allocation_family, allocation_id
HAVING count(*) > 1;
-- Expected: zero duplicate rows.

-- 4. Raw view remains private; authenticated callers use the guarded RPC.
SELECT
  has_function_privilege('authenticated', 'public.internal_statement_line_matching_review_v1(text,text,uuid,integer)', 'EXECUTE') AS authenticated_can_execute_review_rpc,
  has_table_privilege('authenticated', 'public.statement_line_matching_review_v1', 'SELECT') AS authenticated_can_select_private_review_view;
-- Expected: true, false.

-- 5. Review authorization is explicitly active admin/supervisor, not the
-- accounting-admin helper used by allocation/freeze commands.
SELECT
  position('role_type' in pg_get_functiondef(p.oid)) > 0 AS resolves_staff_role,
  position('admin' in pg_get_functiondef(p.oid)) > 0 AS permits_admin,
  position('supervisor' in pg_get_functiondef(p.oid)) > 0 AS permits_supervisor,
  position('internal_has_accounting_admin_access_v1' in pg_get_functiondef(p.oid)) = 0 AS does_not_use_accounting_admin_helper
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'internal_statement_line_matching_review_v1';
-- Expected: all true.

-- 6. Reversal contains the active frozen-cash boundary and row lock.
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

-- 7. Freeze-side trigger exists and locks/revalidates source allocation.
SELECT t.tgname, pg_get_triggerdef(t.oid) AS trigger_definition
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

-- 8. Corrected allocator consumes canonical amount-aware control position.
SELECT
  position('statement_line_control_position_v1' in pg_get_functiondef(p.oid)) > 0 AS uses_amount_aware_position,
  position('remaining_unconsumed_gbp' in pg_get_functiondef(p.oid)) > 0 AS uses_true_remaining,
  position('FOR UPDATE OF dsl' in pg_get_functiondef(p.oid)) > 0 AS locks_statement_line,
  position('internal_has_accounting_admin_access_v1' in pg_get_functiondef(p.oid)) > 0 AS allocation_stays_accounting_admin
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'staff_allocate_main_bank_line_to_shipper_ap_v1';
-- Expected: all true.

-- 9. Existing invalid state must never be present after migration.
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
-- Expected: zero rows. The migration itself aborts if this is non-zero before install.

-- 10. Mixed-family source positions for functional verification.
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

-- 11. Cross-check review rows against canonical source position.
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

-- 12. Find an eligible confirmed, unfrozen shipper allocation for controlled testing.
SELECT
  a.id AS allocation_id,
  a.dva_statement_line_id,
  a.shipping_document_id,
  a.allocated_gbp_amount,
  ('cash:shipper_invoice_payment:main_bank_shipper_ap_allocation:' || a.id::text) AS queue_row_id
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
ORDER BY a.created_at DESC
LIMIT 50;

-- ============================================================================
-- 13. LOW-LEVEL TRIGGER HARNESS — NON-PRODUCTION ONLY
-- ============================================================================
-- Retain a direct database-boundary test independent of the application RPCs.
-- Use a disposable database. For a reversed allocation, attempt an INSERT into
-- cash_posting_snapshots with active=true, source_type='main_bank_shipper_ap_allocation',
-- source_id=<reversed allocation>, posting_category='shipper_invoice_payment'.
-- Expected: guard_main_bank_shipper_cash_snapshot_v1 rejects the INSERT.
-- Also test a missing source UUID. Expected: rejected as source allocation missing.

-- ============================================================================
-- 14. REAL RPC TWO-SESSION CONCURRENCY HARNESS — NON-PRODUCTION ONLY
-- ============================================================================
-- IMPORTANT:
-- * Use authenticated database sessions whose auth.uid() resolves to an active
--   admin user with accounting-admin access. The admin role satisfies both the
--   freeze RPC and reversal RPC permissions without changing either contract.
-- * Use an allocation returned by section 12 that is selectable in
--   internal_cash_posting_workbench_rows_v1.
-- * Replace <ALLOCATION_UUID> and <QUEUE_ROW_ID> in both sessions.
-- * Confirm BOTH sessions report READ COMMITTED before starting.
-- * These calls exercise the real production database functions; they do not call Sage.
--
-- SELECT current_setting('transaction_isolation');
-- Expected: read committed.

-- ---------------------------------------------------------------------------
-- ORDERING A — REAL REVERSAL RPC WINS
-- ---------------------------------------------------------------------------
-- SESSION A:
-- BEGIN;
-- SELECT public.staff_reverse_main_bank_shipper_ap_allocation_v1(
--   '<ALLOCATION_UUID>'::uuid,
--   'non-production reversal wins concurrency test'
-- );
-- -- Function succeeds but transaction remains open, holding statement/allocation locks.
-- -- STOP HERE. Do not COMMIT yet.
--
-- SESSION B, while Session A remains open:
-- BEGIN;
-- SELECT *
-- FROM public.internal_freeze_cash_posting_rows_v2(
--   ARRAY['<QUEUE_ROW_ID>']::text[],
--   'non-production reversal wins concurrency test'
-- );
-- -- Expected: Session B waits on the shipper-allocation row in the snapshot trigger.
--
-- SESSION A:
-- COMMIT;
--
-- SESSION B:
-- -- Expected after Session A commits: the freeze statement is rejected because
-- -- the trigger re-reads the source allocation as reversed. Transaction is aborted.
-- ROLLBACK;
--
-- FINAL ASSERTION:
-- SELECT
--   a.id,
--   a.allocation_status,
--   count(cps.id) FILTER (WHERE cps.active = true) AS active_shipper_snapshots
-- FROM public.main_bank_shipper_ap_allocations a
-- LEFT JOIN public.cash_posting_snapshots cps
--   ON cps.source_type = 'main_bank_shipper_ap_allocation'
--  AND cps.source_id = a.id
--  AND cps.posting_category = 'shipper_invoice_payment'
-- WHERE a.id = '<ALLOCATION_UUID>'::uuid
-- GROUP BY a.id, a.allocation_status;
-- Expected: allocation_status = reversed; active_shipper_snapshots = 0.
--
-- Use a fresh eligible confirmed allocation for Ordering B. Do not rewrite production history.

-- ---------------------------------------------------------------------------
-- ORDERING B — REAL FREEZE RPC WINS
-- ---------------------------------------------------------------------------
-- SESSION A:
-- BEGIN;
-- SELECT *
-- FROM public.internal_freeze_cash_posting_rows_v2(
--   ARRAY['<QUEUE_ROW_ID>']::text[],
--   'non-production freeze wins concurrency test'
-- );
-- -- Expected result includes freeze_status='frozen'. The transaction remains open,
-- -- and the trigger-held allocation row lock remains held until COMMIT/ROLLBACK.
-- -- STOP HERE. Do not COMMIT yet.
--
-- SESSION B, while Session A remains open:
-- BEGIN;
-- SELECT public.staff_reverse_main_bank_shipper_ap_allocation_v1(
--   '<ALLOCATION_UUID>'::uuid,
--   'non-production freeze wins concurrency test'
-- );
-- -- Expected: Session B obtains/holds the statement-line lock, then waits on the
-- -- shipper-allocation row held by Session A.
--
-- SESSION A:
-- COMMIT;
--
-- SESSION B:
-- -- Expected after Session A commits: reversal resumes, sees the newly committed
-- -- active snapshot and raises the governed frozen-accounting blocker.
-- ROLLBACK;
--
-- FINAL ASSERTION:
-- SELECT
--   a.id,
--   a.allocation_status,
--   count(cps.id) FILTER (WHERE cps.active = true) AS active_shipper_snapshots
-- FROM public.main_bank_shipper_ap_allocations a
-- LEFT JOIN public.cash_posting_snapshots cps
--   ON cps.source_type = 'main_bank_shipper_ap_allocation'
--  AND cps.source_id = a.id
--  AND cps.posting_category = 'shipper_invoice_payment'
-- WHERE a.id = '<ALLOCATION_UUID>'::uuid
-- GROUP BY a.id, a.allocation_status;
-- Expected: allocation_status = confirmed; active_shipper_snapshots = 1.
--
-- CLEANUP FOR DISPOSABLE TEST DATABASE ONLY:
-- UPDATE public.cash_posting_snapshots
-- SET active = false,
--     notes = concat_ws(E'\n', notes, 'Deactivated after non-production RPC concurrency test')
-- WHERE active = true
--   AND source_type = 'main_bank_shipper_ap_allocation'
--   AND source_id = '<ALLOCATION_UUID>'::uuid
--   AND posting_category = 'shipper_invoice_payment';

-- 15. Final global invariant after tests/cleanup.
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
