BEGIN;
SET TRANSACTION READ ONLY;

-- Governing authority:
-- docs/governing-pack/architecture/VAT_TEST_RUN_SEQUENCE_EXCLUSION_ADDENDUM_v1.md

WITH target AS (
  SELECT r.*
  FROM public.vat_return_runs r
  WHERE r.id = '87b23d75-3729-4695-bef0-d8c5d34cdf06'::uuid
),
target_journal AS (
  SELECT j.*
  FROM public.vat_return_adjustment_journals j
  WHERE j.id = 'bfcc0531-ecfd-4f23-b64a-c1c9e5f1ae55'::uuid
),
active_open AS (
  SELECT r.*
  FROM public.vat_return_runs r
  WHERE r.sequence_excluded_at IS NULL
    AND r.status NOT IN ('matched_to_sage_locked', 'superseded')
),
latest_locked AS (
  SELECT r.*
  FROM public.vat_return_runs r
  WHERE r.status = 'matched_to_sage_locked'
  ORDER BY r.period_end_date DESC, r.created_at DESC
  LIMIT 1
),
next_period AS (
  SELECT
    (date_trunc('month', l.period_end_date) + interval '1 month')::date AS period_start,
    (date_trunc('month', l.period_end_date) + interval '2 months - 1 day')::date AS period_end
  FROM latest_locked l
),
sequence_function AS (
  SELECT
    p.oid,
    md5(pg_get_functiondef(p.oid)) AS body_hash,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'enforce_vat_return_run_sequence_v1'
    AND pg_get_function_identity_arguments(p.oid) = ''
  LIMIT 1
)
SELECT jsonb_build_object(
  '00_verdict',
  CASE
    WHEN NOT EXISTS (SELECT 1 FROM target)
      THEN 'FAIL — governed test VAT run missing'
    WHEN EXISTS (
      SELECT 1 FROM target
      WHERE status <> 'sage_adjustment_journals_posted'
         OR sequence_excluded_at IS NULL
    )
      THEN 'FAIL — test run is not preserved-and-excluded as governed'
    WHEN NOT EXISTS (
      SELECT 1 FROM target_journal
      WHERE status = 'posted_to_sage'
        AND sage_journal_id = '6098fed5102947a38191e4767648f3ed'
    )
      THEN 'FAIL — posted Sage test journal drifted'
    WHEN (SELECT count(*) FROM active_open) <> 0
      THEN 'FAIL — another active VAT run still blocks monthly sequencing'
    WHEN NOT EXISTS (
      SELECT 1 FROM latest_locked
      WHERE id = '7926b0c6-a923-4dad-bd21-7dd9b4939347'::uuid
        AND period_end_date = DATE '2026-05-31'
    )
      THEN 'FAIL — May locked sequence anchor drifted'
    WHEN NOT EXISTS (
      SELECT 1 FROM next_period
      WHERE period_start = DATE '2026-06-01'
        AND period_end = DATE '2026-06-30'
    )
      THEN 'FAIL — next VAT period is not June 2026'
    WHEN NOT EXISTS (
      SELECT 1 FROM sequence_function
      WHERE definition ILIKE '%sequence_excluded_at IS NULL%'
    )
      THEN 'FAIL — database sequence guard does not honour exclusion metadata'
    ELSE 'PASS — TEST RUN PRESERVED, EXCLUDED FROM SEQUENCE, NEXT PERIOD JUNE 2026'
  END,
  '01_target_run',
  (
    SELECT jsonb_build_object(
      'id', id,
      'run_ref', run_ref,
      'label', return_period_label,
      'status', status,
      'sequence_excluded_at', sequence_excluded_at,
      'sequence_excluded_reason', sequence_excluded_reason,
      'locked_at', locked_at
    )
    FROM target
  ),
  '02_test_journal',
  (
    SELECT jsonb_build_object(
      'id', id,
      'status', status,
      'sage_journal_id', sage_journal_id,
      'sage_journal_ref', sage_journal_ref,
      'posted_at', posted_at,
      'reverses_journal_id', reverses_journal_id,
      'reversed_by_journal_id', reversed_by_journal_id
    )
    FROM target_journal
  ),
  '03_active_open_runs',
  COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', id,
      'run_ref', run_ref,
      'label', return_period_label,
      'status', status,
      'period_start', period_start_date,
      'period_end', period_end_date
    ) ORDER BY period_start_date, created_at)
    FROM active_open
  ), '[]'::jsonb),
  '04_latest_locked',
  (
    SELECT jsonb_build_object(
      'id', id,
      'run_ref', run_ref,
      'label', return_period_label,
      'status', status,
      'period_end', period_end_date,
      'locked_at', locked_at
    )
    FROM latest_locked
  ),
  '05_next_period',
  (
    SELECT jsonb_build_object(
      'period_start', period_start,
      'period_end', period_end
    )
    FROM next_period
  ),
  '06_sequence_guard',
  (
    SELECT jsonb_build_object(
      'body_hash', body_hash,
      'honours_sequence_exclusion', definition ILIKE '%sequence_excluded_at IS NULL%'
    )
    FROM sequence_function
  ),
  '07_safety',
  'READ ONLY — no VAT status, journal, Sage payload, source line, blocker or submission evidence write executed'
);

ROLLBACK;
