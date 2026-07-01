BEGIN;

-- DVA supplier payment source auto-resolution v1.
-- Contract: docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_AUTO_RESOLUTION_ADDENDUM_v1.md
--
-- Keep supplier invoice settlement on the normal DVA statement allocation route.
-- When staff allocate an OUT statement line to a supplier invoice, stamp the
-- allocation with the source bank mapping that cash posting already consumes.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statement_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_lines';
  END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statements';
  END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dva_statement_line_allocations';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Missing public.supplier_invoices';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Missing public.orders';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Missing public.staff';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dva_statements'
      AND column_name = 'statement_account_context'
  ) THEN
    RAISE EXCEPTION 'Missing public.dva_statements.statement_account_context';
  END IF;
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
BEGIN
  -- Staff identity is derived from auth.uid(); browser must not pass staff id.
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

  -- Lock and validate the real statement line.
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

  IF v_statement_account_context = 'importer_dva_card_account'
     AND v_statement_local_ccy = 'GBP' THEN
    v_source_wallet_code := 'virtual_gbp_wallet';
    v_source_bank_account_mapping_code := 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT';
  END IF;

  -- Lock and validate supplier invoice/order/importer consistency.
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

  -- Prevent duplicate active allocation from the same statement line to the same invoice.
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

  -- Guard 1: do not over-allocate the statement line.
  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_confirmed_total_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_status = 'confirmed';

  IF v_confirmed_total_before + v_amount > ROUND(v_line.amount_gbp_equivalent::numeric, 2) + 0.01 THEN
    RAISE EXCEPTION 'Allocation would over-allocate statement line %. Statement GBP %, already confirmed %, proposed %',
      p_dva_statement_line_id, ROUND(v_line.amount_gbp_equivalent::numeric, 2), v_confirmed_total_before, v_amount;
  END IF;

  -- Guard 2: do not over-allocate the supplier invoice across all statement lines.
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
'Staff/supervisor SECURITY DEFINER RPC to allocate one OUT DVA/card statement line to one supplier invoice. v3 keeps v2 over-allocation guards and stamps source bank mapping for cash posting: importer payment GBP lines use LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT; other importer payment lines default to DVA_CASH_BANK_ACCOUNT. Does not post to Sage and does not use the retired completion-loyalty supplier-wallet route.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks after execution:
-- select to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)') as allocation_rpc;
-- select obj_description('public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)'::regprocedure, 'pg_proc') as rpc_comment;
-- select column_name from information_schema.columns where table_schema = 'public' and table_name = 'dva_statement_line_allocations' and column_name in ('source_bank_account_mapping_code','source_wallet_code') order by column_name;
