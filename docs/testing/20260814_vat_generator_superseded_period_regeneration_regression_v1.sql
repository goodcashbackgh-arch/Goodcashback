BEGIN;
SET TRANSACTION READ ONLY;

-- Governing authority:
-- docs/governing-pack/architecture/VAT_TEST_RUN_SEQUENCE_EXCLUSION_ADDENDUM_v1.md

WITH generator AS (
  SELECT
    p.oid,
    md5(pg_get_functiondef(p.oid)) AS body_hash,
    pg_get_functiondef(p.oid) AS definition,
    p.prosecdef AS security_definer,
    p.proconfig AS function_config
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'generate_vat_return_draft_run_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_period_start_date date, p_period_end_date date, p_return_period_label text'
  LIMIT 1
),
june AS (
  SELECT *
  FROM public.vat_return_runs
  WHERE id = 'd8a1b7f8-b419-4cb2-b246-f203bcc46f8a'::uuid
),
july AS (
  SELECT *
  FROM public.vat_return_runs
  WHERE id = 'fbd18b51-228a-47c3-a9f7-b6cf94bd14e1'::uuid
),
active_june AS (
  SELECT *
  FROM public.vat_return_runs r
  WHERE r.period_start_date = DATE '2026-06-01'
    AND r.period_end_date = DATE '2026-06-30'
    AND r.status NOT IN ('matched_to_sage_locked', 'superseded')
    AND r.sequence_excluded_at IS NULL
)
SELECT jsonb_build_object(
  '00_verdict',
  CASE
    WHEN NOT EXISTS (SELECT 1 FROM generator)
      THEN 'FAIL — generator missing'
    WHEN EXISTS (
      SELECT 1 FROM generator
      WHERE definition ILIKE '%r.status <> ''matched_to_sage_locked''%'
    )
      THEN 'FAIL — stale same-period duplicate predicate still installed'
    WHEN NOT EXISTS (
      SELECT 1 FROM generator
      WHERE definition ILIKE '%r.status NOT IN (''matched_to_sage_locked'', ''superseded'')%'
        AND definition ILIKE '%r.sequence_excluded_at IS NULL%'
    )
      THEN 'FAIL — corrected same-period participation predicate is incomplete'
    WHEN NOT EXISTS (
      SELECT 1 FROM june
      WHERE status = 'superseded'
        AND superseded_reason = 'Out-of-sequence draft generated before earlier VAT return was filed'
    )
      THEN 'FAIL — historical June superseded run drifted'
    WHEN NOT EXISTS (
      SELECT 1 FROM july
      WHERE status = 'superseded'
        AND superseded_reason = 'Out-of-sequence draft generated before earlier VAT return was filed'
    )
      THEN 'FAIL — historical July superseded run drifted'
    WHEN EXISTS (SELECT 1 FROM active_june)
      THEN 'FAIL — a genuinely active June 2026 run still blocks regeneration'
    ELSE 'PASS — GENERATOR IGNORES RETIRED SAME-PERIOD HISTORY; JUNE READY FOR NORMAL GENERATION'
  END,
  '01_generator',
  (
    SELECT jsonb_build_object(
      'body_hash', body_hash,
      'security_definer', security_definer,
      'function_config', function_config,
      'stale_predicate_present', definition ILIKE '%r.status <> ''matched_to_sage_locked''%',
      'superseded_excluded', definition ILIKE '%r.status NOT IN (''matched_to_sage_locked'', ''superseded'')%',
      'sequence_excluded_rows_excluded', definition ILIKE '%r.sequence_excluded_at IS NULL%'
    )
    FROM generator
  ),
  '02_june_history',
  (
    SELECT jsonb_build_object(
      'id', id,
      'run_ref', run_ref,
      'status', status,
      'superseded_at', superseded_at,
      'superseded_reason', superseded_reason,
      'sequence_excluded_at', sequence_excluded_at
    )
    FROM june
  ),
  '03_july_history',
  (
    SELECT jsonb_build_object(
      'id', id,
      'run_ref', run_ref,
      'status', status,
      'superseded_at', superseded_at,
      'superseded_reason', superseded_reason,
      'sequence_excluded_at', sequence_excluded_at
    )
    FROM july
  ),
  '04_active_june_blockers',
  COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', id,
      'run_ref', run_ref,
      'label', return_period_label,
      'status', status,
      'sequence_excluded_at', sequence_excluded_at
    ) ORDER BY created_at)
    FROM active_june
  ), '[]'::jsonb),
  '05_safety',
  'READ ONLY — no RPC executed; no VAT run, line, blocker, journal, Sage payload or evidence write executed'
);

ROLLBACK;
