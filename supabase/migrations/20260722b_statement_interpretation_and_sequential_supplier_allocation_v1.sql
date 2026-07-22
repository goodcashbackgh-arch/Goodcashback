BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Treasury statement control corrective pack — Phase 2.
-- 1. Preserve raw statement evidence and add an audited effective interpretation.
-- 2. Harden the amount-aware resolver behind a staff-authorised v2 interface.
-- 3. Preserve the existing strict full-OUT and atomic bundle RPCs while adding a
--    separate sequential one-OUT/many-invoice allocation RPC.

DO $$
BEGIN
  IF to_regclass('public.dva_statement_lines') IS NULL
     OR to_regclass('public.dva_statements') IS NULL
     OR to_regclass('public.dva_reconciliation') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.staff') IS NULL
     OR to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL
     OR to_regclass('public.main_bank_shipper_ap_allocations') IS NULL
  THEN
    RAISE EXCEPTION 'Treasury statement control Phase 2 prerequisite relation is missing.';
  END IF;

  IF to_regclass('public.statement_line_control_position_v1') IS NULL
     OR to_regprocedure('public.internal_statement_line_control_resolver_v1(uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Apply 20260721_amount_aware_statement_line_control_v1.sql before Phase 2.';
  END IF;

  IF to_regprocedure('public.internal_supplier_payment_readiness_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_supplier_payment_bundle_source_v1(uuid,numeric)') IS NULL
  THEN
    RAISE EXCEPTION 'Supplier-payment readiness/bundle source controls are missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dva_statement_line_allocations'
      AND column_name IN ('source_bank_account_mapping_code', 'source_wallet_code')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 2
  ) THEN
    RAISE EXCEPTION 'Supplier allocation source-mapping columns are missing.';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.statement_line_interpretation_corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_statement_line_id uuid NOT NULL REFERENCES public.dva_statement_lines(id) ON DELETE RESTRICT,
  raw_direction_snapshot varchar NOT NULL CHECK (raw_direction_snapshot IN ('in', 'out')),
  effective_direction varchar NOT NULL CHECK (effective_direction IN ('in', 'out')),
  economic_classification varchar NOT NULL CHECK (economic_classification IN (
    'unclassified',
    'customer_order_funding',
    'supplier_payment',
    'retailer_refund',
    'final_balance_payment',
    'bank_fee',
    'fx_card_difference',
    'completion_loyalty_source_transfer',
    'completion_loyalty_destination_transfer',
    'main_bank_shipper_ap',
    'exception_control'
  )),
  corrected_display_description text,
  correction_reason text NOT NULL CHECK (char_length(btrim(correction_reason)) >= 8),
  active boolean NOT NULL DEFAULT true,
  created_by_staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  created_by_auth_user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  superseded_at timestamptz,
  superseded_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  superseded_by_auth_user_id uuid
);

CREATE UNIQUE INDEX IF NOT EXISTS statement_line_interpretation_one_active_uidx
  ON public.statement_line_interpretation_corrections(dva_statement_line_id)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS statement_line_interpretation_history_idx
  ON public.statement_line_interpretation_corrections(dva_statement_line_id, created_at DESC, id DESC);

ALTER TABLE public.statement_line_interpretation_corrections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS statement_line_interpretation_staff_select ON public.statement_line_interpretation_corrections;
CREATE POLICY statement_line_interpretation_staff_select
ON public.statement_line_interpretation_corrections
FOR SELECT
TO authenticated
USING (public.is_active_staff());

REVOKE ALL ON TABLE public.statement_line_interpretation_corrections FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.statement_line_interpretation_corrections FROM authenticated;
GRANT SELECT ON TABLE public.statement_line_interpretation_corrections TO authenticated;

CREATE OR REPLACE VIEW public.statement_line_effective_interpretation_v1 AS
SELECT
  dsl.id AS dva_statement_line_id,
  dsl.dva_statement_id,
  ds.importer_id,
  COALESCE(ds.statement_account_context, 'importer_dva_card_account')::text AS statement_account_context,
  ds.statement_account_label::text,
  ds.source_bank::text,
  dsl.statement_date,
  dsl.direction::text AS raw_direction,
  COALESCE(c.effective_direction, dsl.direction::text)::text AS effective_direction,
  COALESCE(c.economic_classification, 'unclassified')::text AS effective_economic_classification,
  dsl.reference_raw::text AS raw_description,
  COALESCE(NULLIF(btrim(c.corrected_display_description), ''), dsl.reference_raw::text)::text AS effective_display_description,
  dsl.amount_local_ccy,
  dsl.local_ccy::text,
  dsl.fx_rate_applied,
  dsl.card_markup_pct_applied,
  dsl.amount_gbp_equivalent,
  dsl.auth_id_ref::text,
  dsl.retailer_name_ref::text,
  dsl.match_status::text,
  c.id AS interpretation_correction_id,
  c.correction_reason,
  c.created_by_staff_id AS interpretation_corrected_by_staff_id,
  c.created_at AS interpretation_corrected_at
FROM public.dva_statement_lines dsl
JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
LEFT JOIN public.statement_line_interpretation_corrections c
  ON c.dva_statement_line_id = dsl.id
 AND c.active = true;

COMMENT ON TABLE public.statement_line_interpretation_corrections IS
'Audited override of statement direction, economic classification and display description. Raw bank/OCR evidence and all amounts remain unchanged.';

COMMENT ON VIEW public.statement_line_effective_interpretation_v1 IS
'One effective statement interpretation per physical line. Raw direction/description remain visible beside the active audited correction.';

CREATE OR REPLACE FUNCTION public.staff_correct_statement_line_interpretation_v1(
  p_dva_statement_line_id uuid,
  p_effective_direction text,
  p_economic_classification text,
  p_corrected_display_description text,
  p_correction_reason text
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
  v_direction text := lower(NULLIF(btrim(COALESCE(p_effective_direction, '')), ''));
  v_classification text := lower(NULLIF(btrim(COALESCE(p_economic_classification, '')), ''));
  v_description text := NULLIF(btrim(COALESCE(p_corrected_display_description, '')), '');
  v_reason text := NULLIF(btrim(COALESCE(p_correction_reason, '')), '');
  v_existing_id uuid;
  v_correction_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: statement interpretation correction requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR COALESCE(v_staff.role_type, '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can correct statement interpretation.';
  END IF;

  IF v_direction NOT IN ('in', 'out') THEN
    RAISE EXCEPTION 'Effective direction must be in or out.';
  END IF;
  IF v_classification NOT IN (
    'unclassified',
    'customer_order_funding',
    'supplier_payment',
    'retailer_refund',
    'final_balance_payment',
    'bank_fee',
    'fx_card_difference',
    'completion_loyalty_source_transfer',
    'completion_loyalty_destination_transfer',
    'main_bank_shipper_ap',
    'exception_control'
  ) THEN
    RAISE EXCEPTION 'Unsupported economic classification: %', p_economic_classification;
  END IF;
  IF v_reason IS NULL OR char_length(v_reason) < 8 THEN
    RAISE EXCEPTION 'Correction reason must contain at least 8 characters.';
  END IF;

  SELECT
    dsl.id,
    dsl.direction::text AS raw_direction,
    dsl.amount_gbp_equivalent,
    ds.importer_id,
    COALESCE(ds.statement_account_context, 'importer_dva_card_account')::text AS statement_account_context
  INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'Statement line not found: %', p_dva_statement_line_id;
  END IF;
  IF ROUND(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2) <= 0 THEN
    RAISE EXCEPTION 'Statement line amount is missing or non-positive.';
  END IF;

  IF v_classification IN ('customer_order_funding', 'retailer_refund', 'final_balance_payment', 'completion_loyalty_destination_transfer')
     AND (v_line.statement_account_context <> 'importer_dva_card_account' OR v_direction <> 'in') THEN
    RAISE EXCEPTION 'Classification % requires importer DVA/card IN.', v_classification;
  END IF;

  IF v_classification = 'supplier_payment'
     AND (v_line.statement_account_context <> 'importer_dva_card_account' OR v_direction <> 'out') THEN
    RAISE EXCEPTION 'Supplier payment requires importer DVA/card OUT.';
  END IF;

  IF v_classification IN ('completion_loyalty_source_transfer', 'main_bank_shipper_ap')
     AND (v_line.statement_account_context <> 'main_company_bank_account' OR v_direction <> 'out') THEN
    RAISE EXCEPTION 'Classification % requires main-company-bank OUT.', v_classification;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.dva_reconciliation dr
    WHERE dr.dva_statement_line_id = p_dva_statement_line_id
  ) OR EXISTS (
    SELECT 1 FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.allocation_status <> 'reversed'
  ) OR EXISTS (
    SELECT 1 FROM public.main_bank_completion_loyalty_funding_matches lm
    WHERE (lm.dva_statement_line_id = p_dva_statement_line_id OR lm.destination_in_statement_line_id = p_dva_statement_line_id)
      AND lm.match_status IN ('confirmed', 'released_available_dashboard_credit')
      AND COALESCE(lm.transfer_pair_status, '') <> 'reversed'
  ) OR EXISTS (
    SELECT 1 FROM public.main_bank_shipper_ap_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.allocation_status <> 'reversed'
  ) THEN
    RAISE EXCEPTION 'Statement line % already has active economic use. Reverse the incorrect use before changing its interpretation.', p_dva_statement_line_id;
  END IF;

  IF to_regclass('public.cash_posting_snapshots') IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.cash_posting_snapshots cps
    WHERE cps.statement_line_id = p_dva_statement_line_id
      AND COALESCE(cps.active, false) = true
  ) THEN
    RAISE EXCEPTION 'Statement line % has an active cash-posting snapshot. Reverse accounting use before correction.', p_dva_statement_line_id;
  END IF;

  SELECT c.id INTO v_existing_id
  FROM public.statement_line_interpretation_corrections c
  WHERE c.dva_statement_line_id = p_dva_statement_line_id
    AND c.active = true
  LIMIT 1
  FOR UPDATE;

  IF v_existing_id IS NOT NULL THEN
    UPDATE public.statement_line_interpretation_corrections
       SET active = false,
           superseded_at = now(),
           superseded_by_staff_id = v_staff.id,
           superseded_by_auth_user_id = v_auth_uid
     WHERE id = v_existing_id;
  END IF;

  INSERT INTO public.statement_line_interpretation_corrections (
    dva_statement_line_id,
    raw_direction_snapshot,
    effective_direction,
    economic_classification,
    corrected_display_description,
    correction_reason,
    created_by_staff_id,
    created_by_auth_user_id
  ) VALUES (
    p_dva_statement_line_id,
    v_line.raw_direction,
    v_direction,
    v_classification,
    v_description,
    v_reason,
    v_staff.id,
    v_auth_uid
  ) RETURNING id INTO v_correction_id;

  RETURN jsonb_build_object(
    'ok', true,
    'statement_line_id', p_dva_statement_line_id,
    'correction_id', v_correction_id,
    'raw_direction', v_line.raw_direction,
    'effective_direction', v_direction,
    'economic_classification', v_classification,
    'corrected_display_description', v_description,
    'correction_reason', v_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_correct_statement_line_interpretation_v1(uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_correct_statement_line_interpretation_v1(uuid, text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_correct_statement_line_interpretation_v1(uuid, text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_statement_line_control_resolver_v2(
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
  raw_description text,
  effective_display_description text,
  raw_direction text,
  effective_direction text,
  effective_economic_classification text,
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
  interpretation_correction_id uuid,
  interpretation_corrected_at timestamptz,
  usage_evidence jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for statement-line control.';
  END IF;

  RETURN QUERY
  SELECT
    p.statement_line_id,
    p.statement_id,
    p.importer_id,
    p.statement_account_context,
    p.statement_account_label,
    p.source_bank,
    p.statement_date,
    e.raw_description,
    e.effective_display_description,
    e.raw_direction,
    e.effective_direction,
    e.effective_economic_classification,
    p.statement_gbp_amount,
    p.active_consumed_gbp,
    p.active_reserved_gbp,
    p.remaining_unconsumed_gbp,
    p.overconsumed_gbp,
    p.raw_active_families,
    p.active_economic_lanes,
    p.principal_lane_count,
    p.historical_row_count,
    (
      NOT EXISTS (
        SELECT 1
        FROM unnest(p.active_economic_lanes) lane
        WHERE (lane = 'customer_order_funding' AND (p.statement_account_context <> 'importer_dva_card_account' OR e.effective_direction <> 'in'))
           OR (lane = 'supplier_payment' AND (p.statement_account_context <> 'importer_dva_card_account' OR e.effective_direction <> 'out'))
           OR (lane IN ('retailer_refund', 'final_balance_payment', 'completion_loyalty_destination_transfer', 'legacy_completion_loyalty_funding') AND (p.statement_account_context <> 'importer_dva_card_account' OR e.effective_direction <> 'in'))
           OR (lane IN ('main_bank_shipper_ap', 'completion_loyalty_source_transfer') AND (p.statement_account_context <> 'main_company_bank_account' OR e.effective_direction <> 'out'))
      )
      AND NOT (
        e.effective_economic_classification IN ('customer_order_funding', 'retailer_refund', 'final_balance_payment', 'completion_loyalty_destination_transfer')
        AND (p.statement_account_context <> 'importer_dva_card_account' OR e.effective_direction <> 'in')
      )
      AND NOT (
        e.effective_economic_classification = 'supplier_payment'
        AND (p.statement_account_context <> 'importer_dva_card_account' OR e.effective_direction <> 'out')
      )
      AND NOT (
        e.effective_economic_classification IN ('completion_loyalty_source_transfer', 'main_bank_shipper_ap')
        AND (p.statement_account_context <> 'main_company_bank_account' OR e.effective_direction <> 'out')
      )
    ) AS direction_context_valid_yn,
    p.principal_lane_count > 1 AS incompatible_principal_lanes_yn,
    (
      p.statement_account_context = 'importer_dva_card_account'
      AND e.effective_direction = 'in'
      AND e.effective_economic_classification IN ('unclassified', 'customer_order_funding')
      AND p.overconsumed_gbp <= 0.01
      AND p.principal_lane_count <= 1
      AND NOT (p.active_economic_lanes && ARRAY['retailer_refund', 'final_balance_payment', 'completion_loyalty_destination_transfer', 'legacy_completion_loyalty_funding', 'supplier_payment', 'main_bank_shipper_ap', 'completion_loyalty_source_transfer']::text[])
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
      WHEN e.effective_economic_classification = 'customer_order_funding' THEN 'order_funding'
      WHEN e.effective_economic_classification = 'supplier_payment' THEN 'supplier_payment'
      WHEN e.effective_economic_classification = 'retailer_refund' THEN 'retailer_refund'
      WHEN e.effective_economic_classification = 'final_balance_payment' THEN 'final_balance_payment'
      WHEN e.effective_economic_classification = 'completion_loyalty_source_transfer' THEN 'completion_loyalty_source_pairing'
      WHEN e.effective_economic_classification = 'completion_loyalty_destination_transfer' THEN 'completion_loyalty_destination_pairing'
      WHEN e.effective_economic_classification = 'main_bank_shipper_ap' THEN 'main_bank_shipper_ap'
      WHEN e.effective_economic_classification IN ('bank_fee', 'fx_card_difference', 'exception_control') THEN 'matching_workspace'
      WHEN p.statement_account_context = 'importer_dva_card_account' AND e.effective_direction = 'in' AND p.remaining_unconsumed_gbp > 0.01 THEN 'funding_or_inbound_classification'
      WHEN p.statement_account_context = 'importer_dva_card_account' AND e.effective_direction = 'out' AND p.remaining_unconsumed_gbp > 0.01 THEN 'supplier_payment_or_outbound_classification'
      WHEN p.statement_account_context = 'main_company_bank_account' AND e.effective_direction = 'out' AND p.remaining_unconsumed_gbp > 0.01 THEN 'main_bank_shipper_or_loyalty_classification'
      ELSE 'review_pack'
    END::text AS next_action,
    e.interpretation_correction_id,
    e.interpretation_corrected_at,
    p.usage_evidence
  FROM public.statement_line_control_position_v1 p
  JOIN public.statement_line_effective_interpretation_v1 e
    ON e.dva_statement_line_id = p.statement_line_id
  WHERE p.statement_line_id = p_statement_line_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_statement_line_control_resolver_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_statement_line_control_resolver_v1(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.internal_statement_line_control_resolver_v1(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_statement_line_control_resolver_v2(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_statement_line_control_resolver_v2(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_statement_line_control_resolver_v2(uuid) TO authenticated;

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
  FROM public.internal_statement_line_control_resolver_v2(NEW.dva_statement_line_id)
  LIMIT 1;

  IF v_control.statement_line_id IS NULL THEN
    RAISE EXCEPTION 'Statement line control row missing for %.', NEW.dva_statement_line_id;
  END IF;
  IF v_control.statement_account_context <> 'importer_dva_card_account' OR v_control.effective_direction <> 'in' THEN
    RAISE EXCEPTION 'Order funding requires effective importer DVA/card IN. Context %, direction %.', v_control.statement_account_context, v_control.effective_direction;
  END IF;
  IF v_control.effective_economic_classification NOT IN ('unclassified', 'customer_order_funding') THEN
    RAISE EXCEPTION 'Statement line % is classified as %, not order funding.', NEW.dva_statement_line_id, v_control.effective_economic_classification;
  END IF;
  IF v_control.overconsumed_gbp > 0.01 OR v_control.incompatible_principal_lanes_yn THEN
    RAISE EXCEPTION 'Statement line % is blocked by amount-aware control: %.', NEW.dva_statement_line_id, COALESCE(v_control.blocker, 'integrity_block');
  END IF;
  IF NOT v_control.funding_action_allowed_yn THEN
    RAISE EXCEPTION 'Statement line % is not eligible for order funding. Next action: %.', NEW.dva_statement_line_id, v_control.next_action;
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

CREATE OR REPLACE FUNCTION public.internal_statement_line_control_worklist_v1(
  p_importer_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 300,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  dva_statement_line_id uuid,
  dva_statement_id uuid,
  importer_id uuid,
  statement_account_context text,
  statement_account_label text,
  source_bank text,
  statement_date date,
  raw_description text,
  effective_display_description text,
  raw_direction text,
  effective_direction text,
  effective_economic_classification text,
  amount_local_ccy numeric,
  local_ccy text,
  fx_rate_applied numeric,
  card_markup_pct_applied numeric,
  statement_gbp_amount numeric,
  auth_id_ref text,
  retailer_name_ref text,
  match_status text,
  confirmed_allocated_gbp numeric,
  open_allocated_gbp numeric,
  confirmed_unallocated_gbp numeric,
  active_allocation_count bigint,
  active_consumed_gbp numeric,
  active_reserved_gbp numeric,
  remaining_unconsumed_gbp numeric,
  overconsumed_gbp numeric,
  funding_action_allowed_yn boolean,
  control_status text,
  blocker text,
  next_action text,
  interpretation_correction_id uuid,
  interpretation_corrected_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 300), 1), 500);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for statement-line control worklist.';
  END IF;

  RETURN QUERY
  WITH allocation_totals AS (
    SELECT
      a.dva_statement_line_id,
      ROUND(COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed'), 0)::numeric, 2) AS confirmed_allocated_gbp,
      ROUND(COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status IN ('draft', 'held')), 0)::numeric, 2) AS open_allocated_gbp,
      COUNT(*) FILTER (WHERE a.allocation_status <> 'reversed') AS active_allocation_count
    FROM public.dva_statement_line_allocations a
    GROUP BY a.dva_statement_line_id
  ), base AS (
    SELECT
      e.*,
      COALESCE(at.confirmed_allocated_gbp, 0)::numeric AS confirmed_allocated_gbp,
      COALESCE(at.open_allocated_gbp, 0)::numeric AS open_allocated_gbp,
      ROUND(GREATEST(COALESCE(e.amount_gbp_equivalent, 0) - COALESCE(at.confirmed_allocated_gbp, 0), 0)::numeric, 2) AS confirmed_unallocated_gbp,
      COALESCE(at.active_allocation_count, 0)::bigint AS active_allocation_count,
      c.active_consumed_gbp,
      c.active_reserved_gbp,
      c.remaining_unconsumed_gbp,
      c.overconsumed_gbp,
      c.funding_action_allowed_yn,
      c.control_status,
      c.blocker,
      c.next_action
    FROM public.statement_line_effective_interpretation_v1 e
    JOIN LATERAL public.internal_statement_line_control_resolver_v2(e.dva_statement_line_id) c ON true
    LEFT JOIN allocation_totals at ON at.dva_statement_line_id = e.dva_statement_line_id
    WHERE p_importer_id IS NULL OR e.importer_id = p_importer_id
  )
  SELECT
    b.dva_statement_line_id,
    b.dva_statement_id,
    b.importer_id,
    b.statement_account_context,
    b.statement_account_label,
    b.source_bank,
    b.statement_date,
    b.raw_description,
    b.effective_display_description,
    b.raw_direction,
    b.effective_direction,
    b.effective_economic_classification,
    b.amount_local_ccy,
    b.local_ccy,
    b.fx_rate_applied,
    b.card_markup_pct_applied,
    ROUND(COALESCE(b.amount_gbp_equivalent, 0)::numeric, 2),
    b.auth_id_ref,
    b.retailer_name_ref,
    b.match_status,
    b.confirmed_allocated_gbp,
    b.open_allocated_gbp,
    b.confirmed_unallocated_gbp,
    b.active_allocation_count,
    b.active_consumed_gbp,
    b.active_reserved_gbp,
    b.remaining_unconsumed_gbp,
    b.overconsumed_gbp,
    b.funding_action_allowed_yn,
    b.control_status,
    b.blocker,
    b.next_action,
    b.interpretation_correction_id,
    b.interpretation_corrected_at,
    COUNT(*) OVER() AS total_count
  FROM base b
  ORDER BY b.statement_date DESC, b.dva_statement_line_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_statement_line_control_worklist_v1(uuid, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_statement_line_control_worklist_v1(uuid, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_statement_line_control_worklist_v1(uuid, integer, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(
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
  v_amount numeric(12,2) := ROUND(COALESCE(p_allocated_gbp_amount, 0)::numeric, 2);
  v_statement_total numeric(12,2);
  v_line_confirmed_before numeric(12,2) := 0;
  v_line_remaining_before numeric(12,2) := 0;
  v_line_confirmed_after numeric(12,2) := 0;
  v_line_remaining_after numeric(12,2) := 0;
  v_invoice_total numeric(12,2) := 0;
  v_invoice_confirmed_before numeric(12,2) := 0;
  v_invoice_remaining_before numeric(12,2) := 0;
  v_invoice_confirmed_after numeric(12,2) := 0;
  v_invoice_remaining_after numeric(12,2) := 0;
  v_existing_order_count integer := 0;
  v_existing_importer_count integer := 0;
  v_existing_retailer_count integer := 0;
  v_existing_mapping_count integer := 0;
  v_existing_order_id uuid;
  v_existing_importer_id uuid;
  v_existing_retailer_id uuid;
  v_source_mapping text;
  v_source_wallet text;
  v_source_reason text;
  v_source record;
  v_readiness record;
  v_allocation_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: sequential supplier allocation requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR COALESCE(v_staff.role_type, '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can allocate supplier payments.';
  END IF;
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Allocated GBP amount must be greater than zero.';
  END IF;

  SELECT
    e.dva_statement_line_id AS id,
    e.effective_direction AS direction,
    e.effective_economic_classification,
    e.amount_gbp_equivalent,
    e.fx_rate_applied,
    e.card_markup_pct_applied,
    e.importer_id,
    e.statement_account_context
  INTO v_line
  FROM public.statement_line_effective_interpretation_v1 e
  WHERE e.dva_statement_line_id = p_dva_statement_line_id
  FOR UPDATE OF e;

  -- Views cannot be row-locked. Lock the physical line explicitly after resolving interpretation.
  PERFORM 1 FROM public.dva_statement_lines dsl
  WHERE dsl.id = p_dva_statement_line_id
  FOR UPDATE;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'Statement line not found: %', p_dva_statement_line_id;
  END IF;
  IF v_line.statement_account_context <> 'importer_dva_card_account' OR v_line.direction <> 'out' THEN
    RAISE EXCEPTION 'Sequential supplier allocation requires effective importer DVA/card OUT.';
  END IF;
  IF v_line.effective_economic_classification NOT IN ('unclassified', 'supplier_payment') THEN
    RAISE EXCEPTION 'Statement line is classified as %, not supplier payment.', v_line.effective_economic_classification;
  END IF;

  v_statement_total := ROUND(COALESCE(v_line.amount_gbp_equivalent, 0)::numeric, 2);
  IF v_statement_total <= 0 THEN
    RAISE EXCEPTION 'Statement line amount must be positive.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.allocation_status IN ('draft', 'held')
  ) THEN
    RAISE EXCEPTION 'Resolve draft/held allocations on statement line % before sequential supplier allocation.', p_dva_statement_line_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.allocation_status <> 'reversed'
      AND a.allocation_type <> 'supplier_invoice'
  ) THEN
    RAISE EXCEPTION 'Statement line % has an incompatible active non-supplier allocation.', p_dva_statement_line_id;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_line_confirmed_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  v_line_remaining_before := ROUND(GREATEST(v_statement_total - v_line_confirmed_before, 0)::numeric, 2);
  IF v_line_remaining_before <= 0.01 THEN
    RAISE EXCEPTION 'Statement line % has no remaining amount to allocate.', p_dva_statement_line_id;
  END IF;
  IF v_amount > v_line_remaining_before + 0.01 THEN
    RAISE EXCEPTION 'Requested allocation % exceeds statement-line remaining amount %.', v_amount, v_line_remaining_before;
  END IF;

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
  IF v_invoice.review_status IS DISTINCT FROM 'approved_current' THEN
    RAISE EXCEPTION 'Supplier invoice % is not approved_current. Status: %', p_supplier_invoice_id, v_invoice.review_status;
  END IF;

  SELECT ROUND(COALESCE(
    v_invoice.ocr_invoice_total_gbp,
    v_invoice.reconciliation_gbp_total,
    SUM(COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)),
    0
  )::numeric, 2)
  INTO v_invoice_total
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id;

  IF v_invoice_total <= 0 THEN
    RAISE EXCEPTION 'Supplier invoice % has no positive total.', p_supplier_invoice_id;
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_invoice_confirmed_before
  FROM public.dva_statement_line_allocations a
  WHERE a.supplier_invoice_id = p_supplier_invoice_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  v_invoice_remaining_before := ROUND(GREATEST(v_invoice_total - v_invoice_confirmed_before, 0)::numeric, 2);
  IF v_invoice_remaining_before <= 0.01 THEN
    RAISE EXCEPTION 'Supplier invoice % is already fully allocated.', p_supplier_invoice_id;
  END IF;
  IF v_amount > v_invoice_remaining_before + 0.01 THEN
    RAISE EXCEPTION 'Requested allocation % exceeds supplier-invoice remaining amount %.', v_amount, v_invoice_remaining_before;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.dva_statement_line_id = p_dva_statement_line_id
      AND a.supplier_invoice_id = p_supplier_invoice_id
      AND a.allocation_type = 'supplier_invoice'
      AND a.allocation_status <> 'reversed'
  ) THEN
    RAISE EXCEPTION 'Statement line % already has an active allocation to invoice %.', p_dva_statement_line_id, p_supplier_invoice_id;
  END IF;

  SELECT o.id, o.order_ref, o.importer_id, o.retailer_id, o.status, COALESCE(o.order_type, 'original') AS order_type
    INTO v_order
  FROM public.orders o
  WHERE o.id = v_invoice.order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found for supplier invoice %.', p_supplier_invoice_id;
  END IF;
  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN
    RAISE EXCEPTION 'Statement-line importer % does not match order importer %.', v_line.importer_id, v_order.importer_id;
  END IF;
  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot allocate to order % with status %.', v_order.id, v_order.status;
  END IF;

  SELECT * INTO v_readiness
  FROM public.internal_supplier_payment_readiness_v1(v_order.id)
  LIMIT 1;

  IF v_readiness.supplier_payment_ready_yn IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'source_funding_required_for_supplier_payment_bank_resolution: order %, blocker %', v_order.id, COALESCE(v_readiness.blocker, 'readiness_row_missing');
  END IF;

  SELECT
    COUNT(DISTINCT asi.order_id)::integer,
    COUNT(DISTINCT ao.importer_id)::integer,
    COUNT(DISTINCT ao.retailer_id)::integer,
    COUNT(DISTINCT concat_ws('|', NULLIF(btrim(a.source_bank_account_mapping_code), ''), NULLIF(btrim(a.source_wallet_code), '')))::integer,
    (array_agg(DISTINCT asi.order_id) FILTER (WHERE asi.order_id IS NOT NULL))[1],
    (array_agg(DISTINCT ao.importer_id) FILTER (WHERE ao.importer_id IS NOT NULL))[1],
    (array_agg(DISTINCT ao.retailer_id) FILTER (WHERE ao.retailer_id IS NOT NULL))[1],
    (array_agg(DISTINCT NULLIF(btrim(a.source_bank_account_mapping_code), '')) FILTER (WHERE NULLIF(btrim(a.source_bank_account_mapping_code), '') IS NOT NULL))[1],
    (array_agg(DISTINCT NULLIF(btrim(a.source_wallet_code), '')) FILTER (WHERE NULLIF(btrim(a.source_wallet_code), '') IS NOT NULL))[1]
  INTO
    v_existing_order_count,
    v_existing_importer_count,
    v_existing_retailer_count,
    v_existing_mapping_count,
    v_existing_order_id,
    v_existing_importer_id,
    v_existing_retailer_id,
    v_source_mapping,
    v_source_wallet
  FROM public.dva_statement_line_allocations a
  JOIN public.supplier_invoices asi ON asi.id = a.supplier_invoice_id
  JOIN public.orders ao ON ao.id = asi.order_id
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  IF v_existing_order_count > 0 THEN
    IF v_existing_order_count <> 1 OR v_existing_importer_count <> 1 OR v_existing_retailer_count <> 1 THEN
      RAISE EXCEPTION 'Existing sequential allocations on statement line % do not resolve to one order/importer/retailer.', p_dva_statement_line_id;
    END IF;
    IF v_existing_order_id IS DISTINCT FROM v_order.id
       OR v_existing_importer_id IS DISTINCT FROM v_order.importer_id
       OR v_existing_retailer_id IS DISTINCT FROM v_order.retailer_id THEN
      RAISE EXCEPTION 'Sequential allocation must remain on the same order, importer and retailer as the first allocation.';
    END IF;
    IF v_existing_mapping_count <> 1 OR v_source_mapping IS NULL THEN
      RAISE EXCEPTION 'Existing sequential allocation source mapping is missing or inconsistent.';
    END IF;
    v_source_reason := 'inherited_from_first_statement_line_supplier_allocation';
  ELSE
    SELECT * INTO v_source
    FROM public.internal_supplier_payment_bundle_source_v1(v_order.id, v_statement_total)
    LIMIT 1;

    v_source_mapping := v_source.source_bank_account_mapping_code;
    v_source_wallet := v_source.source_wallet_code;
    v_source_reason := v_source.source_resolution_reason;

    IF NULLIF(btrim(COALESCE(v_source_mapping, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Supplier-payment source mapping could not be resolved for order % and physical OUT %.', v_order.id, v_statement_total;
    END IF;
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
  ) VALUES (
    p_dva_statement_line_id,
    'supplier_invoice',
    p_supplier_invoice_id,
    NULL,
    v_order.id,
    v_amount,
    'confirmed',
    v_line.fx_rate_applied,
    v_line.card_markup_pct_applied,
    v_source_mapping,
    v_source_wallet,
    concat_ws(E'\n', NULLIF(p_notes, ''), 'Sequential supplier allocation: ' || v_source_reason),
    v_staff.id,
    now(),
    v_staff.id,
    now()
  ) RETURNING id INTO v_allocation_id;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_line_confirmed_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = p_dva_statement_line_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
    INTO v_invoice_confirmed_after
  FROM public.dva_statement_line_allocations a
  WHERE a.supplier_invoice_id = p_supplier_invoice_id
    AND a.allocation_type = 'supplier_invoice'
    AND a.allocation_status = 'confirmed';

  v_line_remaining_after := ROUND(GREATEST(v_statement_total - v_line_confirmed_after, 0)::numeric, 2);
  v_invoice_remaining_after := ROUND(GREATEST(v_invoice_total - v_invoice_confirmed_after, 0)::numeric, 2);

  RETURN jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'supplier_invoice_id', p_supplier_invoice_id,
    'order_id', v_order.id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'retailer_id', v_order.retailer_id,
    'allocated_gbp_amount', v_amount,
    'statement_gbp_amount', v_statement_total,
    'statement_confirmed_before_gbp', v_line_confirmed_before,
    'statement_remaining_before_gbp', v_line_remaining_before,
    'statement_confirmed_after_gbp', v_line_confirmed_after,
    'statement_remaining_after_gbp', v_line_remaining_after,
    'statement_balanced_yn', v_line_remaining_after <= 0.01,
    'invoice_ref', COALESCE(v_invoice.ocr_invoice_ref, v_invoice.invoice_ref),
    'invoice_total_gbp', v_invoice_total,
    'invoice_confirmed_before_gbp', v_invoice_confirmed_before,
    'invoice_remaining_before_gbp', v_invoice_remaining_before,
    'invoice_confirmed_after_gbp', v_invoice_confirmed_after,
    'invoice_remaining_after_gbp', v_invoice_remaining_after,
    'invoice_fully_allocated_yn', v_invoice_remaining_after <= 0.01,
    'source_bank_account_mapping_code', v_source_mapping,
    'source_wallet_code', v_source_wallet,
    'source_resolution_reason', v_source_reason,
    'next_step', CASE WHEN v_line_remaining_after > 0.01 THEN 'select_next_eligible_invoice_for_same_order_and_retailer' ELSE 'review_statement_line_balance' END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) TO authenticated;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) IS
'Separate sequential supplier-payment allocator. Preserves the strict full-OUT and atomic bundle RPCs; locks the physical OUT and invoice; repeats readiness; permits one OUT to be applied invoice-by-invoice only within one order/importer/retailer; inherits the first allocation source mapping; and prevents line/invoice over-allocation.';

NOTIFY pgrst, 'reload schema';
COMMIT;
