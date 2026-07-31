-- Main-bank shipper allocation review + reversal v1
-- Post-migration structural and live-control checks.
-- Read-only. Run after 20260731_main_bank_shipper_allocation_review_reversal_v1.sql is deployed.

-- 1. Required objects exist.
DO $$
BEGIN
  IF to_regclass('public.statement_line_matching_review_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing statement_line_matching_review_v1';
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

-- 4. Confirm the reversal function contains the active frozen-cash boundary.
SELECT
  position('cash_posting_snapshots' in pg_get_functiondef(p.oid)) > 0 AS checks_cash_snapshots,
  position('main_bank_shipper_ap_allocation' in pg_get_functiondef(p.oid)) > 0 AS checks_source_type,
  position('shipper_invoice_payment' in pg_get_functiondef(p.oid)) > 0 AS checks_posting_category,
  position('cps.active = true' in pg_get_functiondef(p.oid)) > 0 AS checks_active_snapshot
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'staff_reverse_main_bank_shipper_ap_allocation_v1';

-- Expected: all true.

-- 5. Confirm the corrected allocator consumes the amount-aware control position.
SELECT
  position('statement_line_control_position_v1' in pg_get_functiondef(p.oid)) > 0 AS uses_amount_aware_position,
  position('remaining_unconsumed_gbp' in pg_get_functiondef(p.oid)) > 0 AS uses_true_remaining,
  position('FOR UPDATE OF dsl' in pg_get_functiondef(p.oid)) > 0 AS locks_statement_line
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'staff_allocate_main_bank_line_to_shipper_ap_v1';

-- Expected: all true.

-- 6. Find mixed main-bank rows for functional verification.
-- For every returned row, active_used + remaining should equal statement amount
-- unless overconsumed_gbp is non-zero and requires separate control remediation.
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

-- 7. Cross-check review rows against canonical source position.
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

-- 8. Identify shipper allocations that MUST be blocked from review reversal.
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

-- Any row returned here must be rejected by
-- staff_reverse_main_bank_shipper_ap_allocation_v1.

-- 9. Identify unfrozen confirmed shipper allocations eligible for controlled
-- reversal testing in a non-production environment.
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
