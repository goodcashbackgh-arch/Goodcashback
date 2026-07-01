BEGIN;

-- Completion loyalty supplier wallet payment source fix v1.
-- Replace only the candidate resolver. The first bridge joined from credit_applied
-- events to funding matches; this uses the repo's existing reversal/accounting
-- trace direction instead: released match -> credit ledger -> applied debit row ->
-- order_funding_events.credit_applied.
-- No changes to DVA_CASH_BANK_ACCOUNT, existing cash workbench rows, or Sage posters.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_events'; END IF;
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.importers') IS NULL THEN RAISE EXCEPTION 'Missing public.importers'; END IF;
  IF to_regclass('public.retailers') IS NULL THEN RAISE EXCEPTION 'Missing public.retailers'; END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoices'; END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_posting_snapshots'; END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_party_mappings'; END IF;
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_snapshots'; END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_batch_rows'; END IF;
  IF to_regclass('public.cash_posting_batches') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_batches'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_wallet_bank_account_resolver_v1(uuid)') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_completion_loyalty_wallet_bank_account_resolver_v1(uuid)'; END IF;
END $$;

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
  WITH applied_from_released_matches AS (
    SELECT
      ofe.id AS order_funding_event_id,
      ofe.order_id,
      o.order_ref::text AS order_ref,
      o.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      o.retailer_id,
      COALESCE(r.name::text, 'Retailer/supplier')::text AS retailer_name,
      lm.credit_ledger_id AS source_credit_ledger_id,
      lm.destination_in_statement_line_id,
      round(abs(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      COALESCE(NULLIF(to_jsonb(ofe)->>'created_at', '')::timestamptz::date, now()::date) AS posting_date
    FROM public.main_bank_completion_loyalty_funding_matches lm
    JOIN LATERAL (
      SELECT d.id AS debit_ledger_id
      FROM public.importer_credit_ledger d
      WHERE d.direction = 'debit'
        AND d.lock_reason IS NULL
        AND (
          (COALESCE(d.source_table, '') = 'importer_credit_ledger' AND d.source_id = lm.credit_ledger_id)
          OR (COALESCE(d.source_entity_type, '') = 'importer_credit_ledger' AND d.source_entity_id = lm.credit_ledger_id)
        )
    ) debit ON true
    JOIN public.order_funding_events ofe
      ON ofe.event_type = 'credit_applied'
     AND ofe.source_entity_type = 'importer_credit_ledger'
     AND ofe.source_entity_id = debit.debit_ledger_id
    JOIN public.orders o ON o.id = ofe.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    WHERE lm.match_status = 'released_available_dashboard_credit'
      AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
      AND lm.credit_ledger_id IS NOT NULL
      AND lm.destination_in_statement_line_id IS NOT NULL
      AND o.importer_id = lm.importer_id
  ), supplier_target AS (
    SELECT
      a.*,
      si.id AS supplier_invoice_id,
      COALESCE(si.ocr_invoice_ref, si.invoice_ref, si.id::text)::text AS supplier_invoice_ref,
      sps.id AS supplier_ap_snapshot_id,
      sps.sage_invoice_id::text AS target_sage_purchase_invoice_id,
      round(COALESCE(sps.amount_gbp, 0)::numeric, 2) AS supplier_ap_amount_gbp
    FROM applied_from_released_matches a
    LEFT JOIN LATERAL (
      SELECT si0.*
      FROM public.supplier_invoices si0
      WHERE si0.order_id = a.order_id
        AND (si0.review_status IN ('approved_current','ref_corrected_approved') OR COALESCE(si0.is_current_for_order, false) = true)
      ORDER BY COALESCE(
        NULLIF(to_jsonb(si0)->>'reviewed_at', '')::timestamptz,
        NULLIF(to_jsonb(si0)->>'created_at', '')::timestamptz,
        now()
      ) DESC
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
      existing.existing_snapshot_id,
      existing.existing_batch_id,
      existing.existing_batch_ref
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
    LEFT JOIN LATERAL (
      SELECT
        cps.id AS existing_snapshot_id,
        cb.id AS existing_batch_id,
        cb.batch_ref AS existing_batch_ref
      FROM public.cash_posting_snapshots cps
      LEFT JOIN public.cash_posting_batch_rows cbr ON cbr.snapshot_id = cps.id AND cbr.active = true
      LEFT JOIN public.cash_posting_batches cb ON cb.id = cbr.batch_id AND cb.active = true
      WHERE cps.active = true
        AND cps.idempotency_key = ('completion-loyalty-supplier-wallet:' || st.order_funding_event_id::text || ':' || COALESCE(st.supplier_invoice_id::text, 'missing') || ':' || COALESCE(wr.wallet_code, 'missing'))
      ORDER BY cps.created_at DESC, cbr.created_at DESC NULLS LAST
      LIMIT 1
    ) existing ON true
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
    CASE
      WHEN f.final_blocker IS NULL THEN 'ready_to_freeze_loyalty_supplier_wallet_payment'
      WHEN f.final_blocker = 'already_frozen' AND f.existing_batch_id IS NULL THEN 'frozen_ready_to_batch'
      WHEN f.final_blocker = 'already_frozen' AND f.existing_batch_id IS NOT NULL THEN 'already_batched'
      ELSE 'blocked'
    END::text,
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

COMMENT ON FUNCTION public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(text, integer, integer) IS 'Read-only candidates for completion-loyalty supplier payments from released funding matches that have been applied to orders. Does not touch DVA_CASH_BANK_ACCOUNT.';

NOTIFY pgrst, 'reload schema';

COMMIT;
