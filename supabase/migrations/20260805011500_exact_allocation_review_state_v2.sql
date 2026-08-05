BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive exact allocation-level review state.
-- No Mini Build 1–4 function, trigger, table or grant is replaced.

CREATE OR REPLACE FUNCTION public.internal_tracking_allocation_review_state_v2(
  p_order_id uuid DEFAULT NULL,
  p_tracking_submission_id uuid DEFAULT NULL,
  p_tracking_line_allocation_id uuid DEFAULT NULL
)
RETURNS TABLE(
  order_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  review_enrolled_qty numeric,
  active_review_qty numeric,
  completed_review_qty numeric,
  review_available_qty numeric,
  next_review_expires_at timestamptz,
  review_state text,
  position_valid_yn boolean,
  position_blocker text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH routing AS (
    SELECT r.*
    FROM public.internal_tracking_allocation_fulfilment_routing_position_v2(
      p_order_id,
      p_tracking_submission_id,
      p_tracking_line_allocation_id
    ) r
  ),
  deadline AS (
    SELECT
      m.tracking_line_allocation_id,
      MIN(link_row.expires_at) FILTER (
        WHERE m.membership_status = 'active'
          AND link_row.is_active = true
          AND link_row.expires_at IS NOT NULL
          AND link_row.expires_at > now()
      ) AS next_review_expires_at
    FROM public.customer_review_cycle_memberships m
    JOIN public.customer_order_review_links link_row
      ON link_row.id = m.review_link_id
    WHERE p_order_id IS NULL OR m.order_id = p_order_id
    GROUP BY m.tracking_line_allocation_id
  )
  SELECT
    r.order_id,
    r.tracking_submission_id,
    r.tracking_line_allocation_id,
    r.review_enrolled_qty,
    r.active_review_qty,
    r.completed_review_qty,
    r.review_available_qty,
    d.next_review_expires_at,
    CASE
      WHEN NOT r.position_valid_yn THEN 'blocked'
      WHEN r.review_available_qty > 0 THEN 'not_enrolled'
      WHEN r.active_review_qty > 0 THEN 'active'
      WHEN r.completed_review_qty > 0 THEN 'completed'
      WHEN r.effective_clean_qty = 0 THEN 'not_applicable'
      ELSE 'unproven'
    END::text AS review_state,
    r.position_valid_yn,
    r.position_blocker
  FROM routing r
  LEFT JOIN deadline d
    ON d.tracking_line_allocation_id = r.tracking_line_allocation_id;
$function$;

ALTER FUNCTION public.internal_tracking_allocation_review_state_v2(uuid,uuid,uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.internal_tracking_allocation_review_state_v2(uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.internal_tracking_allocation_review_state_v2(uuid,uuid,uuid)
  TO service_role;

DO $postflight$
DECLARE
  v_candidate_md5 text;
  v_materialiser_md5 text;
  v_component_md5 text;
  v_immutable_md5 text;
  v_shipper_candidates_md5 text;
  v_shipper_create_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_candidates_v1(uuid)'::regprocedure))
    INTO v_candidate_md5;
  SELECT md5(pg_get_functiondef('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure))
    INTO v_materialiser_md5;
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure))
    INTO v_component_md5;
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure))
    INTO v_immutable_md5;
  SELECT md5(pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure))
    INTO v_shipper_candidates_md5;
  SELECT md5(pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure))
    INTO v_shipper_create_md5;

  IF v_candidate_md5 IS DISTINCT FROM '80c5ca83374ed2ddaedeadd3b88dd95d'
     OR v_materialiser_md5 IS DISTINCT FROM '0293a94d4eb17daf9c7e48131cd75ca1'
     OR v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
     OR v_shipper_candidates_md5 IS DISTINCT FROM '952f24084fed0dffcdebbfae988e7400'
     OR v_shipper_create_md5 IS DISTINCT FROM '4e4b86b0121a85523fe95c1530a41658'
  THEN
    RAISE EXCEPTION 'Protected authority changed during additive review-state install.';
  END IF;
END
$postflight$;

COMMIT;
