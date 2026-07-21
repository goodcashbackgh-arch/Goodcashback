BEGIN;

-- Amount-aware statement-line control v1.
-- Additive shared resolver and future order-funding write guard.
-- Existing specialist write RPCs remain authoritative.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.dva_statements') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statements'; END IF;
  IF to_regclass('public.dva_reconciliation') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_reconciliation'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches'; END IF;
  IF to_regclass('public.completion_loyalty_reward_funding_confirmations') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_reward_funding_confirmations'; END IF;
  IF to_regclass('public.main_bank_shipper_ap_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_shipper_ap_allocations'; END IF;
END $$;

CREATE OR REPLACE VIEW public.statement_line_control_usage_v1 AS
WITH funding AS (
  SELECT
    dr.dva_statement_line_id AS statement_line_id,
    'order_funding_reconciliation'::text AS raw_family,
    CASE WHEN COALESCE(dr.reconciliation_type::text, '') = 'order_funding'
      THEN 'customer_order_funding'::text
      ELSE 'legacy_dva_reconciliation'::text
    END AS economic_lane,
    true AS principal_lane,
    false AS documentary_only,
    'active'::text AS evidence_state,
    ROUND(ABS(COALESCE(dr.reconciled_gbp_amount, 0))::numeric, 2) AS consumed_gbp,
    0::numeric AS reserved_gbp,
    dr.id AS evidence_id,
    jsonb_build_object(
      'table', 'dva_reconciliation',
      'id', dr.id,
      'reconciliation_type', dr.reconciliation_type,
      'order_id', dr.order_id,
      'supplier_invoice_id', dr.supplier_invoice_id,
      'dispute_id', dr.dispute_id
    ) AS evidence_json
  FROM public.dva_reconciliation dr
  WHERE dr.dva_statement_line_id IS NOT NULL
), allocations AS (
  SELECT
    a.dva_statement_line_id AS statement_line_id,
    'dva_allocation'::text AS raw_family,
    CASE a.allocation_type::text
      WHEN 'supplier_invoice' THEN 'supplier_payment'
      WHEN 'retailer_refund' THEN 'retailer_refund'
      WHEN 'final_balance_payment' THEN 'final_balance_payment'
      WHEN 'fx_card_difference' THEN 'fx_card_difference'
      WHEN 'bank_fee' THEN 'bank_fee'
      WHEN 'exception_hold' THEN 'exception_control'
      WHEN 'not_charged_closure' THEN 'exception_control'
      WHEN 'unmatched_hold' THEN 'exception_control'
      ELSE 'exception_control'
    END AS economic_lane,
    a.allocation_type::text IN ('supplier_invoice','retailer_refund','final_balance_payment') AS principal_lane,
    false AS documentary_only,
    CASE WHEN a.allocation_status::text = 'reversed' THEN 'historical' ELSE 'active' END AS evidence_state,
    CASE WHEN a.allocation_status::text = 'confirmed'
      THEN ROUND(ABS(COALESCE(a.allocated_gbp_amount, 0))::numeric, 2)
      ELSE 0::numeric
    END AS consumed_gbp,
    CASE WHEN a.allocation_status::text IN ('draft','held')
      THEN ROUND(ABS(COALESCE(a.allocated_gbp_amount, 0))::numeric, 2)
      ELSE 0::numeric
    END AS reserved_gbp,
    a.id AS evidence_id,
    jsonb_build_object(
      'table', 'dva_statement_line_allocations',
      'id', a.id,
      'allocation_type', a.allocation_type,
      'allocation_status', a.allocation_status,
      'supplier_invoice_id', a.supplier_invoice_id,
      'dispute_id', a.dispute_id,
      'order_id', a.order_id
    ) AS evidence_json
  FROM public.dva_statement_line_allocations a
), loyalty_source AS (
  SELECT
    lm.dva_statement_line_id AS statement_line_id,
    'completion_loyalty_source_match'::text AS raw_family,
    'completion_loyalty_source_transfer'::text AS economic_lane,
    true AS principal_lane,
    false AS documentary_only,
    CASE WHEN lm.match_status::text = 'reversed' OR COALESCE(lm.transfer_pair_status::text, '') = 'reversed'
      THEN 'historical' ELSE 'active' END AS evidence_state,
    CASE WHEN lm.match_status::text IN ('confirmed','released_available_dashboard_credit')
      THEN ROUND(ABS(COALESCE(lm.matched_gbp_amount, 0))::numeric, 2)
      ELSE 0::numeric
    END AS consumed_gbp,
    0::numeric AS reserved_gbp,
    lm.id AS evidence_id,
    jsonb_build_object(
      'table', 'main_bank_completion_loyalty_funding_matches',
      'id', lm.id,
      'side', 'source_out',
      'match_status', lm.match_status,
      'transfer_pair_status', lm.transfer_pair_status,
      'completed_order_id', lm.completed_order_id,
      'destination_in_statement_line_id', lm.destination_in_statement_line_id
    ) AS evidence_json
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.dva_statement_line_id IS NOT NULL
), loyalty_destination AS (
  SELECT
    lm.destination_in_statement_line_id AS statement_line_id,
    'completion_loyalty_destination_match'::text AS raw_family,
    'completion_loyalty_destination_transfer'::text AS economic_lane,
    true AS principal_lane,
    false AS documentary_only,
    CASE WHEN lm.match_status::text = 'reversed' OR COALESCE(lm.transfer_pair_status::text, '') = 'reversed'
      THEN 'historical' ELSE 'active' END AS evidence_state,
    CASE WHEN lm.match_status::text IN ('confirmed','released_available_dashboard_credit')
      THEN ROUND(ABS(COALESCE(lm.matched_gbp_amount, 0))::numeric, 2)
      ELSE 0::numeric
    END AS consumed_gbp,
    0::numeric AS reserved_gbp,
    lm.id AS evidence_id,
    jsonb_build_object(
      'table', 'main_bank_completion_loyalty_funding_matches',
      'id', lm.id,
      'side', 'destination_in',
      'match_status', lm.match_status,
      'transfer_pair_status', lm.transfer_pair_status,
      'completed_order_id', lm.completed_order_id,
      'source_out_statement_line_id', lm.dva_statement_line_id
    ) AS evidence_json
  FROM public.main_bank_completion_loyalty_funding_matches lm
  WHERE lm.destination_in_statement_line_id IS NOT NULL
), loyalty_confirmation AS (
  SELECT
    fc.dva_statement_line_id AS statement_line_id,
    'completion_loyalty_funding_confirmation'::text AS raw_family,
    CASE WHEN EXISTS (
      SELECT 1
      FROM public.main_bank_completion_loyalty_funding_matches lm
      WHERE lm.funding_confirmation_id = fc.id
    ) THEN 'completion_loyalty_destination_transfer'
    ELSE 'legacy_completion_loyalty_funding'
    END AS economic_lane,
    NOT EXISTS (
      SELECT 1
      FROM public.main_bank_completion_loyalty_funding_matches lm
      WHERE lm.funding_confirmation_id = fc.id
    ) AS principal_lane,
    EXISTS (
      SELECT 1
      FROM public.main_bank_completion_loyalty_funding_matches lm
      WHERE lm.funding_confirmation_id = fc.id
    ) AS documentary_only,
    CASE WHEN fc.funding_status::text LIKE 'reversed%' THEN 'historical' ELSE 'active' END AS evidence_state,
    CASE WHEN NOT EXISTS (
      SELECT 1
      FROM public.main_bank_completion_loyalty_funding_matches lm
      WHERE lm.funding_confirmation_id = fc.id
    ) AND fc.funding_status::text NOT LIKE 'reversed%'
      THEN ROUND(ABS(COALESCE(fc.amount_released_gbp, fc.amount_funded_gbp, 0))::numeric, 2)
      ELSE 0::numeric
    END AS consumed_gbp,
    0::numeric AS reserved_gbp,
    fc.id AS evidence_id,
    jsonb_build_object(
      'table', 'completion_loyalty_reward_funding_confirmations',
      'id', fc.id,
      'funding_status', fc.funding_status,
      'approval_id', fc.approval_id,
      'completed_order_id', fc.completed_order_id
    ) AS evidence_json
  FROM public.completion_loyalty_reward_funding_confirmations fc
  WHERE fc.dva_statement_line_id IS NOT NULL
), shipper_ap AS (
  SELECT
    a.dva_statement_line_id AS statement_line_id,
    'main_bank_shipper_ap'::text AS raw_family,
    'main_bank_shipper_ap'::text AS economic_lane,
    true AS principal_lane,
    false AS documentary_only,
    CASE WHEN a.allocation_status::text = 'reversed' THEN 'historical' ELSE 'active' END AS evidence_state,
    CASE WHEN a.allocation_status::text = 'confirmed'
      THEN ROUND(ABS(COALESCE(a.allocated_gbp_amount, 0))::numeric, 2)
      ELSE 0::numeric
    END AS consumed_gbp,
    0::numeric AS reserved_gbp,
    a.id AS evidence_id,
    jsonb_build_object(
      'table', 'main_bank_shipper_ap_allocations',
      'id', a.id,
      'allocation_status', a.allocation_status,
      'shipping_document_id', a.shipping_document_id
    ) AS evidence_json
  FROM public.main_bank_shipper_ap_allocations a
), cash_snapshot AS (
  SELECT
    s.statement_line_id,
    'cash_posting_snapshot'::text AS raw_family,
    'customer_order_funding'::text AS economic_lane,
    false AS principal_lane,
    true AS documentary_only,
    CASE WHEN COALESCE(s.active, false) THEN 'active' ELSE 'historical' END AS evidence_state,
    0::numeric AS consumed_gbp,
    0::numeric AS reserved_gbp,
    s.id AS evidence_id,
    jsonb_build_object(
      'table', 'cash_posting_snapshots',
      'id', s.id,
      'active', s.active,
      'posting_category', s.posting_category,
      'sage_posting_status', s.sage_posting_status
    ) AS evidence_json
  FROM public.cash_posting_snapshots s
  WHERE s.statement_line_id IS NOT NULL
)
SELECT * FROM funding
UNION ALL SELECT * FROM allocations
UNION ALL SELECT * FROM loyalty_source
UNION ALL SELECT * FROM loyalty_destination
UNION ALL SELECT * FROM loyalty_confirmation
UNION ALL SELECT * FROM shipper_ap
UNION ALL SELECT * FROM cash_snapshot;

CREATE OR REPLACE VIEW public.statement_line_control_position_v1 AS
WITH active_usage AS (
  SELECT
    u.statement_line_id,
    ROUND(COALESCE(SUM(u.consumed_gbp) FILTER (WHERE u.evidence_state = 'active' AND NOT u.documentary_only), 0)::numeric, 2) AS active_consumed_gbp,
    ROUND(COALESCE(SUM(u.reserved_gbp) FILTER (WHERE u.evidence_state = 'active' AND NOT u.documentary_only), 0)::numeric, 2) AS active_reserved_gbp,
    ARRAY_AGG(DISTINCT u.raw_family ORDER BY u.raw_family) FILTER (WHERE u.evidence_state = 'active') AS raw_active_families,
    ARRAY_AGG(DISTINCT u.economic_lane ORDER BY u.economic_lane) FILTER (WHERE u.evidence_state = 'active' AND NOT u.documentary_only) AS active_economic_lanes,
    COUNT(DISTINCT u.economic_lane) FILTER (WHERE u.evidence_state = 'active' AND u.principal_lane AND NOT u.documentary_only) AS principal_lane_count,
    COUNT(*) FILTER (WHERE u.evidence_state = 'historical') AS historical_row_count,
    JSONB_AGG(u.evidence_json ORDER BY u.raw_family, u.evidence_id) AS usage_evidence
  FROM public.statement_line_control_usage_v1 u
  GROUP BY u.statement_line_id
)
SELECT
  l.id AS statement_line_id,
  l.dva_statement_id AS statement_id,
  s.importer_id,
  COALESCE(s.statement_account_context, 'importer_dva_card_account')::text AS statement_account_context,
  s.statement_account_label::text,
  s.source_bank::text,
  l.statement_date,
  l.reference_raw::text,
  l.direction::text,
  ROUND(COALESCE(l.amount_gbp_equivalent, 0)::numeric, 2) AS statement_gbp_amount,
  COALESCE(u.active_consumed_gbp, 0)::numeric AS active_consumed_gbp,
  COALESCE(u.active_reserved_gbp, 0)::numeric AS active_reserved_gbp,
  ROUND(GREATEST(COALESCE(l.amount_gbp_equivalent, 0) - COALESCE(u.active_consumed_gbp, 0) - COALESCE(u.active_reserved_gbp, 0), 0)::numeric, 2) AS remaining_unconsumed_gbp,
  ROUND(GREATEST(COALESCE(u.active_consumed_gbp, 0) + COALESCE(u.active_reserved_gbp, 0) - COALESCE(l.amount_gbp_equivalent, 0), 0)::numeric, 2) AS overconsumed_gbp,
  COALESCE(u.raw_active_families, ARRAY[]::text[]) AS raw_active_families,
  COALESCE(u.active_economic_lanes, ARRAY[]::text[]) AS active_economic_lanes,
  COALESCE(u.principal_lane_count, 0)::integer AS principal_lane_count,
  COALESCE(u.historical_row_count, 0)::integer AS historical_row_count,
  COALESCE(u.usage_evidence, '[]'::jsonb) AS usage_evidence
FROM public.dva_statement_lines l
JOIN public.dva_statements s ON s.id = l.dva_statement_id
LEFT JOIN active_usage u ON u.statement_line_id = l.id;

CREATE OR REPLACE FUNCTION public.internal_statement_line_control_resolver_v1(
  p_statement_line_id uuid
)
RETURNS TABLE (
  statement_line_id uuid,
  statement_id uuid,
  importer_id uuid,
  statement_account_context text,
  statement_account_label text,
  source_bank text,
  statement_date date,
  reference_raw text,
  direction text,
  statement_gbp_amount numeric,
  active_consumed_gbp numeric,
  active_reserved_gbp numeric,
  remaining_unconsumed_gbp numeric,
  overconsumed_gbp numeric,
  raw_active_families text[],
  active_economic_lanes text[],
  principal_lane_count integer,
  historical_row_count integer,
  direction_context_valid_yn boolean,
  incompatible_principal_lanes_yn boolean,
  funding_action_allowed_yn boolean,
  control_status text,
  blocker text,
  next_action text,
  usage_evidence jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    p.statement_line_id,
    p.statement_id,
    p.importer_id,
    p.statement_account_context,
    p.statement_account_label,
    p.source_bank,
    p.statement_date,
    p.reference_raw,
    p.direction,
    p.statement_gbp_amount,
    p.active_consumed_gbp,
    p.active_reserved_gbp,
    p.remaining_unconsumed_gbp,
    p.overconsumed_gbp,
    p.raw_active_families,
    p.active_economic_lanes,
    p.principal_lane_count,
    p.historical_row_count,
    NOT EXISTS (
      SELECT 1
      FROM unnest(p.active_economic_lanes) lane
      WHERE (lane = 'customer_order_funding' AND (p.statement_account_context <> 'importer_dva_card_account' OR p.direction <> 'in'))
         OR (lane = 'supplier_payment' AND (p.statement_account_context <> 'importer_dva_card_account' OR p.direction <> 'out'))
         OR (lane IN ('retailer_refund','final_balance_payment','completion_loyalty_destination_transfer','legacy_completion_loyalty_funding') AND (p.statement_account_context <> 'importer_dva_card_account' OR p.direction <> 'in'))
         OR (lane IN ('main_bank_shipper_ap','completion_loyalty_source_transfer') AND (p.statement_account_context <> 'main_company_bank_account' OR p.direction <> 'out'))
    ) AS direction_context_valid_yn,
    p.principal_lane_count > 1 AS incompatible_principal_lanes_yn,
    (
      p.statement_account_context = 'importer_dva_card_account'
      AND p.direction = 'in'
      AND p.overconsumed_gbp <= 0.01
      AND p.principal_lane_count <= 1
      AND NOT (p.active_economic_lanes && ARRAY['retailer_refund','final_balance_payment','completion_loyalty_destination_transfer','legacy_completion_loyalty_funding','supplier_payment','main_bank_shipper_ap','completion_loyalty_source_transfer']::text[])
      AND p.remaining_unconsumed_gbp > 0.01
    ) AS funding_action_allowed_yn,
    CASE
      WHEN p.overconsumed_gbp > 0.01 THEN 'blocked'
      WHEN p.principal_lane_count > 1 THEN 'blocked'
      WHEN EXISTS (SELECT 1 FROM unnest(p.active_economic_lanes) lane WHERE lane = 'legacy_completion_loyalty_funding') THEN 'review_required'
      WHEN p.remaining_unconsumed_gbp > 0.01 THEN 'open'
      ELSE 'controlled'
    END::text AS control_status,
    CASE
      WHEN p.overconsumed_gbp > 0.01 THEN 'statement_line_overconsumed'
      WHEN p.principal_lane_count > 1 THEN 'incompatible_principal_economic_lanes'
      WHEN EXISTS (SELECT 1 FROM unnest(p.active_economic_lanes) lane WHERE lane = 'legacy_completion_loyalty_funding') THEN 'legacy_loyalty_evidence_without_modern_match_link'
      WHEN p.statement_gbp_amount <= 0 THEN 'statement_amount_missing_or_non_positive'
      ELSE NULL::text
    END AS blocker,
    CASE
      WHEN p.overconsumed_gbp > 0.01 OR p.principal_lane_count > 1 THEN 'integrity_review'
      WHEN p.statement_account_context = 'importer_dva_card_account' AND p.direction = 'in'
        AND NOT (p.active_economic_lanes && ARRAY['retailer_refund','final_balance_payment','completion_loyalty_destination_transfer','legacy_completion_loyalty_funding']::text[])
        AND p.remaining_unconsumed_gbp > 0.01 THEN 'funding_or_inbound_classification'
      WHEN p.statement_account_context = 'importer_dva_card_account' AND p.direction = 'out' AND p.remaining_unconsumed_gbp > 0.01 THEN 'supplier_payment_or_outbound_classification'
      WHEN p.statement_account_context = 'main_company_bank_account' AND p.direction = 'out' AND p.remaining_unconsumed_gbp > 0.01 THEN 'main_bank_shipper_or_loyalty_classification'
      ELSE 'review_pack'
    END::text AS next_action,
    p.usage_evidence
  FROM public.statement_line_control_position_v1 p
  WHERE p.statement_line_id = p_statement_line_id;
$$;

REVOKE ALL ON FUNCTION public.internal_statement_line_control_resolver_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_statement_line_control_resolver_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_guard_order_funding_statement_line_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_control record;
  v_amount numeric(18,2);
BEGIN
  IF COALESCE(NEW.reconciliation_type::text, '') <> 'order_funding' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_control
  FROM public.internal_statement_line_control_resolver_v1(NEW.dva_statement_line_id)
  LIMIT 1;

  IF v_control.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Statement line control row missing for %.', NEW.dva_statement_line_id;
  END IF;

  IF v_control.statement_account_context <> 'importer_dva_card_account' OR v_control.direction <> 'in' THEN
    RAISE EXCEPTION 'Order funding requires importer DVA/card IN. Context %, direction %.', v_control.statement_account_context, v_control.direction;
  END IF;

  IF v_control.overconsumed_gbp > 0.01 OR v_control.incompatible_principal_lanes_yn THEN
    RAISE EXCEPTION 'Statement line % is blocked by amount-aware control: %.', NEW.dva_statement_line_id, COALESCE(v_control.blocker, 'integrity_block');
  END IF;

  IF v_control.active_economic_lanes && ARRAY['retailer_refund','final_balance_payment','completion_loyalty_destination_transfer','legacy_completion_loyalty_funding','supplier_payment','main_bank_shipper_ap','completion_loyalty_source_transfer']::text[] THEN
    RAISE EXCEPTION 'Statement line % is already classified for a non-funding principal lane: %.', NEW.dva_statement_line_id, v_control.active_economic_lanes;
  END IF;

  v_amount := ROUND(ABS(COALESCE(NEW.reconciled_gbp_amount, 0))::numeric, 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Order-funding reconciliation amount must be positive.';
  END IF;

  IF v_amount > v_control.remaining_unconsumed_gbp + 0.01 THEN
    RAISE EXCEPTION 'Order-funding amount % exceeds statement-line remaining amount %.', v_amount, v_control.remaining_unconsumed_gbp;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_order_funding_statement_line_v1 ON public.dva_reconciliation;
CREATE TRIGGER trg_guard_order_funding_statement_line_v1
BEFORE INSERT ON public.dva_reconciliation
FOR EACH ROW
EXECUTE FUNCTION public.internal_guard_order_funding_statement_line_v1();

COMMENT ON VIEW public.statement_line_control_usage_v1 IS
'Raw evidence rows mapped to amount-aware economic lanes. Linked loyalty confirmations and cash snapshots are documentary and do not consume the statement amount twice.';

COMMENT ON VIEW public.statement_line_control_position_v1 IS
'One amount-aware position per physical statement line, including active consumed/reserved/remaining amount, principal lanes and complete evidence JSON.';

COMMENT ON FUNCTION public.internal_statement_line_control_resolver_v1(uuid) IS
'Shared read-only resolver for funding, supplier/refund, completion-loyalty and main-bank statement-line routing. Historical evidence remains visible but does not consume current amount.';

NOTIFY pgrst, 'reload schema';
COMMIT;
