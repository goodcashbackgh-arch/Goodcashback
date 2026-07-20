BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shipper_package_receipts';
  END IF;
  IF to_regclass('public.shipper_shipment_batch_packages') IS NULL THEN
    RAISE EXCEPTION '