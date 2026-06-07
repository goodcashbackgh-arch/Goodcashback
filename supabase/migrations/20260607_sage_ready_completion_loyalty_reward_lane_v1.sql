BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_ready_for_sage_queue_v1()';
  END IF;
  IF to_regprocedure('public.internal_sage_mapping_configured_v1(text)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_sage_mapping_configured_v1(text)';
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.completion_loyalty_reward_approvals';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_customer_tax_ready boolean;
  v_customer_sales_ledger_ready boolean;
  v_shipper_ap_ledger_ready boolean;
  v_loyalty_expense_ledger_ready boolean;
  v_customer_credit_liability_ledger_ready boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: ready for Sage queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for ready for Sage queue.';
  END IF;

  v_customer_tax_ready := public.internal_sage_mapping_configured_v1('ZERO_RATED_EXPORT_TAX_RATE');
  v_customer_sales_ledger_ready := public.internal_sage_mapping_configured_v1('EXPORT_SALE_INCOME_LEDGER');
  v_shipper_ap_ledger_ready := public.internal_sage_mapping_configured_v1('SHIPPER_FREIGHT_COST_LEDGER');
  v_loyalty_expense_ledger_ready := public.internal_sage_mapping_configured_v1('LOYALTY_REWARD_EXPENSE_LEDGER');
  v_customer_credit_liability_ledger_ready := public.internal_sage_mapping_configured_v1('CUSTOMER_CREDIT_LIABILITY_LEDGER');

  RETURN QUERY
  WITH base_queue AS (
    SELECT q.*,
      EXISTS (
        SELECT 1
        FROM public.customer_pre_shipment_hold_requests h
        WHERE h.order_id = q.order_id
          AND h.status IN ('requested','supervisor_approved')
      ) AS has_unresolved_customer_hold
    FROM public.internal_ready_for_sage_queue_v1() q
  ), mapped_queue AS (
    SELECT
      q.queue_row_id,
      q.document_lane,
      q.document_type,
      q.source_table,
      q.source_id,
      q.order_id,
      q.order_ref,
      q.shipment_batch_id,
      q.booking_ref,
      q.counterparty_name,
      q.amount_gbp,
      q.currency_code,
      q.invoice_type,
      q.sage_status,
      q.sage_invoice_id,
      q.sage_posted_at,
      CASE
        WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
          THEN 'internally_marked_posted_no_sage_confirmation'
        WHEN q.sage_status = 'posted'
          THEN 'sage_confirmation_recorded'
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN 'blocked_customer_pre_shipment_hold'
        WHEN q.document_lane = 'customer_sales'
          AND q.sage_status = 'draft'
          AND (v_customer_tax_ready IS DISTINCT FROM true OR v_customer_sales_ledger_ready IS DISTINCT FROM true)
          THEN 'blocked_sage_mapping_required'
        WHEN q.document_lane = 'customer_sales'
          AND q.sage_status = 'draft'
          THEN 'ready_for_sage_posting_preview'
        WHEN q.document_lane = 'shipper_ap'
          AND v_shipper_ap_ledger_ready IS DISTINCT FROM true
          THEN 'blocked_sage_mapping_required'
        ELSE q.readiness_status
      END AS readiness_status,
      CASE
        WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
          THEN 'legacy_internal_posted_status_without_sage_confirmation'
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN 'customer_pre_shipment_hold_unresolved'
        WHEN q.document_lane = 'customer_sales'
          AND q.sage_status = 'draft'
          AND (v_customer_tax_ready IS DISTINCT FROM true OR v_customer_sales_ledger_ready IS DISTINCT FROM true)
          THEN concat_ws(', ',
            CASE WHEN v_customer_tax_ready IS DISTINCT FROM true THEN 'missing_zero_rated_export_tax_rate' END,
            CASE WHEN v_customer_sales_ledger_ready IS DISTINCT FROM true THEN 'missing_export_sales_income_ledger' END
          )
        WHEN q.document_lane = 'shipper_ap'
          AND v_shipper_ap_ledger_ready IS DISTINCT FROM true
          THEN 'missing_shipper_freight_cost_ledger'
        ELSE q.blocker
      END AS blocker,
      q.reference_text,
      q.notes_text,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN '/internal/customer-holds'
        WHEN q.document_lane = 'customer_sales'
          AND NULLIF(q.source_payload #>> '{draft_control,shipment_batch_id}', '') IS NOT NULL
          THEN '/internal/shipping-control/customer-invoice/' || (q.source_payload #>> '{draft_control,shipment_batch_id}')
        ELSE q.detail_href
      END AS detail_href,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND q.has_unresolved_customer_hold = true
          THEN COALESCE(q.source_payload, '{}'::jsonb) || jsonb_build_object('customer_hold_blocker', true)
        ELSE q.source_payload
      END AS source_payload
    FROM base_queue q
  ), grouped_hold_blockers AS (
    SELECT
      h.order_id,
      COUNT(*) FILTER (WHERE h.status IN ('requested','supervisor_approved')) AS active_hold_count,
      COUNT(*) FILTER (WHERE h.status = 'requested') AS requested_hold_count,
      COUNT(*) FILTER (WHERE h.status = 'supervisor_approved') AS approved_hold_count,
      COUNT(*) FILTER (WHERE h.requested_scope = 'line') AS line_hold_count,
      COUNT(*) FILTER (WHERE h.requested_scope = 'tracking') AS tracking_hold_count,
      COUNT(*) FILTER (WHERE h.requested_scope = 'order') AS order_hold_count,
      (array_agg(h.id ORDER BY h.created_at DESC, h.id::text DESC))[1] AS representative_hold_id,
      STRING_AGG(DISTINCT h.requested_scope::text, ', ' ORDER BY h.requested_scope::text) AS scopes_text,
      STRING_AGG(DISTINCT h.status::text, ', ' ORDER BY h.status::text) AS statuses_text,
      STRING_AGG(DISTINCT NULLIF(h.reason, ''), ' | ' ORDER BY NULLIF(h.reason, '')) AS reasons_text,
      jsonb_agg(jsonb_build_object(
        'hold_request_id', h.id,
        'hold_status', h.status,
        'requested_scope', h.requested_scope,
        'tracking_submission_id', h.tracking_submission_id,
        'supplier_invoice_line_id', h.supplier_invoice_line_id,
        'reason', h.reason,
        'created_at', h.created_at,
        'supervisor_review_note', h.supervisor_review_note
      ) ORDER BY h.created_at DESC) AS hold_rows
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.status IN ('requested','supervisor_approved')
    GROUP BY h.order_id
  ), customer_hold_rows AS (
    SELECT
      ('customer_hold_order:' || gh.order_id::text)::text AS queue_row_id,
      'customer_sales'::text AS document_lane,
      'customer_pre_shipment_hold'::text AS document_type,
      'customer_pre_shipment_hold_requests'::text AS source_table,
      gh.order_id AS source_id,
      gh.order_id,
      o.order_ref::text AS order_ref,
      NULL::uuid AS shipment_batch_id,
      NULL::text AS booking_ref,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Customer / importer')::text AS counterparty_name,
      o.order_total_gbp_declared::numeric AS amount_gbp,
      'GBP'::text AS currency_code,
      'customer_sales_hold_blocker'::text AS invoice_type,
      'blocked'::text AS sage_status,
      NULL::text AS sage_invoice_id,
      NULL::timestamptz AS sage_posted_at,
      'blocked_customer_pre_shipment_hold'::text AS readiness_status,
      'customer_pre_shipment_hold_unresolved'::text AS blocker,
      COALESCE(o.order_ref::text, gh.order_id::text) AS reference_text,
      (
        'Customer hold unresolved: '
        || gh.active_hold_count::text || ' active hold(s); '
        || gh.approved_hold_count::text || ' approved; '
        || gh.requested_hold_count::text || ' requested; '
        || gh.line_hold_count::text || ' line-level. '
        || COALESCE(NULLIF(gh.reasons_text, ''), 'No reason recorded.')
      )::text AS notes_text,
      '/internal/customer-holds'::text AS detail_href,
      jsonb_build_object(
        'customer_hold_blocker', true,
        'grouped_by_order', true,
        'active_hold_count', gh.active_hold_count,
        'requested_hold_count', gh.requested_hold_count,
        'approved_hold_count', gh.approved_hold_count,
        'line_hold_count', gh.line_hold_count,
        'tracking_hold_count', gh.tracking_hold_count,
        'order_hold_count', gh.order_hold_count,
        'representative_hold_id', gh.representative_hold_id,
        'hold_scopes', gh.scopes_text,
        'hold_statuses', gh.statuses_text,
        'hold_rows', gh.hold_rows
      ) AS source_payload
    FROM grouped_hold_blockers gh
    JOIN public.orders o ON o.id = gh.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM mapped_queue mq
      WHERE mq.document_lane = 'customer_sales'
        AND mq.order_id = gh.order_id
    )
  ), loyalty_reward_journals AS (
    SELECT
      ('completion_loyalty_reward:' || icl.id::text)::text AS queue_row_id,
      'customer_credit'::text AS document_lane,
      'completion_loyalty_reward_journal'::text AS document_type,
      'importer_credit_ledger'::text AS source_table,
      icl.id AS source_id,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      NULL::uuid AS shipment_batch_id,
      NULL::text AS booking_ref,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Customer / importer')::text AS counterparty_name,
      ABS(icl.amount_gbp)::numeric AS amount_gbp,
      COALESCE(NULLIF(icl.local_ccy::text, ''), 'GBP')::text AS currency_code,
      'journal'::text AS invoice_type,
      'locked_pending_sage_journal'::text AS sage_status,
      NULL::text AS sage_invoice_id,
      NULL::timestamptz AS sage_posted_at,
      CASE
        WHEN v_loyalty_expense_ledger_ready IS DISTINCT FROM true
          OR v_customer_credit_liability_ledger_ready IS DISTINCT FROM true
          THEN 'blocked_sage_mapping_required'
        ELSE 'ready_for_sage_posting_preview'
      END::text AS readiness_status,
      CASE
        WHEN v_loyalty_expense_ledger_ready IS DISTINCT FROM true
          OR v_customer_credit_liability_ledger_ready IS DISTINCT FROM true
          THEN concat_ws(', ',
            CASE WHEN v_loyalty_expense_ledger_ready IS DISTINCT FROM true THEN 'missing_loyalty_reward_expense_ledger' END,
            CASE WHEN v_customer_credit_liability_ledger_ready IS DISTINCT FROM true THEN 'missing_customer_credit_liability_ledger' END
          )
        ELSE NULL::text
      END AS blocker,
      ('LOY-' || COALESCE(o.order_ref::text, o.id::text) || '-' || LEFT(icl.id::text, 8))::text AS reference_text,
      'Completion loyalty reward journal: Dr loyalty reward expense / Cr customer credit liability. Credit remains locked until Sage success.'::text AS notes_text,
      '/internal/sage-ready'::text AS detail_href,
      jsonb_build_object(
        'document_lane', 'customer_credit',
        'document_type', 'completion_loyalty_reward_journal',
        'source_table', 'importer_credit_ledger',
        'source_id', icl.id,
        'approval_id', a.id,
        'credit_ledger_id', icl.id,
        'lock_reason', icl.lock_reason,
        'reference', ('LOY-' || COALESCE(o.order_ref::text, o.id::text) || '-' || LEFT(icl.id::text, 8)),
        'journal_description', 'Completion loyalty reward approved for clean completed order',
        'posting_preview', jsonb_build_array(
          jsonb_build_object(
            'line', 1,
            'entry', 'debit',
            'mapping_code', 'LOYALTY_REWARD_EXPENSE_LEDGER',
            'description', 'Loyalty reward expense / Sales promotion expense',
            'amount_gbp', ABS(icl.amount_gbp),
            'tax_treatment', 'no_tax_return_inclusion'
          ),
          jsonb_build_object(
            'line', 2,
            'entry', 'credit',
            'mapping_code', 'CUSTOMER_CREDIT_LIABILITY_LEDGER',
            'description', 'Customer credit liability / Customer account credit',
            'amount_gbp', ABS(icl.amount_gbp),
            'tax_treatment', 'no_tax_return_inclusion'
          )
        ),
        'approval_snapshot', a.proposal_snapshot_json,
        'approved_amount_gbp', a.approved_amount_gbp,
        'approved_reward_rate_pct', a.approved_reward_rate_pct,
        'qualifying_net_spend_gbp', a.qualifying_net_spend_gbp,
        'created_at', icl.created_at
      ) AS source_payload
    FROM public.importer_credit_ledger icl
    JOIN public.orders o
      ON o.id = COALESCE(icl.linked_order_id, icl.source_entity_id)
    LEFT JOIN public.importers i ON i.id = o.importer_id
    JOIN public.completion_loyalty_reward_approvals a
      ON a.credit_ledger_id = icl.id
    WHERE icl.source_type = 'completion_loyalty_reward'
      AND icl.source_entity_type = 'order'
      AND icl.direction = 'credit'
      AND icl.lock_reason = 'awaiting_sage_loyalty_journal'
      AND a.approval_status IN ('approved_locked_awaiting_sage','ready_for_sage_posting_preview')
  ), final_rows AS (
    SELECT * FROM mapped_queue
    UNION ALL
    SELECT * FROM customer_hold_rows
    UNION ALL
    SELECT * FROM loyalty_reward_journals
  )
  SELECT *
  FROM final_rows fr
  ORDER BY
    CASE fr.document_lane
      WHEN 'customer_sales' THEN 0
      WHEN 'shipper_ap' THEN 1
      WHEN 'customer_credit' THEN 2
      ELSE 3
    END,
    CASE
      WHEN fr.readiness_status LIKE 'blocked%' THEN 0
      WHEN fr.readiness_status LIKE 'ready%' THEN 1
      WHEN fr.readiness_status LIKE 'posted%' THEN 2
      ELSE 3
    END,
    fr.reference_text NULLS LAST,
    fr.source_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
