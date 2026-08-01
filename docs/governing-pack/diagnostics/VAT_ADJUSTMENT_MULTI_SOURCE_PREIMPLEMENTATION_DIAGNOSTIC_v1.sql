-- VAT adjustment multi-source allocation pre-implementation diagnostic v1
-- Read-only. No DDL, no DML, no function changes, no Sage calls.
-- Expected outcome: each section returns zero rows unless explicitly noted.

BEGIN;
SET TRANSACTION READ ONLY;

-- 1. Cross-return source links: expected zero rows.
SELECT
  j.id AS journal_id,
  j.vat_return_run_id AS journal_return_id,
  j.vat_return_run_line_id,
  l.vat_return_run_id AS source_line_return_id,
  j.status,
  j.target_box,
  j.direction,
  j.amount_gbp
FROM public.vat_return_adjustment_journals j
JOIN public.vat_return_run_lines l
  ON l.id = j.vat_return_run_line_id
WHERE j.vat_return_run_id <> l.vat_return_run_id
ORDER BY j.created_at;

-- 2. Amount differences under the governed box basis: expected zero rows,
-- unless an existing rule intentionally derives the amount differently.
SELECT
  j.id AS journal_id,
  j.status,
  j.target_box,
  j.direction,
  j.amount_gbp AS journal_amount_gbp,
  l.amount_gbp AS source_net_amount_gbp,
  l.vat_amount_gbp AS source_vat_amount_gbp,
  CASE
    WHEN j.target_box IN (1,4) THEN abs(j.amount_gbp - abs(l.vat_amount_gbp))
    WHEN j.target_box IN (6,7) THEN abs(j.amount_gbp - abs(l.amount_gbp))
  END AS expected_difference_gbp,
  l.line_kind,
  l.adjustment_reason,
  l.source_ref
FROM public.vat_return_adjustment_journals j
JOIN public.vat_return_run_lines l
  ON l.id = j.vat_return_run_line_id
WHERE CASE
  WHEN j.target_box IN (1,4)
    THEN abs(j.amount_gbp - abs(l.vat_amount_gbp)) > 0.01
  WHEN j.target_box IN (6,7)
    THEN abs(j.amount_gbp - abs(l.amount_gbp)) > 0.01
  ELSE false
END
ORDER BY expected_difference_gbp DESC, j.created_at DESC;

-- 3. Linked sources that are inactive or no longer adjustment-required:
-- expected zero rows, or separately classified governed history.
SELECT
  j.id AS journal_id,
  j.status AS journal_status,
  j.vat_return_run_id,
  j.vat_return_run_line_id,
  l.status AS source_line_status,
  l.adjustment_required,
  l.line_kind,
  l.source_ref,
  j.amount_gbp
FROM public.vat_return_adjustment_journals j
JOIN public.vat_return_run_lines l
  ON l.id = j.vat_return_run_line_id
WHERE l.status <> 'active'
   OR l.adjustment_required = false
ORDER BY j.created_at DESC;

-- 4. Reversal/correction patterns: informational. Any returned rows must be
-- classified before implementation so allocation inheritance is not guessed.
SELECT
  j.id,
  j.status,
  j.adjustment_type,
  j.target_box,
  j.direction,
  j.amount_gbp,
  j.vat_return_run_line_id,
  j.reverses_journal_id,
  j.reversed_by_journal_id,
  l.prior_vat_return_line_id,
  l.line_kind,
  l.adjustment_reason,
  l.source_ref
FROM public.vat_return_adjustment_journals j
LEFT JOIN public.vat_return_run_lines l
  ON l.id = j.vat_return_run_line_id
WHERE j.reverses_journal_id IS NOT NULL
   OR j.reversed_by_journal_id IS NOT NULL
   OR l.prior_vat_return_line_id IS NOT NULL
   OR j.status IN ('requires_reversal','reversed')
ORDER BY j.created_at DESC;

-- 5. Malformed or unbalanced existing two-line journals: expected zero rows.
SELECT
  j.id AS journal_id,
  j.status,
  count(l.id) AS line_count,
  count(*) FILTER (WHERE l.line_role = 'vat_box_line') AS vat_box_line_count,
  count(*) FILTER (WHERE l.line_role = 'balancing_line') AS balancing_line_count,
  sum(l.debit_amount_gbp) AS total_debits_gbp,
  sum(l.credit_amount_gbp) AS total_credits_gbp
FROM public.vat_return_adjustment_journals j
LEFT JOIN public.vat_return_adjustment_journal_lines l
  ON l.vat_return_adjustment_journal_id = j.id
GROUP BY j.id, j.status, j.created_at
HAVING count(l.id) <> 2
    OR count(*) FILTER (WHERE l.line_role = 'vat_box_line') <> 1
    OR count(*) FILTER (WHERE l.line_role = 'balancing_line') <> 1
    OR abs(coalesce(sum(l.debit_amount_gbp),0) - coalesce(sum(l.credit_amount_gbp),0)) > 0.01
ORDER BY j.created_at DESC;

ROLLBACK;
