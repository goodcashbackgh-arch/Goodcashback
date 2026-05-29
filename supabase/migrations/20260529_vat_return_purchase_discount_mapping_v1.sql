BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- VAT return reconstruction mapping only.
-- Creates the Sage Mapping card for Purchase Discounts (5010).
-- This does not post journals, submit VAT returns, pay VAT, or call HMRC.

INSERT INTO public.sage_mapping_settings (
  mapping_code,
  mapping_group,
  display_name,
  description,
  value_kind,
  required_for,
  sage_external_id,
  sage_display_name,
  is_active,
  configured_at,
  notes
)
VALUES (
  'VAT_BOX7_PURCHASE_DISCOUNTS_LEDGER',
  'vat_return_reconstruction',
  'VAT Box 7 purchase discounts ledger',
  'Sage direct-expense contra-purchase ledger used to reduce VAT Box 7 net purchases. Standard Sage nominal: Purchase Discounts (5010).',
  'ledger_account_id',
  ARRAY['vat_return_reconstruction','vat_box_7','contra_purchase']::text[],
  'ea28cb3d3be211f194130283b27a38ab',
  'Purchase Discounts (5010)',
  true,
  now(),
  'Seeded from Sage ledger account catalogue screenshot for VAT return reconstruction. Contra-purchase: reduces Box 7.'
)
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    sage_external_id = COALESCE(NULLIF(trim(public.sage_mapping_settings.sage_external_id), ''), EXCLUDED.sage_external_id),
    sage_display_name = COALESCE(NULLIF(trim(public.sage_mapping_settings.sage_display_name), ''), EXCLUDED.sage_display_name),
    is_active = true,
    configured_at = CASE
      WHEN NULLIF(trim(COALESCE(public.sage_mapping_settings.sage_external_id, '')), '') IS NULL THEN now()
      ELSE public.sage_mapping_settings.configured_at
    END,
    notes = COALESCE(NULLIF(trim(public.sage_mapping_settings.notes), ''), EXCLUDED.notes),
    updated_at = now();

NOTIFY pgrst, 'reload schema';

COMMIT;
