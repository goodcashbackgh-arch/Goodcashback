BEGIN;

-- Allow attachment attempts to be logged separately from financial posting.
-- This fixes the previous blind spot where request_kind='attachment'
-- violated the existing CHECK constraint, so no Sage attachment requests
-- appeared in sage_api_request_log.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_api_request_log') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_api_request_log';
  END IF;
END $$;

ALTER TABLE public.sage_api_request_log
  DROP CONSTRAINT IF EXISTS sage_api_request_log_request_kind_check;

ALTER TABLE public.sage_api_request_log
  ADD CONSTRAINT sage_api_request_log_request_kind_check CHECK (request_kind IN (
    'oauth',
    'token_refresh',
    'business_discovery',
    'test_connection',
    'posting',
    'attachment',
    'other'
  ));

NOTIFY pgrst, 'reload schema';
COMMIT;
