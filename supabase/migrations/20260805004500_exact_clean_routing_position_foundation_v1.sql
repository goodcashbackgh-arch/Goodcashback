BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive Phase 1 foundation only.
-- Does not replace or alter any Mini Build 1–4 function, trigger, table or grant.
-- Does not alter shipment candidates or shipment creation yet.

CREATE OR REPLACE FUNCTION public.internal_tracking_allocation_fulfilment_routing_position_v2(
  p_order_id uuid DEFAULT NULL,
  p_tracking_submission_id uuid DEFAULT NULL,
  p_tracking_line_allocation_id uuid DEFAULT NULL
)
RETURNS TABLE(
  order_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  supplier_invoice_line_id uuid,
  allocated_qty numeric,
  effective_allocated_qty numeric,
  source_physical_clean_qty numeric,
  source_physical_exception_qty numeric,
  supervisor_released_to_clean_qty numeric,
  effective_clean_qty numeric,
  effective_exception_qty numeric,
  review_enrolled_qty numeric,
  active_review_qty numeric,
  completed_review_qty numeric,
  active_hold_qty numeric,
  shipped_qty numeric,
  customer_released_qty numeric,
  remedy_assigned_qty numeric,
  review_available_qty numeric,
  awaiting_customer_review_qty numeric,
  shipment_ready_qty numeric,
  diverted_qty numeric,
  position_valid_yn boolean,
  position_blocker text,
  source_receipt_id uuid,
  source_receipt_model text,
  is_same_order_successor boolean,
  source_allocation_id uuid,
  replacement_route_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH base AS (
    SELECT p.*
    FROM public.internal_tracking_allocation_fulfilment_position_v1(
      p_order_id,
      p_tracking_submission_id,
      p_tracking_line_allocation_id
    ) p
  ),
  entitlement AS (
    SELECT e.*
    FROM public.tracking_allocation_effective_entitlement_v1(p_order_id, NULL) e
    WHERE p_tracking_submission_id IS NULL
       OR e.tracking_submission_id = p_tracking_submission_id
  ),
  review_state AS (
    SELECT
      m.tracking_line_allocation_id,
      COALESCE(SUM(m.review_qty), 0)::numeric AS review_enrolled_qty,
      COALESCE(SUM(m.review_qty) FILTER (
        WHERE m.membership_status = 'active'
          AND link_row.is_active = true
          AND link_row.expires_at IS NOT NULL
          AND link_row.expires_at > now()
      ), 0)::numeric AS active_review_qty,
      COALESCE(SUM(m.review_qty) FILTER (
        WHERE m.membership_status <> 'active'
           OR link_row.is_active = false
           OR (link_row.expires_at IS NOT NULL AND link_row.expires_at <= now())
      ), 0)::numeric AS completed_review_qty
    FROM public.customer_review_cycle_memberships m
    JOIN public.customer_order_review_links link_row
      ON link_row.id = m.review_link_id
    WHERE p_order_id IS NULL OR m.order_id = p_order_id
    GROUP BY m.tracking_line_allocation_id
  ),
  joined AS (
    SELECT
      b.*,
      COALESCE(e.effective_qty_allocated, b.allocated_qty)::numeric AS effective_allocated_qty,
      COALESCE(e.is_same_order_successor, false) AS is_same_order_successor,
      e.source_allocation_id,
      e.replacement_route_id,
      COALESCE(rs.review_enrolled_qty, 0)::numeric AS exact_review_enrolled_qty,
      COALESCE(rs.active_review_qty, 0)::numeric AS exact_active_review_qty,
      COALESCE(rs.completed_review_qty, 0)::numeric AS exact_completed_review_qty
    FROM base b
    LEFT JOIN entitlement e
      ON e.allocation_id = b.tracking_line_allocation_id
    LEFT JOIN review_state rs
      ON rs.tracking_line_allocation_id = b.tracking_line_allocation_id
  ),
  derived AS (
    SELECT
      j.*,
      LEAST(j.physical_clean_qty, j.effective_allocated_qty)::numeric
        AS effective_clean_qty_derived,
      GREATEST(
        LEAST(j.physical_exception_qty, j.effective_allocated_qty),
        0
      )::numeric AS effective_exception_qty_derived
    FROM joined j
  )
  SELECT
    d.order_id,
    d.tracking_submission_id,
    d.tracking_line_allocation_id,
    d.supplier_invoice_line_id,
    d.allocated_qty,
    d.effective_allocated_qty,
    d.physical_clean_qty AS source_physical_clean_qty,
    d.physical_exception_qty AS source_physical_exception_qty,
    0::numeric AS supervisor_released_to_clean_qty,
    d.effective_clean_qty_derived AS effective_clean_qty,
    d.effective_exception_qty_derived AS effective_exception_qty,
    d.exact_review_enrolled_qty AS review_enrolled_qty,
    d.exact_active_review_qty AS active_review_qty,
    LEAST(d.exact_completed_review_qty, d.effective_clean_qty_derived)::numeric
      AS completed_review_qty,
    d.active_hold_qty,
    d.shipped_qty,
    d.customer_released_qty,
    d.remedy_assigned_qty,
    CASE
      WHEN d.position_valid_yn THEN GREATEST(
        d.effective_clean_qty_derived
          - GREATEST(
              d.exact_review_enrolled_qty,
              d.shipped_qty,
              d.customer_released_qty
            ),
        0
      )
      ELSE 0
    END::numeric AS review_available_qty,
    CASE
      WHEN d.position_valid_yn THEN GREATEST(
        d.effective_clean_qty_derived
          - LEAST(d.exact_completed_review_qty, d.effective_clean_qty_derived),
        0
      )
      ELSE 0
    END::numeric AS awaiting_customer_review_qty,
    CASE
      WHEN d.position_valid_yn THEN GREATEST(
        LEAST(d.exact_completed_review_qty, d.effective_clean_qty_derived)
          - d.active_hold_qty
          - d.shipped_qty,
        0
      )
      ELSE 0
    END::numeric AS shipment_ready_qty,
    CASE
      WHEN d.position_valid_yn THEN GREATEST(
        d.effective_exception_qty_derived + d.active_hold_qty,
        0
      )
      ELSE d.effective_allocated_qty
    END::numeric AS diverted_qty,
    (
      d.position_valid_yn
      AND d.effective_allocated_qty >= 0
      AND d.effective_clean_qty_derived >= 0
      AND d.effective_exception_qty_derived >= 0
      AND d.effective_clean_qty_derived + d.effective_exception_qty_derived
          <= d.effective_allocated_qty + 0.0005
      AND d.exact_review_enrolled_qty
          <= d.effective_clean_qty_derived + 0.0005
      AND d.exact_active_review_qty
          <= d.exact_review_enrolled_qty + 0.0005
      AND d.exact_completed_review_qty
          <= d.exact_review_enrolled_qty + 0.0005
    ) AS position_valid_yn,
    CASE
      WHEN NOT d.position_valid_yn THEN d.position_blocker
      WHEN d.effective_allocated_qty < 0
        THEN 'negative_effective_entitlement'
      WHEN d.effective_clean_qty_derived + d.effective_exception_qty_derived
           > d.effective_allocated_qty + 0.0005
        THEN 'effective_physical_quantity_exceeds_entitlement'
      WHEN d.exact_review_enrolled_qty
           > d.effective_clean_qty_derived + 0.0005
        THEN 'review_enrolled_quantity_exceeds_effective_clean'
      WHEN d.exact_active_review_qty
           > d.exact_review_enrolled_qty + 0.0005
        THEN 'active_review_quantity_exceeds_enrolled'
      WHEN d.exact_completed_review_qty
           > d.exact_review_enrolled_qty + 0.0005
        THEN 'completed_review_quantity_exceeds_enrolled'
      ELSE NULL
    END::text AS position_blocker,
    d.source_receipt_id,
    d.source_receipt_model,
    d.is_same_order_successor,
    d.source_allocation_id,
    d.replacement_route_id
  FROM derived d;
$function$;

ALTER FUNCTION public.internal_tracking_allocation_fulfilment_routing_position_v2(uuid,uuid,uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.internal_tracking_allocation_fulfilment_routing_position_v2(uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.internal_tracking_allocation_fulfilment_routing_position_v2(uuid,uuid,uuid)
  TO service_role;

DO $postflight$
DECLARE
  v_component text;
  v_immutable text;
BEGIN
  SELECT md5(pg_get_functiondef(
    'public.customer_review_cycle_component_guard_v1()'::regprocedure
  )) INTO v_component;

  SELECT md5(pg_get_functiondef(
    'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure
  )) INTO v_immutable;

  IF v_component IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
  THEN
    RAISE EXCEPTION
      'Protected Mini Build guard changed: component %, immutable %',
      v_component,
      v_immutable;
  END IF;
END
$postflight$;

COMMIT;
