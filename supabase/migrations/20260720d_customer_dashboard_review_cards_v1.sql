BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.customer_active_order_review_link_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_active_order_review_link_v1(uuid)';
  END IF;

  IF to_regprocedure('public.customer_order_has_review_ready_lines_v1(uuid)') IS NULL THEN
