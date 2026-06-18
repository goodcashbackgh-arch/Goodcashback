UPDATE public.sage_mapping_settings
SET
  sage_external_id = 'ea29af733be211f194130283b27a38ab',
  sage_display_name = 'Carriage on Purchases (5100)',
  configured_at = COALESCE(configured_at, now()),
  notes = COALESCE(NULLIF(notes, ''), 'Corrected Sage external id for Carriage on Purchases (5100). Previous seed was missing one character.')
WHERE mapping_code = 'VAT_BOX7_CARRIAGE_ON_PURCHASES_LEDGER'
  AND sage_external_id = 'ea29af73be211f194130283b27a38ab';
