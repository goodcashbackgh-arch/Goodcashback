BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- TEMPORARY CONTROLLED-TESTING OVERRIDE ONLY.
-- Governing authority:
-- docs/governing-pack/architecture/TEMPORARY_PRE_PILOT_EXACT_CUSTOMER_REVIEW_WINDOW_AMENDMENT_v1.md
--
-- Canonical pilot/production duration remains 24 hours.
-- Before any external pilot or production launch, a reviewed additive migration
-- must restore these exact/mixed review intervals to 24 hours.
--
-- Scope is deliberately limited to:
--   1. internal_customer_review_cycle_candidates_v2(uuid)
--      - review_expires_at interval
--      - matching source_fingerprint interval
--   2. internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)
--      - fixed-cycle containment interval
--
-- No table data, stored review deadline, membership, receipt, hold, shipment,
-- accounting, Sage, VAT, permission, UI or unrelated review logic is changed.

DO $patch$
DECLARE
  v_candidate_oid oid;
  v_bridge_oid oid;
  v_candidate_before text;
  v_candidate_after text;
  v_bridge_before text;
  v_bridge_after text;
  v_candidate_24_count integer;
  v_candidate_2m_count integer;
  v_bridge_24_count integer;
  v_bridge_2m_count integer;
BEGIN
  v_candidate_oid := to_regprocedure(
    'public.internal_customer_review_cycle_candidates_v2(uuid)'
  );

  IF v_candidate_oid IS NULL THEN
    RAISE EXCEPTION
      'Temporary exact review-window patch blocked: internal_customer_review_cycle_candidates_v2(uuid) is missing.';
  END IF;

  v_bridge_oid := to_regprocedure(
    'public.internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)'
  );

  IF v_bridge_oid IS NULL THEN
    RAISE EXCEPTION
      'Temporary exact review-window patch blocked: internal_bridge_exact_customer_review_candidates_v1(uuid,uuid) is missing.';
  END IF;

  SELECT pg_get_functiondef(v_candidate_oid)
  INTO v_candidate_before;

  v_candidate_24_count := (
    length(v_candidate_before)
    - length(replace(v_candidate_before, 'interval ''24 hours''', ''))
  ) / length('interval ''24 hours''');

  v_candidate_2m_count := (
    length(v_candidate_before)
    - length(replace(v_candidate_before, 'interval ''2 minutes''', ''))
  ) / length('interval ''2 minutes''');

  IF v_candidate_24_count = 2 AND v_candidate_2m_count = 0 THEN
    v_candidate_after := replace(
      v_candidate_before,
      'interval ''24 hours''',
      'interval ''2 minutes'''
    );
    EXECUTE v_candidate_after;
  ELSIF v_candidate_24_count = 0 AND v_candidate_2m_count = 2 THEN
    -- Live controlled-test database may already contain the reviewed 2-minute
    -- override. Preserve it exactly and continue to postflight.
    NULL;
  ELSE
    RAISE EXCEPTION
      'Temporary exact review-window patch blocked: candidate function drifted (24h %, 2m %).',
      v_candidate_24_count,
      v_candidate_2m_count;
  END IF;

  SELECT pg_get_functiondef(v_bridge_oid)
  INTO v_bridge_before;

  v_bridge_24_count := (
    length(v_bridge_before)
    - length(replace(v_bridge_before, 'interval ''24 hours''', ''))
  ) / length('interval ''24 hours''');

  v_bridge_2m_count := (
    length(v_bridge_before)
    - length(replace(v_bridge_before, 'interval ''2 minutes''', ''))
  ) / length('interval ''2 minutes''');

  IF v_bridge_24_count = 1 AND v_bridge_2m_count = 0 THEN
    v_bridge_after := replace(
      v_bridge_before,
      'interval ''24 hours''',
      'interval ''2 minutes'''
    );
    EXECUTE v_bridge_after;
  ELSIF v_bridge_24_count = 0 AND v_bridge_2m_count = 1 THEN
    -- Same idempotent live-test allowance as above.
    NULL;
  ELSE
    RAISE EXCEPTION
      'Temporary exact review-window patch blocked: exact bridge drifted (24h %, 2m %).',
      v_bridge_24_count,
      v_bridge_2m_count;
  END IF;
END
$patch$;

DO $postflight$
DECLARE
  v_candidate text;
  v_bridge text;
  v_candidate_24_count integer;
  v_candidate_2m_count integer;
  v_bridge_24_count integer;
  v_bridge_2m_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_review_cycle_candidates_v2(uuid)'::regprocedure
  ) INTO v_candidate;

  SELECT pg_get_functiondef(
    'public.internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)'::regprocedure
  ) INTO v_bridge;

  v_candidate_24_count := (
    length(v_candidate)
    - length(replace(v_candidate, 'interval ''24 hours''', ''))
  ) / length('interval ''24 hours''');

  v_candidate_2m_count := (
    length(v_candidate)
    - length(replace(v_candidate, 'interval ''2 minutes''', ''))
  ) / length('interval ''2 minutes''');

  v_bridge_24_count := (
    length(v_bridge)
    - length(replace(v_bridge, 'interval ''24 hours''', ''))
  ) / length('interval ''24 hours''');

  v_bridge_2m_count := (
    length(v_bridge)
    - length(replace(v_bridge, 'interval ''2 minutes''', ''))
  ) / length('interval ''2 minutes''');

  IF v_candidate_24_count <> 0
     OR v_candidate_2m_count <> 2
     OR v_bridge_24_count <> 0
     OR v_bridge_2m_count <> 1
  THEN
    RAISE EXCEPTION
      'Temporary exact review-window postflight failed: candidate (24h %, 2m %), bridge (24h %, 2m %).',
      v_candidate_24_count,
      v_candidate_2m_count,
      v_bridge_24_count,
      v_bridge_2m_count;
  END IF;
END
$postflight$;

COMMIT;
