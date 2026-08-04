BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow additive bridge into the existing Mini Build 4 review tables.
-- It does not replace the Mini Build 4 candidate, materialiser, guards or triggers.
-- It only enrols exact v2 candidates that the unchanged whole-package candidate cannot see.

CREATE OR REPLACE FUNCTION public.internal_bridge_exact_customer_review_candidates_v1(
  p_order_id uuid,
  p_created_by_staff_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_link_id uuid;
  v_deadline timestamptz;
  v_candidate_deadline timestamptz;
  v_inserted integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtext('exact_customer_review_bridge|' || p_order_id::text)
  );

  PERFORM 1
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_order_review_links link_row
    WHERE link_row.order_id = p_order_id
      AND link_row.is_active = true
      AND link_row.expires_at IS NULL
  ) THEN
    RETURN 0;
  END IF;

  SELECT MAX(candidate.review_expires_at)
  INTO v_candidate_deadline
  FROM public.internal_customer_review_cycle_candidates_v2(p_order_id) candidate;

  IF v_candidate_deadline IS NULL THEN
    RETURN 0;
  END IF;

  SELECT link_row.id, link_row.expires_at
  INTO v_link_id, v_deadline
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
  ORDER BY link_row.created_at, link_row.id
  LIMIT 1
  FOR UPDATE;

  IF v_link_id IS NULL THEN
    INSERT INTO public.customer_order_review_links (
      order_id,
      is_active,
      expires_at,
      created_by_staff_id
    ) VALUES (
      p_order_id,
      true,
      v_candidate_deadline,
      p_created_by_staff_id
    )
    RETURNING id, expires_at
    INTO v_link_id, v_deadline;
  ELSIF v_deadline < v_candidate_deadline THEN
    UPDATE public.customer_order_review_links
    SET expires_at = v_candidate_deadline
    WHERE id = v_link_id
    RETURNING expires_at INTO v_deadline;
  END IF;

  INSERT INTO public.customer_review_cycle_memberships (
    review_link_id,
    order_id,
    supplier_invoice_id,
    supplier_invoice_line_id,
    tracking_submission_id,
    tracking_line_allocation_id,
    review_qty,
    goods_amount_gbp,
    delivery_share_gbp,
    discount_share_gbp,
    receipt_recorded_at,
    membership_status,
    membership_fingerprint,
    legacy_backfill_yn,
    created_by_staff_id
  )
  SELECT
    v_link_id,
    candidate.order_id,
    candidate.supplier_invoice_id,
    candidate.supplier_invoice_line_id,
    candidate.tracking_submission_id,
    candidate.tracking_line_allocation_id,
    candidate.review_qty,
    candidate.goods_amount_gbp,
    candidate.delivery_share_gbp,
    candidate.discount_share_gbp,
    candidate.review_eligible_at,
    CASE
      WHEN candidate.review_expires_at <= now() THEN 'expired'
      ELSE 'active'
    END,
    md5(v_link_id::text || '|' || candidate.source_fingerprint),
    false,
    p_created_by_staff_id
  FROM public.internal_customer_review_cycle_candidates_v2(p_order_id) candidate
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0
     AND NOT EXISTS (
       SELECT 1
       FROM public.customer_review_cycle_memberships m
       WHERE m.review_link_id = v_link_id
     )
  THEN
    DELETE FROM public.customer_order_review_links
    WHERE id = v_link_id;
  END IF;

  RETURN v_inserted;
END;
$function$;

ALTER FUNCTION public.internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)
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
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_candidates_v1(uuid)'::regprocedure)) INTO v_candidate_md5;
  SELECT md5(pg_get_functiondef('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure)) INTO v_materialiser_md5;
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure)) INTO v_component_md5;
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure)) INTO v_immutable_md5;
  SELECT md5(pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure)) INTO v_shipper_candidates_md5;
  SELECT md5(pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure)) INTO v_shipper_create_md5;

  IF v_candidate_md5 IS DISTINCT FROM '80c5ca83374ed2ddaedeadd3b88dd95d'
     OR v_materialiser_md5 IS DISTINCT FROM '0293a94d4eb17daf9c7e48131cd75ca1'
     OR v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
     OR v_shipper_candidates_md5 IS DISTINCT FROM '952f24084fed0dffcdebbfae988e7400'
     OR v_shipper_create_md5 IS DISTINCT FROM '4e4b86b0121a85523fe95c1530a41658'
  THEN
    RAISE EXCEPTION 'Protected authority changed during exact enrolment bridge install.';
  END IF;
END
$postflight$;

COMMIT;
