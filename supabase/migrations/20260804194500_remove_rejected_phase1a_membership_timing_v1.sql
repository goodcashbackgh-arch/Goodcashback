BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow cleanup only.
-- Removes the rejected Phase 1A timing columns, their check constraint and their index.
-- Does not alter Mini Build 4 functions, triggers, review links, memberships, shipment logic or UI.

DO $preflight$
DECLARE
  v_component_md5 text;
  v_immutable_md5 text;
  v_bad integer;
BEGIN
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure))
  INTO v_component_md5;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure))
  INTO v_immutable_md5;

  IF v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
  THEN
    RAISE EXCEPTION
      'Mini 4 guard fingerprint mismatch before cleanup: component %, immutable %',
      v_component_md5,
      v_immutable_md5;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'customer_review_cycle_memberships'
      AND column_name = 'review_eligible_at'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'customer_review_cycle_memberships'
      AND column_name = 'review_expires_at'
  ) THEN
    RAISE EXCEPTION 'Rejected Phase 1A timing columns are not both present.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM public.customer_review_cycle_memberships membership
  JOIN public.customer_order_review_links link_row
    ON link_row.id = membership.review_link_id
  WHERE membership.review_eligible_at IS DISTINCT FROM membership.receipt_recorded_at
     OR membership.review_expires_at IS DISTINCT FROM link_row.expires_at;

  IF v_bad <> 0 THEN
    RAISE EXCEPTION
      'Rejected timing columns contain non-duplicate values on % membership rows.',
      v_bad;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (
        position('membership.review_eligible_at' in pg_get_functiondef(p.oid)) > 0
        OR position('membership.review_expires_at' in pg_get_functiondef(p.oid)) > 0
        OR position('customer_review_cycle_memberships.review_eligible_at' in pg_get_functiondef(p.oid)) > 0
        OR position('customer_review_cycle_memberships.review_expires_at' in pg_get_functiondef(p.oid)) > 0
      )
  ) THEN
    RAISE EXCEPTION 'A live function references the rejected timing columns.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_views
    WHERE schemaname = 'public'
      AND (
        position('customer_review_cycle_memberships.review_eligible_at' in definition) > 0
        OR position('customer_review_cycle_memberships.review_expires_at' in definition) > 0
      )
  ) THEN
    RAISE EXCEPTION 'A live view references the rejected timing columns.';
  END IF;
END
$preflight$;

DROP INDEX IF EXISTS public.customer_review_cycle_membership_active_expiry_v1;

ALTER TABLE public.customer_review_cycle_memberships
  DROP CONSTRAINT IF EXISTS customer_review_cycle_membership_timing_pair_v1,
  DROP COLUMN review_eligible_at,
  DROP COLUMN review_expires_at;

DO $postflight$
DECLARE
  v_component_md5 text;
  v_immutable_md5 text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'customer_review_cycle_memberships'
      AND column_name IN ('review_eligible_at', 'review_expires_at')
  ) THEN
    RAISE EXCEPTION 'Rejected Phase 1A timing columns remain after cleanup.';
  END IF;

  IF to_regclass('public.customer_review_cycle_membership_active_expiry_v1') IS NOT NULL THEN
    RAISE EXCEPTION 'Rejected Phase 1A timing index remains after cleanup.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_constraint con
    WHERE con.conrelid = 'public.customer_review_cycle_memberships'::regclass
      AND con.conname = 'customer_review_cycle_membership_timing_pair_v1'
  ) THEN
    RAISE EXCEPTION 'Rejected Phase 1A timing constraint remains after cleanup.';
  END IF;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure))
  INTO v_component_md5;

  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure))
  INTO v_immutable_md5;

  IF v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
  THEN
    RAISE EXCEPTION
      'Mini 4 guard fingerprint changed during cleanup: component %, immutable %',
      v_component_md5,
      v_immutable_md5;
  END IF;
END
$postflight$;

COMMIT;
