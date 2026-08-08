BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/governing-pack/accounting/
-- DEFERRED_PENDING_RECEIPT_SURPLUS_CREDIT_RESOLUTION_ADDENDUM_v1.md
--
-- Exact scope:
--   1. pending-only evidence additionally recognises confirmed final-balance payments;
--   2. the established credit-confirmation RPC remains unchanged;
--   3. a new wrapper records future-only provenance after that RPC succeeds;
--   4. only the supplier-OUT FX INPUT to canonical settlement is reduced by the
--      exact overlap displaced by a new-path pending-residual credit;
--   5. canonical base/calculated/resolved/final settlement structure and arithmetic
--      remain byte-for-byte sourced from the installed view definition.

DO $prereq$
BEGIN
  IF to_regclass('public.order_pending_funding_surplus') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_pending_funding_surplus.';
  END IF;
  IF to_regclass('public.order_surplus_evidence_position_v2') IS NULL
     OR to_regclass('public.order_surplus_evidence_position_v3') IS NULL THEN
    RAISE EXCEPTION 'Missing established surplus-evidence views.';
  END IF;
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1.';
  END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.dva_statement_lines') IS NULL
     OR to_regclass('public.dva_statements') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.importer_credit_ledger') IS NULL
     OR to_regclass('public.order_settlement_resolution_actions') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Required established settlement/evidence objects are missing.';
  END IF;
  IF to_regprocedure('public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing established staff_confirm_surplus_from_evidence_min_v1 prerequisite.';
  END IF;
  IF to_regprocedure('public.internal_order_settlement_resolution_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing established internal settlement RPC contract.';
  END IF;
END
$prereq$;

CREATE TEMP TABLE pending_receipt_surplus_contract_guard_v1
ON COMMIT DROP
AS
SELECT
  'order_surplus_evidence_position_v3'::text AS object_name,
  array_agg(c.column_name::text ORDER BY c.ordinal_position) AS column_names
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.table_name = 'order_surplus_evidence_position_v3'
UNION ALL
SELECT
  'order_settlement_resolution_position_v1'::text,
  array_agg(c.column_name::text ORDER BY c.ordinal_position)
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.table_name = 'order_settlement_resolution_position_v1';

-- 1. Correct only the pending branch of v3 evidence.
CREATE OR REPLACE VIEW public.order_surplus_evidence_position_v3 AS
WITH pending AS (
  SELECT
    p.order_id,
    ROUND(SUM(p.pending_surplus_gbp)::numeric, 2) AS pending_surplus_gbp,
    COUNT(*)::integer AS pending_position_count,
    COUNT(*) FILTER (WHERE p.status = 'credit_confirmed')::integer AS pending_credit_confirmed_count
  FROM public.order_pending_funding_surplus p
  WHERE p.status IN ('pending_evidence','credit_confirmed')
  GROUP BY p.order_id
), final_balance AS (
  SELECT
    a.order_id,
    ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) AS final_balance_payment_gbp
  FROM public.dva_statement_line_allocations a
  WHERE a.order_id IS NOT NULL
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed'
  GROUP BY a.order_id
), calculated AS (
  SELECT
    v.*,
    COALESCE(p.pending_surplus_gbp, 0)::numeric AS pending_surplus_gbp,
    COALESCE(p.pending_position_count, 0)::integer AS pending_position_count,
    COALESCE(p.pending_credit_confirmed_count, 0)::integer AS pending_credit_confirmed_count,
    ROUND((
      v.funding_total_gbp
      + COALESCE(p.pending_surplus_gbp, 0)
      + CASE WHEN COALESCE(p.pending_position_count, 0) > 0
          THEN COALESCE(fb.final_balance_payment_gbp, 0) ELSE 0 END
    )::numeric, 2) AS effective_receipt_gbp,
    ROUND((
      v.funding_total_gbp
      + COALESCE(p.pending_surplus_gbp, 0)
      + CASE WHEN COALESCE(p.pending_position_count, 0) > 0
          THEN COALESCE(fb.final_balance_payment_gbp, 0) ELSE 0 END
      - v.evidence_value_gbp
    )::numeric, 2) AS pending_aware_evidence_surplus_gbp
  FROM public.order_surplus_evidence_position_v2 v
  LEFT JOIN pending p ON p.order_id = v.order_id
  LEFT JOIN final_balance fb ON fb.order_id = v.order_id
)
SELECT
  c.order_id,
  c.order_ref,
  c.importer_id,
  c.payment_auth_id,
  c.declared_order_gbp,
  c.funding_total_gbp,
  c.supplier_out_gbp,
  c.supplier_out_count,
  c.posted_invoice_gbp,
  c.posted_invoice_count,
  c.draft_invoice_gbp,
  c.draft_invoice_count,
  c.credit_created_gbp,
  c.open_dispute_count,
  c.active_hold_count,
  c.evidence_value_gbp,
  CASE WHEN c.pending_position_count > 0 THEN c.pending_aware_evidence_surplus_gbp ELSE c.evidence_surplus_gbp END::numeric AS evidence_surplus_gbp,
  CASE
    WHEN c.pending_position_count = 0 THEN c.evidence_status
    WHEN c.credit_created_gbp > 0 THEN 'credit_created'
    WHEN c.open_dispute_count > 0 OR c.active_hold_count > 0 THEN 'blocked_by_open_issue'
    WHEN c.effective_receipt_gbp <= 0 THEN 'no_confirmed_funding'
    WHEN c.evidence_basis = 'posted_customer_invoice' AND c.pending_aware_evidence_surplus_gbp > 0 THEN 'ready_posted_invoice_surplus'
    WHEN c.evidence_basis = 'draft_customer_invoice' AND c.pending_aware_evidence_surplus_gbp > 0 THEN 'ready_draft_invoice_surplus'
    WHEN c.evidence_basis = 'matched_supplier_out' AND c.pending_aware_evidence_surplus_gbp > 0 THEN 'ready_strong_in_out_surplus'
    WHEN c.evidence_basis = 'matched_supplier_out' THEN 'in_out_no_surplus'
    ELSE 'pending_insufficient_evidence'
  END::text AS evidence_status,
  c.evidence_basis,
  c.effective_receipt_gbp,
  c.pending_surplus_gbp,
  c.pending_position_count,
  c.pending_credit_confirmed_count
FROM calculated c;

COMMENT ON VIEW public.order_surplus_evidence_position_v3 IS
'Pending-aware wrapper over v2. Only active pending positions additionally recognise confirmed final_balance_payment allocations when measuring effective receipt against downstream evidence; non-pending behaviour remains v2-compatible.';

-- 2. Future-only provenance. No backfill.
CREATE TABLE public.order_pending_surplus_credit_resolution_provenance_v1 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  pending_surplus_id uuid NOT NULL REFERENCES public.order_pending_funding_surplus(id),
  confirmed_credit_ledger_id uuid NOT NULL REFERENCES public.importer_credit_ledger(id),
  created_by_staff_id uuid NOT NULL REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_pending_surplus_credit_resolution_pending_v1 UNIQUE (pending_surplus_id),
  CONSTRAINT uq_pending_surplus_credit_resolution_credit_v1 UNIQUE (confirmed_credit_ledger_id)
);

CREATE INDEX idx_pending_surplus_credit_resolution_order_v1
  ON public.order_pending_surplus_credit_resolution_provenance_v1(order_id, created_at);
ALTER TABLE public.order_pending_surplus_credit_resolution_provenance_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_pending_surplus_credit_resolution_provenance_v1 FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.order_pending_surplus_credit_resolution_provenance_v1 IS
'Future-only provenance linking one original pending customer receipt residual to the exact customer credit created through the deferred pending-residual confirmation wrapper. No backfill and no FX mutation.';

-- 3. Atomic wrapper. Lock order matches the established RPC: order then pending.
CREATE OR REPLACE FUNCTION public.staff_confirm_pending_receipt_surplus_credit_v1(
  p_order_id uuid,
  p_reason text DEFAULT 'supervisor_confirmed_credit',
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_order record;
  v_pending record;
  v_evidence record;
  v_provenance record;
  v_result jsonb;
  v_active_count integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid() AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Supervisor/admin required.';
  END IF;

  SELECT o.id, COALESCE(o.order_type, 'original') AS order_type
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_order.order_type <> 'original' THEN RAISE EXCEPTION 'Original order required.'; END IF;

  SELECT COUNT(*)::integer INTO v_active_count
  FROM public.order_pending_funding_surplus p
  WHERE p.order_id = p_order_id AND p.status IN ('pending_evidence','credit_confirmed');

  IF v_active_count <> 1 THEN
    RAISE EXCEPTION 'Exactly one active pending receipt residual is required; found %.', v_active_count;
  END IF;

  SELECT p.* INTO v_pending
  FROM public.order_pending_funding_surplus p
  WHERE p.order_id = p_order_id AND p.status IN ('pending_evidence','credit_confirmed')
  ORDER BY p.created_at, p.id
  LIMIT 1
  FOR UPDATE;

  SELECT pr.* INTO v_provenance
  FROM public.order_pending_surplus_credit_resolution_provenance_v1 pr
  WHERE pr.pending_surplus_id = v_pending.id;

  IF v_provenance.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_confirmed', true,
      'pending_surplus_id', v_pending.id,
      'credit_ledger_id', v_provenance.confirmed_credit_ledger_id,
      'provenance_id', v_provenance.id
    );
  END IF;

  IF v_pending.status <> 'pending_evidence' THEN
    RAISE EXCEPTION 'Existing credit_confirmed pending residual has no new-path provenance; legacy rows are not backfilled.';
  END IF;

  SELECT e.* INTO v_evidence
  FROM public.order_surplus_evidence_position_v3 e
  WHERE e.order_id = p_order_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Pending-aware surplus evidence position is missing.'; END IF;
  IF v_evidence.evidence_status NOT IN ('ready_posted_invoice_surplus','ready_draft_invoice_surplus','ready_strong_in_out_surplus') THEN
    RAISE EXCEPTION 'Not ready: %', v_evidence.evidence_status;
  END IF;
  IF v_evidence.evidence_surplus_gbp <= 0 THEN RAISE EXCEPTION 'No surplus.'; END IF;

  SELECT public.staff_confirm_surplus_from_evidence_min_v1(p_order_id, p_reason, p_notes)
  INTO v_result;

  SELECT p.* INTO v_pending
  FROM public.order_pending_funding_surplus p
  WHERE p.id = v_pending.id
  FOR UPDATE;

  IF v_pending.status <> 'credit_confirmed' OR v_pending.confirmed_credit_ledger_id IS NULL THEN
    RAISE EXCEPTION 'Established confirmation RPC did not produce the required credit_confirmed provenance state.';
  END IF;

  INSERT INTO public.order_pending_surplus_credit_resolution_provenance_v1 (
    order_id, pending_surplus_id, confirmed_credit_ledger_id, created_by_staff_id
  ) VALUES (
    p_order_id, v_pending.id, v_pending.confirmed_credit_ledger_id, v_staff.id
  ) RETURNING * INTO v_provenance;

  RETURN COALESCE(v_result, '{}'::jsonb) || jsonb_build_object(
    'pending_surplus_id', v_pending.id,
    'credit_ledger_id', v_pending.confirmed_credit_ledger_id,
    'provenance_id', v_provenance.id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_confirm_pending_receipt_surplus_credit_v1(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_confirm_pending_receipt_surplus_credit_v1(uuid,text,text) TO authenticated;

COMMENT ON FUNCTION public.staff_confirm_pending_receipt_surplus_credit_v1(uuid,text,text) IS
'Atomic future-only wrapper around staff_confirm_surplus_from_evidence_min_v1. It locks order then pending receipt, calls the established accounting RPC unchanged, then records exact pending-to-credit provenance. Historical credit_confirmed rows are not backfilled.';

-- 4. Restore the proven narrow July patch pattern: replace ONLY settlement_actions.
--    All provenance lookup and overlap maths stay inside this CTE. The installed
--    blockers/base/calculated/resolved/final SQL is preserved verbatim.
DO $settlement_patch$
DECLARE
  v_definition text;
  v_lower text;
  v_current_settlement text;
  v_patched text;
  v_start integer;
  v_end integer;
  v_start_count integer;
  v_end_count integer;
  v_tail_original text;
  v_tail_patched text;
  v_start_anchor text := 'settlement_actions as (';
  v_end_anchor text := '), blockers as (';
  v_new text := $new$
settlement_actions AS (
   SELECT x.order_id,
      round(COALESCE(sum(x.fx_card_difference_gbp), (0)::numeric), 2) AS settlement_fx_card_difference_gbp,
      COALESCE(sum(x.active_resolution_action_count), (0)::bigint)::integer AS active_resolution_action_count,
      COALESCE(sum(x.reversed_resolution_action_count), (0)::bigint)::integer AS reversed_resolution_action_count
     FROM (
       SELECT a.order_id,
          COALESCE(sum(a.fx_card_difference_gbp) FILTER (WHERE a.status = 'active'::text), (0)::numeric) AS fx_card_difference_gbp,
          count(*) FILTER (WHERE a.status = 'active'::text) AS active_resolution_action_count,
          count(*) FILTER (WHERE a.status = 'reversed'::text) AS reversed_resolution_action_count
         FROM public.order_settlement_resolution_actions a
        GROUP BY a.order_id
       UNION ALL
       SELECT supplier_input.order_id,
          GREATEST(
            supplier_input.raw_supplier_fx_gbp
            - GREATEST(
                supplier_input.supplier_needed_before_pending_credit_gbp
                - supplier_input.supplier_needed_after_pending_credit_gbp,
                (0)::numeric
              ),
            (0)::numeric
          ) AS fx_card_difference_gbp,
          (0)::bigint AS active_resolution_action_count,
          (0)::bigint AS reversed_resolution_action_count
         FROM (
           SELECT supplier_raw.order_id,
              supplier_raw.raw_supplier_fx_gbp,
              round(LEAST(
                supplier_raw.raw_supplier_fx_gbp,
                GREATEST(
                  inputs.gross_positive_difference_gbp
                  - inputs.explicit_before_pending_credit_gbp,
                  (0)::numeric
                )
              )::numeric, 2) AS supplier_needed_before_pending_credit_gbp,
              round(LEAST(
                supplier_raw.raw_supplier_fx_gbp,
                GREATEST(
                  inputs.gross_positive_difference_gbp
                  - (
                      inputs.explicit_before_pending_credit_gbp
                      + COALESCE(pc.pending_resolution_credit_gbp, (0)::numeric)
                    ),
                  (0)::numeric
                )
              )::numeric, 2) AS supplier_needed_after_pending_credit_gbp
             FROM (
               SELECT supplier_order.order_id,
                  COALESCE(sum(abs(COALESCE(NULLIF(fx.fx_or_card_diff_gbp, (0)::numeric), fx.allocated_gbp_amount, (0)::numeric))), (0)::numeric) AS raw_supplier_fx_gbp
                 FROM public.dva_statement_line_allocations fx
                 JOIN public.dva_statement_lines dsl ON dsl.id = fx.dva_statement_line_id
                 JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
                 JOIN LATERAL (
                   WITH supplier_orders AS (
                     SELECT DISTINCT COALESCE(si.order_id, supplier_alloc.order_id) AS order_id
                       FROM public.dva_statement_line_allocations supplier_alloc
                       LEFT JOIN public.supplier_invoices si ON si.id = supplier_alloc.supplier_invoice_id
                      WHERE supplier_alloc.dva_statement_line_id = fx.dva_statement_line_id
                        AND supplier_alloc.allocation_status = 'confirmed'::text
                        AND supplier_alloc.allocation_type = 'supplier_invoice'::text
                        AND COALESCE(si.order_id, supplier_alloc.order_id) IS NOT NULL
                   )
                   SELECT so.order_id
                     FROM supplier_orders so
                    WHERE (SELECT count(*) FROM supplier_orders) = 1
                 ) supplier_order ON true
                WHERE fx.allocation_type = 'fx_card_difference'::text
                  AND fx.allocation_status = 'confirmed'::text
                  AND dsl.direction = 'out'::text
                  AND COALESCE(ds.statement_account_context, 'importer_dva_card_account'::text) = 'importer_dva_card_account'::text
                GROUP BY supplier_order.order_id
             ) supplier_raw
             LEFT JOIN funding f ON f.order_id = supplier_raw.order_id
             LEFT JOIN pending_receipt pr ON pr.order_id = supplier_raw.order_id
             LEFT JOIN inbound_fx_receipt ifx ON ifx.order_id = supplier_raw.order_id
             LEFT JOIN final_balance fb ON fb.order_id = supplier_raw.order_id
             LEFT JOIN sales sa ON sa.order_id = supplier_raw.order_id
             LEFT JOIN order_credit oc ON oc.order_id = supplier_raw.order_id
             LEFT JOIN LATERAL (
               SELECT round(COALESCE(sum(abs(c.amount_gbp)), (0)::numeric), 2) AS pending_resolution_credit_gbp
                 FROM public.order_pending_surplus_credit_resolution_provenance_v1 provenance
                 JOIN public.importer_credit_ledger c ON c.id = provenance.confirmed_credit_ledger_id
                WHERE provenance.order_id = supplier_raw.order_id
                  AND c.direction = 'credit'::text
                  AND c.lock_reason IS NULL
             ) pc ON true
             LEFT JOIN LATERAL (
               SELECT COALESCE(sum(a.fx_card_difference_gbp) FILTER (WHERE a.status = 'active'::text), (0)::numeric) AS active_action_fx_gbp
                 FROM public.order_settlement_resolution_actions a
                WHERE a.order_id = supplier_raw.order_id
             ) explicit_fx ON true
             LEFT JOIN LATERAL (
               SELECT
                 round(GREATEST(
                   COALESCE(f.funding_total_gbp, (0)::numeric)
                   + COALESCE(fb.final_balance_payment_gbp, (0)::numeric)
                   + COALESCE(pr.pending_receipt_residual_gbp, (0)::numeric)
                   + COALESCE(ifx.inbound_fx_receipt_residual_gbp, (0)::numeric)
                   - COALESCE(sa.final_order_value_gbp, (0)::numeric),
                   (0)::numeric
                 )::numeric, 2) AS gross_positive_difference_gbp,
                 round((
                   GREATEST(
                     COALESCE(oc.confirmed_customer_credit_gbp, (0)::numeric)
                     - COALESCE(pc.pending_resolution_credit_gbp, (0)::numeric),
                     (0)::numeric
                   )
                   + COALESCE(ifx.inbound_fx_receipt_residual_gbp, (0)::numeric)
                   + COALESCE(explicit_fx.active_action_fx_gbp, (0)::numeric)
                 )::numeric, 2) AS explicit_before_pending_credit_gbp
             ) inputs ON true
         ) supplier_input
     ) x
    GROUP BY x.order_id
), blockers AS (
$new$;
BEGIN
  SELECT pg_get_viewdef('public.order_settlement_resolution_position_v1'::regclass, true)
  INTO v_definition;
  v_lower := lower(v_definition);

  v_start_count := (length(v_lower) - length(replace(v_lower, v_start_anchor, ''))) / length(v_start_anchor);
  v_end_count := (length(v_lower) - length(replace(v_lower, v_end_anchor, ''))) / length(v_end_anchor);
  IF v_start_count <> 1 OR v_end_count <> 1 THEN
    RAISE EXCEPTION 'Canonical settlement_actions/blockers boundaries drifted. Stop before patching.';
  END IF;

  v_start := position(v_start_anchor IN v_lower);
  v_end := position(v_end_anchor IN v_lower);
  IF v_start <= 0 OR v_end <= v_start THEN
    RAISE EXCEPTION 'Canonical settlement CTE order has drifted. Stop before patching.';
  END IF;

  -- Match the July migration's deparser-safe approach: prove the existing
  -- settlement_actions CTE semantically, not through brittle alias/whitespace text.
  v_current_settlement := substring(v_lower FROM v_start FOR v_end - v_start);
  IF position('fx_card_difference' IN v_current_settlement) = 0
     OR position('supplier_invoice' IN v_current_settlement) = 0
     OR position('supplier_order' IN v_current_settlement) = 0
     OR position('supplier_alloc' IN v_current_settlement) = 0
     OR position('direction' IN v_current_settlement) = 0
     OR position('''out''' IN v_current_settlement) = 0
     OR position('statement_account_context' IN v_current_settlement) = 0
     OR position('settlement_fx_card_difference_gbp' IN v_current_settlement) = 0 THEN
    RAISE EXCEPTION 'Established supplier-OUT FX settlement inference is not semantically present inside settlement_actions. Stop before patching.';
  END IF;

  v_tail_original := substring(v_definition FROM v_end + length(v_end_anchor));
  v_patched := substring(v_definition FROM 1 FOR v_start - 1) || rtrim(v_new) || v_tail_original;

  -- Hard scope guard: everything after the settlement_actions boundary is unchanged.
  v_tail_patched := substring(v_patched FROM position('blockers as (' IN lower(v_patched)) + length('blockers as ('));
  IF v_tail_patched IS DISTINCT FROM v_tail_original THEN
    RAISE EXCEPTION 'Scope violation: blockers/base/calculated/resolved/final settlement SQL changed. Stop before patching.';
  END IF;

  EXECUTE 'CREATE OR REPLACE VIEW public.order_settlement_resolution_position_v1 AS ' || v_patched;
END
$settlement_patch$;

DO $post_guard$
DECLARE
  v_before text[];
  v_after text[];
  v_count integer;
BEGIN
  SELECT g.column_names INTO v_before FROM pending_receipt_surplus_contract_guard_v1 g WHERE g.object_name = 'order_surplus_evidence_position_v3';
  SELECT array_agg(c.column_name::text ORDER BY c.ordinal_position) INTO v_after
  FROM information_schema.columns c WHERE c.table_schema = 'public' AND c.table_name = 'order_surplus_evidence_position_v3';
  IF v_before IS DISTINCT FROM v_after THEN RAISE EXCEPTION 'order_surplus_evidence_position_v3 column contract changed. Stop.'; END IF;

  SELECT g.column_names INTO v_before FROM pending_receipt_surplus_contract_guard_v1 g WHERE g.object_name = 'order_settlement_resolution_position_v1';
  SELECT array_agg(c.column_name::text ORDER BY c.ordinal_position) INTO v_after
  FROM information_schema.columns c WHERE c.table_schema = 'public' AND c.table_name = 'order_settlement_resolution_position_v1';
  IF v_before IS DISTINCT FROM v_after THEN RAISE EXCEPTION 'order_settlement_resolution_position_v1 column contract changed. Stop.'; END IF;

  SELECT COUNT(*)::integer INTO v_count FROM public.order_pending_surplus_credit_resolution_provenance_v1;
  IF v_count <> 0 THEN RAISE EXCEPTION 'New provenance table must install empty; legacy rows must not be backfilled.'; END IF;
END
$post_guard$;

NOTIFY pgrst, 'reload schema';
COMMIT;
