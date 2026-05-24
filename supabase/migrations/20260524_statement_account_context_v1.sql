BEGIN;

-- Statement account context v1
-- Purpose: allow DVA/card statement import to support both importer DVA/card accounts
-- and the main/company bank account used for shipper/platform payments.
--
-- Safety:
-- - Existing importer DVA/card behaviour is preserved.
-- - Main company bank account is NOT represented as a fake importer.
-- - Main bank lines remain excluded from importer funding flows by account context.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statement_import_batches') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_import_batches';
  END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statements';
  END IF;
  IF to_regclass('public.dva_statement_line_import_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_line_import_links';
  END IF;
END $$;

ALTER TABLE public.dva_statement_import_batches
  ADD COLUMN IF NOT EXISTS statement_account_context text NOT NULL DEFAULT 'importer_dva_card_account',
  ADD COLUMN IF NOT EXISTS statement_account_key text,
  ADD COLUMN IF NOT EXISTS statement_account_label text;

ALTER TABLE public.dva_statements
  ADD COLUMN IF NOT EXISTS statement_account_context text NOT NULL DEFAULT 'importer_dva_card_account',
  ADD COLUMN IF NOT EXISTS statement_account_key text,
  ADD COLUMN IF NOT EXISTS statement_account_label text;

ALTER TABLE public.dva_statement_line_import_links
  ADD COLUMN IF NOT EXISTS statement_account_context text NOT NULL DEFAULT 'importer_dva_card_account',
  ADD COLUMN IF NOT EXISTS statement_account_key text,
  ADD COLUMN IF NOT EXISTS statement_account_label text;

UPDATE public.dva_statement_import_batches
   SET statement_account_context = COALESCE(NULLIF(statement_account_context, ''), 'importer_dva_card_account'),
       statement_account_key = COALESCE(NULLIF(statement_account_key, ''), importer_id::text, 'main_company_bank_account'),
       statement_account_label = COALESCE(NULLIF(statement_account_label, ''), 'Importer DVA/card account')
 WHERE statement_account_key IS NULL
    OR statement_account_key = ''
    OR statement_account_label IS NULL
    OR statement_account_label = '';

UPDATE public.dva_statements
   SET statement_account_context = COALESCE(NULLIF(statement_account_context, ''), 'importer_dva_card_account'),
       statement_account_key = COALESCE(NULLIF(statement_account_key, ''), importer_id::text, 'main_company_bank_account'),
       statement_account_label = COALESCE(NULLIF(statement_account_label, ''), 'Importer DVA/card account')
 WHERE statement_account_key IS NULL
    OR statement_account_key = ''
    OR statement_account_label IS NULL
    OR statement_account_label = '';

UPDATE public.dva_statement_line_import_links
   SET statement_account_context = COALESCE(NULLIF(statement_account_context, ''), 'importer_dva_card_account'),
       statement_account_key = COALESCE(NULLIF(statement_account_key, ''), importer_id::text, 'main_company_bank_account'),
       statement_account_label = COALESCE(NULLIF(statement_account_label, ''), 'Importer DVA/card account')
 WHERE statement_account_key IS NULL
    OR statement_account_key = ''
    OR statement_account_label IS NULL
    OR statement_account_label = '';

ALTER TABLE public.dva_statement_import_batches
  ALTER COLUMN statement_account_key SET NOT NULL;

ALTER TABLE public.dva_statements
  ALTER COLUMN statement_account_key SET NOT NULL;

ALTER TABLE public.dva_statement_line_import_links
  ALTER COLUMN statement_account_key SET NOT NULL;

ALTER TABLE public.dva_statement_import_batches
  ALTER COLUMN importer_id DROP NOT NULL;

ALTER TABLE public.dva_statements
  ALTER COLUMN importer_id DROP NOT NULL;

ALTER TABLE public.dva_statement_line_import_links
  ALTER COLUMN importer_id DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dva_statement_import_batches_account_context_chk'
      AND conrelid = 'public.dva_statement_import_batches'::regclass
  ) THEN
    ALTER TABLE public.dva_statement_import_batches
      ADD CONSTRAINT dva_statement_import_batches_account_context_chk CHECK (
        statement_account_context IN ('importer_dva_card_account', 'main_company_bank_account')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dva_statements_account_context_chk'
      AND conrelid = 'public.dva_statements'::regclass
  ) THEN
    ALTER TABLE public.dva_statements
      ADD CONSTRAINT dva_statements_account_context_chk CHECK (
        statement_account_context IN ('importer_dva_card_account', 'main_company_bank_account')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dva_statement_line_import_links_account_context_chk'
      AND conrelid = 'public.dva_statement_line_import_links'::regclass
  ) THEN
    ALTER TABLE public.dva_statement_line_import_links
      ADD CONSTRAINT dva_statement_line_import_links_account_context_chk CHECK (
        statement_account_context IN ('importer_dva_card_account', 'main_company_bank_account')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dva_statement_import_batches_account_importer_chk'
      AND conrelid = 'public.dva_statement_import_batches'::regclass
  ) THEN
    ALTER TABLE public.dva_statement_import_batches
      ADD CONSTRAINT dva_statement_import_batches_account_importer_chk CHECK (
        (statement_account_context = 'importer_dva_card_account' AND importer_id IS NOT NULL)
        OR (statement_account_context = 'main_company_bank_account')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'dva_statements_account_importer_chk'
      AND conrelid = 'public.dva_statements'::regclass
  ) THEN
    ALTER TABLE public.dva_statements
      ADD CONSTRAINT dva_statements_account_importer_chk CHECK (
        (statement_account_context = 'importer_dva_card_account' AND importer_id IS NOT NULL)
        OR (statement_account_context = 'main_company_bank_account')
      );
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS dva_statement_line_import_links_unique_account_fingerprint
  ON public.dva_statement_line_import_links(statement_account_context, statement_account_key, source_bank, statement_line_fingerprint_hash)
  WHERE active_yn = true;

CREATE INDEX IF NOT EXISTS idx_dva_statement_import_batches_account_context
  ON public.dva_statement_import_batches(statement_account_context, statement_account_key, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_dva_statements_account_context
  ON public.dva_statements(statement_account_context, statement_account_key, uploaded_at DESC);

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
  p_notes text DEFAULT NULL
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
    'committed_count', v_committed_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_create_dva_statement_import_batch_with_context_v1(varchar, uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_create_dva_statement_import_batch_with_context_v1(varchar, uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.staff_commit_dva_statement_import_batch(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_commit_dva_statement_import_batch(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks:
-- select column_name from information_schema.columns where table_schema='public' and table_name='dva_statement_import_batches' and column_name like 'statement_account%';
-- select to_regprocedure('public.staff_create_dva_statement_import_batch_with_context_v1(character varying,uuid,character varying,date,date,character varying,character varying,character varying,character varying,numeric,text,text)');
-- select to_regprocedure('public.staff_commit_dva_statement_import_batch(uuid,text)');
