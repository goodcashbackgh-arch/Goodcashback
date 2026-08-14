-- Customer order early-correction live verification after
-- 20260814141500_customer_order_early_correction_order_scoped_access_v1.sql
--
-- ROLLBACK-ONLY. No test write survives.

BEGIN;
SET LOCAL statement_timeout = '0';
SET LOCAL lock_timeout = '15s';

-- 1. Installed authority / security boundary.
DO $$
DECLARE
  v_correction_def text;
  v_wrapper_def text;
  v_correction_secdef boolean;
  v_wrapper_secdef boolean;
  v_correction_config text[];
  v_wrapper_config text[];
BEGIN
  IF to_regprocedure('public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])') IS NULL
     OR to_regprocedure('public.customer_order_correction_eligibility_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: correction authority is missing.';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef, p.proconfig
  INTO v_correction_def, v_correction_secdef, v_correction_config
  FROM pg_proc p
  WHERE p.oid = 'public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])'::regprocedure;

  SELECT pg_get_functiondef(p.oid), p.prosecdef, p.proconfig
  INTO v_wrapper_def, v_wrapper_secdef, v_wrapper_config
  FROM pg_proc p
  WHERE p.oid = 'public.customer_order_correction_eligibility_v1(uuid)'::regprocedure;

  IF NOT COALESCE(v_correction_secdef, false)
     OR NOT COALESCE(v_wrapper_secdef, false)
     OR NOT COALESCE(v_correction_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[]
     OR NOT COALESCE(v_wrapper_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[]
     OR position('oi.importer_id = v_order.importer_id' IN v_correction_def) = 0
     OR position('v_operator.importer_id := v_order.importer_id' IN v_correction_def) = 0
     OR position('ORDER BY oi.id DESC' IN v_correction_def) > 0
     OR position('FOR UPDATE OF o' IN v_wrapper_def) = 0
     OR position('customer_correct_unprocessed_order_v1' IN v_wrapper_def) = 0
     OR position('NULL::text[]' IN v_wrapper_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: installed authority/security boundary is not the governed version.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.customer_order_correction_eligibility_v1(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated EXECUTE grant is missing.';
  END IF;

  RAISE NOTICE 'PASS 1/8: installed authority and security boundary';
END $$;

-- Fixture preflight.
DO $$
DECLARE
  v_full record;
  v_partial record;
BEGIN
  SELECT o.id, o.operator_id, o.importer_id, o.status, o.order_type, o.order_total_gbp_declared, o.funded_at,
         f.applied_credit_gbp, f.funded_total_gbp, f.gap_remaining_gbp, f.threshold_met_yn, f.confirmed_dva_funding_gbp
  INTO v_full
  FROM public.orders o
  JOIN public.order_funding_position_vw f ON f.order_id = o.id
  WHERE o.id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;

  SELECT o.id, o.operator_id, o.importer_id, o.status, o.order_type, o.order_total_gbp_declared, o.funded_at,
         f.applied_credit_gbp, f.funded_total_gbp, f.gap_remaining_gbp, f.threshold_met_yn, f.confirmed_dva_funding_gbp
  INTO v_partial
  FROM public.orders o
  JOIN public.order_funding_position_vw f ON f.order_id = o.id
  WHERE o.id = '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid;

  IF v_full.id IS NULL
     OR v_full.operator_id IS DISTINCT FROM 'b5d0aa51-596f-41d1-ac88-b8d74206107d'::uuid
     OR v_full.status IS DISTINCT FROM 'pending_dva_funding'
     OR v_full.order_type IS DISTINCT FROM 'original'
     OR COALESCE(v_full.applied_credit_gbp, 0) <= 0.01
     OR COALESCE(v_full.confirmed_dva_funding_gbp, 0) > 0.01
     OR COALESCE(v_full.funded_total_gbp, 0) > COALESCE(v_full.applied_credit_gbp, 0) + 0.01
     OR NOT (v_full.funded_at IS NOT NULL OR COALESCE(v_full.threshold_met_yn, false) OR COALESCE(v_full.gap_remaining_gbp, 0) <= 0.01) THEN
    RAISE EXCEPTION 'FAIL: full-credit fixture drifted.';
  END IF;

  IF v_partial.id IS NULL
     OR v_partial.operator_id IS DISTINCT FROM 'ba440d50-0162-4040-a771-87029f089d4b'::uuid
     OR v_partial.status IS DISTINCT FROM 'pending_dva_funding'
     OR v_partial.order_type IS DISTINCT FROM 'original'
     OR COALESCE(v_partial.applied_credit_gbp, 0) <= 0.01
     OR COALESCE(v_partial.confirmed_dva_funding_gbp, 0) > 0.01
     OR COALESCE(v_partial.funded_total_gbp, 0) > COALESCE(v_partial.applied_credit_gbp, 0) + 0.01
     OR COALESCE(v_partial.gap_remaining_gbp, 0) <= 0.01 THEN
    RAISE EXCEPTION 'FAIL: partial-credit fixture drifted.';
  END IF;
END $$;

-- 2. Wrapper snapshot matches current state and performs no mutation.
DO $$
DECLARE
  v_result jsonb;
  v_order_before record;
  v_order_after record;
  v_funding_before record;
  v_funding_after record;
  v_event_sum_before numeric;
  v_event_sum_after numeric;
  v_event_count_before integer;
  v_event_count_after integer;
  v_screenshot_count_before integer;
  v_screenshot_count_after integer;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);

    SELECT id, importer_id, total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at
    INTO v_order_before
    FROM public.orders
    WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;

    SELECT applied_credit_gbp, funded_total_gbp, markup_applied_gbp, gap_remaining_gbp, threshold_met_yn
    INTO v_funding_before
    FROM public.order_funding_position_vw
    WHERE order_id = v_order_before.id;

    SELECT COALESCE(ROUND(SUM(amount_gbp), 2), 0), COUNT(*)::integer
    INTO v_event_sum_before, v_event_count_before
    FROM public.order_funding_events
    WHERE order_id = v_order_before.id;

    SELECT COUNT(*)::integer INTO v_screenshot_count_before
    FROM public.order_screenshots
    WHERE order_id = v_order_before.id AND note = 'Original order screenshot';

    v_result := public.customer_order_correction_eligibility_v1(v_order_before.id);

    IF COALESCE((v_result->>'ok')::boolean, false) IS NOT TRUE
       OR COALESCE((v_result->>'eligible')::boolean, false) IS NOT TRUE
       OR COALESCE((v_result->>'changed')::boolean, true) IS NOT FALSE
       OR (v_result->>'importer_id')::uuid IS DISTINCT FROM v_order_before.importer_id
       OR (v_result->>'current_qty')::integer IS DISTINCT FROM v_order_before.total_qty_declared
       OR ROUND((v_result->>'current_amount')::numeric, 2) IS DISTINCT FROM ROUND(v_order_before.order_total_gbp_declared::numeric, 2)
       OR (v_result->>'original_screenshot_count')::integer IS DISTINCT FROM v_screenshot_count_before
       OR ROUND((v_result->>'applied_credit_gbp')::numeric, 2) IS DISTINCT FROM ROUND(COALESCE(v_funding_before.applied_credit_gbp, 0)::numeric, 2)
       OR ROUND((v_result->>'funded_total_gbp')::numeric, 2) IS DISTINCT FROM ROUND(COALESCE(v_funding_before.funded_total_gbp, 0)::numeric, 2)
       OR ROUND((v_result->>'markup_applied_gbp')::numeric, 2) IS DISTINCT FROM ROUND(COALESCE(v_funding_before.markup_applied_gbp, 0)::numeric, 2) THEN
      RAISE EXCEPTION 'FAIL: eligibility wrapper snapshot mismatch.';
    END IF;

    SELECT id, importer_id, total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at
    INTO v_order_after FROM public.orders WHERE id = v_order_before.id;
    SELECT applied_credit_gbp, funded_total_gbp, markup_applied_gbp, gap_remaining_gbp, threshold_met_yn
    INTO v_funding_after FROM public.order_funding_position_vw WHERE order_id = v_order_before.id;
    SELECT COALESCE(ROUND(SUM(amount_gbp), 2), 0), COUNT(*)::integer
    INTO v_event_sum_after, v_event_count_after FROM public.order_funding_events WHERE order_id = v_order_before.id;
    SELECT COUNT(*)::integer INTO v_screenshot_count_after
    FROM public.order_screenshots WHERE order_id = v_order_before.id AND note = 'Original order screenshot';

    IF v_order_after.total_qty_declared IS DISTINCT FROM v_order_before.total_qty_declared
       OR ROUND(v_order_after.order_total_gbp_declared::numeric, 2) IS DISTINCT FROM ROUND(v_order_before.order_total_gbp_declared::numeric, 2)
       OR ROUND(v_order_after.quote_total_ghs::numeric, 2) IS DISTINCT FROM ROUND(v_order_before.quote_total_ghs::numeric, 2)
       OR v_order_after.funded_at IS DISTINCT FROM v_order_before.funded_at
       OR ROUND(COALESCE(v_funding_after.applied_credit_gbp, 0)::numeric, 2) IS DISTINCT FROM ROUND(COALESCE(v_funding_before.applied_credit_gbp, 0)::numeric, 2)
       OR ROUND(COALESCE(v_funding_after.funded_total_gbp, 0)::numeric, 2) IS DISTINCT FROM ROUND(COALESCE(v_funding_before.funded_total_gbp, 0)::numeric, 2)
       OR ROUND(COALESCE(v_funding_after.gap_remaining_gbp, 0)::numeric, 2) IS DISTINCT FROM ROUND(COALESCE(v_funding_before.gap_remaining_gbp, 0)::numeric, 2)
       OR COALESCE(v_funding_after.threshold_met_yn, false) IS DISTINCT FROM COALESCE(v_funding_before.threshold_met_yn, false)
       OR v_event_sum_after IS DISTINCT FROM v_event_sum_before
       OR v_event_count_after IS DISTINCT FROM v_event_count_before
       OR v_screenshot_count_after IS DISTINCT FROM v_screenshot_count_before THEN
      RAISE EXCEPTION 'FAIL: eligibility wrapper mutated state.';
    END IF;

    RAISE EXCEPTION '__PASS_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM '__PASS_ROLLBACK__' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 2/8: wrapper snapshot is authoritative and non-mutating';
END $$;

-- 3. A newer/different active importer assignment must not steal order scope.
DO $$
DECLARE
  v_order_importer uuid;
  v_other_importer uuid;
  v_relationship_type text;
  v_result jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);

    SELECT importer_id INTO v_order_importer FROM public.orders
    WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT relationship_type INTO v_relationship_type FROM public.operator_importers
    WHERE operator_id = 'b5d0aa51-596f-41d1-ac88-b8d74206107d'::uuid
      AND importer_id = v_order_importer AND revoked_at IS NULL LIMIT 1;
    SELECT i.id INTO v_other_importer FROM public.importers i
    WHERE i.id IS DISTINCT FROM v_order_importer
      AND NOT EXISTS (
        SELECT 1 FROM public.operator_importers oi
        WHERE oi.operator_id = 'b5d0aa51-596f-41d1-ac88-b8d74206107d'::uuid
          AND oi.importer_id = i.id AND oi.revoked_at IS NULL
      )
    ORDER BY i.id LIMIT 1;

    IF v_relationship_type IS NULL OR v_other_importer IS NULL THEN
      RAISE EXCEPTION 'FAIL: cannot construct multi-importer rollback fixture.';
    END IF;

    INSERT INTO public.operator_importers(id, operator_id, importer_id, relationship_type, granted_at, revoked_at)
    VALUES (gen_random_uuid(), 'b5d0aa51-596f-41d1-ac88-b8d74206107d'::uuid, v_other_importer, v_relationship_type, clock_timestamp(), NULL);

    v_result := public.customer_order_correction_eligibility_v1('51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid);
    IF COALESCE((v_result->>'eligible')::boolean, false) IS NOT TRUE
       OR (v_result->>'importer_id')::uuid IS DISTINCT FROM v_order_importer THEN
      RAISE EXCEPTION 'FAIL: additional active importer assignment changed order scope.';
    END IF;

    RAISE EXCEPTION '__PASS_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM '__PASS_ROLLBACK__' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 3/8: multi-importer order scope is correct';
END $$;

-- 4. Revoked exact membership and wrong owner both fail closed.
DO $$
DECLARE v_dummy jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);
    UPDATE public.operator_importers SET revoked_at = clock_timestamp()
    WHERE operator_id = 'b5d0aa51-596f-41d1-ac88-b8d74206107d'::uuid
      AND importer_id = (SELECT importer_id FROM public.orders WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid)
      AND revoked_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: active Day3 assignment not found.'; END IF;
    v_dummy := public.customer_order_correction_eligibility_v1('51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid);
    RAISE EXCEPTION 'FAIL: revoked assignment retained access.';
  EXCEPTION WHEN OTHERS THEN
    IF position('does not belong to the active customer/operator assignment' IN lower(SQLERRM)) = 0 THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);
    v_dummy := public.customer_order_correction_eligibility_v1('21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid);
    RAISE EXCEPTION 'FAIL: wrong operator gained access.';
  EXCEPTION WHEN OTHERS THEN
    IF position('does not belong to the active customer/operator assignment' IN lower(SQLERRM)) = 0 THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 4/8: revoked assignment and wrong owner fail closed';
END $$;

-- 5. Fully funded decrease must fail.
DO $$
DECLARE v_qty integer; v_amount numeric; v_dummy jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);
    SELECT total_qty_declared, order_total_gbp_declared INTO v_qty, v_amount
    FROM public.orders WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    v_dummy := public.customer_correct_unprocessed_order_v1(
      '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid, v_qty, ROUND(v_amount - 5.00, 2), NULL::text[]);
    RAISE EXCEPTION 'FAIL: fully funded decrease unexpectedly succeeded.';
  EXCEPTION WHEN OTHERS THEN
    IF position('corrected value would require credit release or financial-state repair' IN lower(SQLERRM)) = 0 THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 5/8: fully funded decrease rejected';
END $$;

-- 6. Fully funded quantity-only change preserves all funding state.
DO $$
DECLARE
  v_before_order record; v_after_order record; v_before_funding record; v_after_funding record;
  v_event_sum_before numeric; v_event_sum_after numeric; v_event_count_before integer; v_event_count_after integer; v_result jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);
    SELECT total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at INTO v_before_order
    FROM public.orders WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT applied_credit_gbp, funded_total_gbp, gap_remaining_gbp, threshold_met_yn INTO v_before_funding
    FROM public.order_funding_position_vw WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT COALESCE(ROUND(SUM(amount_gbp),2),0), COUNT(*)::integer INTO v_event_sum_before, v_event_count_before
    FROM public.order_funding_events WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;

    v_result := public.customer_correct_unprocessed_order_v1(
      '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid,
      v_before_order.total_qty_declared + 1, v_before_order.order_total_gbp_declared, NULL::text[]);

    SELECT total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at INTO v_after_order
    FROM public.orders WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT applied_credit_gbp, funded_total_gbp, gap_remaining_gbp, threshold_met_yn INTO v_after_funding
    FROM public.order_funding_position_vw WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT COALESCE(ROUND(SUM(amount_gbp),2),0), COUNT(*)::integer INTO v_event_sum_after, v_event_count_after
    FROM public.order_funding_events WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;

    IF COALESCE((v_result->>'changed')::boolean,false) IS NOT TRUE
       OR v_after_order.total_qty_declared IS DISTINCT FROM v_before_order.total_qty_declared + 1
       OR ROUND(v_after_order.order_total_gbp_declared::numeric,2) IS DISTINCT FROM ROUND(v_before_order.order_total_gbp_declared::numeric,2)
       OR ROUND(v_after_order.quote_total_ghs::numeric,2) IS DISTINCT FROM ROUND(v_before_order.quote_total_ghs::numeric,2)
       OR v_after_order.funded_at IS DISTINCT FROM v_before_order.funded_at
       OR ROUND(COALESCE(v_after_funding.applied_credit_gbp,0)::numeric,2) IS DISTINCT FROM ROUND(COALESCE(v_before_funding.applied_credit_gbp,0)::numeric,2)
       OR ROUND(COALESCE(v_after_funding.funded_total_gbp,0)::numeric,2) IS DISTINCT FROM ROUND(COALESCE(v_before_funding.funded_total_gbp,0)::numeric,2)
       OR ROUND(COALESCE(v_after_funding.gap_remaining_gbp,0)::numeric,2) IS DISTINCT FROM ROUND(COALESCE(v_before_funding.gap_remaining_gbp,0)::numeric,2)
       OR COALESCE(v_after_funding.threshold_met_yn,false) IS DISTINCT FROM COALESCE(v_before_funding.threshold_met_yn,false)
       OR v_event_sum_after IS DISTINCT FROM v_event_sum_before OR v_event_count_after IS DISTINCT FROM v_event_count_before THEN
      RAISE EXCEPTION 'FAIL: quantity-only correction changed financial state.';
    END IF;
    RAISE EXCEPTION '__PASS_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM '__PASS_ROLLBACK__' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 6/8: fully funded quantity-only correction preserves funding';
END $$;

-- 7. Fully funded upward-value change creates only expected gap.
DO $$
DECLARE
  v_before_order record; v_after_order record; v_before_funding record; v_after_funding record;
  v_new_amount numeric; v_expected_quote numeric; v_expected_gap numeric;
  v_event_sum_before numeric; v_event_sum_after numeric; v_event_count_before integer; v_event_count_after integer; v_result jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'aa64af59-2244-4323-87c3-e9f32644af44', true);
    SELECT total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at INTO v_before_order
    FROM public.orders WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT applied_credit_gbp, funded_total_gbp, markup_applied_gbp, gap_remaining_gbp, threshold_met_yn INTO v_before_funding
    FROM public.order_funding_position_vw WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT COALESCE(ROUND(SUM(amount_gbp),2),0), COUNT(*)::integer INTO v_event_sum_before, v_event_count_before
    FROM public.order_funding_events WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;

    v_new_amount := ROUND(v_before_order.order_total_gbp_declared::numeric + 5.00, 2);
    v_expected_quote := ROUND((v_before_order.quote_total_ghs::numeric / v_before_order.order_total_gbp_declared::numeric) * v_new_amount, 2);
    v_expected_gap := ROUND(GREATEST(v_new_amount + COALESCE(v_before_funding.markup_applied_gbp,0) - COALESCE(v_before_funding.funded_total_gbp,0), 0)::numeric, 2);

    v_result := public.customer_correct_unprocessed_order_v1(
      '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid,
      v_before_order.total_qty_declared, v_new_amount, NULL::text[]);

    SELECT total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at INTO v_after_order
    FROM public.orders WHERE id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT applied_credit_gbp, funded_total_gbp, gap_remaining_gbp, threshold_met_yn INTO v_after_funding
    FROM public.order_funding_position_vw WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;
    SELECT COALESCE(ROUND(SUM(amount_gbp),2),0), COUNT(*)::integer INTO v_event_sum_after, v_event_count_after
    FROM public.order_funding_events WHERE order_id = '51c1a8bb-9f58-4f3b-8e50-9d9d935f0167'::uuid;

    IF COALESCE((v_result->>'changed')::boolean,false) IS NOT TRUE
       OR ROUND(v_after_order.order_total_gbp_declared::numeric,2) IS DISTINCT FROM v_new_amount
       OR ROUND(v_after_order.quote_total_ghs::numeric,2) IS DISTINCT FROM v_expected_quote
       OR v_after_order.funded_at IS NOT NULL
       OR ROUND(COALESCE(v_after_funding.applied_credit_gbp,0)::numeric,2) IS DISTINCT FROM ROUND(COALESCE(v_before_funding.applied_credit_gbp,0)::numeric,2)
       OR ROUND(COALESCE(v_after_funding.funded_total_gbp,0)::numeric,2) IS DISTINCT FROM ROUND(COALESCE(v_before_funding.funded_total_gbp,0)::numeric,2)
       OR ROUND(COALESCE(v_after_funding.gap_remaining_gbp,0)::numeric,2) IS DISTINCT FROM v_expected_gap
       OR COALESCE(v_after_funding.threshold_met_yn,false)
       OR v_event_sum_after IS DISTINCT FROM v_event_sum_before OR v_event_count_after IS DISTINCT FROM v_event_count_before THEN
      RAISE EXCEPTION 'FAIL: fully funded upward-value correction violated financial postconditions.';
    END IF;
    RAISE EXCEPTION '__PASS_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM '__PASS_ROLLBACK__' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 7/8: fully funded upward-value correction creates only the expected gap';
END $$;

-- 8. Partial-credit upward-value change preserves credit and derives expected gap.
DO $$
DECLARE
  v_before_order record; v_after_order record; v_before_funding record; v_after_funding record;
  v_new_amount numeric; v_expected_quote numeric; v_expected_gap numeric;
  v_event_sum_before numeric; v_event_sum_after numeric; v_event_count_before integer; v_event_count_after integer; v_result jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', 'abf6dab8-2f12-49d4-ab71-af8ce0c989aa', true);
    SELECT total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at INTO v_before_order
    FROM public.orders WHERE id = '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid;
    SELECT applied_credit_gbp, funded_total_gbp, markup_applied_gbp, gap_remaining_gbp, threshold_met_yn INTO v_before_funding
    FROM public.order_funding_position_vw WHERE order_id = '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid;
    SELECT COALESCE(ROUND(SUM(amount_gbp),2),0), COUNT(*)::integer INTO v_event_sum_before, v_event_count_before
    FROM public.order_funding_events WHERE order_id = '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid;

    v_new_amount := ROUND(v_before_order.order_total_gbp_declared::numeric + 5.00, 2);
    v_expected_quote := ROUND((v_before_order.quote_total_ghs::numeric / v_before_order.order_total_gbp_declared::numeric) * v_new_amount, 2);
    v_expected_gap := ROUND(GREATEST(v_new_amount + COALESCE(v_before_funding.markup_applied_gbp,0) - COALESCE(v_before_funding.funded_total_gbp,0), 0)::numeric, 2);

    v_result := public.customer_correct_unprocessed_order_v1(
      '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid,
      v_before_order.total_qty_declared, v_new_amount, NULL::text[]);

    SELECT total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at INTO v_after_order
    FROM public.orders WHERE id = '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid;
    SELECT applied_credit_gbp, funded_total_gbp, gap_remaining_gbp, threshold_met_yn INTO v_after_funding
    FROM public.order_funding_position_vw WHERE order_id = '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid;
    SELECT COALESCE(ROUND(SUM(amount_gbp),2),0), COUNT(*)::integer INTO v_event_sum_after, v_event_count_after
    FROM public.order_funding_events WHERE order_id = '21dbf28d-f671-47dd-b85d-5c542dd61e2e'::uuid;

    IF COALESCE((v_result->>'changed')::boolean,false) IS NOT TRUE
       OR ROUND(v_after_order.order_total_gbp_declared::numeric,2) IS DISTINCT FROM v_new_amount
       OR ROUND(v_after_order.quote_total_ghs::numeric,2) IS DISTINCT FROM v_expected_quote
       OR v_after_order.funded_at IS DISTINCT FROM v_before_order.funded_at
       OR ROUND(COALESCE(v_after_funding.applied_credit_gbp,0)::numeric,2) IS DISTINCT FROM ROUND(COALESCE(v_before_funding.applied_credit_gbp,0)::numeric,2)
       OR ROUND(COALESCE(v_after_funding.funded_total_gbp,0)::numeric,2) IS DISTINCT FROM ROUND(COALESCE(v_before_funding.funded_total_gbp,0)::numeric,2)
       OR ROUND(COALESCE(v_after_funding.gap_remaining_gbp,0)::numeric,2) IS DISTINCT FROM v_expected_gap
       OR COALESCE(v_after_funding.threshold_met_yn,false)
       OR v_event_sum_after IS DISTINCT FROM v_event_sum_before OR v_event_count_after IS DISTINCT FROM v_event_count_before THEN
      RAISE EXCEPTION 'FAIL: partial-credit upward-value correction violated financial postconditions.';
    END IF;
    RAISE EXCEPTION '__PASS_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM IS DISTINCT FROM '__PASS_ROLLBACK__' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 8/8: partial-credit upward-value correction preserves existing credit';
END $$;

ROLLBACK;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'installed authority; locked non-mutating wrapper; multi-importer order scope; revoked/wrong-owner rejection; full decrease rejection; full quantity-only preservation; full upward-value gap; partial-credit upward-value gap'
) AS customer_order_early_correction_live_regression;
