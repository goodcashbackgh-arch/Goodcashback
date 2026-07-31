-- Main-bank shipper allocation review + reversal v1
-- Post-migration structural and live-control checks.
-- Read-only unless explicitly noted in the transactional test section.
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

-- 2. Unified review exposes both storage families when rows exist.
SELECT
  allocation_family,
  allocation_status,
  count(*) AS row_count
FROM public.statement_line_matching_review_v1
GROUP BY allocation_family, allocation_status
ORDER BY allocation_family, allocation_status;

-- 3. No duplicate review identity within a family.
SELECT allocation_family, allocation_id, count(*) AS duplicate_count
FROM public.statement_line_matching_review_v1
GROUP BY allocation_family, allocation_id
HAVING count(*) > 1;
-- Expected: zero rows.

-- 4. Review access is through the staff-guarded RPC, not a direct authenticated view grant.
SELECT
  has_function_privilege('authenticated', 'public.internal_statement_line_matching_review_v1(text,text,uuid,integer)', 'EXECUTE') AS authenticated_can_execute_review_rpc,
  has_table_privilege('authenticated', 'public.statement_line_matching_review_v1', 'SELECT') AS authenticated_can_select_private_review_view;
-- Expected: true, false.

-- 5. Confirm the reversal function contains the active frozen-cash boundary.
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

-- 6. Confirm the freeze-side trigger exists and locks/revalidates the source allocation.
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

-- 7. Confirm the corrected allocator consumes the amount-aware control position.
SELECT
  position('statement_line_control_position_v1' in pg_get_functiondef(p.oid)) > 0 AS uses_amount_aware_position,
  position('remaining_unconsumed_gbp' in pg_get_functiondef(p.oid)) > 0 AS uses_true_remaining,
  position('FOR UPDATE OF dsl' in pg_get_functiondef(p.oid)) > 0 AS locks_statement_line
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'staff_allocate_main_bank_line_to_shipper_ap_v1';
-- Expected: all true.

-- 8. Find mixed main-bank rows for functional verification.
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

-- 9. Cross-check review rows against canonical source position.
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

-- 10. Identify shipper allocations that MUST be blocked from review reversal.
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

-- 11. Invalid committed state must not exist.
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

-- 12. Identify unfrozen confirmed shipper allocations eligible for controlled reversal testing.
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

-- 13. Transactional negative test for the trigger (NON-PRODUCTION TEST DATABASE ONLY).
-- Use a real reversed allocation id and a structurally valid snapshot row cloned
-- from an existing test snapshot. The INSERT must fail with:
--   Main-bank shipper allocation <id> is reversed and cannot be frozen into cash posting.
-- Keep the test inside BEGIN/ROLLBACK and do not run against production.
--
-- 14. Concurrency harness (NON-PRODUCTION ONLY):
-- Session A: begin; lock/reverse an eligible shipper allocation but pause before commit.
-- Session B: attempt governed freeze for the same allocation; it must wait on the
--            source-allocation row and then fail after Session A commits reversed.
-- Repeat with order reversed: freeze obtains lock/inserts snapshot first; reversal
-- must wait, then observe the active snapshot and fail. Neither ordering may commit
-- `reversed allocation + newly active shipper-payment snapshot`.
