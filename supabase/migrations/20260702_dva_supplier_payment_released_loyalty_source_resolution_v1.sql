BEGIN;

-- DVA supplier payment released-loyalty source resolution v1.
-- Contract: docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_AUTO_RESOLUTION_ADDENDUM_v1.md
--
-- This replaces the prior "importer GBP statement means virtual wallet" shortcut.
-- Supplier invoice allocation now resolves loyalty source only from proven released
-- completion-loyalty provenance on the order funding chain. Cash posting already
-- consumes source_bank_account_mapping_code from the allocation row.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoices'; END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoice_lines'; END IF;
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing public.staff'; END IF;
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_events'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid)') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid)'; END IF;
END $$;

ALTER TABLE public.dva_statement_line_allocations
  ADD COLUMN IF NOT EXISTS source_bank_account_mapping_code text,
  ADD COLUMN IF NOT EXISTS source_wallet_code text;

CREATE INDEX IF NOT EXISTS dva_statement_line_allocations_source_bank_mapping_idx
  ON public.dva_statement_line_allocations(source_bank_account_mapping_code)
  WHERE allocation_status <> 'reversed';

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
  v_source_bank_account_mapping_code text := 'DVA_CASH_BANK_ACCOUNT';
  v_source_wallet_code text := NULL;
  v_source_resolution_reason text := 'default_real_dva_cash';
  v_loyalty_exact_count integer := 0;
  v_loyalty_total_remaining_gbp numeric(12,2) := 0;
  v_cash_funding_remaining_gbp numeric(12,2) := 0;
  v_exact_wallet_code text;
  v_exact_mapping_code text;
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
    ds.statement_account_context
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

  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.id AS order_funding_event_id,
      round(abs(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      resolver.resolved_wallet_code::text AS source_wallet_code
    FROM public.order_funding_events ofe
    JOIN public.importer_credit_ledger debit
      ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN COALESCE(debit.source_table, '') = 'importer_credit_ledger' THEN debit.source_id
        WHEN COALESCE(debit.source_entity_type, '') = 'importer_credit_ledger' THEN debit.source_entity_id
        ELSE NULL::uuid
      END
     AND lm.importer_id = v_order.importer_id
     AND lm.match_status = 'released_available_dashboard_credit'
     AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
     AND lm.destination_in_statement_line_id IS NOT NULL
    JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(lm.destination_in_statement_line_id) resolver
      ON resolver.resolved_wallet_code IN ('virtual_gbp_wallet', 'dva_ghs_wallet')
     AND resolver.blocker IS NULL
    WHERE ofe.order_id = v_order.id
      AND ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
      AND round(abs(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
    ORDER BY ofe.id, lm.id
  ), loyalty_by_wallet AS (
    SELECT
      la.source_wallet_code,
      round(sum(la.amount_gbp)::numeric, 2) AS applied_gbp
    FROM loyalty_applied la
    GROUP BY la.source_wallet_code
  ), existing_source_allocations AS (
    SELECT
      COALESCE(NULLIF(trim(a.source_bank_account_mapping_code), ''), 'DVA_CASH_BANK_ACCOUNT') AS source_bank_account_mapping_code,
      NULLIF(trim(a.source_wallet_code), '') AS source_wallet_code,
      round(sum(COALESCE(a.allocated_gbp_amount, 0))::numeric, 2) AS allocated_gbp
    FROM public.dva_statement_line_allocations a
    JOIN public.supplier_invoices asi
      ON asi.id = a.supplier_invoice_id
    WHERE asi.order_id = v_order.id
      AND a.allocation_type = 'supplier_invoice'
      AND a.allocation_status = 'confirmed'
    GROUP BY
      COALESCE(NULLIF(trim(a.source_bank_account_mapping_code), ''), 'DVA_CASH_BANK_ACCOUNT'),
      NULLIF(trim(a.source_wallet_code), '')
  ), loyalty_remaining AS (
    SELECT
      lbw.source_wallet_code,
      CASE lbw.source_wallet_code
        WHEN 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
        WHEN 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
        ELSE NULL::text
      END AS source_bank_account_mapping_code,
      round(GREATEST(lbw.applied_gbp - COALESCE(esa.allocated_gbp, 0), 0)::numeric, 2) AS remaining_gbp
    FROM loyalty_by_wallet lbw
    LEFT JOIN existing_source_allocations esa
      ON esa.source_wallet_code = lbw.source_wallet_code
  ), cash_funding AS (
    SELECT round(COALESCE(SUM(abs(ofe.amount_gbp)), 0)::numeric, 2) AS cash_funded_gbp
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = v_order.id
      AND ofe.event_type IN ('funding_contribution', 'manual_adjustment')
  ), cash_allocated AS (
    SELECT round(COALESCE(SUM(esa.allocated_gbp), 0)::numeric, 2) AS cash_allocated_gbp
    FROM existing_source_allocations esa
    WHERE esa.source_bank_account_mapping_code = 'DVA_CASH_BANK_ACCOUNT'
  ), totals AS (
    SELECT
      COUNT(*) FILTER (WHERE abs(lr.remaining_gbp - v_amount) < 0.01 AND lr.source_bank_account_mapping_code IS NOT NULL) AS exact_count,
      MAX(lr.source_wallet_code) FILTER (WHERE abs(lr.remaining_gbp - v_amount) < 0.01 AND lr.source_bank_account_mapping_code IS NOT NULL) AS exact_wallet_code,
      MAX(lr.source_bank_account_mapping_code) FILTER (WHERE abs(lr.remaining_gbp - v_amount) < 0.01 AND lr.source_bank_account_mapping_code IS NOT NULL) AS exact_mapping_code,
      round(COALESCE(SUM(lr.remaining_gbp), 0)::numeric, 2) AS loyalty_remaining_gbp,
      round(GREATEST((SELECT cash_funded_gbp FROM cash_funding) - (SELECT cash_allocated_gbp FROM cash_allocated), 0)::numeric, 2) AS cash_remaining_gbp
    FROM loyalty_remaining lr
  )
  SELECT
    COALESCE(t.exact_count, 0),
    COALESCE(t.loyalty_remaining_gbp, 0),
    COALESCE(t.cash_remaining_gbp, 0),
    t.exact_wallet_code,
    t.exact_mapping_code
  INTO
    v_loyalty_exact_count,
    v_loyalty_total_remaining_gbp,
    v_cash_funding_remaining_gbp,
    v_exact_wallet_code,
    v_exact_mapping_code
  FROM totals t;

  IF v_loyalty_exact_count = 1 THEN
    v_source_wallet_code := v_exact_wallet_code;
    v_source_bank_account_mapping_code := v_exact_mapping_code;
    v_source_resolution_reason := 'exact_remaining_released_loyalty_source';
  ELSIF v_loyalty_exact_count > 1 THEN
    RAISE EXCEPTION 'source_funding_ambiguous_for_supplier_payment_bank_resolution: order %, allocation %', v_order.id, v_amount;
  ELSIF v_cash_funding_remaining_gbp + 0.01 >= v_amount THEN
    v_source_wallet_code := NULL;
    v_source_bank_account_mapping_code := 'DVA_CASH_BANK_ACCOUNT';
    v_source_resolution_reason := 'remaining_order_cash_funding';
  ELSIF v_loyalty_total_remaining_gbp > 0 THEN
    RAISE EXCEPTION 'source_funding_required_for_supplier_payment_bank_resolution: order %, allocation %, loyalty remaining %, cash remaining %',
      v_order.id, v_amount, v_loyalty_total_remaining_gbp, v_cash_funding_remaining_gbp;
  ELSE
    v_source_wallet_code := NULL;
    v_source_bank_account_mapping_code := 'DVA_CASH_BANK_ACCOUNT';
    v_source_resolution_reason := 'default_real_dva_cash_no_released_loyalty_source';
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
    v_source_bank_account_mapping_code,
    v_source_wallet_code,
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
    'source_bank_account_mapping_code', v_source_bank_account_mapping_code,
    'source_wallet_code', v_source_wallet_code,
    'source_resolution_reason', v_source_resolution_reason,
    'remaining_order_cash_funding_gbp', v_cash_funding_remaining_gbp,
    'remaining_released_loyalty_funding_gbp', v_loyalty_total_remaining_gbp,
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

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) IS
'Staff/supervisor SECURITY DEFINER RPC to allocate one OUT DVA/card statement line to one supplier invoice. Source bank resolution is provenance-based: exact remaining released completion-loyalty funding maps to LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT or LOYALTY_DVA_GHS_BANK_ACCOUNT via the paired destination IN resolver; otherwise covered cash defaults to DVA_CASH_BANK_ACCOUNT. Does not post to Sage and does not use the retired completion-loyalty supplier-wallet route.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
