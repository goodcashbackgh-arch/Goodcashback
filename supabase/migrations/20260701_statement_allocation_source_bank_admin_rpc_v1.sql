BEGIN;

-- Admin helper for DVA supplier payment source-bank split.
-- Contract: docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_line_allocations';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_set_dva_statement_allocation_source_bank_v1(
  p_allocation_id uuid,
  p_source_bank_account_mapping_code text,
  p_source_wallet_code text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_allocation record;
  v_mapping_code text := upper(NULLIF(trim(COALESCE(p_source_bank_account_mapping_code, '')), ''));
  v_mapping_external_id text;
  v_wallet_code text := NULLIF(trim(COALESCE(p_source_wallet_code, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;
  IF p_allocation_id IS NULL THEN
    RAISE EXCEPTION 'Allocation id is required.';
  END IF;
  IF v_mapping_code IS NULL THEN
    RAISE EXCEPTION 'Source bank account mapping code is required.';
  END IF;

  SELECT a.*
  INTO v_allocation
  FROM public.dva_statement_line_allocations a
  WHERE a.id = p_allocation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DVA statement-line allocation % not found.', p_allocation_id;
  END IF;
  IF v_allocation.allocation_type <> 'supplier_invoice' THEN
    RAISE EXCEPTION 'Source bank override is only supported for supplier_invoice allocations.';
  END IF;
  IF v_allocation.allocation_status = 'reversed' THEN
    RAISE EXCEPTION 'Cannot update source bank mapping for a reversed allocation.';
  END IF;

  SELECT sms.sage_external_id::text
  INTO v_mapping_external_id
  FROM public.sage_mapping_settings sms
  WHERE sms.mapping_code = v_mapping_code
    AND sms.is_active = true
  LIMIT 1;

  IF NULLIF(trim(COALESCE(v_mapping_external_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Active Sage bank account mapping % is missing or has no Sage external id.', v_mapping_code;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cash_posting_snapshots cps
    WHERE cps.active = true
      AND cps.source_id = p_allocation_id
      AND cps.posting_category = 'supplier_invoice_payment'
      AND COALESCE(cps.sage_posting_status, '') IN ('posted', 'posting_in_progress')
  ) THEN
    RAISE EXCEPTION 'Cannot update source bank mapping after supplier payment posting has started or posted.';
  END IF;

  UPDATE public.dva_statement_line_allocations
  SET source_bank_account_mapping_code = v_mapping_code,
      source_wallet_code = v_wallet_code,
      notes = concat_ws(E'\n', NULLIF(notes, ''), NULLIF(trim(COALESCE(p_notes, '')), ''))
  WHERE id = p_allocation_id;

  RETURN jsonb_build_object(
    'ok', true,
    'allocation_id', p_allocation_id,
    'source_bank_account_mapping_code', v_mapping_code,
    'source_wallet_code', v_wallet_code,
    'sage_bank_account_id', v_mapping_external_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_set_dva_statement_allocation_source_bank_v1(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_set_dva_statement_allocation_source_bank_v1(uuid, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.staff_set_dva_statement_allocation_source_bank_v1(uuid, text, text, text) IS
'Sets the source Sage bank/wallet mapping for a supplier_invoice DVA statement-line allocation before supplier payment posting. Used for split supplier AP settlement, e.g. DVA cash plus loyalty/virtual wallet legs.';

NOTIFY pgrst, 'reload schema';

COMMIT;
