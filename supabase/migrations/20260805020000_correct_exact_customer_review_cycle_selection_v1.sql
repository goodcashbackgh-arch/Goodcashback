BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Corrects only the newly added exact review bridge.
-- Existing Mini Build 1–4 authorities remain unchanged.
-- Rule:
--   * a clean item joins an existing fixed 24-hour cycle only when its own
--     receipt timestamp falls inside that cycle;
--   * an item received after that cycle closes starts a new fixed 24-hour cycle;
--   * an earlier cycle is never extended or reopened.

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
  v_candidate record;
  v_link_id uuid;
  v_link_expires_at timestamptz;
  v_created_link boolean;
  v_inserted integer;
  v_total_inserted integer := 0;
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

  -- Close any timed cycle whose fixed deadline has passed. This does not alter
  -- its deadline and does not affect completed membership history.
  UPDATE public.customer_order_review_links link_row
  SET is_active = false
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at <= now();

  UPDATE public.customer_review_cycle_memberships membership
  SET membership_status = 'expired',
      status_updated_at = COALESCE(membership.status_updated_at, now())
  FROM public.customer_order_review_links link_row
  WHERE link_row.id = membership.review_link_id
    AND link_row.order_id = p_order_id
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at <= now()
    AND membership.membership_status = 'active';

  FOR v_candidate IN
    SELECT candidate.*
    FROM public.internal_customer_review_cycle_candidates_v2(p_order_id) candidate
    ORDER BY
      candidate.review_eligible_at,
      candidate.tracking_submission_id,
      candidate.tracking_line_allocation_id
  LOOP
    v_link_id := NULL;
    v_link_expires_at := NULL;
    v_created_link := false;
    v_inserted := 0;

    -- Reuse only a cycle whose original fixed 24-hour interval contains this
    -- candidate's receipt. The deadline is never changed.
    SELECT link_row.id, link_row.expires_at
    INTO v_link_id, v_link_expires_at
    FROM public.customer_order_review_links link_row
    WHERE link_row.order_id = p_order_id
      AND link_row.expires_at IS NOT NULL
      AND v_candidate.review_eligible_at >= link_row.expires_at - interval '24 hours'
      AND v_candidate.review_eligible_at < link_row.expires_at
    ORDER BY link_row.expires_at, link_row.created_at, link_row.id
    LIMIT 1
    FOR UPDATE;

    IF v_link_id IS NULL THEN
      -- Any currently active timed cycle cannot contain this later receipt, so
      -- close it before opening the next independent cycle.
      UPDATE public.customer_order_review_links link_row
      SET is_active = false
      WHERE link_row.order_id = p_order_id
        AND link_row.is_active = true
        AND link_row.expires_at IS NOT NULL;

      UPDATE public.customer_review_cycle_memberships membership
      SET membership_status = 'expired',
          status_updated_at = COALESCE(membership.status_updated_at, now())
      FROM public.customer_order_review_links link_row
      WHERE link_row.id = membership.review_link_id
        AND link_row.order_id = p_order_id
        AND link_row.is_active = false
        AND membership.membership_status = 'active';

      INSERT INTO public.customer_order_review_links (
        order_id,
        is_active,
        expires_at,
        created_by_staff_id
      ) VALUES (
        p_order_id,
        true,
        v_candidate.review_expires_at,
        p_created_by_staff_id
      )
      RETURNING id, expires_at
      INTO v_link_id, v_link_expires_at;

      v_created_link := true;
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
    ) VALUES (
      v_link_id,
      v_candidate.order_id,
      v_candidate.supplier_invoice_id,
      v_candidate.supplier_invoice_line_id,
      v_candidate.tracking_submission_id,
      v_candidate.tracking_line_allocation_id,
      v_candidate.review_qty,
      v_candidate.goods_amount_gbp,
      v_candidate.delivery_share_gbp,
      v_candidate.discount_share_gbp,
      v_candidate.review_eligible_at,
      CASE
        WHEN v_link_expires_at <= now() THEN 'expired'
        ELSE 'active'
      END,
      md5(v_link_id::text || '|' || v_candidate.source_fingerprint),
      false,
      p_created_by_staff_id
    )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    v_total_inserted := v_total_inserted + v_inserted;

    IF v_created_link
       AND v_inserted = 0
       AND NOT EXISTS (
         SELECT 1
         FROM public.customer_review_cycle_memberships membership
         WHERE membership.review_link_id = v_link_id
       )
    THEN
      DELETE FROM public.customer_order_review_links
      WHERE id = v_link_id;
    END IF;
  END LOOP;

  RETURN v_total_inserted;
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
    RAISE EXCEPTION 'Protected authority changed during exact review cycle-selection correction.';
  END IF;
END
$postflight$;

COMMIT;
