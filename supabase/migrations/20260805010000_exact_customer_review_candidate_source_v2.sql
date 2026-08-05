BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive exact customer-review candidate source.
-- This does not replace customer_review_cycle_candidates_v1 or the Mini Build 4 materialiser.
-- It establishes the exact candidate contract before any live caller is changed.

CREATE OR REPLACE FUNCTION public.internal_customer_review_cycle_candidates_v2(
  p_order_id uuid
)
RETURNS TABLE(
  order_id uuid,
  supplier_invoice_id uuid,
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  review_qty numeric,
  goods_amount_gbp numeric,
  delivery_share_gbp numeric,
  discount_share_gbp numeric,
  review_eligible_at timestamptz,
  review_expires_at timestamptz,
  source_receipt_id uuid,
  routing_reason text,
  source_fingerprint text
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
      NULL,
      NULL
    ) r
    WHERE r.position_valid_yn = true
      AND r.review_available_qty > 0
  ),
  allocation_source AS (
    SELECT
      r.order_id,
      sil.supplier_invoice_id,
      r.supplier_invoice_line_id,
      r.tracking_submission_id,
      r.tracking_line_allocation_id,
      r.review_available_qty,
      r.effective_allocated_qty,
      COALESCE(a.base_value_gbp, 0)::numeric AS base_value_gbp,
      COALESCE(a.retailer_delivery_share_gbp, 0)::numeric AS delivery_share_gbp,
      COALESCE(a.discount_share_gbp, 0)::numeric AS discount_share_gbp,
      r.source_receipt_id,
      receipt.recorded_at,
      CASE
        WHEN r.is_same_order_successor THEN 'successor_clean_receipt'
        ELSE 'original_clean_receipt'
      END::text AS routing_reason
    FROM routing r
    JOIN public.order_tracking_line_allocations a
      ON a.id = r.tracking_line_allocation_id
     AND a.order_id = r.order_id
     AND a.tracking_submission_id = r.tracking_submission_id
    JOIN public.supplier_invoice_lines sil
      ON sil.id = r.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = r.order_id
    JOIN public.shipper_package_receipts receipt
      ON receipt.id = r.source_receipt_id
    WHERE COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, ''))
        IN ('y','yes','true','1')
      AND r.source_receipt_model IN ('v2_exact','legacy_v1')
  )
  SELECT
    s.order_id,
    s.supplier_invoice_id,
    s.supplier_invoice_line_id,
    s.tracking_submission_id,
    s.tracking_line_allocation_id,
    ROUND(s.review_available_qty, 3)::numeric AS review_qty,
    ROUND(
      CASE WHEN s.effective_allocated_qty > 0
        THEN s.base_value_gbp * s.review_available_qty / s.effective_allocated_qty
        ELSE 0
      END,
      2
    )::numeric AS goods_amount_gbp,
    ROUND(
      CASE WHEN s.effective_allocated_qty > 0
        THEN s.delivery_share_gbp * s.review_available_qty / s.effective_allocated_qty
        ELSE 0
      END,
      2
    )::numeric AS delivery_share_gbp,
    ROUND(
      CASE WHEN s.effective_allocated_qty > 0
        THEN s.discount_share_gbp * s.review_available_qty / s.effective_allocated_qty
        ELSE 0
      END,
      2
    )::numeric AS discount_share_gbp,
    s.recorded_at AS review_eligible_at,
    s.recorded_at + interval '24 hours' AS review_expires_at,
    s.source_receipt_id,
    s.routing_reason,
    md5(concat_ws(
      '|',
      'exact_customer_review_candidate_v2',
      s.order_id,
      s.supplier_invoice_id,
      s.supplier_invoice_line_id,
      s.tracking_submission_id,
      s.tracking_line_allocation_id,
      ROUND(s.review_available_qty, 3),
      s.source_receipt_id,
      s.routing_reason,
      s.recorded_at,
      s.recorded_at + interval '24 hours'
    ))::text AS source_fingerprint
  FROM allocation_source s;
$function$;

ALTER FUNCTION public.internal_customer_review_cycle_candidates_v2(uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.internal_customer_review_cycle_candidates_v2(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.internal_customer_review_cycle_candidates_v2(uuid)
  TO service_role;

DO $postflight$
DECLARE
  v_candidate_md5 text;
  v_materialiser_md5 text;
  v_component_md5 text;
  v_immutable_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef(
    'public.customer_review_cycle_candidates_v1(uuid)'::regprocedure
  )) INTO v_candidate_md5;

  SELECT md5(pg_get_functiondef(
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure
  )) INTO v_materialiser_md5;

  SELECT md5(pg_get_functiondef(
    'public.customer_review_cycle_component_guard_v1()'::regprocedure
  )) INTO v_component_md5;

  SELECT md5(pg_get_functiondef(
    'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure
  )) INTO v_immutable_md5;

  IF v_candidate_md5 IS DISTINCT FROM '80c5ca83374ed2ddaedeadd3b88dd95d'
     OR v_materialiser_md5 IS DISTINCT FROM '0293a94d4eb17daf9c7e48131cd75ca1'
     OR v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
  THEN
    RAISE EXCEPTION
      'Protected Mini Build definition changed: candidate %, materialiser %, component %, immutable %',
      v_candidate_md5,
      v_materialiser_md5,
      v_component_md5,
      v_immutable_md5;
  END IF;
END
$postflight$;

COMMIT;
