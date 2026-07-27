BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Scope: replace the shared supplier-payment source resolver only.
-- Existing allocator RPCs, allocation writes, locking, posting and Sage routes
-- remain unchanged.

CREATE OR REPLACE FUNCTION public.internal_supplier_payment_bundle_source_v1(
  p_order_id uuid,
  p_physical_out_gbp numeric
)
RETURNS TABLE (
  source_bank_account_mapping_code text,
  source_wallet_code text,
  source_resolution_reason text,
  remaining_order_cash_funding_gbp numeric,
  remaining_released_loyalty_funding_gbp numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
#variable_conflict use_column
DECLARE
  v_order record;
  v_amount numeric(12,2) := ROUND(COALESCE(p_physical_out_gbp, 0)::numeric, 2);
  v_funding_required boolean;
  v_ready boolean;
  v_blocker text;
  v_has_credit boolean := false;
  v_invalid_cash_credit_count integer := 0;
  v_unsupported_credit_count integer := 0;
  v_unproven_cash_credit_count integer := 0;
  v_cash_backed_credit_gbp numeric(12,2) := 0;
  v_exact_count integer := 0;
  v_loyalty_remaining numeric(12,2) := 0;
  v_cash_remaining numeric(12,2) := 0;
  v_wallet text;
  v_mapping text;
BEGIN
  SELECT o.id, o.importer_id, COALESCE(o.order_type, 'original') AS order_type
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_order.id IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'A valid order and positive physical OUT amount are required.';
  END IF;

  SELECT r.supplier_payment_ready_yn, r.blocker, r.funding_required_yn
  INTO v_ready, v_blocker, v_funding_required
  FROM public.internal_supplier_payment_readiness_v1(p_order_id) r
  LIMIT 1;

  IF v_ready IS DISTINCT FROM true THEN
    RAISE EXCEPTION
      'source_funding_required_for_supplier_payment_bank_resolution: order %, blocker %',
      p_order_id,
      COALESCE(v_blocker, 'readiness_row_missing');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'credit_applied'
      AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
  )
  INTO v_has_credit;

  /*
    New proof lane. It is deliberately limited to settlement_credit and
    overfunding. Completion-loyalty events remain exclusively on the unchanged
    loyalty resolver below.
  */
  WITH applied AS (
    SELECT
      ofe.id AS funding_event_id,
      ofe.source_entity_type AS event_source_entity_type,
      ofe.source_entity_id AS application_debit_id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS event_amount_gbp,

      debit.importer_id AS debit_importer_id,
      debit.direction AS debit_direction,
      debit.source_type::text AS debit_source_type,
      debit.source_table::text AS debit_source_table,
      debit.source_id AS debit_source_id,
      debit.source_entity_type::text AS debit_source_entity_type,
      debit.source_entity_id AS debit_source_entity_id,
      debit.applied_to_order_id,
      debit.linked_order_id AS debit_linked_order_id,
      debit.lock_reason AS debit_lock_reason,
      ROUND(ABS(COALESCE(debit.amount_gbp, 0))::numeric, 2) AS debit_amount_gbp,

      credit.id AS source_credit_id,
      credit.importer_id AS source_credit_importer_id,
      credit.direction AS source_credit_direction,
      credit.source_type::text AS source_credit_type,
      credit.source_table::text AS source_credit_source_table,
      credit.source_id AS source_credit_source_id,
      credit.source_entity_type::text AS source_credit_entity_type,
      credit.source_entity_id AS source_order_id,
      credit.linked_order_id AS source_credit_linked_order_id,
      credit.lock_reason AS source_credit_lock_reason,
      ROUND(ABS(COALESCE(credit.amount_gbp, 0))::numeric, 2) AS source_credit_amount_gbp
    FROM public.order_funding_events ofe
    LEFT JOIN public.importer_credit_ledger debit
      ON debit.id = ofe.source_entity_id
    LEFT JOIN public.importer_credit_ledger credit
      ON credit.id = CASE
        WHEN debit.source_table = 'importer_credit_ledger'
          THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger'
          THEN debit.source_entity_id
        ELSE NULL::uuid
      END
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'credit_applied'
      AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
  ),
  supported_cash_applied AS (
    SELECT *
    FROM applied a
    WHERE a.source_credit_type IN ('settlement_credit', 'overfunding')
  ),
  event_counts AS (
    SELECT
      a.application_debit_id,
      COUNT(ofe.id)::integer AS event_count
    FROM (
      SELECT DISTINCT application_debit_id
      FROM supported_cash_applied
      WHERE application_debit_id IS NOT NULL
    ) a
    LEFT JOIN public.order_funding_events ofe
      ON ofe.event_type = 'credit_applied'
     AND ofe.source_entity_type = 'importer_credit_ledger'
     AND ofe.source_entity_id = a.application_debit_id
    GROUP BY a.application_debit_id
  ),
  linked_debits AS (
    SELECT
      lot.source_credit_id,
      ROUND(COALESCE(SUM(ABS(d.amount_gbp)), 0)::numeric, 2) AS linked_debit_gbp
    FROM (
      SELECT DISTINCT source_credit_id, source_credit_importer_id
      FROM supported_cash_applied
      WHERE source_credit_id IS NOT NULL
    ) lot
    LEFT JOIN public.importer_credit_ledger d
      ON d.importer_id = lot.source_credit_importer_id
     AND d.direction = 'debit'
     AND d.lock_reason IS NULL
     AND (
          (d.source_table = 'importer_credit_ledger' AND d.source_id = lot.source_credit_id)
       OR (d.source_entity_type = 'importer_credit_ledger' AND d.source_entity_id = lot.source_credit_id)
     )
    GROUP BY lot.source_credit_id
  ),
  checked_cash_applied AS (
    SELECT
      a.*,
      CASE
        WHEN a.event_source_entity_type IS DISTINCT FROM 'importer_credit_ledger' THEN false
        WHEN a.application_debit_id IS NULL THEN false
        WHEN COALESCE(ec.event_count, 0) <> 1 THEN false
        WHEN a.debit_importer_id IS DISTINCT FROM v_order.importer_id THEN false
        WHEN a.debit_direction IS DISTINCT FROM 'debit' THEN false
        WHEN a.debit_source_type IS DISTINCT FROM 'credit_application' THEN false
        WHEN COALESCE(a.applied_to_order_id, a.debit_linked_order_id) IS DISTINCT FROM p_order_id THEN false
        WHEN a.debit_source_table IS DISTINCT FROM 'importer_credit_ledger' THEN false
        WHEN a.debit_source_entity_type IS DISTINCT FROM 'importer_credit_ledger' THEN false
        WHEN a.debit_source_id IS NULL OR a.debit_source_entity_id IS NULL THEN false
        WHEN a.debit_source_id IS DISTINCT FROM a.debit_source_entity_id THEN false
        WHEN a.source_credit_id IS DISTINCT FROM a.debit_source_id THEN false
        WHEN a.source_credit_importer_id IS DISTINCT FROM v_order.importer_id THEN false
        WHEN a.source_credit_direction IS DISTINCT FROM 'credit' THEN false
        WHEN a.debit_lock_reason IS NOT NULL OR a.source_credit_lock_reason IS NOT NULL THEN false
        WHEN ABS(a.event_amount_gbp - a.debit_amount_gbp) > 0.01 THEN false
        WHEN a.debit_amount_gbp > a.source_credit_amount_gbp + 0.01 THEN false
        WHEN COALESCE(ld.linked_debit_gbp, 0) > a.source_credit_amount_gbp + 0.01 THEN false
        ELSE true
      END AS application_valid
    FROM supported_cash_applied a
    LEFT JOIN event_counts ec
      ON ec.application_debit_id = a.application_debit_id
    LEFT JOIN linked_debits ld
      ON ld.source_credit_id = a.source_credit_id
  ),
  source_orders AS (
    SELECT DISTINCT
      ca.source_order_id,
      ca.source_credit_importer_id AS importer_id
    FROM checked_cash_applied ca
    WHERE ca.application_valid IS TRUE
      AND ca.source_order_id IS NOT NULL
  ),
  source_lots AS (
    SELECT
      so.source_order_id,
      so.importer_id,
      c.id AS credit_ledger_id,
      c.source_type::text AS source_type,
      c.source_table::text AS source_table,
      c.source_id,
      c.source_entity_type::text AS source_entity_type,
      c.source_entity_id,
      c.linked_order_id,
      ROUND(ABS(COALESCE(c.amount_gbp, 0))::numeric, 2) AS credit_amount_gbp
    FROM source_orders so
    JOIN public.importer_credit_ledger c
      ON c.importer_id = so.importer_id
     AND c.direction = 'credit'
     AND c.lock_reason IS NULL
     AND c.source_type IN ('settlement_credit', 'overfunding')
     AND c.source_entity_type = 'order'
     AND c.source_entity_id = so.source_order_id
  ),
  receipt_mapping_rows AS (
    SELECT
      so.source_order_id,
      so.importer_id,
      ofe.id AS funding_event_id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS event_amount_gbp,
      ofe.source_entity_type,
      dr.id AS reconciliation_id,
      dr.order_id AS reconciliation_order_id,
      dr.reconciliation_type,
      ROUND(ABS(COALESCE(dr.reconciled_gbp_amount, 0))::numeric, 2) AS reconciliation_amount_gbp,
      dr.dva_statement_line_id,
      dsl.direction AS statement_direction,
      ds.importer_id AS statement_importer_id,
      map.source_wallet_code AS mapped_wallet_code,
      map.source_bank_account_mapping_code AS mapped_bank_code
    FROM source_orders so
    JOIN public.order_funding_events ofe
      ON ofe.order_id = so.source_order_id
     AND ofe.event_type = 'funding_contribution'
     AND ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) > 0
    LEFT JOIN public.dva_reconciliation dr
      ON dr.id = ofe.source_entity_id
    LEFT JOIN public.dva_statement_lines dsl
      ON dsl.id = dr.dva_statement_line_id
    LEFT JOIN public.dva_statements ds
      ON ds.id = dsl.dva_statement_id
    LEFT JOIN public.dva_statement_line_import_links il
      ON il.dva_statement_line_id = dsl.id
     AND il.active_yn = true
    LEFT JOIN LATERAL public.internal_dva_statement_source_mapping_v1(
      COALESCE(
        NULLIF(il.statement_account_context, ''),
        NULLIF(ds.statement_account_context, ''),
        'importer_dva_card_account'
      ),
      dsl.local_ccy,
      il.statement_source_wallet_code,
      il.statement_source_bank_account_mapping_code
    ) map ON true
  ),
  receipt_by_line AS (
    SELECT
      r.source_order_id,
      r.dva_statement_line_id,
      COUNT(DISTINCT r.reconciliation_id)::integer AS reconciliation_count,
      COUNT(DISTINCT (
        COALESCE(r.mapped_wallet_code, '<NULL>'),
        COALESCE(r.mapped_bank_code, '<NULL>')
      ))::integer AS source_count,
      BOOL_AND(
        r.source_entity_type = 'dva_reconciliation'
        AND r.reconciliation_id IS NOT NULL
        AND r.reconciliation_order_id = r.source_order_id
        AND r.reconciliation_type = 'order_funding'
        AND r.statement_direction = 'in'
        AND r.statement_importer_id = r.importer_id
        AND ABS(r.event_amount_gbp - r.reconciliation_amount_gbp) <= 0.01
        AND r.mapped_wallet_code = 'dva_cash'
        AND r.mapped_bank_code = 'DVA_CASH_BANK_ACCOUNT'
      ) AS rows_valid,
      MIN(r.event_amount_gbp) AS min_event_gbp,
      MAX(r.event_amount_gbp) AS max_event_gbp,
      MAX(r.reconciliation_amount_gbp) AS receipt_gbp
    FROM receipt_mapping_rows r
    GROUP BY r.source_order_id, r.dva_statement_line_id
  ),
  receipt_pool AS (
    SELECT
      so.source_order_id,
      COUNT(r.dva_statement_line_id)::integer AS line_count,
      COUNT(r.dva_statement_line_id) FILTER (
        WHERE r.rows_valid IS TRUE
          AND r.reconciliation_count = 1
          AND r.source_count = 1
          AND ABS(r.max_event_gbp - r.min_event_gbp) <= 0.01
      )::integer AS valid_line_count,
      ROUND(COALESCE(SUM(r.receipt_gbp) FILTER (
        WHERE r.rows_valid IS TRUE
          AND r.reconciliation_count = 1
          AND r.source_count = 1
          AND ABS(r.max_event_gbp - r.min_event_gbp) <= 0.01
      ), 0)::numeric, 2) AS proven_receipt_gbp
    FROM source_orders so
    LEFT JOIN receipt_by_line r
      ON r.source_order_id = so.source_order_id
    GROUP BY so.source_order_id
  ),
  settlement_proof AS (
    SELECT
      sl.credit_ledger_id,
      COUNT(a.id)::integer AS action_count,
      COUNT(a.id) FILTER (
        WHERE sl.source_table = 'order_settlement_resolution_actions'
          AND sl.source_id = a.id
          AND sl.source_entity_type = 'order'
          AND sl.source_entity_id = sl.source_order_id
          AND sl.linked_order_id = sl.source_order_id
          AND a.order_id = sl.source_order_id
          AND a.importer_id = sl.importer_id
          AND a.status = 'active'
          AND a.reversed_at IS NULL
          AND ABS(
            ROUND(COALESCE(a.customer_credit_gbp, 0)::numeric, 2)
            - sl.credit_amount_gbp
          ) <= 0.01
      )::integer AS valid_action_count
    FROM source_lots sl
    LEFT JOIN public.order_settlement_resolution_actions a
      ON a.credit_ledger_id = sl.credit_ledger_id
    WHERE sl.source_type = 'settlement_credit'
    GROUP BY sl.credit_ledger_id
  ),
  overfunding_mapping_rows AS (
    SELECT
      sl.credit_ledger_id,
      sl.source_order_id,
      sl.importer_id,
      sl.credit_amount_gbp,
      sl.source_table,
      sl.source_id,
      sl.source_entity_type,
      sl.source_entity_id,
      sl.linked_order_id,
      ops.id AS pending_id,
      ops.order_id AS pending_order_id,
      ops.importer_id AS pending_importer_id,
      ops.status AS pending_status,
      ops.reversed_at,
      ops.confirmed_credit_ledger_id,
      ROUND(COALESCE(ops.pending_surplus_gbp, 0)::numeric, 2) AS pending_surplus_gbp,
      ops.dva_statement_line_id,
      dr.order_id AS reconciliation_order_id,
      dr.reconciliation_type,
      dr.dva_statement_line_id AS reconciliation_statement_line_id,
      dsl.direction AS statement_direction,
      ds.importer_id AS statement_importer_id,
      map.source_wallet_code AS mapped_wallet_code,
      map.source_bank_account_mapping_code AS mapped_bank_code
    FROM source_lots sl
    LEFT JOIN public.order_pending_funding_surplus ops
      ON ops.confirmed_credit_ledger_id = sl.credit_ledger_id
    LEFT JOIN public.dva_reconciliation dr
      ON dr.id = ops.dva_reconciliation_id
    LEFT JOIN public.dva_statement_lines dsl
      ON dsl.id = ops.dva_statement_line_id
    LEFT JOIN public.dva_statements ds
      ON ds.id = dsl.dva_statement_id
    LEFT JOIN public.dva_statement_line_import_links il
      ON il.dva_statement_line_id = dsl.id
     AND il.active_yn = true
    LEFT JOIN LATERAL public.internal_dva_statement_source_mapping_v1(
      COALESCE(
        NULLIF(il.statement_account_context, ''),
        NULLIF(ds.statement_account_context, ''),
        'importer_dva_card_account'
      ),
      dsl.local_ccy,
      il.statement_source_wallet_code,
      il.statement_source_bank_account_mapping_code
    ) map ON true
    WHERE sl.source_type = 'overfunding'
  ),
  overfunding_proof AS (
    SELECT
      r.credit_ledger_id,
      COUNT(DISTINCT r.pending_id)::integer AS pending_count,
      COUNT(DISTINCT (
        COALESCE(r.mapped_wallet_code, '<NULL>'),
        COALESCE(r.mapped_bank_code, '<NULL>')
      ))::integer AS source_count,
      BOOL_AND(
        r.source_table = 'orders'
        AND r.source_id = r.source_order_id
        AND r.source_entity_type = 'order'
        AND r.source_entity_id = r.source_order_id
        AND r.linked_order_id = r.source_order_id
        AND r.pending_id IS NOT NULL
        AND r.pending_order_id = r.source_order_id
        AND r.pending_importer_id = r.importer_id
        AND r.pending_status = 'credit_confirmed'
        AND r.reversed_at IS NULL
        AND r.confirmed_credit_ledger_id = r.credit_ledger_id
        AND ABS(r.pending_surplus_gbp - r.credit_amount_gbp) <= 0.01
        AND r.reconciliation_order_id = r.pending_order_id
        AND r.reconciliation_type = 'order_funding'
        AND r.reconciliation_statement_line_id = r.dva_statement_line_id
        AND r.statement_direction = 'in'
        AND r.statement_importer_id = r.importer_id
        AND r.mapped_wallet_code = 'dva_cash'
        AND r.mapped_bank_code = 'DVA_CASH_BANK_ACCOUNT'
      ) AS rows_valid
    FROM overfunding_mapping_rows r
    GROUP BY r.credit_ledger_id
  ),
  proven_lots AS (
    SELECT
      sl.source_order_id,
      sl.credit_ledger_id,
      sl.credit_amount_gbp,
      CASE
        WHEN sl.source_type = 'settlement_credit'
          THEN COALESCE(sp.action_count, 0) = 1
           AND COALESCE(sp.valid_action_count, 0) = 1
        WHEN sl.source_type = 'overfunding'
          THEN COALESCE(op.pending_count, 0) = 1
           AND COALESCE(op.source_count, 0) = 1
           AND op.rows_valid IS TRUE
        ELSE false
      END AS proven
    FROM source_lots sl
    LEFT JOIN settlement_proof sp
      ON sp.credit_ledger_id = sl.credit_ledger_id
    LEFT JOIN overfunding_proof op
      ON op.credit_ledger_id = sl.credit_ledger_id
  ),
  source_pool AS (
    SELECT
      so.source_order_id,
      ROUND(COALESCE(SUM(pl.credit_amount_gbp), 0)::numeric, 2) AS obligation_gbp,
      COUNT(pl.credit_ledger_id) FILTER (
        WHERE pl.proven IS DISTINCT FROM true
      )::integer AS unproven_lot_count,
      rp.line_count,
      rp.valid_line_count,
      rp.proven_receipt_gbp
    FROM source_orders so
    LEFT JOIN proven_lots pl
      ON pl.source_order_id = so.source_order_id
    LEFT JOIN receipt_pool rp
      ON rp.source_order_id = so.source_order_id
    GROUP BY
      so.source_order_id,
      rp.line_count,
      rp.valid_line_count,
      rp.proven_receipt_gbp
  ),
  valid_cash_events AS (
    SELECT
      ca.funding_event_id,
      ca.event_amount_gbp
    FROM checked_cash_applied ca
    JOIN proven_lots pl
      ON pl.credit_ledger_id = ca.source_credit_id
     AND pl.proven IS TRUE
    JOIN source_pool sp
      ON sp.source_order_id = ca.source_order_id
    WHERE ca.application_valid IS TRUE
      AND sp.line_count > 0
      AND sp.valid_line_count = sp.line_count
      AND sp.unproven_lot_count = 0
      AND sp.obligation_gbp <= sp.proven_receipt_gbp + 0.01
  ),
  diagnostics AS (
    SELECT
      (
        SELECT COUNT(*)::integer
        FROM checked_cash_applied ca
        WHERE ca.application_valid IS DISTINCT FROM true
      ) AS invalid_cash_credit_count,
      (
        SELECT COUNT(*)::integer
        FROM applied a
        WHERE COALESCE(a.source_credit_type, '') NOT IN (
          'completion_loyalty_reward',
          'settlement_credit',
          'overfunding'
        )
      ) AS unsupported_credit_count,
      (
        SELECT COUNT(*)::integer
        FROM checked_cash_applied ca
        WHERE ca.application_valid IS TRUE
          AND NOT EXISTS (
            SELECT 1
            FROM valid_cash_events v
            WHERE v.funding_event_id = ca.funding_event_id
          )
      ) AS unproven_cash_credit_count,
      (
        SELECT ROUND(COALESCE(SUM(v.event_amount_gbp), 0)::numeric, 2)
        FROM valid_cash_events v
      ) AS cash_backed_credit_gbp
  )
  SELECT
    d.invalid_cash_credit_count,
    d.unsupported_credit_count,
    d.unproven_cash_credit_count,
    d.cash_backed_credit_gbp
  INTO
    v_invalid_cash_credit_count,
    v_unsupported_credit_count,
    v_unproven_cash_credit_count,
    v_cash_backed_credit_gbp
  FROM diagnostics d;

  IF v_invalid_cash_credit_count > 0 THEN
    RAISE EXCEPTION
      'source_funding_required_for_supplier_payment_bank_resolution: order %, blocker %',
      p_order_id,
      'credit_application_amount_or_source_integrity_invalid';
  END IF;

  IF v_unsupported_credit_count > 0 THEN
    RAISE EXCEPTION
      'source_funding_required_for_supplier_payment_bank_resolution: order %, blocker %',
      p_order_id,
      'unsupported_applied_credit_source_type';
  END IF;

  IF v_unproven_cash_credit_count > 0 THEN
    RAISE EXCEPTION
      'source_funding_required_for_supplier_payment_bank_resolution: order %, blocker %',
      p_order_id,
      'cash_backed_credit_source_unresolved_or_ambiguous';
  END IF;

  /*
    Existing released-loyalty implementation is preserved verbatim.
  */
  WITH loyalty_applied AS (
    SELECT DISTINCT ON (ofe.id)
      ofe.id,
      ROUND(ABS(COALESCE(ofe.amount_gbp, 0))::numeric, 2) AS amount_gbp,
      resolver.resolved_wallet_code::text AS wallet_code
    FROM public.order_funding_events ofe
    JOIN public.importer_credit_ledger debit
      ON debit.id = ofe.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches lm
      ON lm.credit_ledger_id = CASE
        WHEN debit.source_table = 'importer_credit_ledger'
          THEN debit.source_id
        WHEN debit.source_entity_type = 'importer_credit_ledger'
          THEN debit.source_entity_id
        ELSE NULL::uuid
      END
     AND lm.importer_id = v_order.importer_id
     AND lm.match_status = 'released_available_dashboard_credit'
     AND COALESCE(lm.transfer_pair_status, '') = 'paired_released'
     AND lm.destination_in_statement_line_id IS NOT NULL
    JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(
      lm.destination_in_statement_line_id
    ) resolver ON resolver.blocker IS NULL
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'credit_applied'
      AND ofe.source_entity_type = 'importer_credit_ledger'
    ORDER BY ofe.id, lm.id
  ),
  loyalty_by_wallet AS (
    SELECT wallet_code, ROUND(SUM(amount_gbp)::numeric, 2) AS applied_gbp
    FROM loyalty_applied
    GROUP BY wallet_code
  ),
  existing_source_allocations AS (
    SELECT
      NULLIF(TRIM(a.source_bank_account_mapping_code), '') AS mapping_code,
      NULLIF(TRIM(a.source_wallet_code), '') AS wallet_code,
      ROUND(SUM(COALESCE(a.allocated_gbp_amount, 0))::numeric, 2) AS allocated_gbp
    FROM public.dva_statement_line_allocations a
    JOIN public.supplier_invoices si
      ON si.id = a.supplier_invoice_id
    WHERE si.order_id = p_order_id
      AND a.allocation_type = 'supplier_invoice'
      AND a.allocation_status = 'confirmed'
    GROUP BY 1, 2
  ),
  loyalty_remaining AS (
    SELECT
      lbw.wallet_code,
      CASE lbw.wallet_code
        WHEN 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
        WHEN 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
        ELSE NULL::text
      END AS mapping_code,
      ROUND(
        GREATEST(
          lbw.applied_gbp - COALESCE(esa.allocated_gbp, 0),
          0
        )::numeric,
        2
      ) AS remaining_gbp
    FROM loyalty_by_wallet lbw
    LEFT JOIN existing_source_allocations esa
      ON esa.wallet_code = lbw.wallet_code
  ),
  cash_funding AS (
    SELECT ROUND(
      (
        COALESCE(SUM(ABS(ofe.amount_gbp)), 0)
        + v_cash_backed_credit_gbp
      )::numeric,
      2
    ) AS funded_gbp
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'funding_contribution'
  ),
  cash_allocated AS (
    SELECT ROUND(COALESCE(SUM(allocated_gbp), 0)::numeric, 2) AS allocated_gbp
    FROM existing_source_allocations
    WHERE mapping_code = 'DVA_CASH_BANK_ACCOUNT'
  )
  SELECT
    COUNT(*) FILTER (
      WHERE ABS(lr.remaining_gbp - v_amount) < 0.01
        AND lr.mapping_code IS NOT NULL
    )::integer,
    ROUND(COALESCE(SUM(lr.remaining_gbp), 0)::numeric, 2),
    ROUND(
      GREATEST(
        (SELECT funded_gbp FROM cash_funding)
        - (SELECT allocated_gbp FROM cash_allocated),
        0
      )::numeric,
      2
    ),
    MAX(lr.wallet_code) FILTER (
      WHERE ABS(lr.remaining_gbp - v_amount) < 0.01
        AND lr.mapping_code IS NOT NULL
    ),
    MAX(lr.mapping_code) FILTER (
      WHERE ABS(lr.remaining_gbp - v_amount) < 0.01
        AND lr.mapping_code IS NOT NULL
    )
  INTO
    v_exact_count,
    v_loyalty_remaining,
    v_cash_remaining,
    v_wallet,
    v_mapping
  FROM loyalty_remaining lr;

  IF v_exact_count > 1
     OR (v_exact_count = 1 AND v_cash_remaining + 0.01 >= v_amount)
  THEN
    RAISE EXCEPTION
      'source_funding_ambiguous_for_supplier_payment_bank_resolution: order %, OUT %',
      p_order_id,
      v_amount;
  ELSIF v_exact_count = 1 THEN
    RETURN QUERY SELECT
      v_mapping,
      v_wallet,
      'exact_remaining_released_loyalty_source'::text,
      v_cash_remaining,
      v_loyalty_remaining;
  ELSIF v_cash_remaining + 0.01 >= v_amount THEN
    RETURN QUERY SELECT
      'DVA_CASH_BANK_ACCOUNT'::text,
      NULL::text,
      'proven_remaining_order_cash_funding'::text,
      v_cash_remaining,
      v_loyalty_remaining;
  ELSIF v_funding_required IS DISTINCT FROM true
        AND v_has_credit IS DISTINCT FROM true
  THEN
    RETURN QUERY SELECT
      'DVA_CASH_BANK_ACCOUNT'::text,
      NULL::text,
      'funding_not_required_physical_out_without_applied_credit_provenance'::text,
      v_cash_remaining,
      v_loyalty_remaining;
  ELSE
    RAISE EXCEPTION
      'source_funding_required_for_supplier_payment_bank_resolution: order %, OUT %, loyalty remaining %, cash remaining %',
      p_order_id,
      v_amount,
      v_loyalty_remaining,
      v_cash_remaining;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION
  public.internal_supplier_payment_bundle_source_v1(uuid, numeric)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION
  public.internal_supplier_payment_bundle_source_v1(uuid, numeric)
  FROM anon;
GRANT EXECUTE ON FUNCTION
  public.internal_supplier_payment_bundle_source_v1(uuid, numeric)
  TO authenticated;

COMMIT;
