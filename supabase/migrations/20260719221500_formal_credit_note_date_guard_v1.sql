BEGIN;

-- Require an explicit document date for formal supplier credit notes without
-- stranding legacy undated rows that still need OCR, rejection or remediation.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_sub