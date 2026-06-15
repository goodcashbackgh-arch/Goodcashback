-- =============================================================================
-- Fix VAT Box 6 partial prepayment function grouping v2
-- =============================================================================
-- Problem fixed:
--   v1 used si.* plus grouped funding aggregation. Live sales_invoices has extra
--   columns such as sage_reference, so Postgres correctly required those columns
--   in GROUP BY.
--
-- Fix:
--   Keep the same Box 6 partial-prepayment accounting logic but calculate funding
--   totals with per-invoice LATERAL subqueries. This removes the brittle GROUP BY
--   over sales_invoices columns and makes the function safe when sales_invoices has
--   additive columns.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_apply_vat_timing_source_lines_v1(
  p_vat_return_run_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_period_start date;
  v_period_end date;
  v_period_label text;
BEGIN
  SELECT
    r.period_start_date,
    r.period_end_date,
    r.return_period_label
  INTO
    v_period_start,
    v_period_end,
    v_period_label
  FROM public.vat_return_runs r
  WHERE r.id = p_vat_return_run_id;

  IF v_period_start IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found: %', p_vat_return_run_id;
  END IF;

  UPDATE public.vat_return_run_lines
  SET status = 'superseded'
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND line_kind IN (
      'box6_prepayment_increase',
      'sage_sales_invoice_natural_current',
      'box6_anti_duplicate_decrease',
      'box1_export_evidence_breach',
      'box1_export_evidence_reinstatement'
    );

  -- -------------------------------------------------------------------------
  -- Box 6 prepayment increase.
  -- Uses order_funding_events by order_id and event date. No GROUP BY over
  -- sales_invoices columns is used; additive invoice columns cannot break this.
  -- -------------------------------------------------------------------------

  WITH invoice_scope AS (
    SELECT
      si.*,
      COALESCE(
        CASE
          WHEN si.sage_invoice_period ~ '^[0-9]{4}-[0-9]{2}$'
            THEN to_date(si.sage_invoice_period || '-01', 'YYYY-MM-DD')
          ELSE NULL
        END,
        date_trunc('month', si.sage_invoice_date)::date
      ) AS invoice_period_start,
      ABS(COALESCE(si.amount_gbp, 0)) AS invoice_amount_gbp
    FROM public.sales_invoices si
    WHERE COALESCE(si.sage_status, '') <> 'void'
      AND LOWER(COALESCE(si.invoice_type, '')) NOT IN (
        'credit_note',
        'credit note',
        'sales_credit_note',
        'sales credit note'
      )
      AND COALESCE(si.amount_gbp, 0) > 0
      AND si.order_id IS NOT NULL
      AND si.sage_invoice_date IS NOT NULL
  ), invoice_ordered AS (
    SELECT
      i.*,
      COALESCE(
        SUM(i.invoice_amount_gbp) OVER (
          PARTITION BY i.order_id
          ORDER BY i.invoice_period_start, i.sage_invoice_date, i.created_at, i.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ),
        0
      ) AS prior_invoice_amount_gbp
    FROM invoice_scope i
  ), timing_base AS (
    SELECT
      i.*,
      COALESCE(f.funding_before_run_gbp, 0) AS funding_before_run_gbp,
      COALESCE(f.funding_through_run_gbp, 0) AS funding_through_run_gbp,
      COALESCE(f.funding_before_invoice_period_gbp, 0) AS funding_before_invoice_period_gbp,
      COALESCE(f.funding_in_current_run_before_invoice_period_gbp, 0) AS funding_in_current_run_before_invoice_period_gbp,
      COALESCE(f.same_invoice_period_funding_gbp, 0) AS same_invoice_period_funding_gbp,
      COALESCE(f.pre_invoice_funding_events_json, '[]'::jsonb) AS pre_invoice_funding_events_json,
      COALESCE(f.current_run_pre_invoice_funding_events_json, '[]'::jsonb) AS current_run_pre_invoice_funding_events_json
    FROM invoice_ordered i
    LEFT JOIN LATERAL (
      SELECT
        SUM(
          CASE
            WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
              AND fe.created_at::date < v_period_start
              AND fe.created_at::date < i.invoice_period_start
              THEN COALESCE(fe.amount_gbp, 0)
            WHEN fe.event_type = 'funding_reversed'
              AND fe.created_at::date < v_period_start
              AND fe.created_at::date < i.invoice_period_start
              THEN -ABS(COALESCE(fe.amount_gbp, 0))
            ELSE 0
          END
        ) AS funding_before_run_gbp,
        SUM(
          CASE
            WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
              AND fe.created_at::date <= v_period_end
              AND fe.created_at::date < i.invoice_period_start
              THEN COALESCE(fe.amount_gbp, 0)
            WHEN fe.event_type = 'funding_reversed'
              AND fe.created_at::date <= v_period_end
              AND fe.created_at::date < i.invoice_period_start
              THEN -ABS(COALESCE(fe.amount_gbp, 0))
            ELSE 0
          END
        ) AS funding_through_run_gbp,
        SUM(
          CASE
            WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
              AND fe.created_at::date < i.invoice_period_start
              THEN COALESCE(fe.amount_gbp, 0)
            WHEN fe.event_type = 'funding_reversed'
              AND fe.created_at::date < i.invoice_period_start
              THEN -ABS(COALESCE(fe.amount_gbp, 0))
            ELSE 0
          END
        ) AS funding_before_invoice_period_gbp,
        SUM(
          CASE
            WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
              AND fe.created_at::date BETWEEN v_period_start AND v_period_end
              AND fe.created_at::date < i.invoice_period_start
              THEN COALESCE(fe.amount_gbp, 0)
            WHEN fe.event_type = 'funding_reversed'
              AND fe.created_at::date BETWEEN v_period_start AND v_period_end
              AND fe.created_at::date < i.invoice_period_start
              THEN -ABS(COALESCE(fe.amount_gbp, 0))
            ELSE 0
          END
        ) AS funding_in_current_run_before_invoice_period_gbp,
        SUM(
          CASE
            WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
              AND fe.created_at::date BETWEEN i.invoice_period_start
                                        AND (i.invoice_period_start + INTERVAL '1 month - 1 day')::date
              THEN COALESCE(fe.amount_gbp, 0)
            WHEN fe.event_type = 'funding_reversed'
              AND fe.created_at::date BETWEEN i.invoice_period_start
                                        AND (i.invoice_period_start + INTERVAL '1 month - 1 day')::date
              THEN -ABS(COALESCE(fe.amount_gbp, 0))
            ELSE 0
          END
        ) AS same_invoice_period_funding_gbp,
        jsonb_agg(
          jsonb_build_object(
            'funding_event_id', fe.id,
            'event_type', fe.event_type,
            'amount_gbp', fe.amount_gbp,
            'created_at', fe.created_at,
            'source_ref', fe.source_ref,
            'source_entity_type', fe.source_entity_type,
            'source_entity_id', fe.source_entity_id
          )
          ORDER BY fe.created_at, fe.id
        ) FILTER (
          WHERE fe.id IS NOT NULL
            AND fe.event_type IN ('funding_contribution', 'credit_applied', 'funding_reversed')
            AND fe.created_at::date < i.invoice_period_start
        ) AS pre_invoice_funding_events_json,
        jsonb_agg(
          jsonb_build_object(
            'funding_event_id', fe.id,
            'event_type', fe.event_type,
            'amount_gbp', fe.amount_gbp,
            'created_at', fe.created_at,
            'source_ref', fe.source_ref,
            'source_entity_type', fe.source_entity_type,
            'source_entity_id', fe.source_entity_id
          )
          ORDER BY fe.created_at, fe.id
        ) FILTER (
          WHERE fe.id IS NOT NULL
            AND fe.event_type IN ('funding_contribution', 'credit_applied', 'funding_reversed')
            AND fe.created_at::date BETWEEN v_period_start AND v_period_end
            AND fe.created_at::date < i.invoice_period_start
        ) AS current_run_pre_invoice_funding_events_json
      FROM public.order_funding_events fe
      WHERE fe.order_id = i.order_id
    ) f ON true
  ), timing_calc AS (
    SELECT
      t.*,
      LEAST(GREATEST(t.funding_before_run_gbp - t.prior_invoice_amount_gbp, 0), t.invoice_amount_gbp) AS allocated_before_run_gbp,
      LEAST(GREATEST(t.funding_through_run_gbp - t.prior_invoice_amount_gbp, 0), t.invoice_amount_gbp) AS allocated_through_run_gbp,
      LEAST(GREATEST(t.funding_before_invoice_period_gbp - t.prior_invoice_amount_gbp, 0), t.invoice_amount_gbp) AS anti_duplicate_amount_gbp
    FROM timing_base t
  ), timing_final AS (
    SELECT
      t.*,
      GREATEST(t.allocated_through_run_gbp - t.allocated_before_run_gbp, 0) AS current_run_prepayment_amount_gbp
    FROM timing_calc t
  ), prepayment_updates AS (
    UPDATE public.vat_return_run_lines l
    SET
      line_kind = 'box6_prepayment_increase',
      direction = 'increase',
      amount_gbp = round(t.current_run_prepayment_amount_gbp::numeric, 2),
      vat_amount_gbp = 0,
      vat_basis = 'order_funding_events_partial_prepayment_capped_to_invoice',
      tax_point_date = COALESCE(t.consideration_received_date, v_period_start),
      return_period_label = v_period_label,
      natural_sage_covered = false,
      adjustment_required = true,
      adjustment_reason = 'box6_partial_prepayment_increase_from_order_funding_events',
      source_ref = COALESCE(t.invoice_type, 'sales_invoice') || ':' || t.id::text,
      source_json = jsonb_build_object(
        'vat_timing_rule', 'box6_partial_prepayment_increase_from_order_funding_events',
        'order_id', t.order_id,
        'sales_invoice_id', t.id,
        'invoice_amount_gbp', t.invoice_amount_gbp,
        'prior_invoice_amount_gbp', t.prior_invoice_amount_gbp,
        'invoice_period_start', t.invoice_period_start,
        'funding_before_run_gbp', t.funding_before_run_gbp,
        'funding_through_run_gbp', t.funding_through_run_gbp,
        'funding_in_current_run_before_invoice_period_gbp', t.funding_in_current_run_before_invoice_period_gbp,
        'same_invoice_period_funding_gbp_excluded', t.same_invoice_period_funding_gbp,
        'capped_box6_amount_gbp', round(t.current_run_prepayment_amount_gbp::numeric, 2),
        'current_run_pre_invoice_funding_events', t.current_run_pre_invoice_funding_events_json,
        'all_pre_invoice_funding_events', t.pre_invoice_funding_events_json
      ),
      source_lineage_json = jsonb_build_object(
        'lineage', 'order_funding_events.order_id -> sales_invoices.order_id -> vat_return_run_lines',
        'order_id', t.order_id,
        'sales_invoice_id', t.id,
        'funding_events', t.current_run_pre_invoice_funding_events_json
      )
    FROM timing_final t
    WHERE l.vat_return_run_id = p_vat_return_run_id
      AND l.status = 'active'
      AND l.source_table = 'sales_invoices'
      AND l.source_id = t.id
      AND l.box_number = 6
      AND t.current_run_prepayment_amount_gbp > 0
      AND NOT (
        t.sage_status = 'posted'
        AND t.sage_invoice_date BETWEEN v_period_start AND v_period_end
      )
    RETURNING l.source_id
  ), prepayment_suppressed_base AS (
    UPDATE public.vat_return_run_lines l
    SET
      status = 'superseded',
      adjustment_reason = 'superseded_no_confirmed_pre_invoice_order_funding_for_box6_timing'
    FROM timing_final t
    WHERE l.vat_return_run_id = p_vat_return_run_id
      AND l.status = 'active'
      AND l.source_table = 'sales_invoices'
      AND l.source_id = t.id
      AND l.box_number = 6
      AND l.line_kind = 'sales_invoice_box6_candidate'
      AND t.current_run_prepayment_amount_gbp <= 0
      AND t.consideration_received_date BETWEEN v_period_start AND v_period_end
      AND NOT (
        t.sage_status = 'posted'
        AND t.sage_invoice_date BETWEEN v_period_start AND v_period_end
      )
    RETURNING l.source_id
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id,
    line_kind,
    source_table,
    source_id,
    source_ref,
    source_json,
    source_lineage_json,
    box_number,
    direction,
    amount_gbp,
    vat_amount_gbp,
    vat_basis,
    tax_point_date,
    return_period_label,
    natural_sage_covered,
    adjustment_required,
    adjustment_reason,
    status
  )
  SELECT
    p_vat_return_run_id,
    'box6_prepayment_increase',
    'sales_invoices',
    t.id,
    COALESCE(t.invoice_type, 'sales_invoice') || ':' || t.id::text,
    jsonb_build_object(
      'vat_timing_rule', 'box6_partial_prepayment_increase_from_order_funding_events',
      'order_id', t.order_id,
      'sales_invoice_id', t.id,
      'invoice_amount_gbp', t.invoice_amount_gbp,
      'prior_invoice_amount_gbp', t.prior_invoice_amount_gbp,
      'invoice_period_start', t.invoice_period_start,
      'funding_before_run_gbp', t.funding_before_run_gbp,
      'funding_through_run_gbp', t.funding_through_run_gbp,
      'funding_in_current_run_before_invoice_period_gbp', t.funding_in_current_run_before_invoice_period_gbp,
      'same_invoice_period_funding_gbp_excluded', t.same_invoice_period_funding_gbp,
      'capped_box6_amount_gbp', round(t.current_run_prepayment_amount_gbp::numeric, 2),
      'current_run_pre_invoice_funding_events', t.current_run_pre_invoice_funding_events_json,
      'all_pre_invoice_funding_events', t.pre_invoice_funding_events_json
    ),
    jsonb_build_object(
      'lineage', 'order_funding_events.order_id -> sales_invoices.order_id -> vat_return_run_lines',
      'order_id', t.order_id,
      'sales_invoice_id', t.id,
      'funding_events', t.current_run_pre_invoice_funding_events_json
    ),
    6,
    'increase',
    round(t.current_run_prepayment_amount_gbp::numeric, 2),
    0,
    'order_funding_events_partial_prepayment_capped_to_invoice',
    COALESCE(t.consideration_received_date, v_period_start),
    v_period_label,
    false,
    true,
    'box6_partial_prepayment_increase_from_order_funding_events',
    'active'
  FROM timing_final t
  WHERE t.current_run_prepayment_amount_gbp > 0
    AND NOT (
      t.sage_status = 'posted'
      AND t.sage_invoice_date BETWEEN v_period_start AND v_period_end
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = p_vat_return_run_id
        AND l.status = 'active'
        AND l.source_table = 'sales_invoices'
        AND l.source_id = t.id
        AND l.line_kind = 'box6_prepayment_increase'
    );

  -- -------------------------------------------------------------------------
  -- Current-period posted Sage invoice natural Box 6 plus anti-duplicate
  -- decrease. Uses the same lateral funding calculation pattern.
  -- -------------------------------------------------------------------------

  WITH invoice_scope AS (
    SELECT
      si.*,
      COALESCE(
        CASE
          WHEN si.sage_invoice_period ~ '^[0-9]{4}-[0-9]{2}$'
            THEN to_date(si.sage_invoice_period || '-01', 'YYYY-MM-DD')
          ELSE NULL
        END,
        date_trunc('month', si.sage_invoice_date)::date
      ) AS invoice_period_start,
      ABS(COALESCE(si.amount_gbp, 0)) AS invoice_amount_gbp
    FROM public.sales_invoices si
    WHERE COALESCE(si.sage_status, '') <> 'void'
      AND LOWER(COALESCE(si.invoice_type, '')) NOT IN (
        'credit_note',
        'credit note',
        'sales_credit_note',
        'sales credit note'
      )
      AND COALESCE(si.amount_gbp, 0) > 0
      AND si.order_id IS NOT NULL
      AND si.sage_invoice_date IS NOT NULL
  ), invoice_ordered AS (
    SELECT
      i.*,
      COALESCE(
        SUM(i.invoice_amount_gbp) OVER (
          PARTITION BY i.order_id
          ORDER BY i.invoice_period_start, i.sage_invoice_date, i.created_at, i.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ),
        0
      ) AS prior_invoice_amount_gbp
    FROM invoice_scope i
  ), current_invoice AS (
    SELECT *
    FROM invoice_ordered
    WHERE sage_status = 'posted'
      AND sage_invoice_date BETWEEN v_period_start AND v_period_end
  ), anti_dup_base AS (
    SELECT
      i.*,
      COALESCE(f.funding_before_invoice_period_gbp, 0) AS funding_before_invoice_period_gbp,
      COALESCE(f.same_invoice_period_funding_gbp, 0) AS same_invoice_period_funding_gbp,
      COALESCE(f.pre_invoice_funding_events_json, '[]'::jsonb) AS pre_invoice_funding_events_json
    FROM current_invoice i
    LEFT JOIN LATERAL (
      SELECT
        SUM(
          CASE
            WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
              AND fe.created_at::date < i.invoice_period_start
              THEN COALESCE(fe.amount_gbp, 0)
            WHEN fe.event_type = 'funding_reversed'
              AND fe.created_at::date < i.invoice_period_start
              THEN -ABS(COALESCE(fe.amount_gbp, 0))
            ELSE 0
          END
        ) AS funding_before_invoice_period_gbp,
        SUM(
          CASE
            WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
              AND fe.created_at::date BETWEEN i.invoice_period_start
                                        AND (i.invoice_period_start + INTERVAL '1 month - 1 day')::date
              THEN COALESCE(fe.amount_gbp, 0)
            WHEN fe.event_type = 'funding_reversed'
              AND fe.created_at::date BETWEEN i.invoice_period_start
                                        AND (i.invoice_period_start + INTERVAL '1 month - 1 day')::date
              THEN -ABS(COALESCE(fe.amount_gbp, 0))
            ELSE 0
          END
        ) AS same_invoice_period_funding_gbp,
        jsonb_agg(
          jsonb_build_object(
            'funding_event_id', fe.id,
            'event_type', fe.event_type,
            'amount_gbp', fe.amount_gbp,
            'created_at', fe.created_at,
            'source_ref', fe.source_ref,
            'source_entity_type', fe.source_entity_type,
            'source_entity_id', fe.source_entity_id
          )
          ORDER BY fe.created_at, fe.id
        ) FILTER (
          WHERE fe.id IS NOT NULL
            AND fe.event_type IN ('funding_contribution', 'credit_applied', 'funding_reversed')
            AND fe.created_at::date < i.invoice_period_start
        ) AS pre_invoice_funding_events_json
      FROM public.order_funding_events fe
      WHERE fe.order_id = i.order_id
    ) f ON true
  ), anti_dup_calc AS (
    SELECT
      a.*,
      LEAST(
        GREATEST(a.funding_before_invoice_period_gbp - a.prior_invoice_amount_gbp, 0),
        a.invoice_amount_gbp
      ) AS anti_duplicate_amount_gbp
    FROM anti_dup_base a
  ), inserted_natural AS (
    INSERT INTO public.vat_return_run_lines (
      vat_return_run_id,
      line_kind,
      source_table,
      source_id,
      source_ref,
      source_json,
      source_lineage_json,
      box_number,
      direction,
      amount_gbp,
      vat_amount_gbp,
      vat_basis,
      tax_point_date,
      return_period_label,
      natural_sage_covered,
      adjustment_required,
      adjustment_reason,
      status
    )
    SELECT
      p_vat_return_run_id,
      'sage_sales_invoice_natural_current',
      'sales_invoices',
      a.id,
      COALESCE(a.invoice_type, 'sales_invoice') || ':' || a.id::text,
      jsonb_build_object(
        'vat_timing_rule', 'sage_sales_invoice_natural_current',
        'order_id', a.order_id,
        'sales_invoice_id', a.id,
        'invoice_amount_gbp', a.invoice_amount_gbp,
        'invoice_period_start', a.invoice_period_start,
        'same_invoice_period_funding_gbp_not_accrued', a.same_invoice_period_funding_gbp
      ),
      jsonb_build_object(
        'lineage', 'sales_invoices -> sage sales invoice -> vat_return_run_lines',
        'order_id', a.order_id,
        'sales_invoice_id', a.id
      ),
      6,
      'natural',
      a.invoice_amount_gbp,
      0,
      'sage_sales_invoice_natural_current_period_value',
      a.sage_invoice_date,
      v_period_label,
      true,
      false,
      'Sage sales invoice naturally appears in this VAT period.',
      'active'
    FROM anti_dup_calc a
    WHERE a.anti_duplicate_amount_gbp > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.vat_return_run_lines l
        WHERE l.vat_return_run_id = p_vat_return_run_id
          AND l.status = 'active'
          AND l.source_table = 'sales_invoices'
          AND l.source_id = a.id
          AND l.line_kind = 'sage_sales_invoice_natural_current'
      )
    RETURNING source_id
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id,
    line_kind,
    source_table,
    source_id,
    source_ref,
    source_json,
    source_lineage_json,
    box_number,
    direction,
    amount_gbp,
    vat_amount_gbp,
    vat_basis,
    tax_point_date,
    return_period_label,
    natural_sage_covered,
    adjustment_required,
    adjustment_reason,
    status
  )
  SELECT
    p_vat_return_run_id,
    'box6_anti_duplicate_decrease',
    'sales_invoices',
    a.id,
    COALESCE(a.invoice_type, 'sales_invoice') || ':' || a.id::text,
    jsonb_build_object(
      'vat_timing_rule', 'box6_partial_prepayment_anti_duplicate_decrease',
      'order_id', a.order_id,
      'sales_invoice_id', a.id,
      'invoice_amount_gbp', a.invoice_amount_gbp,
      'prior_invoice_amount_gbp', a.prior_invoice_amount_gbp,
      'invoice_period_start', a.invoice_period_start,
      'funding_before_invoice_period_gbp', a.funding_before_invoice_period_gbp,
      'same_invoice_period_funding_gbp_excluded_from_reversal', a.same_invoice_period_funding_gbp,
      'capped_box6_anti_duplicate_amount_gbp', round(a.anti_duplicate_amount_gbp::numeric, 2),
      'pre_invoice_funding_events', a.pre_invoice_funding_events_json
    ),
    jsonb_build_object(
      'lineage', 'order_funding_events.order_id -> sales_invoices.order_id -> vat_return_run_lines',
      'order_id', a.order_id,
      'sales_invoice_id', a.id,
      'funding_events', a.pre_invoice_funding_events_json
    ),
    6,
    'decrease',
    round(a.anti_duplicate_amount_gbp::numeric, 2),
    0,
    'order_funding_events_partial_prepayment_anti_duplicate_capped_to_invoice',
    a.sage_invoice_date,
    v_period_label,
    false,
    true,
    'box6_partial_prepayment_anti_duplicate_decrease',
    'active'
  FROM anti_dup_calc a
  WHERE a.anti_duplicate_amount_gbp > 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.vat_return_run_lines l
      WHERE l.vat_return_run_id = p_vat_return_run_id
        AND l.status = 'active'
        AND l.source_table = 'sales_invoices'
        AND l.source_id = a.id
        AND l.line_kind = 'box6_anti_duplicate_decrease'
    );

  -- Preserve existing Box 1 export evidence breach/reinstatement behaviour.
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id,
    line_kind,
    source_table,
    source_id,
    source_ref,
    source_json,
    source_lineage_json,
    box_number,
    direction,
    amount_gbp,
    vat_amount_gbp,
    vat_basis,
    tax_point_date,
    return_period_label,
    natural_sage_covered,
    adjustment_required,
    adjustment_reason,
    status
  )
  SELECT
    p_vat_return_run_id,
    'box1_export_evidence_breach',
    'sales_invoices',
    si.id,
    COALESCE(si.invoice_type, 'sales_invoice') || ':' || si.id::text,
    jsonb_build_object(
      'vat_timing_rule', 'box1_export_evidence_breach',
      'invoice_type', si.invoice_type,
      'amount_gbp', si.amount_gbp,
      'vat_amount_gbp', round((abs(si.amount_gbp) / 6.0)::numeric, 2),
      'zero_rating_deadline_date', si.zero_rating_deadline_date,
      'export_evidence_complete_date', si.export_evidence_complete_date,
      'zero_rating_status', si.zero_rating_status,
      'period_start', v_period_start,
      'period_end', v_period_end
    ),
    jsonb_build_object(
      'lineage', 'sales_invoices -> export evidence deadline -> vat_return_run_lines',
      'sales_invoice_id', si.id,
      'order_id', si.order_id
    ),
    1,
    'increase',
    round((abs(si.amount_gbp) / 6.0)::numeric, 2),
    round((abs(si.amount_gbp) / 6.0)::numeric, 2),
    'vat_inclusive_export_evidence_breach_one_sixth',
    si.zero_rating_deadline_date,
    v_period_label,
    false,
    true,
    'Export evidence deadline expires in this VAT period and acceptable evidence is missing or late. Increase Box 1 for the breach period.',
    'active'
  FROM public.sales_invoices si
  WHERE si.zero_rating_deadline_date BETWEEN v_period_start AND v_period_end
    AND COALESCE(si.sage_status, '') <> 'void'
    AND (
      si.export_evidence_complete_date IS NULL
      OR si.export_evidence_complete_date > si.zero_rating_deadline_date
    );

  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id,
    line_kind,
    source_table,
    source_id,
    source_ref,
    source_json,
    source_lineage_json,
    box_number,
    direction,
    amount_gbp,
    vat_amount_gbp,
    vat_basis,
    tax_point_date,
    return_period_label,
    natural_sage_covered,
    adjustment_required,
    adjustment_reason,
    status
  )
  SELECT
    p_vat_return_run_id,
    'box1_export_evidence_reinstatement',
    'sales_invoices',
    si.id,
    COALESCE(si.invoice_type, 'sales_invoice') || ':' || si.id::text,
    jsonb_build_object(
      'vat_timing_rule', 'box1_export_evidence_reinstatement',
      'invoice_type', si.invoice_type,
      'amount_gbp', si.amount_gbp,
      'vat_amount_gbp', round((abs(si.amount_gbp) / 6.0)::numeric, 2),
      'zero_rating_deadline_date', si.zero_rating_deadline_date,
      'export_evidence_complete_date', si.export_evidence_complete_date,
      'zero_rating_status', si.zero_rating_status,
      'period_start', v_period_start,
      'period_end', v_period_end
    ),
    jsonb_build_object(
      'lineage', 'sales_invoices -> late export evidence -> vat_return_run_lines',
      'sales_invoice_id', si.id,
      'order_id', si.order_id
    ),
    1,
    'decrease',
    round((abs(si.amount_gbp) / 6.0)::numeric, 2),
    round((abs(si.amount_gbp) / 6.0)::numeric, 2),
    'vat_inclusive_export_evidence_reinstatement_one_sixth',
    si.export_evidence_complete_date,
    v_period_label,
    false,
    true,
    'Late acceptable export evidence received in this VAT period after a previous Box 1 breach. Decrease/reinstate Box 1 in the evidence period.',
    'active'
  FROM public.sales_invoices si
  WHERE si.export_evidence_complete_date BETWEEN v_period_start AND v_period_end
    AND COALESCE(si.sage_status, '') <> 'void'
    AND (
      lower(COALESCE(si.zero_rating_status, '')) = 'reinstated'
      OR si.export_evidence_complete_date > si.zero_rating_deadline_date
    );

  WITH active_lines AS (
    SELECT
      box_number,
      direction,
      COALESCE(amount_gbp, 0) AS amount_gbp
    FROM public.vat_return_run_lines
    WHERE vat_return_run_id = p_vat_return_run_id
      AND status = 'active'
  ), sums AS (
    SELECT
      COALESCE(SUM(CASE WHEN box_number = 1 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 1 THEN amount_gbp ELSE 0 END), 0) AS box1,
      COALESCE(SUM(CASE WHEN box_number = 2 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 2 THEN amount_gbp ELSE 0 END), 0) AS box2,
      COALESCE(SUM(CASE WHEN box_number = 4 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 4 THEN amount_gbp ELSE 0 END), 0) AS box4,
      COALESCE(SUM(CASE WHEN box_number = 6 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 6 THEN amount_gbp ELSE 0 END), 0) AS box6,
      COALESCE(SUM(CASE WHEN box_number = 7 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 7 THEN amount_gbp ELSE 0 END), 0) AS box7
    FROM active_lines
  )
  UPDATE public.vat_return_runs r
  SET
    expected_box1_gbp = round(s.box1::numeric, 2),
    expected_box2_gbp = round(s.box2::numeric, 2),
    expected_box3_gbp = round((s.box1 + s.box2)::numeric, 2),
    expected_box4_gbp = round(s.box4::numeric, 2),
    expected_box5_gbp = round(((s.box1 + s.box2) - s.box4)::numeric, 2),
    expected_box6_gbp = round(s.box6::numeric, 2),
    expected_box7_gbp = round(s.box7::numeric, 2),
    expected_box8_gbp = COALESCE(r.expected_box8_gbp, 0),
    expected_box9_gbp = COALESCE(r.expected_box9_gbp, 0)
  FROM sums s
  WHERE r.id = p_vat_return_run_id;
END;
$$;

COMMIT;
