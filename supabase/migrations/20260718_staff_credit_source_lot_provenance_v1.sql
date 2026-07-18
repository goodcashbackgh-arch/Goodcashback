BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/accounting/SUPPLIER_PAYMENT_FUNDING_PROVENANCE_GOVERNING_ADDENDUM_v1.md
--
-- Narrow patch only: preserve the public staff RPC contract while replacing the
-- legacy aggregate debit with deterministic source-lot consumption. Order creation
-- and the separate completion-loyalty application lane are unchanged.

DO $$
BEGIN
  IF