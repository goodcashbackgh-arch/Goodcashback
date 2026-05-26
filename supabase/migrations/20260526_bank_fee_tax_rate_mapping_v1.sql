BEGIN;

-- Bank fee Sage mapping completion.
-- Additive only: gives the cash posting bank-fee poster a proper Sage tax-rate mapping.
-- The actual Sage external id must be selected from Sage tax_rates, normally Exempt 0.00%.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN
    RAISE EXCEPTION 'Missing public.sage_mapping_settings';
  END IF;
END $$;

INSERT INTO public.sage_mapping_settings (
  mapping_code,
  mapping_group,
  display_name,
  description,
  value_kind,
  required_for
)
VALUES (
  'BANK_FEE_TAX_RATE',
  'cash_posting',
  'Bank/provider/card fee tax rate',
  'Sage tax rate id used for bank, provider or card fee other-payment lines. Select the Sage Exempt 0.00% tax rate from tax_rates.',
  'tax_rate_id',
  ARRAY['bank_fee']::text[]
)
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    updated_at = now();

NOTIFY pgrst, 'reload schema';

COMMIT;
