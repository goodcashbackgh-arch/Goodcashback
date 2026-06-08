BEGIN;

-- Superseded placeholder.
-- This file originally contained the main-bank consumption guard patch, but alphabetic migration order
-- could place it before the main-bank loyalty funding table exists.
-- The executable final guard is in:
--   20260609_main_bank_consumption_guards_v2.sql
-- Keep this migration harmless so ordered migration runners do not fail or override the later final function.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

NOTIFY pgrst, 'reload schema';

COMMIT;
