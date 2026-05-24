BEGIN;

-- Main bank -> shipper AP matching v1
-- Isolated lane: does not alter the existing importer DVA/card matching cockpit.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.shipping_documents') IS NULL THEN RAISE EXCEPTION 'Missing public.shipping_documents'; END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_posting_snapshots'; END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_party_mappings'; END IF;
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_mapping_settings'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.main_bank_shipper_ap_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_statement_line_id uuid NOT NULL REFERENCES public.dva_statement_lines(id) ON DELETE RESTRICT,
  shipping_document_id uuid NOT NULL REFERENCES public.shipping_documents(id) ON DELETE RESTRICT,
  sage_posting_snapshot_id uuid REFERENCES public.sage_posting_snapshots(id) ON DELETE SET NULL,
  sage_purchase_invoice_id text,
  allocated_gbp_amount numeric(18,2) NOT NULL CHECK (allocated_gbp_amount > 0),
  allocation_status text NOT NULL DEFAULT 'confirmed' CHECK (allocation_status IN ('confirmed','reversed')),
  notes text,
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  created_by_auth_user_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  reversed_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  reversed_by_auth_user_id uuid,
  reversed_at timestamptz,
  reversal_reason text
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_main_bank_shipper_ap_allocations_active_pair
  ON public.main_bank_shipper_ap_allocations(dva_statement_line_id, shipping_document_id)
  WHERE allocation_status = 'confirmed';

CREATE INDEX IF NOT EXISTS idx_main_bank_shipper_ap_allocations_line
  ON public.main_bank_shipper_ap_allocations(dva_statement_line_id, allocation_status);

CREATE INDEX IF NOT EXISTS idx_main_bank_shipper_ap_allocations_doc
  ON public.main_bank_shipper_ap_allocations(shipping_document_id, allocation_status);

ALTER TABLE public.main_bank_shipper_ap_allocations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS main_bank_shipper_ap_allocations_staff_select ON public.main_bank_shipper_ap_allocations;
CREATE POLICY main_bank_shipper_ap_allocations_staff_select
ON public.main_bank_shipper_ap_allocations
FOR SELECT
TO authenticated
USING (public.is_active_staff());

CREATE OR REPLACE FUNCTION public.internal_main_bank_shipper_statement_lines_v1(
  p_status text DEFAULT 'unmatched',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_id uuid,
  statement_date date,
  reference_raw text,
  direction text,
  amount_local numeric,
  local_currency text,
  amount_gbp numeric,
  allocated_gbp numeric,
  remaining_gbp numeric,
  match_status text,
  statement_account_label text,
  source_bank text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'unmatched'));
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: main bank shipper workspace requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for main bank shipper workspace.'; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      dsl.id AS statement_line_id,
      ds.id AS statement_id,
      dsl.statement_date,
      dsl.reference_raw::text,
      dsl.direction::text,
      dsl.amount_local_ccy::numeric AS amount_local,
      dsl.local_ccy::text AS local_currency,
      round(COALESCE(dsl.amount_gbp_equivalent, 0)::numeric, 2) AS amount_gbp,
      round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2) AS allocated_gbp,
      ds.statement_account_label::text,
      ds.source_bank::text
    FROM public.dva_statement_lines dsl
    JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
    LEFT JOIN public.main_bank_shipper_ap_allocations a ON a.dva_statement_line_id = dsl.id
    WHERE COALESCE(ds.statement_account_context, 'importer_dva_card_account') = 'main_company_bank_account'
      AND dsl.direction = 'out'
    GROUP BY dsl.id, ds.id, ds.statement_account_label, ds.source_bank
  ), enriched AS (
    SELECT
      b.*,
      greatest(round((b.amount_gbp - b.allocated_gbp)::numeric, 2), 0::numeric) AS remaining_gbp,
      CASE
        WHEN b.allocated_gbp <= 0 THEN 'unmatched'
        WHEN b.amount_gbp - b.allocated_gbp > 0.01 THEN 'part_allocated'
        ELSE 'balanced'
      END::text AS match_status
    FROM base b
  ), filtered AS (
    SELECT e.*
    FROM enriched e
    WHERE (v_status = 'all' OR e.match_status = v_status)
      AND (v_search IS NULL OR lower(concat_ws(' ', e.reference_raw, e.statement_date::text, e.amount_gbp::text, e.source_bank)) LIKE '%' || v_search || '%')
  )
  SELECT
    f.statement_line_id,
    f.statement_id,
    f.statement_date,
    f.reference_raw,
    f.direction,
    f.amount_local,
    f.local_currency,
    f.amount_gbp,
    f.allocated_gbp,
    f.remaining_gbp,
    f.match_status,
    f.statement_account_label,
    f.source_bank,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date DESC, f.statement_line_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_shipper_ap_posted_targets_for_main_bank_v1(
  p_status text DEFAULT 'open',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  shipping_document_id uuid,
  shipper_id uuid,
  shipper_name text,
  shipper_invoice_ref text,
  document_date date,
  amount_gbp numeric,
  allocated_gbp numeric,
  remaining_gbp numeric,
  currency_code text,
  sage_snapshot_id uuid,
  sage_purchase_invoice_id text,
  sage_reference text,
  sage_posted_at timestamptz,
  target_status text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'open'));
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: shipper AP targets require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for shipper AP targets.'; END IF;

  RETURN QUERY
  WITH posted AS (
    SELECT DISTINCT ON (sps.source_id)
      sps.id AS sage_snapshot_id,
      sps.source_id AS shipping_document_id,
      sps.reference_text,
      sps.amount_gbp,
      sps.currency_code,
      COALESCE(NULLIF(sps.sage_invoice_id, ''), NULLIF(br.sage_object_id, '')) AS sage_purchase_invoice_id,
      COALESCE(NULLIF(br.sage_reference, ''), NULLIF(sps.reference_text, '')) AS sage_reference,
      COALESCE(sps.sage_posted_at, br.posted_at) AS sage_posted_at
    FROM public.sage_posting_snapshots sps
    LEFT JOIN public.sage_posting_batch_rows br
      ON br.snapshot_id = sps.id
     AND br.posting_status = 'posted'
     AND NULLIF(br.sage_object_id, '') IS NOT NULL
    WHERE sps.active = true
      AND sps.source_table = 'shipping_documents'
      AND sps.document_lane = 'shipper_ap'
      AND sps.sage_posting_status = 'posted'
      AND COALESCE(NULLIF(sps.sage_invoice_id, ''), NULLIF(br.sage_object_id, '')) IS NOT NULL
    ORDER BY sps.source_id, COALESCE(sps.sage_posted_at, br.posted_at, sps.created_at) DESC
  ), base AS (
    SELECT
      sd.id AS shipping_document_id,
      sd.shipper_id,
      COALESCE(sh.name, p.reference_text, 'Shipper')::text AS shipper_name,
      COALESCE(NULLIF(sd.document_ref, ''), NULLIF(p.reference_text, ''), sd.id::text)::text AS shipper_invoice_ref,
      sd.document_date,
      round(COALESCE(p.amount_gbp, sd.total_amount, 0)::numeric, 2) AS amount_gbp,
      round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2) AS allocated_gbp,
      COALESCE(p.currency_code, sd.currency_code, 'GBP')::text AS currency_code,
      p.sage_snapshot_id,
      p.sage_purchase_invoice_id::text,
      p.sage_reference::text,
      p.sage_posted_at
    FROM posted p
    JOIN public.shipping_documents sd ON sd.id = p.shipping_document_id
    LEFT JOIN public.shippers sh ON sh.id = sd.shipper_id
    LEFT JOIN public.main_bank_shipper_ap_allocations a ON a.shipping_document_id = sd.id
    GROUP BY sd.id, sd.shipper_id, sh.name, p.reference_text, p.amount_gbp, p.currency_code, p.sage_snapshot_id, p.sage_purchase_invoice_id, p.sage_reference, p.sage_posted_at
  ), enriched AS (
    SELECT
      b.*,
      greatest(round((b.amount_gbp - b.allocated_gbp)::numeric, 2), 0::numeric) AS remaining_gbp,
      CASE
        WHEN b.amount_gbp - b.allocated_gbp > 0.01 THEN 'open'
        ELSE 'allocated'
      END::text AS target_status
    FROM base b
  ), filtered AS (
    SELECT e.*
    FROM enriched e
    WHERE (v_status = 'all' OR e.target_status = v_status)
      AND (v_search IS NULL OR lower(concat_ws(' ', e.shipper_name, e.shipper_invoice_ref, e.sage_reference, e.amount_gbp::text)) LIKE '%' || v_search || '%')
  )
  SELECT
    f.shipping_document_id,
    f.shipper_id,
    f.shipper_name,
    f.shipper_invoice_ref,
    f.document_date,
    f.amount_gbp,
    f.allocated_gbp,
    f.remaining_gbp,
    f.currency_code,
    f.sage_snapshot_id,
    f.sage_purchase_invoice_id,
    f.sage_reference,
    f.sage_posted_at,
    f.target_status,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.sage_posted_at DESC NULLS LAST, f.shipper_invoice_ref
  LIMIT v_limit OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_allocate_main_bank_line_to_shipper_ap_v1(
  p_dva_statement_line_id uuid,
  p_shipping_document_id uuid,
  p_allocated_gbp_amount numeric DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_line record;
  v_target record;
  v_line_allocated numeric(18,2);
  v_target_allocated numeric(18,2);
  v_line_remaining numeric(18,2);
  v_target_remaining numeric(18,2);
  v_amount numeric(18,2);
  v_allocation_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for main bank shipper allocation.'; END IF;

  SELECT staff_row.id INTO v_staff_id
  FROM public.staff staff_row
  WHERE staff_row.auth_user_id = auth.uid()
    AND staff_row.active = true
  LIMIT 1;

  SELECT
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    ds.statement_account_context,
    ds.statement_account_label,
    dsl.reference_raw,
    dsl.statement_date
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE;

  IF v_line.id IS NULL THEN RAISE EXCEPTION 'Statement line not found: %', p_dva_statement_line_id; END IF;
  IF COALESCE(v_line.statement_account_context, '') <> 'main_company_bank_account' THEN RAISE EXCEPTION 'Statement line is not from the main company bank account.'; END IF;
  IF v_line.direction <> 'out' THEN RAISE EXCEPTION 'Only OUT main-bank lines can be allocated to shipper AP invoices.'; END IF;
  IF COALESCE(v_line.amount_gbp_equivalent, 0) <= 0 THEN RAISE EXCEPTION 'Statement line amount must be positive.'; END IF;

  SELECT * INTO v_target
  FROM public.internal_shipper_ap_posted_targets_for_main_bank_v1('all', NULL, 300, 0) t
  WHERE t.shipping_document_id = p_shipping_document_id
  LIMIT 1;

  IF v_target.shipping_document_id IS NULL THEN RAISE EXCEPTION 'Posted shipper AP target not found: %', p_shipping_document_id; END IF;
  IF NULLIF(trim(COALESCE(v_target.sage_purchase_invoice_id, '')), '') IS NULL THEN RAISE EXCEPTION 'Shipper AP target has no Sage purchase invoice id.'; END IF;

  SELECT round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2)
    INTO v_line_allocated
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id;

  SELECT round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2)
    INTO v_target_allocated
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.shipping_document_id = p_shipping_document_id;

  v_line_remaining := greatest(round((COALESCE(v_line.amount_gbp_equivalent, 0) - COALESCE(v_line_allocated, 0))::numeric, 2), 0::numeric);
  v_target_remaining := greatest(round((COALESCE(v_target.amount_gbp, 0) - COALESCE(v_target_allocated, 0))::numeric, 2), 0::numeric);
  v_amount := round(COALESCE(p_allocated_gbp_amount, LEAST(v_line_remaining, v_target_remaining))::numeric, 2);

  IF v_amount <= 0 THEN RAISE EXCEPTION 'Allocation amount must be greater than zero.'; END IF;
  IF v_amount > v_line_remaining + 0.01 THEN RAISE EXCEPTION 'Allocation amount % exceeds remaining statement amount %.', v_amount, v_line_remaining; END IF;
  IF v_amount > v_target_remaining + 0.01 THEN RAISE EXCEPTION 'Allocation amount % exceeds remaining shipper AP amount %.', v_amount, v_target_remaining; END IF;

  INSERT INTO public.main_bank_shipper_ap_allocations (
    dva_statement_line_id,
    shipping_document_id,
    sage_posting_snapshot_id,
    sage_purchase_invoice_id,
    allocated_gbp_amount,
    allocation_status,
    notes,
    created_by_staff_id,
    created_by_auth_user_id
  ) VALUES (
    p_dva_statement_line_id,
    p_shipping_document_id,
    v_target.sage_snapshot_id,
    v_target.sage_purchase_invoice_id,
    v_amount,
    'confirmed',
    p_notes,
    v_staff_id,
    auth.uid()
  ) RETURNING id INTO v_allocation_id;

  RETURN jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'shipping_document_id', p_shipping_document_id,
    'allocated_gbp_amount', v_amount,
    'sage_purchase_invoice_id', v_target.sage_purchase_invoice_id,
    'shipper_invoice_ref', v_target.shipper_invoice_ref
  );
END;
$$;

-- Extend cash posting read model with confirmed main-bank shipper AP allocations.
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
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: cash posting workbench requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for cash posting workbench.'; END IF;

  RETURN QUERY
  WITH cash_defaults AS (
    SELECT
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'DVA_CASH_BANK_ACCOUNT' AND is_active = true) AS bank_account_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'FX_CARD_GAIN_LEDGER' AND is_active = true) AS fx_gain_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'FX_CARD_LOSS_LEDGER' AND is_active = true) AS fx_loss_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'BANK_FEE_LEDGER' AND is_active = true) AS bank_fee_ledger_id
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
      jsonb_build_object('statement_line_id', dsl.id, 'dva_reconciliation_id', dr.id, 'order_id', o.id, 'order_ref', o.order_ref, 'posting_category', 'customer_receipt_on_account', 'short_reference', ('GCB-IN-' || COALESCE(o.order_ref::text, left(o.id::text, 8)) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10)), 'endpoint', 'POST /contact_payments', 'transaction_type_id', 'CUSTOMER_RECEIPT') AS detail_json
    FROM public.dva_reconciliation dr
    JOIN public.dva_statement_lines dsl ON dsl.id = dr.dva_statement_line_id
    JOIN public.orders o ON o.id = dr.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    CROSS JOIN cash_defaults cd
    LEFT JOIN LATERAL (
      SELECT * FROM public.sage_party_mappings spm
      WHERE spm.platform_party_type = 'importer_customer' AND spm.platform_party_id = o.importer_id AND spm.active = true
      ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST LIMIT 1
    ) pm ON true
    WHERE dr.reconciliation_type = 'order_funding'
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
        WHEN adv.allocation_type = 'fx_card_difference' AND (NULLIF(trim(COALESCE(cd.fx_gain_ledger_id, '')), '') IS NULL OR NULLIF(trim(COALESCE(cd.fx_loss_ledger_id, '')), '') IS NULL) THEN 'blocked_fx_ledger_missing'
        WHEN adv.allocation_type IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'blocked_hold_requires_decision'
        WHEN adv.allocation_type IN ('bank_fee','fx_card_difference') THEN 'blocked_endpoint_prove_required'
        ELSE 'ready_to_freeze'
      END::text AS posting_status,
      CASE
        WHEN adv.allocation_status <> 'confirmed' THEN 'allocation is not confirmed'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN adv.allocation_type = 'supplier_invoice' AND NULLIF(trim(COALESCE(posted.sage_invoice_id, '')), '') IS NULL THEN 'matched supplier purchase invoice has not been posted to Sage'
        WHEN adv.allocation_type = 'supplier_invoice' AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'retailer/supplier Sage contact mapping missing'
        WHEN adv.allocation_type = 'retailer_refund' THEN 'retailer refund IN endpoint/allocation route must be proven before bulk posting'
        WHEN adv.allocation_type = 'bank_fee' AND NULLIF(trim(COALESCE(cd.bank_fee_ledger_id, '')), '') IS NULL THEN 'BANK_FEE_LEDGER mapping missing'
        WHEN adv.allocation_type = 'fx_card_difference' AND (NULLIF(trim(COALESCE(cd.fx_gain_ledger_id, '')), '') IS NULL OR NULLIF(trim(COALESCE(cd.fx_loss_ledger_id, '')), '') IS NULL) THEN 'FX gain/loss ledger mappings missing'
        WHEN adv.allocation_type IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'hold/unmatched row requires accounting decision'
        WHEN adv.allocation_type IN ('bank_fee','fx_card_difference') THEN 'Sage GL/bank transaction endpoint must be proven before live posting'
        ELSE NULL::text
      END AS blocker,
      (adv.allocation_status = 'confirmed' AND adv.allocation_type = 'supplier_invoice' AND NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NOT NULL AND NULLIF(trim(COALESCE(posted.sage_invoice_id, '')), '') IS NOT NULL AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NOT NULL) AS selectable,
      jsonb_build_object('allocation_id', adv.allocation_id, 'allocation_type', adv.allocation_type, 'supplier_invoice_id', adv.supplier_invoice_id, 'supplier_invoice_ref', adv.supplier_invoice_ref, 'order_id', COALESCE(adv.order_id, si.order_id), 'order_ref', adv.order_ref, 'posting_category', CASE WHEN adv.allocation_type = 'supplier_invoice' THEN 'supplier_invoice_payment' WHEN adv.allocation_type = 'retailer_refund' THEN 'retailer_refund_received' ELSE adv.allocation_type END, 'target_sage_object_id', posted.sage_invoice_id, 'short_reference', ('GCB-OUT-' || left(COALESCE(adv.supplier_invoice_ref::text, adv.order_ref::text, adv.allocation_id::text), 18)), 'endpoint', CASE WHEN adv.allocation_type = 'supplier_invoice' THEN 'POST /contact_payments · VENDOR_PAYMENT · allocated_artefacts' ELSE 'endpoint_prove_required' END) AS detail_json
    FROM public.dva_statement_line_allocation_detail_vw adv
    CROSS JOIN cash_defaults cd
    LEFT JOIN public.supplier_invoices si ON si.id = adv.supplier_invoice_id
    LEFT JOIN public.orders o ON o.id = COALESCE(adv.order_id, si.order_id)
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    LEFT JOIN LATERAL (SELECT * FROM public.sage_party_mappings spm WHERE spm.platform_party_type = 'retailer_supplier' AND spm.platform_party_id = o.retailer_id AND spm.active = true ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST LIMIT 1) pm ON true
    LEFT JOIN LATERAL (SELECT sps.sage_invoice_id FROM public.sage_posting_snapshots sps WHERE sps.document_lane = 'supplier_goods_ap' AND sps.source_id = adv.supplier_invoice_id AND sps.sage_posting_status = 'posted' AND NULLIF(trim(COALESCE(sps.sage_invoice_id, '')), '') IS NOT NULL ORDER BY sps.sage_posted_at DESC NULLS LAST, sps.created_at DESC LIMIT 1) posted ON true
    WHERE adv.allocation_status = 'confirmed'
  ), shipper_ap_rows AS (
    SELECT
      ('cash:shipper_invoice_payment:' || a.id::text)::text AS queue_row_id,
      'main_bank_shipper_ap_allocation'::text AS source_type,
      a.id AS source_id,
      dsl.id AS statement_line_id,
      dsl.dva_statement_id AS statement_id,
      dsl.statement_date::text AS statement_date_text,
      'out'::text AS direction,
      'shipper_invoice_payment'::text AS category,
      'shipper'::text AS counterparty_type,
      sd.shipper_id AS counterparty_id,
      COALESCE(sh.name, 'Shipper')::text AS counterparty_name,
      NULL::uuid AS order_id,
      sps.order_ref::text AS order_ref,
      COALESCE(dsl.auth_id_ref, a.id::text)::text AS auth_ref,
      dsl.reference_raw::text AS reference_raw,
      dsl.amount_local_ccy::numeric AS amount_local,
      dsl.local_ccy::text AS local_currency,
      round(a.allocated_gbp_amount::numeric, 2) AS amount_gbp,
      'posted_shipper_purchase_invoice'::text AS matched_target_type,
      sd.id AS matched_target_id,
      COALESCE(NULLIF(sd.document_ref, ''), NULLIF(sps.reference_text, ''), sd.id::text)::text AS matched_target_ref,
      pm.sage_contact_id::text,
      pm.sage_contact_display_name::text,
      cd.bank_account_id::text,
      COALESCE(NULLIF(a.sage_purchase_invoice_id, ''), NULLIF(sps.sage_invoice_id, ''), NULLIF(br.sage_object_id, ''))::text AS target_sage_object_id,
      CASE
        WHEN a.allocation_status <> 'confirmed' THEN 'blocked_allocation_not_confirmed'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'blocked_missing_sage_bank_account'
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'blocked_missing_sage_contact'
        WHEN NULLIF(trim(COALESCE(a.sage_purchase_invoice_id, sps.sage_invoice_id, br.sage_object_id, '')), '') IS NULL THEN 'blocked_target_invoice_not_posted'
        WHEN round(COALESCE(a.allocated_gbp_amount, 0)::numeric, 2) <= 0 THEN 'blocked_invalid_amount'
        ELSE 'ready_to_freeze'
      END::text AS posting_status,
      CASE
        WHEN a.allocation_status <> 'confirmed' THEN 'shipper AP allocation is not confirmed'
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'shipper Sage contact mapping missing'
        WHEN NULLIF(trim(COALESCE(a.sage_purchase_invoice_id, sps.sage_invoice_id, br.sage_object_id, '')), '') IS NULL THEN 'matched shipper AP purchase invoice has not been posted to Sage'
        WHEN round(COALESCE(a.allocated_gbp_amount, 0)::numeric, 2) <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS blocker,
      (a.allocation_status = 'confirmed' AND NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NOT NULL AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NOT NULL AND NULLIF(trim(COALESCE(a.sage_purchase_invoice_id, sps.sage_invoice_id, br.sage_object_id, '')), '') IS NOT NULL) AS selectable,
      jsonb_build_object(
        'allocation_id', a.id,
        'allocation_type', 'shipper_ap_payment',
        'statement_line_id', dsl.id,
        'shipping_document_id', sd.id,
        'shipper_id', sd.shipper_id,
        'shipper_invoice_ref', COALESCE(NULLIF(sd.document_ref, ''), NULLIF(sps.reference_text, ''), sd.id::text),
        'posting_category', 'shipper_invoice_payment',
        'target_sage_object_id', COALESCE(NULLIF(a.sage_purchase_invoice_id, ''), NULLIF(sps.sage_invoice_id, ''), NULLIF(br.sage_object_id, '')),
        'short_reference', ('GCB-OUT-' || left(COALESCE(NULLIF(sd.document_ref, ''), NULLIF(sps.reference_text, ''), a.id::text), 18)),
        'endpoint', 'POST /contact_payments · VENDOR_PAYMENT · allocated_artefacts'
      ) AS detail_json
    FROM public.main_bank_shipper_ap_allocations a
    JOIN public.dva_statement_lines dsl ON dsl.id = a.dva_statement_line_id
    JOIN public.shipping_documents sd ON sd.id = a.shipping_document_id
    LEFT JOIN public.shippers sh ON sh.id = sd.shipper_id
    LEFT JOIN public.sage_posting_snapshots sps ON sps.id = a.sage_posting_snapshot_id
    LEFT JOIN public.sage_posting_batch_rows br ON br.snapshot_id = sps.id AND br.posting_status = 'posted'
    CROSS JOIN cash_defaults cd
    LEFT JOIN LATERAL (SELECT * FROM public.sage_party_mappings spm WHERE spm.platform_party_type = 'shipper' AND spm.platform_party_id = sd.shipper_id AND spm.active = true ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST LIMIT 1) pm ON true
    WHERE a.allocation_status = 'confirmed'
  ), all_rows AS (
    SELECT * FROM customer_receipts
    UNION ALL SELECT * FROM allocation_rows
    UNION ALL SELECT * FROM shipper_ap_rows
  ), filtered AS (
    SELECT ar.* FROM all_rows ar
    WHERE (v_direction = 'all' OR lower(ar.direction) = v_direction)
      AND (v_category = 'all' OR lower(ar.category) = v_category)
      AND (v_status = 'all' OR lower(ar.posting_status) = v_status OR (v_status = 'blocked' AND lower(ar.posting_status) LIKE 'blocked%') OR (v_status = 'ready' AND lower(ar.posting_status) = 'ready_to_freeze'))
      AND (v_search IS NULL OR lower(concat_ws(' ', ar.counterparty_name, ar.order_ref, ar.auth_ref, ar.reference_raw, ar.matched_target_ref, ar.category, ar.blocker)) LIKE '%' || v_search || '%')
  )
  SELECT f.*, count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date_text DESC NULLS LAST, f.category, f.counterparty_name, f.queue_row_id
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_main_bank_shipper_statement_lines_v1(text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_shipper_ap_posted_targets_for_main_bank_v1(text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_main_bank_line_to_shipper_ap_v1(uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text, text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_main_bank_shipper_statement_lines_v1(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_shipper_ap_posted_targets_for_main_bank_v1(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_allocate_main_bank_line_to_shipper_ap_v1(uuid, uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text, text, text, text, integer, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Smoke tests after applying:
-- select * from public.internal_main_bank_shipper_statement_lines_v1('all', null, 10, 0);
-- select * from public.internal_shipper_ap_posted_targets_for_main_bank_v1('all', null, 10, 0);
-- select * from public.internal_cash_posting_workbench_rows_v1('out','shipper_invoice_payment','all',null,50,0);
