BEGIN;

-- Null-safe resolver override for completion-loyalty internal-transfer journal lane.
-- Missing mappings must return a blocker row, not raise a record access error.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_statement_ledger_resolver_v1(
  p_statement_line_id uuid
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_account_context text,
  local_ccy text,
  resolved_wallet_code text,
  resolved_mapping_code text,
  sage_ledger_account_id text,
  blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_line record;
  v_context text;
  v_ccy text;
  v_wallet_code text;
  v_mapping_codes text[];
  v_mapping_code text;
  v_sage_ledger_account_id text;
  v_blocker text;
BEGIN
  SELECT
    dsl.id,
    ds.statement_account_context::text AS statement_account_context,
    upper(COALESCE(NULLIF(to_jsonb(dsl)->>'local_ccy', ''), NULLIF(to_jsonb(dsl)->>'currency', ''), ''))::text AS local_ccy
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_statement_line_id;

  IF v_line.id IS NULL THEN
    RETURN QUERY SELECT p_statement_line_id, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, 'statement_line_not_found'::text;
    RETURN;
  END IF;

  v_context := v_line.statement_account_context;
  v_ccy := v_line.local_ccy;

  IF v_context = 'main_company_bank_account' THEN
    v_wallet_code := 'main_gbp_bank';
    v_mapping_codes := ARRAY['LOYALTY_MAIN_GBP_BANK_LEDGER','LOYALTY_MAIN_BANK_LEDGER','MAIN_GBP_BANK_LEDGER','MAIN_BANK_LEDGER','MAIN_COMPANY_BANK_LEDGER'];
  ELSIF v_context = 'importer_dva_card_account' AND v_ccy = 'GBP' THEN
    v_wallet_code := 'virtual_gbp_wallet';
    v_mapping_codes := ARRAY['LOYALTY_VIRTUAL_GBP_BANK_LEDGER','VIRTUAL_GBP_BANK_LEDGER','VIRTUAL_GBP_BANK_ACCOUNT'];
  ELSIF v_context = 'importer_dva_card_account' AND v_ccy = 'GHS' THEN
    v_wallet_code := 'dva_ghs_wallet';
    v_mapping_codes := ARRAY['LOYALTY_DVA_GHS_BANK_LEDGER','DVA_GHS_BANK_LEDGER','DVA_CASH_BANK_LEDGER','DVA_CASH_BANK_LEDGER_ACCOUNT','DVA_CASH_CLEARING_LEDGER'];
  ELSIF v_context = 'importer_dva_card_account' THEN
    v_wallet_code := 'unsupported_importer_wallet_currency';
    v_mapping_codes := ARRAY[]::text[];
    v_blocker := 'unsupported_importer_wallet_currency_' || COALESCE(NULLIF(v_ccy, ''), 'missing');
  ELSE
    v_wallet_code := 'unsupported_statement_account_context';
    v_mapping_codes := ARRAY[]::text[];
    v_blocker := 'unsupported_statement_account_context_' || COALESCE(NULLIF(v_context, ''), 'missing');
  END IF;

  IF v_blocker IS NULL THEN
    SELECT sms.mapping_code, sms.sage_external_id
    INTO v_mapping_code, v_sage_ledger_account_id
    FROM public.sage_mapping_settings sms
    WHERE sms.mapping_code = ANY(v_mapping_codes)
      AND sms.is_active = true
      AND NULLIF(trim(COALESCE(sms.sage_external_id, '')), '') IS NOT NULL
    ORDER BY array_position(v_mapping_codes, sms.mapping_code), sms.updated_at DESC NULLS LAST
    LIMIT 1;

    IF NULLIF(trim(COALESCE(v_sage_ledger_account_id, '')), '') IS NULL THEN
      v_blocker := 'missing_' || v_wallet_code || '_sage_ledger_mapping';
    END IF;
  END IF;

  RETURN QUERY SELECT
    v_line.id::uuid,
    v_context::text,
    v_ccy::text,
    v_wallet_code::text,
    v_mapping_code::text,
    v_sage_ledger_account_id::text,
    v_blocker::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
