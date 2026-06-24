BEGIN;

-- Fix runtime failure when materialising applied completion-loyalty settlement groups:
--   column reference "target_sage_invoice_id" is ambiguous
-- Cause: PL/pgSQL output column names are visible inside the function body, so unqualified
-- CTE column names with the same identifier can become ambiguous. This replacement keeps
-- the public return contract unchanged and uses distinct internal column aliases.

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_open_customer_sales_targets_v1(
  p_order_id uuid,
  p_sage_contact_id text,
  p_amount_gbp numeric
)
RETURNS TABLE (
  target_sage_invoice_snapshot_id uuid,
  target_sage_invoice_id text,
  target_order_id uuid,
  target_order_ref text,
  target_open_amount_gbp numeric,
  allocation_amount_gbp numeric,
  sort_key text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_amount numeric(18,2) := round(COALESCE(p_amount_gbp, 0)::numeric, 2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: open customer sales targets require auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for open customer sales targets.';
  END IF;

  RETURN QUERY
  WITH targets AS (
    SELECT
      sps.id AS open_target_sage_invoice_snapshot_id,
      sps.sage_invoice_id::text AS open_target_sage_invoice_id,
      sps.order_id AS open_target_order_id,
      sps.order_ref::text AS open_target_order_ref,
      round(COALESCE(sps.amount_gbp, 0)::numeric, 2) AS invoice_amount_gbp,
      COALESCE(
        NULLIF(sps.resolved_payload->'sage_header'->>'invoice_date', ''),
        NULLIF(sps.resolved_payload->'sage_header'->>'date', ''),
        NULLIF(sps.resolved_payload->'sage_invoice'->>'date', ''),
        NULLIF(sps.resolved_payload->'invoice'->>'date', ''),
        sps.created_at::date::text,
        sps.id::text
      ) AS open_target_sort_key
    FROM public.sage_posting_snapshots sps
    WHERE sps.active = true
      AND sps.document_lane = 'customer_sales'
      AND sps.sage_posting_status = 'posted'
      AND sps.order_id = p_order_id
      AND NULLIF(trim(COALESCE(sps.sage_invoice_id, '')), '') IS NOT NULL
      AND COALESCE(
        sps.resolved_payload->'sage_header'->>'contact_id',
        sps.resolved_payload->'customer_target'->>'sage_contact_id'
      ) = p_sage_contact_id
  ), previous_request_allocations AS (
    SELECT
      artefact.value->>'artefact_id' AS allocated_sage_invoice_id,
      SUM(
        GREATEST(
          CASE
            WHEN COALESCE(artefact.value->>'amount', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
              THEN (artefact.value->>'amount')::numeric
            ELSE 0
          END,
          0
        )
      )::numeric AS allocated_gbp
    FROM public.cash_posting_snapshots cps
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(cps.sage_allocation_request_payload->'contact_allocation'->'allocated_artefacts', '[]'::jsonb)
    ) AS artefact(value)
    WHERE cps.active = true
      AND cps.sage_allocation_status = 'allocated'
      AND cps.order_id = p_order_id
      AND artefact.value ? 'artefact_id'
    GROUP BY artefact.value->>'artefact_id'
  ), previous_legacy_allocations AS (
    SELECT
      cps.sage_allocation_target_object_id AS allocated_sage_invoice_id,
      SUM(COALESCE(cps.sage_allocation_amount_gbp, 0))::numeric AS allocated_gbp
    FROM public.cash_posting_snapshots cps
    WHERE cps.active = true
      AND cps.sage_allocation_status = 'allocated'
      AND cps.order_id = p_order_id
      AND NULLIF(trim(COALESCE(cps.sage_allocation_target_object_id, '')), '') IS NOT NULL
      AND jsonb_array_length(
        COALESCE(cps.sage_allocation_request_payload->'contact_allocation'->'allocated_artefacts', '[]'::jsonb)
      ) = 0
    GROUP BY cps.sage_allocation_target_object_id
  ), allocated AS (
    SELECT
      x.allocated_sage_invoice_id,
      SUM(x.allocated_gbp)::numeric AS allocated_gbp
    FROM (
      SELECT pra.allocated_sage_invoice_id, pra.allocated_gbp FROM previous_request_allocations pra
      UNION ALL
      SELECT pla.allocated_sage_invoice_id, pla.allocated_gbp FROM previous_legacy_allocations pla
    ) x
    GROUP BY x.allocated_sage_invoice_id
  ), open_targets AS (
    SELECT
      t.open_target_sage_invoice_snapshot_id,
      t.open_target_sage_invoice_id,
      t.open_target_order_id,
      t.open_target_order_ref,
      t.invoice_amount_gbp,
      t.open_target_sort_key,
      round(GREATEST(t.invoice_amount_gbp - COALESCE(a.allocated_gbp, 0), 0)::numeric, 2) AS open_amount_gbp
    FROM targets t
    LEFT JOIN allocated a ON a.allocated_sage_invoice_id = t.open_target_sage_invoice_id
  ), ordered AS (
    SELECT
      ot.*,
      COALESCE(
        SUM(ot.open_amount_gbp) OVER (
          ORDER BY ot.open_target_sort_key, ot.open_target_sage_invoice_snapshot_id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ),
        0
      )::numeric AS prior_open_gbp
    FROM open_targets ot
    WHERE ot.open_amount_gbp > 0
  ), allocated_targets AS (
    SELECT
      o.*,
      round(LEAST(o.open_amount_gbp, GREATEST(v_amount - o.prior_open_gbp, 0))::numeric, 2) AS calculated_allocation_amount_gbp
    FROM ordered o
  )
  SELECT
    at.open_target_sage_invoice_snapshot_id AS target_sage_invoice_snapshot_id,
    at.open_target_sage_invoice_id AS target_sage_invoice_id,
    at.open_target_order_id AS target_order_id,
    at.open_target_order_ref AS target_order_ref,
    at.open_amount_gbp AS target_open_amount_gbp,
    at.calculated_allocation_amount_gbp AS allocation_amount_gbp,
    at.open_target_sort_key AS sort_key
  FROM allocated_targets at
  WHERE at.calculated_allocation_amount_gbp > 0
  ORDER BY at.open_target_sort_key, at.open_target_sage_invoice_snapshot_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_open_customer_sales_targets_v1(uuid, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_open_customer_sales_targets_v1(uuid, text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
