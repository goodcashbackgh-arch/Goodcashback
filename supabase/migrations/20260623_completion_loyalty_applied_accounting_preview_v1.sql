BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.order_funding_events') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_funding_events';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importers';
  END IF;
  IF to_regprocedure('public.is_active_staff()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.is_active_staff()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_applied_accounting_preview_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  preview_row_id text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  amount_gbp numeric,
  source_credit_ledger_id uuid,
  debit_ledger_id uuid,
  order_funding_event_id uuid,
  accounting_event_type text,
  readiness_status text,
  blocker text,
  selectable boolean,
  posting_enabled boolean,
  reference_text text,
  notes_text text,
  posting_preview_json jsonb,
  mapping_status_json jsonb,
  created_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_debit_mapping_configured boolean := false;
  v_credit_mapping_candidates_json jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: completion loyalty applied accounting preview requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for completion loyalty applied accounting preview.';
  END IF;

  IF to_regprocedure('public.internal_sage_mapping_configured_v1(text)') IS NOT NULL THEN
    v_debit_mapping_configured := public.internal_sage_mapping_configured_v1('LOYALTY_REWARD_EXPENSE_LEDGER');

    v_credit_mapping_candidates_json := jsonb_build_array(
      jsonb_build_object(
        'mapping_code', 'CUSTOMER_RECEIVABLE_LEDGER',
        'purpose', 'Possible credit side: customer account / receivable',
        'configured', public.internal_sage_mapping_configured_v1('CUSTOMER_RECEIVABLE_LEDGER')
      ),
      jsonb_build_object(
        'mapping_code', 'CUSTOMER_CLEARING_LEDGER',
        'purpose', 'Possible credit side: customer clearing',
        'configured', public.internal_sage_mapping_configured_v1('CUSTOMER_CLEARING_LEDGER')
      ),
      jsonb_build_object(
        'mapping_code', 'CUSTOMER_ACCOUNT_CREDIT_LEDGER',
        'purpose', 'Possible credit side: customer account credit',
        'configured', public.internal_sage_mapping_configured_v1('CUSTOMER_ACCOUNT_CREDIT_LEDGER')
      )
    );
  END IF;

  RETURN QUERY
  WITH applied AS (
    SELECT
      ('completion_loyalty_applied_accounting_preview:' || ofe.id::text)::text AS preview_row_id,
      'order_funding_events'::text AS source_table,
      ofe.id AS source_id,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      o.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      round(abs(ofe.amount_gbp)::numeric, 2) AS amount_gbp,
      source_credit.id AS source_credit_ledger_id,
      debit.id AS debit_ledger_id,
      ofe.id AS order_funding_event_id,
      'non_cash_loyalty_customer_balance_settlement'::text AS accounting_event_type,
      'preview_only_mapping_not_confirmed'::text AS readiness_status,
      'sage_mapping_endpoint_idempotency_logging_and_reversal_contract_not_locked'::text AS blocker,
      false AS selectable,
      false AS posting_enabled,
      ('LOY-APP-' || COALESCE(o.order_ref::text, o.id::text) || '-' || LEFT(ofe.id::text, 8))::text AS reference_text,
      'Read-only applied completion-loyalty accounting preview. No Sage posting, cash freeze, VAT source row, credit unlock, or queue posting is enabled by this row.'::text AS notes_text,
      jsonb_build_object(
        'preview_only', true,
        'posting_enabled', false,
        'posting_contract_required_before_live_posting', true,
        'document_lane', 'customer_credit_preview_only',
        'document_type', 'completion_loyalty_application_accounting_preview',
        'source_table', 'order_funding_events',
        'source_id', ofe.id,
        'source_credit_ledger_id', source_credit.id,
        'debit_ledger_id', debit.id,
        'order_funding_event_id', ofe.id,
        'accounting_treatment', jsonb_build_array(
          jsonb_build_object(
            'line', 1,
            'entry', 'debit',
            'description', 'Loyalty cost / reward expense / loyalty liability',
            'mapping_policy', 'not_locked',
            'candidate_mapping_code', 'LOYALTY_REWARD_EXPENSE_LEDGER',
            'amount_gbp', round(abs(ofe.amount_gbp)::numeric, 2),
            'tax_treatment', 'no_tax_return_inclusion_from_preview'
          ),
          jsonb_build_object(
            'line', 2,
            'entry', 'credit',
            'description', 'Customer account / receivable',
            'mapping_policy', 'not_locked',
            'candidate_mapping_codes', jsonb_build_array('CUSTOMER_RECEIVABLE_LEDGER','CUSTOMER_CLEARING_LEDGER','CUSTOMER_ACCOUNT_CREDIT_LEDGER'),
            'amount_gbp', round(abs(ofe.amount_gbp)::numeric, 2),
            'tax_treatment', 'no_tax_return_inclusion_from_preview'
          )
        ),
        'contract_boundary', jsonb_build_object(
          'pending_loyalty_posting', false,
          'staged_main_out_posting', false,
          'released_unused_loyalty_posting', false,
          'applied_loyalty_is_accounting_event', true,
          'vat_timing_source_remains_order_funding_events_credit_applied', true,
          'old_approval_stage_loyalty_queue_must_remain_suppressed', true
        )
      ) AS posting_preview_json,
      jsonb_build_object(
        'mapping_policy_status', 'not_locked',
        'posting_endpoint_status', 'not_confirmed',
        'idempotency_policy_status', 'not_confirmed',
        'response_logging_status', 'not_confirmed',
        'reversal_policy_status', 'not_confirmed',
        'debit_candidate', jsonb_build_object(
          'mapping_code', 'LOYALTY_REWARD_EXPENSE_LEDGER',
          'purpose', 'Candidate debit side: loyalty cost / reward expense',
          'configured', v_debit_mapping_configured
        ),
        'credit_candidates', v_credit_mapping_candidates_json,
        'live_posting_blocker', 'Exact debit/credit mappings, Sage endpoint, idempotency, logging, reversal, authority, and feature flag must be separately locked before posting.'
      ) AS mapping_status_json,
      ofe.created_at,
      count(*) over() AS total_count
    FROM public.order_funding_events ofe
    JOIN public.orders o ON o.id = ofe.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    JOIN public.importer_credit_ledger debit ON debit.id = ofe.source_entity_id
    JOIN public.importer_credit_ledger source_credit ON source_credit.id = COALESCE(debit.source_id, debit.source_entity_id)
    WHERE ofe.event_type = 'credit_applied'
      AND source_credit.source_type = 'completion_loyalty_reward'
      AND (
        v_search IS NULL
        OR lower(concat_ws(' ', o.order_ref, i.trading_name, i.company_name, ofe.amount_gbp::text, ofe.id::text, debit.id::text, source_credit.id::text)) LIKE '%' || v_search || '%'
      )
  )
  SELECT *
  FROM applied
  ORDER BY created_at DESC, order_ref DESC NULLS LAST, order_funding_event_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_applied_accounting_preview_v1(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_applied_accounting_preview_v1(text, integer, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
