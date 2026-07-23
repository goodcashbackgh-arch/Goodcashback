-- Rollback-only regression for canonical shipment facts and status-preserving readers.
-- Apply migrations 20260723f-i and 20260723k before running.

BEGIN;

DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.shipper_shipment_batch_package_facts_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: package facts function missing';
  END IF;

  IF to_regprocedure('public.shipper_shipment_batch_summary_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: batch summary function missing';
  END IF;

  SELECT pg_get_functiondef('public.shipper_shipment_batch_package_facts_v1(uuid)'::regprocedure)
  INTO v_def;
  IF position('shipper_shipment_batch_effective_lines_v1' in v_def) = 0 THEN