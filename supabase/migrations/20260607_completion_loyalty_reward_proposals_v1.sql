BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_order_qualifying_net_spend_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_order_qualifying_net_spend_v1(uuid)';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_reward_proposals_v1(p_order_id uuid DEFAULT NULL)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_id uuid,
  completion_state text,
  completion_blocker text,
  basis_status text,
  basis_blocker text,
  qualifying_signed_gross_basis_gbp numeric,
  qualifying_net_spend_gbp numeric,
  default_reward_rate_pct numeric,
  suggested_reward_gbp numeric,
  existing_reward_credit_id uuid,
  existing_reward_credit_status text,
  proposal_status text,
  approval_blocker text,
  final_sale_value_exists boolean,
  final_settlement_state text,
  customer_sales_state text,
  shipment_state text,
  export_evidence_state text,
  pod_delivery_state text,
  exception_state text,
  hold_state text,
  final_balance_due_gbp numeric,
  blocker_details_json jsonb,
  source_detail_json jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: completion loyalty reward proposal read model requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for completion loyalty reward proposal read model.';
  END IF;

  RETURN QUERY
  WITH basis AS (
    SELECT *
    FROM public.internal_order_qualifying_net_spend_v1(p_order_id)
  ), evaluated AS (
    SELECT
      b.*,
      10::numeric AS reward_rate_pct,
      CASE
        WHEN b.basis_status = 'ready' THEN ROUND(COALESCE(b.qualifying_net_spend_gbp, 0) * 0.10, 2)
        ELSE 0::numeric
      END AS reward_amount_gbp,
      CASE
        WHEN b.existing_reward_credit_id IS NOT NULL THEN 'completion_loyalty_reward_already_exists'
        WHEN b.basis_status <> 'ready' THEN b.basis_blocker
        WHEN COALESCE(b.qualifying_net_spend_gbp, 0) <= 0 THEN 'qualifying_net_spend_zero_or_negative'
        ELSE NULL
      END::text AS approval_blocker_eval
    FROM basis b
  )
  SELECT
    e.order_id,
    e.order_ref,
    e.importer_id,
    e.completion_state,
    e.completion_blocker,
    e.basis_status,
    e.basis_blocker,
    e.qualifying_signed_gross_basis_gbp,
    e.qualifying_net_spend_gbp,
    e.reward_rate_pct AS default_reward_rate_pct,
    e.reward_amount_gbp AS suggested_reward_gbp,
    e.existing_reward_credit_id,
    e.existing_reward_credit_status,
    CASE
      WHEN e.existing_reward_credit_id IS NOT NULL THEN 'existing_reward_credit_present'
      WHEN e.approval_blocker_eval IS NULL THEN 'ready_for_supervisor_approval'
      ELSE 'blocked'
    END::text AS proposal_status,
    e.approval_blocker_eval AS approval_blocker,
    e.final_sale_value_exists,
    e.final_settlement_state,
    e.customer_sales_state,
    e.shipment_state,
    e.export_evidence_state,
    e.pod_delivery_state,
    e.exception_state,
    e.hold_state,
    e.final_balance_due_gbp,
    e.blocker_details_json,
    jsonb_build_object(
      'source', 'internal_completion_loyalty_reward_proposals_v1',
      'basis_source', 'internal_order_qualifying_net_spend_v1',
      'default_reward_rate_pct', e.reward_rate_pct,
      'suggested_reward_rule', 'suggested_reward_gbp = qualifying_net_spend_gbp * 10% only when basis_status = ready',
      'credit_availability_rule', 'approval creates locked importer_credit_ledger credit; available only after Sage journal clears lock',
      'basis_snapshot', e.source_detail_json
    ) AS source_detail_json
  FROM evaluated e
  ORDER BY e.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_reward_proposals_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_reward_proposals_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
