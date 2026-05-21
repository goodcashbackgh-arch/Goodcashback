BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.sales_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sales_invoices';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
  IF to_regprocedure('public.order_funding_total_gbp(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_funding_total_gbp(uuid)';
  END IF;
END $$;

CREATE OR REPLACE VIEW public.order_settlement_credit_position_v1 AS
WITH customer_invoice_totals AS (
  SELECT
    si.order_id,
    ROUND(COALESCE(SUM(COALESCE(si.amount_gbp, 0)) FILTER (
      WHERE COALESCE(si.invoice_type::text, '') IN ('main','supplementary')
        AND COALESCE(si.sage_status::text, '') = 'posted'
    ), 0)::numeric, 2) AS posted_customer_invoice_gbp,
    COUNT(*) FILTER (
      WHERE COALESCE(si.invoice_type::text, '') IN ('main','supplementary')
        AND COALESCE(si.sage_status::text, '') = 'posted'
    ) AS posted_customer_invoice_count
  FROM public.sales_invoices si
  GROUP BY si.order_id
), settlement_credits AS (
  SELECT
    icl.source_entity_id AS order_id,
    ROUND(COALESCE(SUM(CASE WHEN icl.direction = 'credit' THEN ABS(icl.amount_gbp) ELSE -ABS(icl.amount_gbp) END), 0)::numeric, 2) AS settlement_credit_created_gbp,
    COUNT(*) AS settlement_credit_rows
  FROM public.importer_credit_ledger icl
  WHERE icl.source_type = 'settlement_credit'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id IS NOT NULL
  GROUP BY icl.source_entity_id
)
SELECT
  o.id AS order_id,
  o.order_ref,
  o.importer_id,
  o.status AS order_status,
  ROUND(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) AS declared_order_gbp,
  ROUND(COALESCE(public.order_funding_total_gbp(o.id), 0)::numeric, 2) AS funding_total_gbp,
  COALESCE(cit.posted_customer_invoice_gbp, 0)::numeric AS posted_customer_invoice_gbp,
  COALESCE(cit.posted_customer_invoice_count, 0)::integer AS posted_customer_invoice_count,
  ROUND((COALESCE(public.order_funding_total_gbp(o.id), 0) - COALESCE(cit.posted_customer_invoice_gbp, 0))::numeric, 2) AS funding_less_posted_invoice_gbp,
  COALESCE(sc.settlement_credit_created_gbp, 0)::numeric AS settlement_credit_created_gbp,
  COALESCE(sc.settlement_credit_rows, 0)::integer AS settlement_credit_rows,
  CASE
    WHEN COALESCE(cit.posted_customer_invoice_count, 0) = 0 THEN 'no_posted_customer_invoice'
    WHEN ROUND((COALESCE(public.order_funding_total_gbp(o.id), 0) - COALESCE(cit.posted_customer_invoice_gbp, 0))::numeric, 2) > 0
      AND COALESCE(sc.settlement_credit_created_gbp, 0) = 0 THEN 'credit_due'
    WHEN ROUND((COALESCE(public.order_funding_total_gbp(o.id), 0) - COALESCE(cit.posted_customer_invoice_gbp, 0))::numeric, 2) > 0
      AND COALESCE(sc.settlement_credit_created_gbp, 0) > 0 THEN 'credit_created'
    WHEN ROUND((COALESCE(public.order_funding_total_gbp(o.id), 0) - COALESCE(cit.posted_customer_invoice_gbp, 0))::numeric, 2) = 0 THEN 'nil_reconciled'
    ELSE 'balance_due'
  END AS settlement_status
FROM public.orders o
LEFT JOIN customer_invoice_totals cit ON cit.order_id = o.id
LEFT JOIN settlement_credits sc ON sc.order_id = o.id;

COMMENT ON VIEW public.order_settlement_credit_position_v1 IS
'Order-level settlement read model: platform funding compared to posted customer sales invoice total. Used to create importer credit only after final invoice reality is known.';

CREATE OR REPLACE FUNCTION public.staff_confirm_order_settlement_credit_v1(
  p_order_id uuid,
  p_reason text,
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
  v_order record;
  v_position record;
  v_reason text;
  v_existing_credit_id uuid;
  v_credit_id uuid;
  v_blocking_hold_count integer := 0;
  v_open_dispute_count integer := 0;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff settlement credit confirmation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found.';
  END IF;

  IF v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can confirm order settlement credit.';
  END IF;

  v_reason := lower(btrim(COALESCE(p_reason, '')));
  IF v_reason NOT IN (
    'not_charged_closure',
    'checkout_changed',
    'discount_or_promo',
    'item_removed_before_charge',
    'customer_hold_excluded',
    'supervisor_confirmed_credit'
  ) THEN
    RAISE EXCEPTION 'Invalid settlement reason %. Use not_charged_closure, checkout_changed, discount_or_promo, item_removed_before_charge, customer_hold_excluded, or supervisor_confirmed_credit.', p_reason;
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, COALESCE(o.order_type, 'original') AS order_type, o.status
    INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.order_type <> 'original' THEN
    RAISE EXCEPTION 'Settlement credit can only be confirmed on original orders. Order % has order_type %', p_order_id, v_order.order_type;
  END IF;

  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NOT NULL THEN
    SELECT COUNT(*)
      INTO v_blocking_hold_count
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = p_order_id
      AND h.status IN ('requested','supervisor_approved');

    IF v_blocking_hold_count > 0 THEN
      RAISE EXCEPTION 'Cannot confirm settlement credit while % active customer hold(s) remain.', v_blocking_hold_count;
    END IF;
  END IF;

  SELECT COUNT(*)
    INTO v_open_dispute_count
  FROM public.disputes d
  WHERE d.order_id = p_order_id
    AND d.resolved_at IS NULL
    AND COALESCE(d.status, '') NOT IN ('closed','resolved','closed_no_action');

  IF v_open_dispute_count > 0 THEN
    RAISE EXCEPTION 'Cannot confirm settlement credit while % open dispute/exception(s) remain.', v_open_dispute_count;
  END IF;

  SELECT *
    INTO v_position
  FROM public.order_settlement_credit_position_v1 p
  WHERE p.order_id = p_order_id;

  IF v_position.order_id IS NULL THEN
    RAISE EXCEPTION 'Settlement position not found for order %', p_order_id;
  END IF;

  IF COALESCE(v_position.posted_customer_invoice_count, 0) = 0 THEN
    RAISE EXCEPTION 'Cannot confirm settlement credit before a posted customer sales invoice exists for order %.', p_order_id;
  END IF;

  IF COALESCE(v_position.funding_less_posted_invoice_gbp, 0) <= 0 THEN
    RAISE EXCEPTION 'No customer credit is due. Funding less posted customer invoice is %.', v_position.funding_less_posted_invoice_gbp;
  END IF;

  SELECT icl.id
    INTO v_existing_credit_id
  FROM public.importer_credit_ledger icl
  WHERE icl.importer_id = v_order.importer_id
    AND icl.source_type = 'settlement_credit'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id = p_order_id
    AND icl.linked_order_id = p_order_id
  ORDER BY icl.created_at, icl.id
  LIMIT 1
  FOR UPDATE;

  IF v_existing_credit_id IS NULL THEN
    INSERT INTO public.importer_credit_ledger (
      importer_id,
      entry_type,
      source_table,
      source_id,
      linked_order_id,
      linked_dispute_id,
      direction,
      amount_gbp,
      amount_local_ccy,
      local_ccy,
      effective_at,
      source_type,
      source_entity_type,
      source_entity_id,
      applied_to_order_id,
      lock_reason,
      created_by_staff_id,
      notes
    ) VALUES (
      v_order.importer_id,
      'manual_credit',
      'orders',
      p_order_id,
      p_order_id,
      NULL,
      'credit',
      v_position.funding_less_posted_invoice_gbp,
      v_position.funding_less_posted_invoice_gbp,
      'GBP',
      now(),
      'settlement_credit',
      'order',
      p_order_id,
      NULL,
      NULL,
      v_staff.id,
      CONCAT('Order settlement credit confirmed. Reason: ', v_reason, CASE WHEN COALESCE(p_notes, '') <> '' THEN CONCAT('. Notes: ', p_notes) ELSE '' END)
    ) RETURNING id INTO v_credit_id;
  ELSE
    UPDATE public.importer_credit_ledger
       SET amount_gbp = v_position.funding_less_posted_invoice_gbp,
           amount_local_ccy = v_position.funding_less_posted_invoice_gbp,
           local_ccy = 'GBP',
           direction = 'credit',
           source_type = 'settlement_credit',
           source_entity_type = 'order',
           source_entity_id = p_order_id,
           linked_order_id = p_order_id,
           applied_to_order_id = NULL,
           lock_reason = NULL,
           created_by_staff_id = COALESCE(created_by_staff_id, v_staff.id),
           effective_at = now(),
           notes = CONCAT('Order settlement credit updated. Reason: ', v_reason, CASE WHEN COALESCE(p_notes, '') <> '' THEN CONCAT('. Notes: ', p_notes) ELSE '' END)
     WHERE id = v_existing_credit_id
     RETURNING id INTO v_credit_id;

    DELETE FROM public.importer_credit_ledger icl
    WHERE icl.id <> v_credit_id
      AND icl.importer_id = v_order.importer_id
      AND icl.source_type = 'settlement_credit'
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id = p_order_id
      AND icl.linked_order_id = p_order_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'credit_ledger_id', v_credit_id,
    'funding_total_gbp', v_position.funding_total_gbp,
    'posted_customer_invoice_gbp', v_position.posted_customer_invoice_gbp,
    'settlement_credit_gbp', v_position.funding_less_posted_invoice_gbp,
    'reason', v_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_confirm_order_settlement_credit_v1(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_confirm_order_settlement_credit_v1(uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
