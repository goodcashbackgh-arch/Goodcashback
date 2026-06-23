BEGIN;

-- Final-balance cash posting bridge.
-- Exposes confirmed DVA/card final_balance_payment allocations as customer receipt
-- cash-posting rows so the existing freeze -> contact_payment -> allocation flow can be reused.
-- No Sage API call here.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN
    RAISE EXCEPTION 'Missing public.sage_mapping_settings';
  END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN
    RAISE EXCEPTION 'Missing public.sage_party_mappings';
  END IF;
  IF to_regclass('public.dva_reconciliation') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_reconciliation';
  END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_lines';
  END IF;
  IF to_regclass('public.dva_statement_line_allocation_detail_vw') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_line_allocation_detail_vw';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing public.sage_posting_snapshots';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_cash_posting_workbench_rows_v1(
  p_direction text DEFAULT 'all',
  p_category text DEFAULT 'all',
  p_status text DEFAULT 'all',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  queue_row_id text,
  source_type text,
  source_id uuid,
  statement_line_id uuid,
  statement_id uuid,
  statement_date_text text,
  direction text,
  category text,
  counterparty_type text,
  counterparty_id uuid,
  counterparty_name text,
  order_id uuid,
  order_ref text,
  auth_ref text,
  reference_raw text,
  amount_local numeric,
  local_currency text,
  amount_gbp numeric,
  matched_target_type text,
  matched_target_id uuid,
  matched_target_ref text,
  sage_contact_id text,
  sage_contact_name text,
  sage_bank_account_id text,
  target_sage_object_id text,
  posting_status text,
  blocker text,
  selectable boolean,
  detail_json jsonb,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_direction text := lower(COALESCE(NULLIF(trim(p_direction), ''), 'all'));
  v_category text := lower(COALESCE(NULLIF(trim(p_category), ''), 'all'));
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'all'));
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: cash posting workbench requires auth.uid()';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for cash posting workbench.';
  END IF;

  RETURN QUERY
  WITH cash_defaults AS (
    SELECT
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'DVA_CASH_BANK_ACCOUNT' AND is_active = true) AS bank_account_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'FX_CARD_GAIN_LEDGER' AND is_active = true) AS fx_gain_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'FX_CARD_LOSS_LEDGER' AND is_active = true) AS fx_loss_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'BANK_FEE_LEDGER' AND is_active = true) AS bank_fee_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'BANK_FEE_TAX_RATE' AND is_active = true) AS bank_fee_tax_rate_id
    FROM public.sage_mapping_settings
  ), customer_receipts AS (
    SELECT
      ('cash:customer_receipt_on_account:' || dr.id::text)::text AS queue_row_id,
      'dva_reconciliation'::text AS source_type,
      dr.id AS source_id,
      dsl.id AS statement_line_id,
      dsl.dva_statement_id AS statement_id,
      COALESCE(to_jsonb(dsl)->>'statement_date', to_jsonb(dsl)->>'transaction_date')::text AS statement_date_text,
      'in'::text AS direction,
      'customer_receipt_on_account'::text AS category,
      'importer_customer'::text AS counterparty_type,
      o.importer_id AS counterparty_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS counterparty_name,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id')::text AS auth_ref,
      (to_jsonb(dsl)->>'reference_raw')::text AS reference_raw,
      NULLIF(to_jsonb(dsl)->>'amount_local_ccy', '')::numeric AS amount_local,
      COALESCE(to_jsonb(dsl)->>'local_ccy', to_jsonb(dsl)->>'currency')::text AS local_currency,
      round(COALESCE(dr.reconciled_gbp_amount, dsl.amount_gbp_equivalent, 0)::numeric, 2) AS amount_gbp,
      'payment_on_account'::text AS matched_target_type,
      o.id AS matched_target_id,
      ('Payment on account · ' || COALESCE(o.order_ref::text, o.id::text))::text AS matched_target_ref,
      pm.sage_contact_id::text,
      pm.sage_contact_display_name::text,
      cd.bank_account_id::text,
      NULL::text AS target_sage_object_id,
      CASE
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'blocked_missing_sage_contact'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'blocked_missing_sage_bank_account'
        WHEN COALESCE(to_jsonb(dsl)->>'direction', '') <> 'in' THEN 'blocked_statement_not_in'
        WHEN round(COALESCE(dr.reconciled_gbp_amount, dsl.amount_gbp_equivalent, 0)::numeric, 2) <= 0 THEN 'blocked_invalid_amount'
        ELSE 'ready_to_freeze'
      END::text AS posting_status,
      CASE
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'importer/customer Sage contact mapping missing'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN COALESCE(to_jsonb(dsl)->>'direction', '') <> 'in' THEN 'DVA funding statement line is not IN'
        WHEN round(COALESCE(dr.reconciled_gbp_amount, dsl.amount_gbp_equivalent, 0)::numeric, 2) <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS blocker,
      (NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NOT NULL AND NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NOT NULL AND COALESCE(to_jsonb(dsl)->>'direction', '') = 'in') AS selectable,
      jsonb_build_object(
        'statement_line_id', dsl.id,
        'dva_reconciliation_id', dr.id,
        'order_id', o.id,
        'order_ref', o.order_ref,
        'posting_category', 'customer_receipt_on_account',
        'short_reference', ('GCB-IN-' || COALESCE(o.order_ref::text, left(o.id::text, 8)) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10)),
        'endpoint', 'POST /contact_payments',
        'transaction_type_id', 'CUSTOMER_RECEIPT'
      ) AS detail_json
    FROM public.dva_reconciliation dr
    JOIN public.dva_statement_lines dsl ON dsl.id = dr.dva_statement_line_id
    JOIN public.orders o ON o.id = dr.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    CROSS JOIN cash_defaults cd
    LEFT JOIN LATERAL (
      SELECT * FROM public.sage_party_mappings spm
      WHERE spm.platform_party_type = 'importer_customer'
        AND spm.platform_party_id = o.importer_id
        AND spm.active = true
      ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
    WHERE dr.reconciliation_type = 'order_funding'
  ), final_balance_receipts AS (
    SELECT
      ('cash:customer_receipt_on_account:' || adv.allocation_id::text)::text AS queue_row_id,
      'dva_final_balance_allocation'::text AS source_type,
      adv.allocation_id AS source_id,
      adv.dva_statement_line_id AS statement_line_id,
      adv.dva_statement_id AS statement_id,
      COALESCE(adv.statement_date::text, adv.transaction_date::text)::text AS statement_date_text,
      adv.statement_direction::text AS direction,
      'customer_receipt_on_account'::text AS category,
      'importer_customer'::text AS counterparty_type,
      o.importer_id AS counterparty_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS counterparty_name,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      COALESCE(o.payment_auth_id::text, '') AS auth_ref,
      adv.statement_reference::text AS reference_raw,
      NULL::numeric AS amount_local,
      NULL::text AS local_currency,
      round(COALESCE(adv.allocated_gbp_amount, 0)::numeric, 2) AS amount_gbp,
      'payment_on_account_final_balance'::text AS matched_target_type,
      o.id AS matched_target_id,
      ('Final balance payment · ' || COALESCE(o.order_ref::text, o.id::text))::text AS matched_target_ref,
      pm.sage_contact_id::text,
      pm.sage_contact_display_name::text,
      cd.bank_account_id::text,
      NULL::text AS target_sage_object_id,
      CASE
        WHEN adv.allocation_status <> 'confirmed' THEN 'blocked_allocation_not_confirmed'
        WHEN adv.statement_direction <> 'in' THEN 'blocked_statement_not_in'
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'blocked_missing_sage_contact'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'blocked_missing_sage_bank_account'
        WHEN round(COALESCE(adv.allocated_gbp_amount, 0)::numeric, 2) <= 0 THEN 'blocked_invalid_amount'
        ELSE 'ready_to_freeze'
      END::text AS posting_status,
      CASE
        WHEN adv.allocation_status <> 'confirmed' THEN 'final-balance allocation is not confirmed'
        WHEN adv.statement_direction <> 'in' THEN 'final-balance payment statement line is not IN'
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'importer/customer Sage contact mapping missing'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN round(COALESCE(adv.allocated_gbp_amount, 0)::numeric, 2) <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS blocker,
      (
        adv.allocation_status = 'confirmed'
        AND adv.statement_direction = 'in'
        AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NOT NULL
        AND NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NOT NULL
        AND round(COALESCE(adv.allocated_gbp_amount, 0)::numeric, 2) > 0
      ) AS selectable,
      jsonb_build_object(
        'allocation_id', adv.allocation_id,
        'allocation_type', adv.allocation_type,
        'statement_line_id', adv.dva_statement_line_id,
        'order_id', o.id,
        'order_ref', o.order_ref,
        'auth_ref', o.payment_auth_id,
        'posting_category', 'customer_receipt_on_account',
        'source_type', 'dva_final_balance_allocation',
        'short_reference', ('GCB-IN-FB-' || left(COALESCE(o.order_ref::text, o.id::text), 16) || '-' || left(adv.allocation_id::text, 8)),
        'endpoint', 'POST /contact_payments',
        'transaction_type_id', 'CUSTOMER_RECEIPT',
        'matched_target_type', 'payment_on_account_final_balance',
        'matched_target_ref', ('Final balance payment · ' || COALESCE(o.order_ref::text, o.id::text))
      ) AS detail_json
    FROM public.dva_statement_line_allocation_detail_vw adv
    JOIN public.orders o ON o.id = adv.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    CROSS JOIN cash_defaults cd
    LEFT JOIN LATERAL (
      SELECT * FROM public.sage_party_mappings spm
      WHERE spm.platform_party_type = 'importer_customer'
        AND spm.platform_party_id = o.importer_id
        AND spm.active = true
      ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
    WHERE adv.allocation_status = 'confirmed'
      AND adv.allocation_type = 'final_balance_payment'
  ), allocation_rows AS (
    SELECT
      ('cash:' || CASE WHEN adv.allocation_type = 'supplier_invoice' THEN 'supplier_invoice_payment' WHEN adv.allocation_type = 'retailer_refund' THEN 'retailer_refund_received' ELSE adv.allocation_type END || ':' || adv.allocation_id::text)::text AS queue_row_id,
      'dva_statement_line_allocation'::text AS source_type,
      adv.allocation_id AS source_id,
      adv.dva_statement_line_id AS statement_line_id,
      adv.dva_statement_id AS statement_id,
      COALESCE(adv.statement_date::text, adv.transaction_date::text)::text AS statement_date_text,
      adv.statement_direction::text AS direction,
      CASE WHEN adv.allocation_type = 'supplier_invoice' THEN 'supplier_invoice_payment' WHEN adv.allocation_type = 'retailer_refund' THEN 'retailer_refund_received' ELSE adv.allocation_type END::text AS category,
      CASE WHEN adv.allocation_type IN ('supplier_invoice','retailer_refund') THEN 'retailer_supplier' ELSE 'ledger_or_hold' END::text AS counterparty_type,
      CASE WHEN adv.allocation_type IN ('supplier_invoice','retailer_refund') THEN o.retailer_id ELSE NULL::uuid END AS counterparty_id,
      CASE WHEN adv.allocation_type IN ('supplier_invoice','retailer_refund') THEN COALESCE(r.name::text, 'Retailer/supplier') WHEN adv.allocation_type = 'bank_fee' THEN 'Bank/provider/card fee' WHEN adv.allocation_type = 'fx_card_difference' THEN 'FX/card residual' ELSE 'Unmatched/hold' END::text AS counterparty_name,
      COALESCE(adv.order_id, si.order_id) AS order_id,
      adv.order_ref::text AS order_ref,
      NULL::text AS auth_ref,
      adv.statement_reference::text AS reference_raw,
      NULL::numeric AS amount_local,
      NULL::text AS local_currency,
      round(COALESCE(adv.allocated_gbp_amount, 0)::numeric, 2) AS amount_gbp,
      CASE WHEN adv.allocation_type = 'supplier_invoice' THEN 'posted_purchase_invoice' WHEN adv.allocation_type = 'retailer_refund' THEN 'retailer_refund_credit_note' WHEN adv.allocation_type = 'bank_fee' THEN 'bank_fee_ledger' WHEN adv.allocation_type = 'fx_card_difference' THEN 'fx_card_difference_ledger' ELSE 'hold_or_exception' END::text AS matched_target_type,
      COALESCE(adv.supplier_invoice_id, adv.dispute_id, adv.dva_statement_line_id) AS matched_target_id,
      COALESCE(adv.supplier_invoice_ref::text, adv.dispute_id::text, adv.allocation_type::text) AS matched_target_ref,
      pm.sage_contact_id::text,
      pm.sage_contact_display_name::text,
      cd.bank_account_id::text,
      posted.sage_invoice_id::text AS target_sage_object_id,
      CASE
        WHEN adv.allocation_status <> 'confirmed' THEN 'blocked_allocation_not_confirmed'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'blocked_missing_sage_bank_account'
        WHEN adv.allocation_type = 'supplier_invoice' AND NULLIF(trim(COALESCE(posted.sage_invoice_id, '')), '') IS NULL THEN 'blocked_target_invoice_not_posted'
        WHEN adv.allocation_type = 'supplier_invoice' AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'blocked_missing_sage_contact'
        WHEN adv.allocation_type = 'retailer_refund' THEN 'blocked_endpoint_prove_required'
        WHEN adv.allocation_type = 'bank_fee' AND NULLIF(trim(COALESCE(cd.bank_fee_ledger_id, '')), '') IS NULL THEN 'blocked_bank_fee_ledger_missing'
        WHEN adv.allocation_type = 'bank_fee' AND NULLIF(trim(COALESCE(cd.bank_fee_tax_rate_id, '')), '') IS NULL THEN 'blocked_bank_fee_tax_rate_missing'
        WHEN adv.allocation_type = 'fx_card_difference' AND (NULLIF(trim(COALESCE(cd.fx_gain_ledger_id, '')), '') IS NULL OR NULLIF(trim(COALESCE(cd.fx_loss_ledger_id, '')), '') IS NULL) THEN 'blocked_fx_ledger_missing'
        WHEN adv.allocation_type IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'blocked_hold_requires_decision'
        ELSE 'ready_to_freeze'
      END::text AS posting_status,
      CASE
        WHEN adv.allocation_status <> 'confirmed' THEN 'allocation is not confirmed'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN adv.allocation_type = 'supplier_invoice' AND NULLIF(trim(COALESCE(posted.sage_invoice_id, '')), '') IS NULL THEN 'matched supplier purchase invoice has not been posted to Sage'
        WHEN adv.allocation_type = 'supplier_invoice' AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'retailer/supplier Sage contact mapping missing'
        WHEN adv.allocation_type = 'retailer_refund' THEN 'retailer refund IN endpoint/allocation route must be proven before bulk posting'
        WHEN adv.allocation_type = 'bank_fee' AND NULLIF(trim(COALESCE(cd.bank_fee_ledger_id, '')), '') IS NULL THEN 'BANK_FEE_LEDGER mapping missing'
        WHEN adv.allocation_type = 'bank_fee' AND NULLIF(trim(COALESCE(cd.bank_fee_tax_rate_id, '')), '') IS NULL THEN 'BANK_FEE_TAX_RATE mapping missing'
        WHEN adv.allocation_type = 'fx_card_difference' AND (NULLIF(trim(COALESCE(cd.fx_gain_ledger_id, '')), '') IS NULL OR NULLIF(trim(COALESCE(cd.fx_loss_ledger_id, '')), '') IS NULL) THEN 'FX gain/loss ledger mappings missing'
        WHEN adv.allocation_type IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'hold/unmatched row requires accounting decision'
        ELSE NULL::text
      END AS blocker,
      (
        adv.allocation_status = 'confirmed'
        AND NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NOT NULL
        AND (
          (
            adv.allocation_type = 'supplier_invoice'
            AND NULLIF(trim(COALESCE(posted.sage_invoice_id, '')), '') IS NOT NULL
            AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NOT NULL
          )
          OR (
            adv.allocation_type = 'bank_fee'
            AND NULLIF(trim(COALESCE(cd.bank_fee_ledger_id, '')), '') IS NOT NULL
            AND NULLIF(trim(COALESCE(cd.bank_fee_tax_rate_id, '')), '') IS NOT NULL
          )
          OR (
            adv.allocation_type = 'fx_card_difference'
            AND NULLIF(trim(COALESCE(cd.fx_gain_ledger_id, '')), '') IS NOT NULL
            AND NULLIF(trim(COALESCE(cd.fx_loss_ledger_id, '')), '') IS NOT NULL
          )
        )
      ) AS selectable,
      jsonb_build_object(
        'allocation_id', adv.allocation_id,
        'allocation_type', adv.allocation_type,
        'supplier_invoice_id', adv.supplier_invoice_id,
        'supplier_invoice_ref', adv.supplier_invoice_ref,
        'order_id', COALESCE(adv.order_id, si.order_id),
        'order_ref', adv.order_ref,
        'posting_category', CASE WHEN adv.allocation_type = 'supplier_invoice' THEN 'supplier_invoice_payment' WHEN adv.allocation_type = 'retailer_refund' THEN 'retailer_refund_received' ELSE adv.allocation_type END,
        'target_sage_object_id', posted.sage_invoice_id,
        'short_reference', ('GCB-OUT-' || left(COALESCE(adv.supplier_invoice_ref::text, adv.order_ref::text, adv.allocation_id::text), 18)),
        'endpoint', CASE
          WHEN adv.allocation_type = 'supplier_invoice' THEN 'POST /purchase_payments then POST /allocations'
          WHEN adv.allocation_type = 'bank_fee' THEN 'POST /other_payments'
          WHEN adv.allocation_type = 'fx_card_difference' THEN 'POST /journals'
          ELSE 'endpoint_prove_required'
        END
      ) AS detail_json
    FROM public.dva_statement_line_allocation_detail_vw adv
    CROSS JOIN cash_defaults cd
    LEFT JOIN public.supplier_invoices si ON si.id = adv.supplier_invoice_id
    LEFT JOIN public.orders o ON o.id = COALESCE(adv.order_id, si.order_id)
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    LEFT JOIN LATERAL (
      SELECT * FROM public.sage_party_mappings spm
      WHERE spm.platform_party_type = 'retailer_supplier'
        AND spm.platform_party_id = o.retailer_id
        AND spm.active = true
      ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
    LEFT JOIN LATERAL (
      SELECT sps.sage_invoice_id
      FROM public.sage_posting_snapshots sps
      WHERE sps.document_lane = 'supplier_goods_ap'
        AND sps.source_id = adv.supplier_invoice_id
        AND sps.sage_posting_status = 'posted'
        AND NULLIF(trim(COALESCE(sps.sage_invoice_id, '')), '') IS NOT NULL
      ORDER BY sps.sage_posted_at DESC NULLS LAST, sps.created_at DESC
      LIMIT 1
    ) posted ON true
    WHERE adv.allocation_status = 'confirmed'
      AND adv.allocation_type <> 'final_balance_payment'
  ), all_rows AS (
    SELECT * FROM customer_receipts
    UNION ALL
    SELECT * FROM final_balance_receipts
    UNION ALL
    SELECT * FROM allocation_rows
  ), filtered AS (
    SELECT ar.* FROM all_rows ar
    WHERE (v_direction = 'all' OR lower(ar.direction) = v_direction)
      AND (v_category = 'all' OR lower(ar.category) = v_category)
      AND (v_status = 'all' OR lower(ar.posting_status) = v_status OR (v_status = 'blocked' AND lower(ar.posting_status) LIKE 'blocked%') OR (v_status = 'ready' AND lower(ar.posting_status) = 'ready_to_freeze')
      AND (v_search IS NULL OR lower(concat_ws(' ', ar.counterparty_name, ar.order_ref, ar.auth_ref, ar.reference_raw, ar.matched_target_ref, ar.category, ar.source_type, ar.blocker)) LIKE '%' || v_search || '%')
  )
  SELECT f.*, count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date_text DESC NULLS LAST, f.category, f.counterparty_name, f.queue_row_id
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text, text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text, text, text, text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text, text, text, text, integer, integer) IS
'Cash posting rows including original customer DVA reconciliation receipts and confirmed final-balance DVA/card IN allocations bridged as customer receipt/payment-on-account rows. No freeze, validate or Sage post.';

NOTIFY pgrst, 'reload schema';

COMMIT;
