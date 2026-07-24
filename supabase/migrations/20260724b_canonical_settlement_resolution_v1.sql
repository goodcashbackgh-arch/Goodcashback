BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Canonical, additive final-settlement resolution layer.
-- It does not rewrite physical statement evidence, funding events, posted sale
-- documents, existing credit rows, statement allocations, Sage or VAT data.

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_events'; END IF;
  IF to_regclass('public.order_pending_funding_surplus') IS NULL THEN RAISE EXCEPTION 'Missing public.order_pending_funding_surplus'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.sales_invoices') IS NULL THEN RAISE EXCEPTION 'Missing public.sales_invoices'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing public.staff'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.order_settlement_resolution_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_key uuid NOT NULL,
  order_id uuid NOT NULL REFERENCES public.orders(id),
  importer_id uuid NOT NULL REFERENCES public.importers(id),
  customer_credit_gbp numeric(12,2) NOT NULL DEFAULT 0 CHECK (customer_credit_gbp >= 0),
  fx_card_difference_gbp numeric(12,2) NOT NULL DEFAULT 0 CHECK (fx_card_difference_gbp >= 0),
  credit_ledger_id uuid REFERENCES public.importer_credit_ledger(id),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','reversed')),
  reason text NOT NULL,
  notes text,
  created_by_staff_id uuid NOT NULL REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  reversed_by_staff_id uuid REFERENCES public.staff(id),
  reversed_at timestamptz,
  reversal_reason text,
  CONSTRAINT order_settlement_resolution_positive_ck CHECK (
    customer_credit_gbp + fx_card_difference_gbp > 0
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_order_settlement_resolution_action_key_v1
  ON public.order_settlement_resolution_actions(action_key);
CREATE INDEX IF NOT EXISTS idx_order_settlement_resolution_order_status_v1
  ON public.order_settlement_resolution_actions(order_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_order_settlement_resolution_credit_v1
  ON public.order_settlement_resolution_actions(credit_ledger_id)
  WHERE credit_ledger_id IS NOT NULL;

ALTER TABLE public.order_settlement_resolution_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_settlement_resolution_actions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_settlement_resolution_actions TO authenticated;

DROP POLICY IF EXISTS order_settlement_resolution_staff_select_v1
  ON public.order_settlement_resolution_actions;
CREATE POLICY order_settlement_resolution_staff_select_v1
  ON public.order_settlement_resolution_actions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.staff s
      WHERE s.auth_user_id = auth.uid()
        AND COALESCE(s.active, true) = true
    )
  );

CREATE OR REPLACE VIEW public.order_settlement_resolution_position_v1 AS
WITH funding AS (
  SELECT
    e.order_id,
    ROUND(COALESCE(SUM(
      CASE
        WHEN e.event_type IN ('funding_contribution','credit_applied','manual_adjustment') THEN e.amount_gbp
        WHEN e.event_type = 'funding_reversed' THEN -ABS(e.amount_gbp)
        ELSE 0
      END
    ), 0)::numeric, 2) AS funding_total_gbp,
    ROUND(COALESCE(SUM(
      CASE WHEN e.event_type = 'credit_applied' THEN ABS(e.amount_gbp) ELSE 0 END
    ), 0)::numeric, 2) AS applied_account_credit_gbp
  FROM public.order_funding_events e
  GROUP BY e.order_id
), pending_receipt AS (
  SELECT
    p.order_id,
    ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS pending_receipt_residual_gbp,
    COUNT(*) FILTER (WHERE p.status = 'pending_evidence')::integer AS pending_evidence_count,
    COUNT(*) FILTER (WHERE p.status = 'credit_confirmed')::integer AS pending_credit_confirmed_count
  FROM public.order_pending_funding_surplus p
  WHERE p.status IN ('pending_evidence','credit_confirmed')
  GROUP BY p.order_id
), inbound_fx_receipt AS (
  SELECT
    a.order_id,
    ROUND(COALESCE(SUM(ABS(COALESCE(NULLIF(a.fx_or_card_diff_gbp, 0), a.allocated_gbp_amount, 0))), 0)::numeric, 2)
      AS inbound_fx_receipt_residual_gbp,
    COUNT(*)::integer AS inbound_fx_receipt_row_count
  FROM public.dva_statement_line_allocations a
  JOIN public.dva_statement_lines l ON l.id = a.dva_statement_line_id
  JOIN public.dva_statements s ON s.id = l.dva_statement_id
  WHERE a.order_id IS NOT NULL
    AND a.allocation_type = 'fx_card_difference'
    AND a.allocation_status = 'confirmed'
    AND l.direction = 'in'
    AND COALESCE(s.statement_account_context, 'importer_dva_card_account') = 'importer_dva_card_account'
  GROUP BY a.order_id
), final_balance AS (
  SELECT
    a.order_id,
    ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) AS final_balance_payment_gbp
  FROM public.dva_statement_line_allocations a
  WHERE a.order_id IS NOT NULL
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed'
  GROUP BY a.order_id
), sales AS (
  SELECT
    si.order_id,
    COUNT(*) FILTER (
      WHERE si.sage_status = 'posted'
        AND si.sage_invoice_id IS NOT NULL
        AND si.invoice_type IN ('main','supplementary','credit_note')
    )::integer AS final_sale_document_count,
    ROUND(COALESCE(SUM(
      CASE
        WHEN si.sage_status = 'posted' AND si.sage_invoice_id IS NOT NULL AND si.invoice_type = 'credit_note'
          THEN -ABS(COALESCE(si.amount_gbp, 0))
        WHEN si.sage_status = 'posted' AND si.sage_invoice_id IS NOT NULL AND si.invoice_type IN ('main','supplementary')
          THEN COALESCE(si.amount_gbp, 0)
        ELSE 0
      END
    ), 0)::numeric, 2) AS final_order_value_gbp
  FROM public.sales_invoices si
  GROUP BY si.order_id
), order_credit AS (
  SELECT
    c.source_entity_id AS order_id,
    ROUND(COALESCE(SUM(
      CASE WHEN c.direction = 'credit' THEN ABS(c.amount_gbp) ELSE -ABS(c.amount_gbp) END
    ), 0)::numeric, 2) AS confirmed_customer_credit_gbp,
    COUNT(*)::integer AS customer_credit_row_count
  FROM public.importer_credit_ledger c
  WHERE c.source_type IN ('overfunding','settlement_credit')
    AND c.source_entity_type = 'order'
    AND c.source_entity_id IS NOT NULL
    AND c.lock_reason IS NULL
  GROUP BY c.source_entity_id
), settlement_actions AS (
  SELECT
    a.order_id,
    ROUND(COALESCE(SUM(a.fx_card_difference_gbp) FILTER (WHERE a.status = 'active'), 0)::numeric, 2)
      AS settlement_fx_card_difference_gbp,
    COUNT(*) FILTER (WHERE a.status = 'active')::integer AS active_resolution_action_count,
    COUNT(*) FILTER (WHERE a.status = 'reversed')::integer AS reversed_resolution_action_count
  FROM public.order_settlement_resolution_actions a
  GROUP BY a.order_id
), blockers AS (
  SELECT
    o.id AS order_id,
    (
      SELECT COUNT(*)
      FROM public.disputes d
      WHERE d.order_id = o.id
        AND d.resolved_at IS NULL
        AND COALESCE(d.status, '') NOT IN ('closed','resolved','refunded','replaced','closed_no_action')
    )::integer AS open_dispute_count,
    (
      SELECT COUNT(*)
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = o.id
        AND h.resolved_at IS NULL
        AND h.status IN ('requested','supervisor_approved','converted_to_exception')
    )::integer AS active_hold_count
  FROM public.orders o
), base AS (
  SELECT
    o.id AS order_id,
    o.order_ref,
    o.importer_id,
    o.payment_auth_id,
    ROUND(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) AS accepted_estimate_gbp,
    COALESCE(f.funding_total_gbp, 0)::numeric AS funding_total_gbp,
    COALESCE(f.applied_account_credit_gbp, 0)::numeric AS applied_account_credit_gbp,
    COALESCE(pr.pending_receipt_residual_gbp, 0)::numeric AS pending_receipt_residual_gbp,
    COALESCE(pr.pending_evidence_count, 0)::integer AS pending_evidence_count,
    COALESCE(pr.pending_credit_confirmed_count, 0)::integer AS pending_credit_confirmed_count,
    COALESCE(ifx.inbound_fx_receipt_residual_gbp, 0)::numeric AS inbound_fx_receipt_residual_gbp,
    COALESCE(ifx.inbound_fx_receipt_row_count, 0)::integer AS inbound_fx_receipt_row_count,
    COALESCE(fb.final_balance_payment_gbp, 0)::numeric AS final_balance_payment_gbp,
    COALESCE(sa.final_sale_document_count, 0)::integer AS final_sale_document_count,
    COALESCE(sa.final_order_value_gbp, 0)::numeric AS final_order_value_gbp,
    COALESCE(oc.confirmed_customer_credit_gbp, 0)::numeric AS confirmed_customer_credit_gbp,
    COALESCE(oc.customer_credit_row_count, 0)::integer AS customer_credit_row_count,
    COALESCE(act.settlement_fx_card_difference_gbp, 0)::numeric AS settlement_fx_card_difference_gbp,
    COALESCE(act.active_resolution_action_count, 0)::integer AS active_resolution_action_count,
    COALESCE(act.reversed_resolution_action_count, 0)::integer AS reversed_resolution_action_count,
    COALESCE(b.open_dispute_count, 0)::integer AS open_dispute_count,
    COALESCE(b.active_hold_count, 0)::integer AS active_hold_count
  FROM public.orders o
  LEFT JOIN funding f ON f.order_id = o.id
  LEFT JOIN pending_receipt pr ON pr.order_id = o.id
  LEFT JOIN inbound_fx_receipt ifx ON ifx.order_id = o.id
  LEFT JOIN final_balance fb ON fb.order_id = o.id
  LEFT JOIN sales sa ON sa.order_id = o.id
  LEFT JOIN order_credit oc ON oc.order_id = o.id
  LEFT JOIN settlement_actions act ON act.order_id = o.id
  LEFT JOIN blockers b ON b.order_id = o.id
  WHERE COALESCE(o.order_type, 'original') = 'original'
), calculated AS (
  SELECT
    b.*,
    ROUND((b.funding_total_gbp + b.final_balance_payment_gbp)::numeric, 2) AS payment_applied_to_order_gbp,
    ROUND((
      b.funding_total_gbp
      + b.final_balance_payment_gbp
      + b.pending_receipt_residual_gbp
      + b.inbound_fx_receipt_residual_gbp
    )::numeric, 2) AS order_attributed_receipt_gbp,
    ROUND(GREATEST(
      b.funding_total_gbp + b.final_balance_payment_gbp - b.final_order_value_gbp,
      0
    )::numeric, 2) AS order_applied_variance_gbp,
    ROUND(GREATEST(
      b.funding_total_gbp
        + b.final_balance_payment_gbp
        + b.pending_receipt_residual_gbp
        + b.inbound_fx_receipt_residual_gbp
        - b.final_order_value_gbp,
      0
    )::numeric, 2) AS gross_positive_difference_gbp,
    ROUND((
      b.confirmed_customer_credit_gbp
      + b.inbound_fx_receipt_residual_gbp
      + b.settlement_fx_card_difference_gbp
    )::numeric, 2) AS total_classified_gbp
  FROM base b
), resolved AS (
  SELECT
    c.*,
    ROUND((c.gross_positive_difference_gbp - c.total_classified_gbp)::numeric, 2) AS raw_remaining_gbp,
    ROUND(GREATEST(c.gross_positive_difference_gbp - c.total_classified_gbp, 0)::numeric, 2)
      AS remaining_unresolved_gbp,
    ROUND(GREATEST(c.total_classified_gbp - c.gross_positive_difference_gbp, 0)::numeric, 2)
      AS over_resolved_gbp
  FROM calculated c
)
SELECT
  r.*,
  (r.open_dispute_count > 0 OR r.active_hold_count > 0) AS operational_blocked_yn,
  CASE
    WHEN r.open_dispute_count > 0 THEN 'open_dispute_or_exception'
    WHEN r.active_hold_count > 0 THEN 'active_customer_hold'
    ELSE NULL::text
  END AS operational_blocker,
  CASE
    WHEN r.final_sale_document_count = 0 THEN 'not_ready_no_final_sale'
    WHEN r.over_resolved_gbp > 0.01 THEN 'over_resolved_review'
    WHEN r.gross_positive_difference_gbp <= 0.01 THEN 'no_positive_difference'
    WHEN r.remaining_unresolved_gbp <= 0.01 THEN 'fully_resolved'
    WHEN r.total_classified_gbp > 0.01 THEN 'partially_resolved'
    ELSE 'ready_for_resolution'
  END::text AS resolution_status,
  (
    r.final_sale_document_count > 0
    AND r.remaining_unresolved_gbp > 0.01
    AND r.over_resolved_gbp <= 0.01
    AND r.pending_evidence_count = 0
    AND r.open_dispute_count = 0
    AND r.active_hold_count = 0
  ) AS credit_action_allowed_yn,
  CASE
    WHEN r.final_sale_document_count = 0 THEN 'final_sale_documents_missing'
    WHEN r.over_resolved_gbp > 0.01 THEN 'over_resolved_requires_reversal'
    WHEN r.remaining_unresolved_gbp <= 0.01 THEN 'nothing_remaining'
    WHEN r.pending_evidence_count > 0 THEN 'classify_original_receipt_residual_first'
    WHEN r.open_dispute_count > 0 THEN 'open_dispute_or_exception'
    WHEN r.active_hold_count > 0 THEN 'active_customer_hold'
    ELSE NULL::text
  END AS credit_action_blocker,
  (
    r.final_sale_document_count > 0
    AND r.remaining_unresolved_gbp > 0.01
    AND r.over_resolved_gbp <= 0.01
    AND r.pending_evidence_count = 0
    AND r.open_dispute_count = 0
    AND r.active_hold_count = 0
  ) AS fx_action_allowed_yn,
  CASE
    WHEN r.final_sale_document_count = 0 THEN 'final_sale_documents_missing'
    WHEN r.over_resolved_gbp > 0.01 THEN 'over_resolved_requires_reversal'
    WHEN r.remaining_unresolved_gbp <= 0.01 THEN 'nothing_remaining'
    WHEN r.pending_evidence_count > 0 THEN 'classify_original_receipt_residual_first'
    WHEN r.open_dispute_count > 0 THEN 'open_dispute_or_exception'
    WHEN r.active_hold_count > 0 THEN 'active_customer_hold'
    ELSE NULL::text
  END AS fx_action_blocker
FROM resolved r;

REVOKE ALL ON public.order_settlement_resolution_position_v1 FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.internal_order_settlement_resolution_v1(
  p_order_id uuid DEFAULT NULL
)
RETURNS SETOF public.order_settlement_resolution_position_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND COALESCE(s.active, true) = true
  ) THEN
    RAISE EXCEPTION 'Active staff account required.';
  END IF;

  RETURN QUERY
  SELECT p.*
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p_order_id IS NULL OR p.order_id = p_order_id
  ORDER BY p.order_ref;
END;
$$;

CREATE OR REPLACE FUNCTION public.order_settlement_audience_v1(
  p_order_id uuid DEFAULT NULL
)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_id uuid,
  payment_auth_id text,
  accepted_estimate_gbp numeric,
  payment_applied_to_order_gbp numeric,
  final_order_value_gbp numeric,
  order_applied_variance_gbp numeric,
  credit_added_to_account_gbp numeric,
  other_settlement_adjustment_gbp numeric,
  potential_additional_credit_gbp numeric,
  resolution_status text,
  no_importer_action_required_yn boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_staff_yn boolean := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.staff s
    WHERE s.auth_user_id = v_uid
      AND COALESCE(s.active, true) = true
  ) INTO v_staff_yn;

  RETURN QUERY
  SELECT
    p.order_id,
    p.order_ref::text,
    p.importer_id,
    p.payment_auth_id::text,
    p.accepted_estimate_gbp,
    p.payment_applied_to_order_gbp,
    p.final_order_value_gbp,
    p.order_applied_variance_gbp,
    p.confirmed_customer_credit_gbp,
    (p.inbound_fx_receipt_residual_gbp + p.settlement_fx_card_difference_gbp)::numeric,
    p.remaining_unresolved_gbp,
    p.resolution_status,
    true
  FROM public.order_settlement_resolution_position_v1 p
  WHERE (p_order_id IS NULL OR p.order_id = p_order_id)
    AND (
      v_staff_yn
      OR EXISTS (
        SELECT 1
        FROM public.operators op
        JOIN public.operator_importers oi
          ON oi.operator_id = op.id
         AND oi.revoked_at IS NULL
        WHERE op.auth_user_id = v_uid
          AND COALESCE(op.active, true) = true
          AND oi.importer_id = p.importer_id
      )
    )
  ORDER BY p.order_ref;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_resolve_order_settlement_v1(
  p_order_id uuid,
  p_customer_credit_gbp numeric DEFAULT 0,
  p_fx_card_difference_gbp numeric DEFAULT 0,
  p_reason text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_action_key uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_order record;
  v_position record;
  v_existing record;
  v_action_id uuid;
  v_credit_ledger_id uuid;
  v_credit numeric(12,2) := ROUND(GREATEST(COALESCE(p_customer_credit_gbp, 0), 0)::numeric, 2);
  v_fx numeric(12,2) := ROUND(GREATEST(COALESCE(p_fx_card_difference_gbp, 0), 0)::numeric, 2);
  v_total numeric(12,2);
  v_reason text := BTRIM(COALESCE(p_reason, ''));
  v_action_key uuid := COALESCE(p_action_key, gen_random_uuid());
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT s.id, s.role_type
  INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Supervisor/admin required.';
  END IF;

  IF char_length(v_reason) < 8 THEN
    RAISE EXCEPTION 'Resolution reason must contain at least eight characters.';
  END IF;

  v_total := ROUND(v_credit + v_fx, 2);
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Enter a customer-credit amount, an FX/card-difference amount, or both.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_settlement_resolution|' || p_order_id::text));

  SELECT * INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF COALESCE(v_order.order_type, 'original') <> 'original' THEN RAISE EXCEPTION 'Original order required.'; END IF;

  SELECT * INTO v_existing
  FROM public.order_settlement_resolution_actions a
  WHERE a.action_key = v_action_key
  FOR UPDATE;

  IF v_existing.id IS NOT NULL THEN
    IF v_existing.order_id IS DISTINCT FROM p_order_id
       OR ABS(v_existing.customer_credit_gbp - v_credit) > 0.005
       OR ABS(v_existing.fx_card_difference_gbp - v_fx) > 0.005 THEN
      RAISE EXCEPTION 'Action key already belongs to a different settlement resolution.';
    END IF;

    SELECT * INTO v_position
    FROM public.order_settlement_resolution_position_v1 p
    WHERE p.order_id = p_order_id;

    RETURN jsonb_build_object(
      'ok', true,
      'already_applied', true,
      'action_id', v_existing.id,
      'customer_credit_gbp', v_existing.customer_credit_gbp,
      'fx_card_difference_gbp', v_existing.fx_card_difference_gbp,
      'remaining_unresolved_gbp', v_position.remaining_unresolved_gbp,
      'resolution_status', v_position.resolution_status
    );
  END IF;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = p_order_id;

  IF v_position.order_id IS NULL THEN RAISE EXCEPTION 'Settlement position not found.'; END IF;
  IF v_position.final_sale_document_count <= 0 THEN RAISE EXCEPTION 'Final sale documents are not posted.'; END IF;
  IF v_position.over_resolved_gbp > 0.01 THEN RAISE EXCEPTION 'Settlement is over-resolved and requires reversal review.'; END IF;
  IF v_position.pending_evidence_count > 0 THEN RAISE EXCEPTION 'Classify the original receipt residual before resolving the later settlement difference.'; END IF;
  IF v_position.remaining_unresolved_gbp <= 0.01 THEN RAISE EXCEPTION 'No unresolved settlement difference remains.'; END IF;
  IF v_total > v_position.remaining_unresolved_gbp + 0.005 THEN
    RAISE EXCEPTION 'Requested resolution % exceeds remaining unresolved amount %.', v_total, v_position.remaining_unresolved_gbp;
  END IF;
  IF v_position.open_dispute_count > 0 OR v_position.active_hold_count > 0 THEN
    RAISE EXCEPTION 'Open dispute/exception or active hold blocks settlement resolution.';
  END IF;

  INSERT INTO public.order_settlement_resolution_actions (
    action_key,
    order_id,
    importer_id,
    customer_credit_gbp,
    fx_card_difference_gbp,
    reason,
    notes,
    created_by_staff_id
  ) VALUES (
    v_action_key,
    p_order_id,
    v_order.importer_id,
    v_credit,
    v_fx,
    v_reason,
    p_notes,
    v_staff.id
  )
  RETURNING id INTO v_action_id;

  IF v_credit > 0 THEN
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
      'order_settlement_resolution_actions',
      v_action_id,
      p_order_id,
      NULL,
      'credit',
      v_credit,
      v_credit,
      'GBP',
      now(),
      'settlement_credit',
      'order',
      p_order_id,
      NULL,
      NULL,
      v_staff.id,
      concat_ws(E'\n', 'Incremental final-settlement customer credit.', 'Reason: ' || v_reason, p_notes)
    )
    RETURNING id INTO v_credit_ledger_id;

    UPDATE public.order_settlement_resolution_actions
    SET credit_ledger_id = v_credit_ledger_id
    WHERE id = v_action_id;
  END IF;

  SELECT * INTO v_position
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = p_order_id;

  RETURN jsonb_build_object(
    'ok', true,
    'already_applied', false,
    'action_id', v_action_id,
    'credit_ledger_id', v_credit_ledger_id,
    'customer_credit_gbp', v_credit,
    'fx_card_difference_gbp', v_fx,
    'gross_positive_difference_gbp', v_position.gross_positive_difference_gbp,
    'confirmed_customer_credit_gbp', v_position.confirmed_customer_credit_gbp,
    'confirmed_fx_card_difference_gbp', v_position.inbound_fx_receipt_residual_gbp + v_position.settlement_fx_card_difference_gbp,
    'remaining_unresolved_gbp', v_position.remaining_unresolved_gbp,
    'resolution_status', v_position.resolution_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_order_settlement_resolution_v1(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.order_settlement_audience_v1(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.staff_resolve_order_settlement_v1(uuid,numeric,numeric,text,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.internal_order_settlement_resolution_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.order_settlement_audience_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_resolve_order_settlement_v1(uuid,numeric,numeric,text,text,uuid) TO authenticated;

COMMENT ON TABLE public.order_settlement_resolution_actions IS
'Additive audit record for incremental final-settlement classification. Customer-credit amounts create linked importer_credit_ledger rows; settlement FX amounts do not consume the physical statement line again.';
COMMENT ON VIEW public.order_settlement_resolution_position_v1 IS
'Canonical order settlement position: order-attributed receipt less signed final sale value, split into confirmed customer credit, confirmed FX/card difference and remaining unresolved amount.';
COMMENT ON FUNCTION public.staff_resolve_order_settlement_v1(uuid,numeric,numeric,text,text,uuid) IS
'Incrementally classifies only the currently unresolved final-settlement difference as customer credit, FX/card difference, or both. Uses an order lock and idempotency key.';

NOTIFY pgrst, 'reload schema';
COMMIT;
