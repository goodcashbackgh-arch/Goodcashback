BEGIN;

-- Completion loyalty supplier wallet payment cash bridge v1.
-- Additive only. Reuses existing cash posting supplier OUT adapter.
-- Does not update DVA_CASH_BANK_ACCOUNT and does not change the DVA/card cash posting read model.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_events'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.importers') IS NULL THEN RAISE EXCEPTION 'Missing public.importers'; END IF;
  IF to_regclass('public.retailers') IS NULL THEN RAISE EXCEPTION 'Missing public.retailers'; END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoices'; END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_posting_snapshots'; END IF;
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_snapshots'; END IF;
  IF to_regclass('public.cash_posting_batches') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_batches'; END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_batch_rows'; END IF;
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_mapping_settings'; END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_party_mappings'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_staff_id_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_completion_loyalty_staff_id_v1()'; END IF;
END $$;

INSERT INTO public.sage_mapping_settings (mapping_code, mapping_group, display_name, description, value_kind, required_for)
VALUES
  ('LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT','completion_loyalty','Virtual GBP wallet Sage bank account','Sage long bank account id used by /contact_payments when completion-loyalty pays a supplier from the company-controlled Virtual GBP wallet. Do not use the GL/display number or ledger_account id.','free_text',ARRAY['completion_loyalty_supplier_wallet_payment','supplier_invoice_payment']::text[]),
  ('LOYALTY_DVA_GHS_BANK_ACCOUNT','completion_loyalty','DVA GHS wallet Sage bank account','Sage long bank account id used by /contact_payments when completion-loyalty pays a supplier from the company-controlled DVA GHS wallet, posted in GBP equivalent. Do not use the GL/display number or ledger_account id.','free_text',ARRAY['completion_loyalty_supplier_wallet_payment','supplier_invoice_payment']::text[])
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    updated_at = now();

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_wallet_bank_account_resolver_v1(
  p_statement_line_id uuid
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_account_context text,
  local_ccy text,
  wallet_code text,
  bank_account_mapping_code text,
  sage_bank_account_id text,
  blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_line record;
  v_mapping_code text;
  v_sage_bank_account_id text;
  v_wallet_code text;
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

  IF v_line.statement_account_context <> 'importer_dva_card_account' THEN
    v_blocker := 'wallet_payment_destination_not_importer_dva_card_account';
  ELSIF v_line.local_ccy = 'GBP' THEN
    v_wallet_code := 'virtual_gbp_wallet';
    v_mapping_code := 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT';
  ELSIF v_line.local_ccy = 'GHS' THEN
    v_wallet_code := 'dva_ghs_wallet';
    v_mapping_code := 'LOYALTY_DVA_GHS_BANK_ACCOUNT';
  ELSE
    v_wallet_code := 'unsupported_wallet_currency';
    v_blocker := 'unsupported_wallet_currency_' || COALESCE(NULLIF(v_line.local_ccy, ''), 'missing');
  END IF;

  IF v_blocker IS NULL THEN
    SELECT sms.sage_external_id
    INTO v_sage_bank_account_id
    FROM public.sage_mapping_settings sms
    WHERE sms.mapping_code = v_mapping_code
      AND sms.is_active = true
      AND NULLIF(trim(COALESCE(sms.sage_external_id, '')), '') IS NOT NULL
    ORDER BY sms.updated_at DESC NULLS LAST
    LIMIT 1;

    IF NULLIF(trim(COALESCE(v_sage_bank_account_id, '')), '') IS NULL THEN
      v_blocker := 'missing_' || v_wallet_code || '_sage_bank_account_mapping';
    END IF;
  END IF;

  RETURN QUERY SELECT
    v_line.id::uuid,
    v_line.statement_account_context::text,
    v_line.local_ccy::text,
    v_wallet_code::text,
    v_mapping_code::text,
    v_sage_bank_account_id::text,
    v_blocker::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  order_funding_event_id uuid,
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  retailer_id uuid,
  retailer_name text,
  supplier_invoice_id uuid,
  supplier_invoice_ref text,
  supplier_ap_snapshot_id uuid,
  target_sage_purchase_invoice_id text,
  supplier_sage_contact_id text,
  supplier_sage_contact_name text,
  source_credit_ledger_id uuid,
  destination_in_statement_line_id uuid,
  wallet_code text,
  wallet_bank_account_mapping_code text,
  wallet_sage_bank_account_id text,
  amount_gbp numeric,
  posting_date date,
  readiness_status text,
  blocker text,
  existing_snapshot_id uuid,
  existing_batch_id uuid,
  existing_batch_ref text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: completion-loyalty supplier wallet candidates require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for completion-loyalty supplier wallet candidates.'; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      ofe.id AS order_funding_event_id,
      ofe.order_id,
      o.order_ref::text AS order_ref,
      o.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      o.retailer_id,
      COALESCE(r.name::text, 'Retailer/supplier')::text AS retailer_name,
      debit.id AS debit_ledger_id,
      source_credit.id AS source_credit_ledger_id,
      round(abs(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      COALESCE(ofe.created_at::date, now()::date) AS posting_date
    FROM public.order_funding_events ofe
    JOIN public.orders o ON o.id = ofe.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    LEFT JOIN public.importer_credit_ledger debit ON debit.id = ofe.source_entity_id
    LEFT JOIN public.importer_credit_ledger source_credit ON source_credit.id = COALESCE(debit.source_id, debit.source_entity_id)
    WHERE ofe.event_type = 'credit_applied'
      AND source_credit.source_type = 'completion_loyalty_reward'
  ), funded AS (
    SELECT
      b.*,
      fm.destination_in_statement_line_id
    FROM base b
    LEFT JOIN LATERAL (
      SELECT m.destination_in_statement_line_id
      FROM public.main_bank_completion_loyalty_funding_matches m
      WHERE m.credit_ledger_id = b.source_credit_ledger_id
        AND m.importer_id = b.importer_id
        AND m.transfer_pair_status = 'paired_released'
        AND m.match_status = 'released_available_dashboard_credit'
        AND m.destination_in_statement_line_id IS NOT NULL
      ORDER BY m.created_at DESC NULLS LAST, m.id DESC
      LIMIT 1
    ) fm ON true
  ), supplier_target AS (
    SELECT
      f.*,
      si.id AS supplier_invoice_id,
      COALESCE(si.ocr_invoice_ref, si.invoice_ref, si.id::text)::text AS supplier_invoice_ref,
      sps.id AS supplier_ap_snapshot_id,
      sps.sage_invoice_id::text AS target_sage_purchase_invoice_id,
      round(COALESCE(sps.amount_gbp, 0)::numeric, 2) AS supplier_ap_amount_gbp
    FROM funded f
    LEFT JOIN LATERAL (
      SELECT si0.*
      FROM public.supplier_invoices si0
      WHERE si0.order_id = f.order_id
        AND (si0.review_status IN ('approved_current','ref_corrected_approved') OR COALESCE(si0.is_current_for_order, false) = true)
      ORDER BY COALESCE(si0.updated_at, si0.created_at) DESC NULLS LAST, si0.created_at DESC NULLS LAST
      LIMIT 1
    ) si ON true
    LEFT JOIN LATERAL (
      SELECT sps0.*
      FROM public.sage_posting_snapshots sps0
      WHERE sps0.document_lane = 'supplier_goods_ap'
        AND sps0.source_id = si.id
        AND sps0.sage_posting_status = 'posted'
        AND NULLIF(trim(COALESCE(sps0.sage_invoice_id, '')), '') IS NOT NULL
      ORDER BY sps0.sage_posted_at DESC NULLS LAST, sps0.created_at DESC
      LIMIT 1
    ) sps ON true
  ), enriched AS (
    SELECT
      st.*,
      spm.sage_contact_id::text AS supplier_sage_contact_id,
      spm.sage_contact_display_name::text AS supplier_sage_contact_name,
      wr.wallet_code,
      wr.bank_account_mapping_code,
      wr.sage_bank_account_id,
      wr.blocker AS wallet_blocker,
      existing.id AS existing_snapshot_id,
      existing_batch.id AS existing_batch_id,
      existing_batch.batch_ref AS existing_batch_ref
    FROM supplier_target st
    LEFT JOIN LATERAL (
      SELECT spm0.*
      FROM public.sage_party_mappings spm0
      WHERE spm0.platform_party_type = 'retailer_supplier'
        AND spm0.platform_party_id = st.retailer_id
        AND spm0.active = true
      ORDER BY spm0.verified_at DESC NULLS LAST, spm0.updated_at DESC NULLS LAST
      LIMIT 1
    ) spm ON true
    LEFT JOIN LATERAL public.internal_completion_loyalty_wallet_bank_account_resolver_v1(st.destination_in_statement_line_id) wr ON true
    LEFT JOIN public.cash_posting_snapshots existing
      ON existing.active = true
     AND existing.idempotency_key = ('completion-loyalty-supplier-wallet:' || st.order_funding_event_id::text || ':' || COALESCE(st.supplier_invoice_id::text, 'missing') || ':' || COALESCE(wr.wallet_code, 'missing'))
    LEFT JOIN public.cash_posting_batch_rows existing_row
      ON existing_row.active = true
     AND existing_row.snapshot_id = existing.id
    LEFT JOIN public.cash_posting_batches existing_batch
      ON existing_batch.id = existing_row.batch_id
     AND existing_batch.active = true
  ), finalised AS (
    SELECT
      e.*,
      CASE
        WHEN e.amount_gbp <= 0 THEN 'applied_loyalty_amount_must_be_positive'
        WHEN e.destination_in_statement_line_id IS NULL THEN 'released_funding_destination_wallet_not_found'
        WHEN e.wallet_blocker IS NOT NULL THEN e.wallet_blocker
        WHEN e.supplier_invoice_id IS NULL THEN 'supplier_invoice_not_found_for_order'
        WHEN e.supplier_ap_snapshot_id IS NULL OR NULLIF(trim(COALESCE(e.target_sage_purchase_invoice_id, '')), '') IS NULL THEN 'supplier_purchase_invoice_not_posted_to_sage'
        WHEN NULLIF(trim(COALESCE(e.supplier_sage_contact_id, '')), '') IS NULL THEN 'retailer_supplier_sage_contact_missing'
        WHEN e.supplier_ap_amount_gbp > 0 AND e.amount_gbp > e.supplier_ap_amount_gbp + 0.01 THEN 'loyalty_payment_exceeds_posted_supplier_invoice_amount'
        WHEN e.existing_snapshot_id IS NOT NULL THEN 'already_frozen'
        ELSE NULL::text
      END AS final_blocker
    FROM enriched e
  ), filtered AS (
    SELECT f.*
    FROM finalised f
    WHERE v_search IS NULL
       OR lower(concat_ws(' ', f.order_ref, f.importer_name, f.retailer_name, f.supplier_invoice_ref, f.wallet_code, f.amount_gbp::text, f.existing_batch_ref, f.final_blocker)) LIKE '%' || v_search || '%'
  )
  SELECT
    f.order_funding_event_id,
    f.order_id,
    f.order_ref,
    f.importer_id,
    f.importer_name,
    f.retailer_id,
    f.retailer_name,
    f.supplier_invoice_id,
    f.supplier_invoice_ref,
    f.supplier_ap_snapshot_id,
    f.target_sage_purchase_invoice_id,
    f.supplier_sage_contact_id,
    f.supplier_sage_contact_name,
    f.source_credit_ledger_id,
    f.destination_in_statement_line_id,
    f.wallet_code,
    f.bank_account_mapping_code,
    f.sage_bank_account_id,
    f.amount_gbp,
    f.posting_date,
    CASE WHEN f.final_blocker IS NULL THEN 'ready_to_freeze_loyalty_supplier_wallet_payment' ELSE 'blocked' END::text,
    f.final_blocker,
    f.existing_snapshot_id,
    f.existing_batch_id,
    f.existing_batch_ref,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.posting_date DESC NULLS LAST, f.order_ref, f.wallet_code
  LIMIT v_limit OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_create_completion_loyalty_supplier_wallet_cash_batch_v1(
  p_order_funding_event_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  order_funding_event_id uuid,
  snapshot_id uuid,
  batch_id uuid,
  batch_ref text,
  row_status text,
  blocker text,
  amount_gbp numeric,
  wallet_code text,
  detail_href text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_batch_id uuid;
  v_batch_ref text;
  v_valid_count integer := 0;
  v_total_amount numeric(18,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: completion-loyalty supplier wallet freeze requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for completion-loyalty supplier wallet freeze.'; END IF;
  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;

  IF COALESCE(array_length(p_order_funding_event_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'Select at least one completion-loyalty credit_applied event.';
  END IF;

  WITH selected AS (
    SELECT DISTINCT unnest(p_order_funding_event_ids)::uuid AS order_funding_event_id
  ), candidates AS (
    SELECT c.*
    FROM selected s
    LEFT JOIN LATERAL (
      SELECT c0.*
      FROM public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(NULL, 300, 0) c0
      WHERE c0.order_funding_event_id = s.order_funding_event_id
      LIMIT 1
    ) c ON true
  ), inserted AS (
    INSERT INTO public.cash_posting_snapshots (
      posting_category,
      source_type,
      source_id,
      statement_line_id,
      order_id,
      order_ref,
      counterparty_type,
      counterparty_id,
      counterparty_name,
      sage_contact_id,
      sage_contact_name,
      sage_bank_account_id,
      amount_gbp,
      posting_date,
      short_reference,
      idempotency_key,
      request_payload,
      internal_reference_json,
      freeze_status,
      validation_status,
      validation_errors,
      notes,
      validated_at,
      created_by_staff_id
    )
    SELECT
      'supplier_invoice_payment',
      'completion_loyalty_supplier_wallet_payment',
      c.order_funding_event_id,
      c.destination_in_statement_line_id,
      c.order_id,
      c.order_ref,
      'retailer_supplier',
      c.retailer_id,
      c.retailer_name,
      c.supplier_sage_contact_id,
      c.supplier_sage_contact_name,
      c.wallet_sage_bank_account_id,
      c.amount_gbp,
      c.posting_date,
      ('CLSP-' || left(c.order_funding_event_id::text, 8))::text,
      ('completion-loyalty-supplier-wallet:' || c.order_funding_event_id::text || ':' || c.supplier_invoice_id::text || ':' || c.wallet_code)::text,
      jsonb_build_object(
        'endpoint', '/contact_payments',
        'method', 'POST',
        'posting_category', 'supplier_invoice_payment',
        'source_lane', 'completion_loyalty_supplier_wallet_payment',
        'contact_payment', jsonb_build_object(
          'transaction_type_id', 'VENDOR_PAYMENT',
          'contact_id', c.supplier_sage_contact_id,
          'bank_account_id', c.wallet_sage_bank_account_id,
          'date', c.posting_date::text,
          'total_amount', c.amount_gbp,
          'reference', ('CLSP-' || left(c.order_funding_event_id::text, 8)),
          'allocated_artefacts', jsonb_build_array(jsonb_build_object('artefact_id', c.target_sage_purchase_invoice_id, 'amount', c.amount_gbp))
        ),
        'allocation_target', jsonb_build_object(
          'purchase_invoice_id', c.target_sage_purchase_invoice_id,
          'target_sage_object_id', c.target_sage_purchase_invoice_id,
          'supplier_invoice_id', c.supplier_invoice_id,
          'supplier_ap_snapshot_id', c.supplier_ap_snapshot_id,
          'amount', c.amount_gbp,
          'matched_target_ref', c.supplier_invoice_ref
        )
      ),
      jsonb_build_object(
        'source_lane', 'completion_loyalty_supplier_wallet_payment',
        'order_funding_event_id', c.order_funding_event_id,
        'source_credit_ledger_id', c.source_credit_ledger_id,
        'destination_in_statement_line_id', c.destination_in_statement_line_id,
        'wallet_code', c.wallet_code,
        'wallet_bank_account_mapping_code', c.wallet_bank_account_mapping_code,
        'wallet_sage_bank_account_id', c.wallet_sage_bank_account_id,
        'supplier_invoice_id', c.supplier_invoice_id,
        'supplier_invoice_ref', c.supplier_invoice_ref,
        'supplier_ap_snapshot_id', c.supplier_ap_snapshot_id,
        'target_sage_purchase_invoice_id', c.target_sage_purchase_invoice_id,
        'notes', p_notes
      ),
      'frozen',
      'validated',
      '[]'::jsonb,
      p_notes,
      now(),
      v_staff_id
    FROM candidates c
    WHERE c.blocker IS NULL
    ON CONFLICT (idempotency_key) WHERE active = true DO NOTHING
    RETURNING id, source_id, amount_gbp
  ), batchable AS (
    SELECT s.id AS snapshot_id, s.source_id, s.amount_gbp, s.idempotency_key, s.request_payload, s.posting_category
    FROM public.cash_posting_snapshots s
    JOIN selected sel ON sel.order_funding_event_id = s.source_id
    LEFT JOIN public.cash_posting_batch_rows existing_row ON existing_row.snapshot_id = s.id AND existing_row.active = true
    WHERE s.active = true
      AND s.source_type = 'completion_loyalty_supplier_wallet_payment'
      AND s.posting_category = 'supplier_invoice_payment'
      AND s.validation_status = 'validated'
      AND s.sage_posting_status <> 'posted'
      AND existing_row.id IS NULL
  )
  SELECT count(*)::integer, round(COALESCE(sum(amount_gbp), 0)::numeric, 2)
  INTO v_valid_count, v_total_amount
  FROM batchable;

  IF v_valid_count > 0 THEN
    v_batch_ref := 'CLSPB-' || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || substr(md5(gen_random_uuid()::text), 1, 6);

    INSERT INTO public.cash_posting_batches (
      batch_ref,
      posting_category,
      batch_status,
      row_count,
      total_amount_gbp,
      notes,
      created_by_staff_id
    ) VALUES (
      v_batch_ref,
      'supplier_invoice_payment',
      'validated',
      v_valid_count,
      v_total_amount,
      NULLIF(p_notes, ''),
      v_staff_id
    ) RETURNING id, batch_ref INTO v_batch_id, v_batch_ref;

    INSERT INTO public.cash_posting_batch_rows (
      batch_id,
      snapshot_id,
      source_id,
      posting_category,
      idempotency_key,
      amount_gbp,
      validation_status,
      posting_status,
      request_payload
    )
    SELECT
      v_batch_id,
      b.snapshot_id,
      b.source_id,
      b.posting_category,
      b.idempotency_key,
      b.amount_gbp,
      'validated',
      'not_posted',
      b.request_payload
    FROM batchable b;
  END IF;

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT unnest(p_order_funding_event_ids)::uuid AS order_funding_event_id
  ), candidates AS (
    SELECT s.order_funding_event_id, c.*
    FROM selected s
    LEFT JOIN LATERAL (
      SELECT c0.*
      FROM public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(NULL, 300, 0) c0
      WHERE c0.order_funding_event_id = s.order_funding_event_id
      LIMIT 1
    ) c ON true
  ), snapshots AS (
    SELECT c.order_funding_event_id, cps.id AS snapshot_id, cps.amount_gbp, cps.internal_reference_json->>'wallet_code' AS wallet_code
    FROM candidates c
    LEFT JOIN public.cash_posting_snapshots cps
      ON cps.active = true
     AND cps.idempotency_key = ('completion-loyalty-supplier-wallet:' || c.order_funding_event_id::text || ':' || COALESCE(c.supplier_invoice_id::text, 'missing') || ':' || COALESCE(c.wallet_code, 'missing'))
  ), batch_rows AS (
    SELECT s.order_funding_event_id, br.batch_id, b.batch_ref
    FROM snapshots s
    LEFT JOIN public.cash_posting_batch_rows br ON br.snapshot_id = s.snapshot_id AND br.active = true
    LEFT JOIN public.cash_posting_batches b ON b.id = br.batch_id AND b.active = true
  )
  SELECT
    c.order_funding_event_id,
    s.snapshot_id,
    br.batch_id,
    br.batch_ref,
    CASE
      WHEN c.order_funding_event_id IS NULL THEN 'blocked'
      WHEN c.blocker IS NOT NULL AND c.blocker <> 'already_frozen' THEN 'blocked'
      WHEN br.batch_id IS NOT NULL AND br.batch_id = v_batch_id THEN 'batched_validated'
      WHEN br.batch_id IS NOT NULL THEN 'already_batched'
      WHEN s.snapshot_id IS NOT NULL THEN 'frozen_not_batched'
      ELSE 'not_frozen'
    END::text AS row_status,
    CASE
      WHEN c.order_funding_event_id IS NULL THEN 'candidate_not_found'
      WHEN c.blocker = 'already_frozen' THEN NULL::text
      ELSE c.blocker
    END AS blocker,
    COALESCE(s.amount_gbp, c.amount_gbp),
    COALESCE(s.wallet_code, c.wallet_code),
    CASE WHEN br.batch_id IS NOT NULL THEN ('/internal/accounting-command-centre/cash-posting/batches/' || br.batch_id::text) ELSE NULL::text END AS detail_href
  FROM candidates c
  LEFT JOIN snapshots s ON s.order_funding_event_id = c.order_funding_event_id
  LEFT JOIN batch_rows br ON br.order_funding_event_id = c.order_funding_event_id
  ORDER BY c.order_funding_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_wallet_bank_account_resolver_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_create_completion_loyalty_supplier_wallet_cash_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_wallet_bank_account_resolver_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_create_completion_loyalty_supplier_wallet_cash_batch_v1(uuid[], text) TO authenticated;

COMMENT ON FUNCTION public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(text, integer, integer) IS 'Read-only candidates for completion-loyalty supplier payments from Virtual GBP or DVA GHS wallet bank accounts. Does not touch DVA_CASH_BANK_ACCOUNT.';
COMMENT ON FUNCTION public.staff_create_completion_loyalty_supplier_wallet_cash_batch_v1(uuid[], text) IS 'Freezes completion-loyalty supplier wallet payments into existing cash posting snapshots/batches using the loyalty wallet Sage bank account id. No Sage API call.';

NOTIFY pgrst, 'reload schema';

COMMIT;
