BEGIN;

-- Main-bank shipper allocation review + reversal v1.
-- Implements MAIN_BANK_SHIPPER_ALLOCATION_REVIEW_AND_REVERSAL_ADDENDUM_v1.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.main_bank_shipper_ap_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_shipper_ap_allocations'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.dva_statement_line_allocation_detail_vw') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocation_detail_vw'; END IF;
  IF to_regclass('public.statement_line_control_position_v1') IS NULL THEN RAISE EXCEPTION 'Missing public.statement_line_control_position_v1'; END IF;
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_snapshots'; END IF;
  IF to_regclass('public.shipping_documents') IS NULL THEN RAISE EXCEPTION 'Missing public.shipping_documents'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
END $$;

-- One review read model, while preserving distinct write families.
CREATE OR REPLACE VIEW public.statement_line_matching_review_v1 AS
SELECT
  'dva_allocation'::text AS allocation_family,
  adv.allocation_id,
  adv.importer_id,
  adv.dva_statement_line_id,
  adv.transaction_date::text AS transaction_date,
  adv.statement_date::text AS statement_date,
  adv.statement_description::text,
  adv.statement_reference::text,
  adv.statement_direction::text,
  adv.statement_gbp_amount::numeric,
  adv.allocation_type::text,
  adv.allocation_status::text,
  adv.supplier_invoice_ref::text,
  adv.dispute_id,
  adv.order_ref::text,
  adv.allocated_gbp_amount::numeric,
  adv.notes::text,
  adv.created_at,
  NULL::uuid AS shipping_document_id,
  NULL::text AS shipper_invoice_ref,
  NULL::uuid AS shipper_id,
  NULL::text AS shipper_name,
  NULL::text AS sage_purchase_invoice_id
FROM public.dva_statement_line_allocation_detail_vw adv

UNION ALL

SELECT
  'main_bank_shipper_ap'::text AS allocation_family,
  a.id AS allocation_id,
  ds.importer_id,
  a.dva_statement_line_id,
  NULL::text AS transaction_date,
  dsl.statement_date::text AS statement_date,
  dsl.reference_raw::text AS statement_description,
  dsl.reference_raw::text AS statement_reference,
  dsl.direction::text AS statement_direction,
  round(COALESCE(dsl.amount_gbp_equivalent, 0)::numeric, 2) AS statement_gbp_amount,
  'main_bank_shipper_ap'::text AS allocation_type,
  a.allocation_status::text,
  NULL::text AS supplier_invoice_ref,
  NULL::uuid AS dispute_id,
  NULL::text AS order_ref,
  round(COALESCE(a.allocated_gbp_amount, 0)::numeric, 2) AS allocated_gbp_amount,
  a.notes::text,
  a.created_at,
  a.shipping_document_id,
  COALESCE(NULLIF(sd.document_ref, ''), sd.id::text)::text AS shipper_invoice_ref,
  sd.shipper_id,
  COALESCE(NULLIF(sh.name, ''), 'Shipper')::text AS shipper_name,
  a.sage_purchase_invoice_id::text
FROM public.main_bank_shipper_ap_allocations a
JOIN public.dva_statement_lines dsl ON dsl.id = a.dva_statement_line_id
JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
JOIN public.shipping_documents sd ON sd.id = a.shipping_document_id
LEFT JOIN public.shippers sh ON sh.id = sd.shipper_id;

ALTER VIEW public.statement_line_matching_review_v1 SET (security_invoker = true);
GRANT SELECT ON public.statement_line_matching_review_v1 TO authenticated;

-- Correct the shipper allocator so statement availability respects all active
-- main-bank consumption families through the authoritative amount-aware control position.
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
  v_position record;
  v_target record;
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

  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;

  -- Deterministic concurrency boundary: statement line first.
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
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN RAISE EXCEPTION 'Statement line not found: %', p_dva_statement_line_id; END IF;
  IF COALESCE(v_line.statement_account_context, '') <> 'main_company_bank_account' THEN RAISE EXCEPTION 'Statement line is not from the main company bank account.'; END IF;
  IF v_line.direction <> 'out' THEN RAISE EXCEPTION 'Only OUT main-bank lines can be allocated to shipper AP invoices.'; END IF;
  IF COALESCE(v_line.amount_gbp_equivalent, 0) <= 0 THEN RAISE EXCEPTION 'Statement line amount must be positive.'; END IF;

  -- Lock target after the statement line so concurrent allocations cannot both
  -- consume the same remaining shipper invoice amount.
  PERFORM 1
  FROM public.shipping_documents sd
  WHERE sd.id = p_shipping_document_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Shipping document not found: %', p_shipping_document_id; END IF;

  SELECT * INTO v_target
  FROM public.internal_shipper_ap_posted_targets_for_main_bank_v1('all', NULL, 300, 0) t
  WHERE t.shipping_document_id = p_shipping_document_id
  LIMIT 1;

  IF v_target.shipping_document_id IS NULL THEN RAISE EXCEPTION 'Posted shipper AP target not found: %', p_shipping_document_id; END IF;
  IF NULLIF(trim(COALESCE(v_target.sage_purchase_invoice_id, '')), '') IS NULL THEN RAISE EXCEPTION 'Shipper AP target has no Sage purchase invoice id.'; END IF;

  SELECT p.* INTO v_position
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_dva_statement_line_id;

  IF v_position.statement_line_id IS NULL THEN RAISE EXCEPTION 'Statement control position not found: %', p_dva_statement_line_id; END IF;
  IF COALESCE(v_position.overconsumed_gbp, 0) > 0.005 THEN
    RAISE EXCEPTION 'Statement line % is already over-consumed by %. Resolve existing usage before allocating.', p_dva_statement_line_id, v_position.overconsumed_gbp;
  END IF;

  v_line_remaining := round(COALESCE(v_position.remaining_unconsumed_gbp, 0)::numeric, 2);

  SELECT round(COALESCE(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2)
    INTO v_target_allocated
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.shipping_document_id = p_shipping_document_id;

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
    'statement_remaining_before_gbp', v_line_remaining,
    'statement_remaining_after_gbp', round((v_line_remaining - v_amount)::numeric, 2),
    'sage_purchase_invoice_id', v_target.sage_purchase_invoice_id,
    'shipper_invoice_ref', v_target.shipper_invoice_ref
  );
END;
$$;

-- Dedicated reversal command. It deliberately does not mutate cash-posting or Sage artefacts.
CREATE OR REPLACE FUNCTION public.staff_reverse_main_bank_shipper_ap_allocation_v1(
  p_allocation_id uuid,
  p_reversal_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_lookup record;
  v_allocation record;
  v_reason text := NULLIF(trim(COALESCE(p_reversal_reason, '')), '');
  v_position record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: main-bank shipper allocation reversal requires auth.uid()';
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
    RAISE EXCEPTION 'Only admin or supervisor staff can reverse main-bank shipper allocations. Current role: %', v_staff.role_type;
  END IF;

  IF v_reason IS NULL OR length(v_reason) < 8 THEN
    RAISE EXCEPTION 'A reversal reason of at least 8 characters is required.';
  END IF;

  -- Unlocked lookup obtains the statement-line id; final mutation is protected
  -- by the deterministic statement-line -> allocation lock order below.
  SELECT a.id, a.dva_statement_line_id
    INTO v_lookup
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.id = p_allocation_id;

  IF v_lookup.id IS NULL THEN
    RAISE EXCEPTION 'Main-bank shipper allocation not found: %', p_allocation_id;
  END IF;

  PERFORM 1
  FROM public.dva_statement_lines dsl
  WHERE dsl.id = v_lookup.dva_statement_line_id
  FOR UPDATE;

  SELECT a.*
    INTO v_allocation
  FROM public.main_bank_shipper_ap_allocations a
  WHERE a.id = p_allocation_id
  FOR UPDATE;

  IF v_allocation.id IS NULL THEN
    RAISE EXCEPTION 'Main-bank shipper allocation not found after lock: %', p_allocation_id;
  END IF;

  IF v_allocation.allocation_status = 'reversed' THEN
    RAISE EXCEPTION 'Main-bank shipper allocation % is already reversed.', p_allocation_id;
  END IF;

  IF v_allocation.allocation_status <> 'confirmed' THEN
    RAISE EXCEPTION 'Main-bank shipper allocation % is not confirmed and cannot be reversed. Current status: %', p_allocation_id, v_allocation.allocation_status;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cash_posting_snapshots cps
    WHERE cps.active = true
      AND cps.source_type = 'main_bank_shipper_ap_allocation'
      AND cps.source_id = p_allocation_id
      AND cps.posting_category = 'shipper_invoice_payment'
  ) THEN
    RAISE EXCEPTION 'This match has already been frozen into cash posting and cannot be reversed here. Resolve the accounting/cash-posting artefact first.';
  END IF;

  UPDATE public.main_bank_shipper_ap_allocations a
     SET allocation_status = 'reversed',
         reversed_by_staff_id = v_staff.id,
         reversed_by_auth_user_id = v_auth_uid,
         reversed_at = now(),
         reversal_reason = v_reason
   WHERE a.id = p_allocation_id;

  SELECT p.* INTO v_position
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = v_allocation.dva_statement_line_id;

  RETURN jsonb_build_object(
    'ok', true,
    'allocation_id', p_allocation_id,
    'dva_statement_line_id', v_allocation.dva_statement_line_id,
    'shipping_document_id', v_allocation.shipping_document_id,
    'reversed_allocation_type', 'main_bank_shipper_ap',
    'reversed_amount_gbp', v_allocation.allocated_gbp_amount,
    'active_consumed_after_gbp', COALESCE(v_position.active_consumed_gbp, 0),
    'active_reserved_after_gbp', COALESCE(v_position.active_reserved_gbp, 0),
    'remaining_unconsumed_after_gbp', COALESCE(v_position.remaining_unconsumed_gbp, 0),
    'reversal_reason', v_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_reverse_main_bank_shipper_ap_allocation_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reverse_main_bank_shipper_ap_allocation_v1(uuid, text) TO authenticated;

-- Preserve the established allocator privilege shape after CREATE OR REPLACE.
REVOKE ALL ON FUNCTION public.staff_allocate_main_bank_line_to_shipper_ap_v1(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_allocate_main_bank_line_to_shipper_ap_v1(uuid, uuid, numeric, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
