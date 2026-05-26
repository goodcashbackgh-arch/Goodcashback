BEGIN;

-- Bank fee ledger default from the connected Sage tenant.
-- Additive/safe: only fills BANK_FEE_LEDGER when it is currently blank.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN
    RAISE EXCEPTION 'Missing public.sage_mapping_settings';
  END IF;
END $$;

UPDATE public.sage_mapping_settings
SET sage_external_id = 'ea2f74533be211f194130283b27a38ab',
    sage_display_name = 'Bank Charges (7900)',
    notes = COALESCE(notes, 'Defaulted from confirmed Sage ledger account for bank/provider/card fees.'),
    configured_at = COALESCE(configured_at, now()),
    updated_at = now(),
    is_active = true
WHERE mapping_code = 'BANK_FEE_LEDGER'
  AND NULLIF(trim(COALESCE(sage_external_id, '')), '') IS NULL;

NOTIFY pgrst, 'reload schema';

COMMIT;
