BEGIN;

-- VAT draft generator same-period regeneration guard v1
-- Governing authority:
-- docs/governing-pack/architecture/VAT_TEST_RUN_SEQUENCE_EXCLUSION_ADDENDUM_v1.md
--
-- Surgical replacement of one stale duplicate-period predicate in the exact live
-- generate_vat_return_draft_run_v1 definition. No historical VAT rows are mutated.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '60s';

DO $migration$
DECLARE
  v_oid oid;
  v_hash text;
  v_definition text;
  v_old_predicate text := E'r.status <> \'matched_to_sage_locked\'';
  v_new_predicate text := E'r.status NOT IN (\'matched_to_sage_locked\', \'superseded\')\n      AND r.sequence_excluded_at IS NULL';
  v_old_count integer;
  v_new_definition text;
  v_june_active_count integer;
BEGIN
  SELECT p.oid,
         md5(pg_get_functiondef(p.oid)),
         pg_get_functiondef(p.oid)
    INTO v_oid, v_hash, v_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'generate_vat_return_draft_run_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_period_start_date date, p_period_end_date date, p_return_period_label text'
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'generate_vat_return_draft_run_v1(date,date,text) is missing; refusing replacement.';
  END IF;

  IF v_hash <> '05f3be1b133f8726b26a98cc8c0c3082' THEN
    RAISE EXCEPTION 'VAT draft generator fingerprint drift: expected 05f3be1b133f8726b26a98cc8c0c3082, got %. Refusing overwrite.', v_hash;
  END IF;

  SELECT count(*)
    INTO v_old_count
  FROM regexp_matches(v_definition, 'r\\.status <> ''matched_to_sage_locked''', 'g');

  IF v_old_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one reviewed stale duplicate predicate; found %. Refusing replacement.', v_old_count;
  END IF;

  SELECT count(*)
    INTO v_june_active_count
  FROM public.vat_return_runs r
  WHERE r.period_start_date = DATE '2026-06-01'
    AND r.period_end_date = DATE '2026-06-30'
    AND r.status NOT IN ('matched_to_sage_locked', 'superseded')
    AND r.sequence_excluded_at IS NULL;

  IF v_june_active_count <> 0 THEN
    RAISE EXCEPTION 'A genuinely active June 2026 VAT run now exists (% row(s)); refusing to weaken duplicate guard.', v_june_active_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vat_return_runs r
    WHERE r.id = 'd8a1b7f8-b419-4cb2-b246-f203bcc46f8a'::uuid
      AND r.period_start_date = DATE '2026-06-01'
      AND r.period_end_date = DATE '2026-06-30'
      AND r.status = 'superseded'
      AND r.superseded_reason = 'Out-of-sequence draft generated before earlier VAT return was filed'
  ) THEN
    RAISE EXCEPTION 'Governed historical June superseded run is missing or drifted; refusing replacement.';
  END IF;

  v_new_definition := replace(v_definition, v_old_predicate, v_new_predicate);

  IF v_new_definition = v_definition THEN
    RAISE EXCEPTION 'Reviewed predicate replacement produced no change; refusing migration.';
  END IF;

  IF position(v_old_predicate IN v_new_definition) > 0 THEN
    RAISE EXCEPTION 'Stale duplicate predicate remains after replacement; refusing migration.';
  END IF;

  IF position(v_new_predicate IN v_new_definition) = 0 THEN
    RAISE EXCEPTION 'Corrected duplicate predicate missing from replacement definition; refusing migration.';
  END IF;

  EXECUTE v_new_definition;
END
$migration$;

DO $postflight$
DECLARE
  v_definition text;
  v_old_count integer;
  v_new_status_count integer;
  v_sequence_count integer;
  v_june_active_count integer;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'generate_vat_return_draft_run_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_period_start_date date, p_period_end_date date, p_return_period_label text'
  LIMIT 1;

  SELECT count(*) INTO v_old_count
  FROM regexp_matches(v_definition, 'r\\.status <> ''matched_to_sage_locked''', 'g');

  SELECT count(*) INTO v_new_status_count
  FROM regexp_matches(v_definition, 'r\\.status NOT IN \\(\'matched_to_sage_locked\', \'superseded\'\\)', 'g');

  SELECT count(*) INTO v_sequence_count
  FROM regexp_matches(v_definition, 'r\\.sequence_excluded_at IS NULL', 'g');

  IF v_old_count <> 0 OR v_new_status_count <> 1 OR v_sequence_count <> 1 THEN
    RAISE EXCEPTION 'Postflight predicate mismatch: old %, corrected-status %, sequence-exclusion %.', v_old_count, v_new_status_count, v_sequence_count;
  END IF;

  SELECT count(*) INTO v_june_active_count
  FROM public.vat_return_runs r
  WHERE r.period_start_date = DATE '2026-06-01'
    AND r.period_end_date = DATE '2026-06-30'
    AND r.status NOT IN ('matched_to_sage_locked', 'superseded')
    AND r.sequence_excluded_at IS NULL;

  IF v_june_active_count <> 0 THEN
    RAISE EXCEPTION 'Unexpected genuinely active June run after generator correction.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vat_return_runs r
    WHERE r.id = 'd8a1b7f8-b419-4cb2-b246-f203bcc46f8a'::uuid
      AND r.status = 'superseded'
      AND r.superseded_reason = 'Out-of-sequence draft generated before earlier VAT return was filed'
  ) THEN
    RAISE EXCEPTION 'Historical June superseded run changed unexpectedly.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vat_return_runs r
    WHERE r.id = 'fbd18b51-228a-47c3-a9f7-b6cf94bd14e1'::uuid
      AND r.status = 'superseded'
      AND r.superseded_reason = 'Out-of-sequence draft generated before earlier VAT return was filed'
  ) THEN
    RAISE EXCEPTION 'Historical July superseded run changed unexpectedly.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
