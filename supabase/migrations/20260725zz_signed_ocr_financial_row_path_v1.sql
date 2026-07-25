BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Permanent signed OCR financial-row path.
--
-- The deployed pre-signed Mindee save implementation remains authoritative for
-- authentication, invoice state, idempotency, audit, human-work and review flags.
-- This migration replaces only the additive ad-h