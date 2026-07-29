-- Supabase SQL Editor regression.
-- Rollback-only. No authenticated allocator RPC is executed.
-- Scope: prove the new partial-overfunding source proof and protect the
-- existing full-overfunding, direct-cash, loyalty and fail-closed behaviours.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $reg