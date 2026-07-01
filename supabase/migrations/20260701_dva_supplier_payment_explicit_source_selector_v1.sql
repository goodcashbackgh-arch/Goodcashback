BEGIN;

-- DVA supplier payment explicit source selector v1.
-- Contract: docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_AUTO_RESOLUTION_ADDENDUM_v1.md
--
-- Fixes the remaining split-funded supplier AP gap:
--   real DVA cash + loyalty DVA/GHS wallet + loyalty virtual GBP wallet.
--
-- The source is selected at statement upload and carried through:
--   import batch -> committed statement -> supplier invoice allocation -> cash posting row.
-- Cash posting already consumes dva_statement_line_allocations.source_bank_account_mapping_code.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

ALTER TABLE public.dva_statement_import_batches
  ADD COLUMN IF NOT EXISTS statement_source_wallet_code text,
  ADD COLUMN IF NOT EXISTS statement_source_bank_account_mapping_code text;

ALTER TABLE public.dva_statements
  ADD COLUMN IF NOT EXISTS statement_source_wallet_code text,
  ADD COLUMN IF NOT EXISTS statement_source_bank_account_mapping_code text;

ALTER TABLE public.dva_statement_line_import_links
  ADD COLUMN IF NOT EXISTS statement_source_wallet_code text,
  ADD COLUMN IF NOT EXISTS statement_source_bank_account_mapping_code text;

COMMENT ON COLUMN public.dva_statement_import_batches.statement_source_wallet_code IS
'Upload-level funding source for importer payment statements. Supported values: dva_cash, dva_ghs_wallet, virtual_gbp_wallet.';

COMMENT ON COLUMN public.dva_statement_import_batches.statement_source_bank_account_mapping_code IS
'Sage mapping code to use for supplier invoice payment legs allocated from this statement source.';

COMMENT ON COLUMN public.dva_statements.statement_source_wallet_code IS
'Committed statement funding source copied from import batch for downstream supplier invoice payment allocation.';

COMMENT ON COLUMN public.dva_statements.statement_source_bank_account_mapping_code IS
'Committed statement Sage bank-account mapping copied from import batch for downstream supplier invoice payment allocation.';

CREATE INDEX IF NOT EXISTS dva_statements_source_bank_mapping_idx
  ON public.dva_statements(statement_source_bank_account_mapping_code)
  WHERE statement_source_bank_account_mapping_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS dva_statement_import_batches_source_wallet_idx
  ON public.dva_statement_import_batches(statement_source_wallet_code)
  WHERE statement_source_wallet_code IS NOT NULL;

-- Confirm the bank-account IDs used by cash posting contact payments.
-- These are Sage long IDs, not GL/account numbers.
INSERT INTO public.sage_mapping_settings (
  mapping_code,
  mapping_group,
  display_name,
  description,
  value_kind,
  required_for,
  sage_external_id,
  is_active,
  configured_at,
  updated_at
)
VALUES
  (
    'DVA_CASH_BANK_ACCOUNT',
    'cash_posting',
    'DVA/card Sage bank account',
    'Default Sage bank account id for real DVA/card/bank cash postings.',
    'free_text',
    ARRAY['cash_posting']::text[],
    '1d21e52bed0a4fedb1b1dc21044b7d07',
    true,
    now(),
    now()
  ),
  (
    'LOYALTY_DVA_GHS_BANK_ACCOUNT',
    'cash_posting',
    'Completion loyalty DVA GHS wallet bank account',
    'Sage bank account id used when a supplier invoice payment leg is funded from completion-loyalty DVA/GHS wallet funds.',
    'free_text',
    ARRAY['supplier_invoice_payment','completion_loyalty_wallet']::text[],
    'c7e2c4be463b4b41a9eca5ad39a06c18',
    true,
    now(),
    now()
  ),
  (
    'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT',
    'cash_posting',
    'Completion loyalty virtual GBP wallet bank account',
    'Sage bank account id used when a supplier invoice payment leg is funded from completion-loyalty virtual GBP wallet funds.',
    'free_text',
    ARRAY['supplier_invoice_payment','completion_loyalty_wallet']::text[],
    '1cf4a2cb34fe4775986ba7c5e0ead260',
    true,
    now(),
    now()
  )
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    sage_external_id = EXCLUDED.sage_external_id,
    is_active = true,
    configured_at = COALESCE(public.sage_mapping_settings.configured_at, EXCLUDED.configured_at),
    updated_at = now();

CREATE OR REPLACE FUNCTION public.internal_dva_statement_source_mapping_v1(
  p_statement_account_context text,
  p_local_ccy text,
  p_statement_source_wallet_code text DEFAULT NULL,
  p_statement_source_bank_account_mapping_code text DEFAULT NULL
)
RETURNS TABLE(source_wallet_code text, source_bank_account_mapping_code text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH normalised AS (
    SELECT
      COALESCE(NULLIF(trim(p_statement_account_context), ''), 'importer_dva_card_account') AS account_context,
      upper(COALESCE(NULLIF(trim(p_local_ccy), ''), '')) AS local_ccy,
      lower(NULLIF(trim(COALESCE(p_statement_source_wallet_code, '')), '')) AS wallet_code,
      upper(NULLIF(trim(COALESCE(p_statement_source_bank_account_mapping_code, '')), '')) AS mapping_code
  )
  SELECT
    CASE
      WHEN account_context <> 'importer_dva_card_account' THEN NULL::text
      WHEN mapping_code = 'LOYALTY_DVA_GHS_BANK_ACCOUNT' OR wallet_code = 'dva_ghs_wallet' THEN 'dva_ghs_wallet'
      WHEN mapping_code = 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT' OR wallet_code = 'virtual_gbp_wallet' THEN 'virtual_gbp_wallet'
      WHEN mapping_code = 'DVA_CASH_BANK_ACCOUNT' OR wallet_code = 'dva_cash' THEN 'dva_cash'
      WHEN local_ccy = 'GBP' THEN 'virtual_gbp_wallet'
      ELSE 'dva_cash'
    END AS source_wallet_code,
    CASE
      WHEN account_context <> 'importer_dva_card_account' THEN NULL::text
      WHEN mapping_code IN ('DVA_CASH_BANK_ACCOUNT','LOYALTY_DVA_GHS_BANK_ACCOUNT','LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT') THEN mapping_code
      WHEN wallet_code = 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
      WHEN wallet_code = 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
      WHEN wallet_code = 'dva_cash' THEN 'DVA_CASH_BANK_ACCOUNT'
      WHEN local_ccy = 'GBP' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
      ELSE 'DVA_CASH_BANK_ACCOUNT'
    END AS source_bank_account_mapping_code
  FROM normalised;
$$;

REVOKE ALL ON FUNCTION public.internal_dva_statement_source_mapping_v1(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_dva_statement_source_mapping_v1(text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_create_dva_statement_import_batch(
  p_importer_id uuid,
  p_source_bank varchar,
  p_statement_period_from date,
  p_statement_period_to date,
  p_local_ccy varchar,
  p_source_file_url varchar,
  p_original_filename varchar DEFAULT NULL,
  p_detected_file_type varchar DEFAULT 'unknown',
  p_default_card_markup_pct numeric DEFAULT 0,
  p_fx_source_context text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_statement_source_wallet_code text DEFAULT 'dva_cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_parser_route varchar;
  v_batch_id uuid;
  v_source record;
BEGIN
  SELECT * INTO v_staff FROM public.current_active_staff_record_();

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for current auth user';
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can create statement import batches. Current role: %', v_staff.role_type;
  END IF;

  IF p_detected_file_type NOT IN ('pdf', 'csv', 'xlsx', 'text', 'unknown') THEN
    RAISE EXCEPTION 'Unsupported detected file type: %', p_detected_file_type;
  END IF;

  SELECT * INTO v_source
  FROM public.internal_dva_statement_source_mapping_v1(
    'importer_dva_card_account',
    p_local_ccy::text,
    COALESCE(NULLIF(trim(p_statement_source_wallet_code), ''), 'dva_cash'),
    NULL
  );

  IF v_source.source_wallet_code NOT IN ('dva_cash','dva_ghs_wallet','virtual_gbp_wallet') THEN
    RAISE EXCEPTION 'Unsupported statement source wallet: %', p_statement_source_wallet_code;
  END IF;

  v_parser_route := CASE p_detected_file_type
    WHEN 'pdf' THEN 'pdf_ocr'
    WHEN 'csv' THEN 'csv_direct'
    WHEN 'xlsx' THEN 'xlsx_direct'
    WHEN 'text' THEN 'text_direct'
    ELSE 'manual_review'
  END;

  INSERT INTO public.dva_statement_import_batches (
    importer_id,
    statement_account_context,
    statement_account_key,
    statement_account_label,
    statement_source_wallet_code,
    statement_source_bank_account_mapping_code,
    source_bank,
    statement_period_from,
    statement_period_to,
    local_ccy,
    source_file_url,
    original_filename,
    detected_file_type,
    parser_route,
    default_card_markup_pct,
    fx_source_context,
    status,
    uploaded_by_staff_id,
    notes
  ) VALUES (
    p_importer_id,
    'importer_dva_card_account',
    p_importer_id::text,
    'Importer DVA/card account',
    v_source.source_wallet_code,
    v_source.source_bank_account_mapping_code,
    p_source_bank,
    p_statement_period_from,
    p_statement_period_to,
    upper(trim(p_local_ccy)),
    p_source_file_url,
    p_original_filename,
    p_detected_file_type,
    v_parser_route,
    round(coalesce(p_default_card_markup_pct, 0)::numeric, 3),
    p_fx_source_context,
    'uploaded',
    v_staff.id,
    p_notes
  ) RETURNING id INTO v_batch_id;

  RETURN jsonb_build_object(
    'ok', true,
    'import_batch_id', v_batch_id,
    'statement_account_context', 'importer_dva_card_account',
    'statement_source_wallet_code', v_source.source_wallet_code,
    'statement_source_bank_account_mapping_code', v_source.source_bank_account_mapping_code,
    'detected_file_type', p_detected_file_type,
    'parser_route', v_parser_route
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_create_dva_statement_import_batch_with_context_v1(
  p_statement_account_context varchar,
  p_importer_id uuid,
  p_source_bank varchar,
  p_statement_period_from date,
  p_statement_period_to date,
  p_local_ccy varchar,
  p_source_file_url varchar,
  p_original_filename varchar DEFAULT NULL,
  p_detected_file_type varchar DEFAULT 'unknown',
  p_default_card_markup_pct numeric DEFAULT 0,
  p_fx_source_context text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_statement_source_wallet_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_parser_route varchar;
  v_batch_id uuid;
  v_context text := COALESCE(NULLIF(trim(p_statement_account_context), ''), 'importer_dva_card_account');
  v_account_key text;
  v_account_label text;
  v_source record;
BEGIN
  SELECT * INTO v_staff FROM public.current_active_staff_record_();

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for current auth user';
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can create statement import batches. Current role: %', v_staff.role_type;
  END IF;

  IF v_context NOT IN ('importer_dva_card_account', 'main_company_bank_account') THEN
    RAISE EXCEPTION 'Unsupported statement account context: %', v_context;
  END IF;

  IF v_context = 'importer_dva_card_account' AND p_importer_id IS NULL THEN
    RAISE EXCEPTION 'Importer is required for importer DVA/card account statement imports.';
  END IF;

  IF p_detected_file_type NOT IN ('pdf', 'csv', 'xlsx', 'text', 'unknown') THEN
    RAISE EXCEPTION 'Unsupported detected file type: %', p_detected_file_type;
  END IF;

  SELECT * INTO v_source
  FROM public.internal_dva_statement_source_mapping_v1(
    v_context,
    p_local_ccy::text,
    CASE WHEN v_context = 'importer_dva_card_account' THEN COALESCE(NULLIF(trim(p_statement_source_wallet_code), ''), 'dva_cash') ELSE NULL END,
    NULL
  );

  v_account_key := CASE
    WHEN v_context = 'main_company_bank_account' THEN 'main_company_bank_account'
    ELSE p_importer_id::text
  END;

  v_account_label := CASE
    WHEN v_context = 'main_company_bank_account' THEN 'Main company bank account'
    ELSE 'Importer DVA/card account'
  END;

  v_parser_route := CASE p_detected_file_type
    WHEN 'pdf' THEN 'pdf_ocr'
    WHEN 'csv' THEN 'csv_direct'
    WHEN 'xlsx' THEN 'xlsx_direct'
    WHEN 'text' THEN 'text_direct'
    ELSE 'manual_review'
  END;

  INSERT INTO public.dva_statement_import_batches (
    importer_id,
    statement_account_context,
    statement_account_key,
    statement_account_label,
    statement_source_wallet_code,
    statement_source_bank_account_mapping_code,
    source_bank,
    statement_period_from,
    statement_period_to,
    local_ccy,
    source_file_url,
    original_filename,
    detected_file_type,
    parser_route,
    default_card_markup_pct,
    fx_source_context,
    status,
    uploaded_by_staff_id,
    notes
  ) VALUES (
    CASE WHEN v_context = 'main_company_bank_account' THEN NULL ELSE p_importer_id END,
    v_context,
    v_account_key,
    v_account_label,
    v_source.source_wallet_code,
    v_source.source_bank_account_mapping_code,
    p_source_bank,
    p_statement_period_from,
    p_statement_period_to,
    upper(trim(p_local_ccy)),
    p_source_file_url,
    p_original_filename,
    p_detected_file_type,
    v_parser_route,
    round(coalesce(p_default_card_markup_pct, 0)::numeric, 3),
    p_fx_source_context,
    'uploaded',
    v_staff.id,
    p_notes
  ) RETURNING id INTO v_batch_id;

  RETURN jsonb_build_object(
    'ok', true,
    'import_batch_id', v_batch_id,
    'statement_account_context', v_context,
    'statement_account_key', v_account_key,
    'statement_source_wallet_code', v_source.source_wallet_code,
    'statement_source_bank_account_mapping_code', v_source.source_bank_account_mapping_code,
    'detected_file_type', p_detected_file_type,
    'parser_route', v_parser_route
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_commit_dva_statement_import_batch(
  p_import_batch_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_batch record;
  v_statement_id uuid;
  v_committed_count integer := 0;
  v_row record;
  v_line_id uuid;
  v_context text;
  v_account_key text;
  v_account_label text;
BEGIN
  SELECT * INTO v_staff FROM public.current_active_staff_record_();

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for current auth user';
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can commit statement imports. Current role: %', v_staff.role_type;
  END IF;

  SELECT * INTO v_batch
  FROM public.dva_statement_import_batches
  WHERE id = p_import_batch_id
  FOR UPDATE;

  IF v_batch.id IS NULL THEN
    RAISE EXCEPTION 'Statement import batch not found: %', p_import_batch_id;
  END IF;

  v_context := COALESCE(NULLIF(v_batch.statement_account_context, ''), 'importer_dva_card_account');
  v_account_key := COALESCE(NULLIF(v_batch.statement_account_key, ''), v_batch.importer_id::text, 'main_company_bank_account');
  v_account_label := COALESCE(NULLIF(v_batch.statement_account_label, ''), CASE WHEN v_context = 'main_company_bank_account' THEN 'Main company bank account' ELSE 'Importer DVA/card account' END);

  IF v_context = 'importer_dva_card_account' AND v_batch.importer_id IS NULL THEN
    RAISE EXCEPTION 'Importer is required before committing importer DVA/card statement imports.';
  END IF;

  IF v_batch.status = 'committed' THEN
    RETURN jsonb_build_object('ok', true, 'already_committed', true, 'committed_count', v_batch.committed_count);
  END IF;

  IF v_batch.status IN ('voided', 'failed') THEN
    RAISE EXCEPTION 'Cannot commit batch % with status %', p_import_batch_id, v_batch.status;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_import_rows
    WHERE import_batch_id = p_import_batch_id
      AND parse_status = 'error'
  ) THEN
    RAISE EXCEPTION 'Cannot commit batch % while row-level parse errors exist', p_import_batch_id;
  END IF;

  INSERT INTO public.dva_statements (
    importer_id,
    statement_account_context,
    statement_account_key,
    statement_account_label,
    statement_source_wallet_code,
    statement_source_bank_account_mapping_code,
    source_bank,
    uploaded_by_staff_id,
    csv_url,
    statement_period_from,
    statement_period_to,
    parse_status,
    parse_errors_json
  ) VALUES (
    CASE WHEN v_context = 'main_company_bank_account' THEN NULL ELSE v_batch.importer_id END,
    v_context,
    v_account_key,
    v_account_label,
    v_batch.statement_source_wallet_code,
    v_batch.statement_source_bank_account_mapping_code,
    v_batch.source_bank,
    v_staff.id,
    v_batch.source_file_url,
    v_batch.statement_period_from,
    v_batch.statement_period_to,
    'parsed',
    NULL
  ) RETURNING id INTO v_statement_id;

  FOR v_row IN
    SELECT *
    FROM public.dva_statement_import_rows
    WHERE import_batch_id = p_import_batch_id
      AND parse_status = 'clean'
    ORDER BY source_row_number
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.dva_statement_line_import_links link
      WHERE link.statement_account_context = v_context
        AND link.statement_account_key = v_account_key
        AND link.source_bank = v_batch.source_bank
        AND link.statement_line_fingerprint_hash = v_row.statement_line_fingerprint_hash
        AND link.active_yn = true
    ) THEN
      UPDATE public.dva_statement_import_rows
         SET parse_status = 'duplicate_skipped',
             error_code = 'duplicate_on_commit',
             error_message = 'Duplicate detected at commit by statement account fingerprint.'
       WHERE id = v_row.id;
      CONTINUE;
    END IF;

    INSERT INTO public.dva_statement_lines (
      dva_statement_id,
      line_order,
      statement_date,
      reference_raw,
      direction,
      amount_local_ccy,
      local_ccy,
      fx_rate_applied,
      card_markup_pct_applied,
      amount_gbp_equivalent,
      auth_id_ref,
      retailer_name_ref,
      match_status
    ) VALUES (
      v_statement_id,
      v_row.source_row_number,
      v_row.statement_date,
      left(coalesce(v_row.raw_text, ''), 255),
      v_row.direction,
      v_row.amount_local_ccy,
      v_row.local_ccy,
      v_row.fx_rate_applied,
      v_row.card_markup_pct_applied,
      v_row.amount_gbp_equivalent,
      coalesce(v_row.auth_or_settlement_ref, v_row.bank_reference),
      v_row.merchant_raw,
      'unmatched'
    ) RETURNING id INTO v_line_id;

    INSERT INTO public.dva_statement_line_import_links (
      importer_id,
      statement_account_context,
      statement_account_key,
      statement_account_label,
      statement_source_wallet_code,
      statement_source_bank_account_mapping_code,
      source_bank,
      import_batch_id,
      import_row_id,
      dva_statement_id,
      dva_statement_line_id,
      statement_line_fingerprint_hash,
      active_yn
    ) VALUES (
      CASE WHEN v_context = 'main_company_bank_account' THEN NULL ELSE v_batch.importer_id END,
      v_context,
      v_account_key,
      v_account_label,
      v_batch.statement_source_wallet_code,
      v_batch.statement_source_bank_account_mapping_code,
      v_batch.source_bank,
      p_import_batch_id,
      v_row.id,
      v_statement_id,
      v_line_id,
      v_row.statement_line_fingerprint_hash,
      true
    );

    UPDATE public.dva_statement_import_rows
       SET parse_status = 'committed',
           committed_dva_statement_line_id = v_line_id,
           committed_at = now()
     WHERE id = v_row.id;

    v_committed_count := v_committed_count + 1;
  END LOOP;

  UPDATE public.dva_statement_import_batches
     SET status = 'committed',
         statement_account_context = v_context,
         statement_account_key = v_account_key,
         statement_account_label = v_account_label,
         committed_by_staff_id = v_staff.id,
         committed_at = now(),
         committed_count = v_committed_count,
         notes = coalesce(p_notes, notes)
   WHERE id = p_import_batch_id;

  RETURN jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'dva_statement_id', v_statement_id,
    'statement_account_context', v_context,
    'statement_account_key', v_account_key,
    'statement_source_wallet_code', v_batch.statement_source_wallet_code,
    'statement_source_bank_account_mapping_code', v_batch.statement_source_bank_account_mapping_code,
    'committed_count', v_committed_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(
  p_dva_statement_line_id uuid,
  p_supplier_invoice_id uuid,
  p_allocated_gbp_amount numeric,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_line record;
  v_invoice record;
  v_order record;
  v_existing_active_allocation_id uuid;
  v_confirmed_total_before numeric(12,2);
  v_confirmed_total_after numeric(12,2);
  v_unallocated_after numeric(12,2);
  v_invoice_total_gbp numeric(12,2);
  v_supplier_confirmed_before numeric(12,2);
  v_supplier_confirmed_after numeric(12,2);
  v_supplier_unallocated_after numeric(12,2);
  v_amount numeric(12,2);
  v_allocation_id uuid;
  v_statement_account_context text;
  v_statement_local_ccy text;
  v_source record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff allocation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can allocate DVA/card statement lines. Current role: %', v_staff.role_type;
  END IF;

  v_amount := ROUND(COALESCE(p_allocated_gbp_amount, 0)::numeric, 2);

  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Allocated GBP amount must be greater than zero. Received: %', v_amount;
  END IF;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.match_status,
    dsl.auth_id_ref,
    dsl.reference_raw,
    dsl.retailer_name_ref,
    dsl.statement_date,
    dsl.local_ccy,
    dsl.fx_rate_applied,
    dsl.card_markup_pct_applied,
    ds.importer_id,
    ds.statement_account_context,
    ds.statement_source_wallet_code,
    ds.statement_source_bank_account_mapping_code
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds
    ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'DVA/card statement line not found: %', p_dva_statement_line_id;
  END IF;

  IF v_line.direction <> 'out' THEN
    RAISE EXCEPTION 'Supplier invoice allocation requires an OUT statement line. Line % has direction %', p_dva_statement_line_id, v_line.direction;
  END IF;

  IF COALESCE(v_line.amount_gbp_equivalent, 0) <= 0 THEN
    RAISE EXCEPTION 'Statement line % has invalid GBP equivalent %', p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  END IF;

  v_statement_account_context := COALESCE(NULLIF(v_line.statement_account_context::text, ''), 'importer_dva_card_account');
  v_statement_local_ccy := UPPER(COALESCE(NULLIF(v_line.local_ccy::text, ''), ''));

  SELECT * INTO v_source
  FROM public.internal_dva_statement_source_mapping_v1(
    v_statement_account_context,
    v_statement_local_ccy,
    v_line.statement_source_wallet_code,
    v_line.statement_source_bank_account_mapping_code
  );

  SELECT
    si.id,
    si.order_id,
    si.invoice_ref,
    si.ocr_invoice_ref,
    si.ocr_invoice_total_gbp,
    si.reconciliation_gbp_total,
    si.review_status
  INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found: %', p_supplier_invoice_id;
  END IF;

  SELECT
    ROUND(
      COALESCE(
        v_invoice.ocr_invoice_total_gbp,
        v_invoice.reconciliation_gbp_total,
        SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0))
      )::numeric,
      2
    )
    INTO v_invoice_total_gbp
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id;

  IF COALESCE(v_invoice_total_gbp, 0) <= 0 THEN
    RAISE EXCEPTION 'Supplier invoice % has no positive invoice total available for allocation', p_supplier_invoice_id;
  END IF;

  SELECT
    o.id,
    o.order_ref,
    o.importer_id,
    o.retailer_id,
    o.status,
    COALESCE(o.order_type, 'original') AS order_type
  INTO v_order
  FROM public.orders o
  WHERE o.id = v_invoice.order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found for supplier invoice %', p_supplier_invoice_id;
  END IF;

  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Importer mismatch: statement line importer % cannot allocate to invoice % / order % importer %',
      v_line.importer_id, p_supplier_invoice_id, v_order.id, v_order.importer_id;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot allocate statement line to supplier invoice on order % with status %', v_order.id, v_order.status;
  END IF;

  SELECT a.id
    INTO v_existing_active_allocation_id
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.supplier_invoice_id = p_supplier_invoice_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status <> 'reversed'
  LIMIT 1;

  IF v_existing_active_allocation_id IS NOT NULL THEN
    RAISE EXCEPTION 'Active allocation already exists for statement line % and supplier invoice %: %',
      p_dva_statement_line_id, p_supplier_invoice_id, v_existing_active_allocation_id;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_confirmed_total_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  IF v_confirmed_total_before + v_amount > ROUND(v_line.amount_gbp_equivalent::numeric, 2) + 0.01 THEN
    RAISE EXCEPTION 'Allocation would over-allocate statement line %. Statement GBP %, already confirmed %, proposed %',
      p_dva_statement_line_id, ROUND(v_line.amount_gbp_equivalent::numeric, 2), v_confirmed_total_before, v_amount;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_supplier_confirmed_before
  FROM public.dva_statement_line_allocations a
  WHERE a.supplier_invoice_id = p_supplier_invoice_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  IF v_supplier_confirmed_before + v_amount > v_invoice_total_gbp + 0.01 THEN
    RAISE EXCEPTION 'Allocation would over-allocate supplier invoice %. Invoice GBP %, already confirmed %, proposed %',
      p_supplier_invoice_id, v_invoice_total_gbp, v_supplier_confirmed_before, v_amount;
  END IF;

  INSERT INTO public.dva_statement_line_allocations (
    dva_statement_line_id,
    allocation_type,
    supplier_invoice_id,
    dispute_id,
    order_id,
    allocated_gbp_amount,
    allocation_status,
    fx_rate_applied,
    card_markup_pct_applied,
    source_bank_account_mapping_code,
    source_wallet_code,
    notes,
    created_by_staff_id,
    created_at,
    confirmed_by_staff_id,
    confirmed_at
  )
  VALUES (
    p_dva_statement_line_id,
    'supplier_invoice',
    p_supplier_invoice_id,
    NULL,
    v_order.id,
    v_amount,
    'confirmed',
    v_line.fx_rate_applied,
    v_line.card_markup_pct_applied,
    v_source.source_bank_account_mapping_code,
    v_source.source_wallet_code,
    p_notes,
    v_staff.id,
    now(),
    v_staff.id,
    now()
  )
  RETURNING id INTO v_allocation_id;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_confirmed_total_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_supplier_confirmed_after
  FROM public.dva_statement_line_allocations a
  WHERE a.supplier_invoice_id = p_supplier_invoice_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  v_unallocated_after := ROUND(v_line.amount_gbp_equivalent::numeric - v_confirmed_total_after, 2);
  v_supplier_unallocated_after := ROUND(v_invoice_total_gbp - v_supplier_confirmed_after, 2);

  RETURN jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'supplier_invoice_id', p_supplier_invoice_id,
    'order_id', v_order.id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'allocated_gbp_amount', v_amount,
    'statement_gbp_amount', ROUND(v_line.amount_gbp_equivalent::numeric, 2),
    'statement_account_context', v_statement_account_context,
    'statement_local_ccy', v_statement_local_ccy,
    'source_bank_account_mapping_code', v_source.source_bank_account_mapping_code,
    'source_wallet_code', v_source.source_wallet_code,
    'confirmed_allocated_before_gbp', v_confirmed_total_before,
    'confirmed_allocated_after_gbp', v_confirmed_total_after,
    'confirmed_unallocated_after_gbp', v_unallocated_after,
    'balanced_yn', ABS(v_unallocated_after) < 0.01,
    'needs_fx_or_additional_allocation_yn', ABS(v_unallocated_after) >= 0.01,
    'invoice_ref', COALESCE(v_invoice.ocr_invoice_ref, v_invoice.invoice_ref),
    'invoice_total_gbp', v_invoice_total_gbp,
    'supplier_invoice_confirmed_before_gbp', v_supplier_confirmed_before,
    'supplier_invoice_confirmed_after_gbp', v_supplier_confirmed_after,
    'supplier_invoice_unallocated_after_gbp', v_supplier_unallocated_after,
    'supplier_invoice_fully_allocated_yn', ABS(v_supplier_unallocated_after) < 0.01
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_create_dva_statement_import_batch(uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_create_dva_statement_import_batch_with_context_v1(varchar, uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_commit_dva_statement_import_batch(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.staff_create_dva_statement_import_batch(uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_create_dva_statement_import_batch_with_context_v1(varchar, uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_commit_dva_statement_import_batch(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) TO authenticated;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) IS
'Staff/supervisor SECURITY DEFINER RPC to allocate one OUT DVA/card statement line to one supplier invoice. Stamps supplier invoice cash payment source from committed statement source metadata: DVA_CASH_BANK_ACCOUNT, LOYALTY_DVA_GHS_BANK_ACCOUNT, or LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks:
-- select mapping_code, sage_external_id from public.sage_mapping_settings where mapping_code in ('DVA_CASH_BANK_ACCOUNT','LOYALTY_DVA_GHS_BANK_ACCOUNT','LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT') order by mapping_code;
-- select to_regprocedure('public.staff_create_dva_statement_import_batch(uuid,character varying,date,date,character varying,character varying,character varying,character varying,numeric,text,text,text)');
-- select to_regprocedure('public.staff_create_dva_statement_import_batch_with_context_v1(character varying,uuid,character varying,date,date,character varying,character varying,character varying,character varying,numeric,text,text,text)');
-- select to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)');
