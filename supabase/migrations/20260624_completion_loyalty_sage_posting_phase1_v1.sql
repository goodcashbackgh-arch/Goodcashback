BEGIN;

-- DEPRECATED DRAFT MIGRATION.
-- Do not use this file as the implementation migration.
-- It has been superseded before being run by:
--   supabase/migrations/20260624_completion_loyalty_sage_posting_lifecycle_controls_v1.sql
--
-- This no-op is intentionally safe if the migration runner sees it before the replacement file.

DO $$
BEGIN
  RAISE NOTICE 'Deprecated draft migration skipped: use 20260624_completion_loyalty_sage_posting_lifecycle_controls_v1.sql';
END $$;

COMMIT;
