BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_materialize_customer_review_cycles_v1(
  p_order_id uuid,
  p_created_by_staff_id uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_active_total_count integer;
  v_active_timed_count integer;
  v_active_untimed_count integer;
  v_link_id uuid;
  v_deadline timestamptz;
  v_anchor_receipt timestamptz;
  v_inserted integer := 0;
  v_total_inserted integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtext('customer_review_cycle|' || p_order_id::text)
  );

  PERFORM 1
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

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

  SELECT COUNT(*)::integer
  INTO v_active_total_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true;

  IF v_active_total_count > 1 THEN
    INSERT INTO public.customer_review_cycle_legacy_issues (
      order_id,
      issue_code,
      issue_detail
    ) VALUES (
      p_order_id,
      'multiple_active_review_links',
      'More than one active review link exists. No membership is guessed and review-cycle materialisation fails closed.'
    )
    ON CONFLICT (order_id, issue_code) DO NOTHING;

    RETURN 0;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_active_untimed_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NULL;

  IF v_active_untimed_count > 1 THEN
    INSERT INTO public.customer_review_cycle_legacy_issues (
      order_id,
      issue_code,
      issue_detail
    ) VALUES (
      p_order_id,
      'multiple_active_untimed_review_links',
      'More than one active untimed legacy review link exists. Compatibility is preserved and new timed-cycle creation fails closed.'
    )
    ON CONFLICT (order_id, issue_code) DO NOTHING;

    RETURN 0;
  END IF;

  IF v_active_untimed_count = 1 THEN
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_review_cycle_legacy_issues issue
    WHERE issue.order_id = p_order_id
      AND issue.resolved_at IS NULL
  ) THEN
    RETURN 0;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_active_timed_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now();

  IF v_active_timed_count > 1 THEN
    INSERT INTO public.customer_review_cycle_legacy_issues (
      order_id,
      issue_code,
      issue_detail
    ) VALUES (
      p_order_id,
      'multiple_active_timed_review_links',
      'More than one active timed review link exists. No membership is guessed and cycle materialisation fails closed.'
    )
    ON CONFLICT (order_id, issue_code) DO NOTHING;

    RETURN 0;
  END IF;

  SELECT
    link_row.id,
    link_row.expires_at
  INTO
    v_link_id,
    v_deadline
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now()
  ORDER BY link_row.created_at, link_row.id
  LIMIT 1
  FOR UPDATE;

  IF v_link_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = v_link_id
    ) THEN
      INSERT INTO public.customer_review_cycle_legacy_issues (
        order_id,
        review_link_id,
        issue_code,
        issue_detail
      ) VALUES (
        p_order_id,
        v_link_id,
        'pre_mini4_timed_membership_unproven',
        'The existing timed link and stored deadline were preserved, but exact historical membership cannot be proven without guessing.'
      )
      ON CONFLICT (order_id, issue_code) DO NOTHING;

      RETURN 0;
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
      candidate.receipt_recorded_at,
      'active',
      md5(v_link_id::text || '|' || candidate.source_fingerprint),
      false,
      p_created_by_staff_id
    FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
    WHERE candidate.receipt_recorded_at < v_deadline
      AND candidate.receipt_recorded_at + interval '24 hours' > now()
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted;
  END IF;

  SELECT MIN(candidate.receipt_recorded_at)
  INTO v_anchor_receipt
  FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
  WHERE candidate.receipt_recorded_at <= now()
    AND candidate.receipt_recorded_at + interval '24 hours' > now();

  IF v_anchor_receipt IS NULL THEN
    RETURN 0;
  END IF;

  v_deadline := v_anchor_receipt + interval '24 hours';

  INSERT INTO public.customer_order_review_links (
    order_id,
    is_active,
    expires_at,
    created_by_staff_id
  ) VALUES (
    p_order_id,
    true,
    NULL,
    p_created_by_staff_id
  )
  RETURNING id INTO v_link_id;

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
    candidate.receipt_recorded_at,
    'active',
    md5(v_link_id::text || '|' || candidate.source_fingerprint),
    false,
    p_created_by_staff_id
  FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
  WHERE candidate.receipt_recorded_at < v_deadline
    AND candidate.receipt_recorded_at + interval '24 hours' > now()
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_total_inserted = ROW_COUNT;

  IF v_total_inserted = 0 THEN
    DELETE FROM public.customer_order_review_links
    WHERE id = v_link_id;

    RETURN 0;
  END IF;

  UPDATE public.customer_order_review_links
  SET expires_at = v_deadline
  WHERE id = v_link_id;

  RETURN v_total_inserted;
END;
$function$;

REVOKE ALL ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
TO service_role;

CREATE OR REPLACE FUNCTION public.customer_review_candidate_change_materialize_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'order_tracking_line_allocations' THEN
    v_order_id := NEW.order_id;

  ELSIF TG_TABLE_NAME = 'supplier_invoice_lines' THEN
    FOR v_order_id IN
      SELECT DISTINCT allocation.order_id
      FROM public.order_tracking_line_allocations allocation
      WHERE allocation.supplier_invoice_line_id = NEW.id
    LOOP
      PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
    END LOOP;

    RETURN NEW;

  ELSIF TG_TABLE_NAME = 'supplier_invoices' THEN
    v_order_id := NEW.order_id;
  END IF;

  IF v_order_id IS NOT NULL THEN
    PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.customer_review_candidate_change_materialize_v1()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.customer_review_candidate_change_materialize_v1()
TO service_role;

DROP TRIGGER IF EXISTS trg_customer_review_allocation_materialize_v1
  ON public.order_tracking_line_allocations;

CREATE TRIGGER trg_customer_review_allocation_materialize_v1
AFTER INSERT OR UPDATE OF
  order_id,
  tracking_submission_id,
  supplier_invoice_line_id,
  qty_allocated,
  base_value_gbp,
  retailer_delivery_share_gbp,
  discount_share_gbp
ON public.order_tracking_line_allocations
FOR EACH ROW
WHEN (
  NEW.supplier_invoice_line_id IS NOT NULL
  AND COALESCE(NEW.qty_allocated, 0) > 0
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

DROP TRIGGER IF EXISTS trg_customer_review_supplier_line_materialize_v1
  ON public.supplier_invoice_lines;

CREATE TRIGGER trg_customer_review_supplier_line_materialize_v1
AFTER UPDATE OF eligible_for_invoice_yn
ON public.supplier_invoice_lines
FOR EACH ROW
WHEN (
  NEW.eligible_for_invoice_yn IS DISTINCT FROM OLD.eligible_for_invoice_yn
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

DROP TRIGGER IF EXISTS trg_customer_review_supplier_invoice_materialize_v1
  ON public.supplier_invoices;

CREATE TRIGGER trg_customer_review_supplier_invoice_materialize_v1
AFTER UPDATE OF review_status
ON public.supplier_invoices
FOR EACH ROW
WHEN (
  NEW.review_status IS DISTINCT FROM OLD.review_status
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

DO $recover$
DECLARE
  v_order_id uuid;
BEGIN
  FOR v_order_id IN
    SELECT DISTINCT candidate.order_id
    FROM public.orders order_row
    CROSS JOIN LATERAL
      public.customer_review_cycle_candidates_v1(order_row.id) candidate
    WHERE candidate.receipt_recorded_at <= now()
      AND candidate.receipt_recorded_at + interval '24 hours' > now()
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_legacy_issues issue
        WHERE issue.order_id = candidate.order_id
          AND issue.resolved_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links link_row
        WHERE link_row.order_id = candidate.order_id
          AND link_row.is_active = true
          AND link_row.expires_at IS NULL
      )
      AND (
        SELECT COUNT(*)
        FROM public.customer_order_review_links link_row
        WHERE link_row.order_id = candidate.order_id
          AND link_row.is_active = true
      ) <= 1
  LOOP
    PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
  END LOOP;
END;
$recover$;

DO $verify$
DECLARE
  v_missing_cycle_count integer;
  v_unexplained_empty_cycle_count integer;
BEGIN
  SELECT COUNT(*)::integer
  INTO v_missing_cycle_count
  FROM (
    SELECT DISTINCT candidate.order_id
    FROM public.orders order_row
    CROSS JOIN LATERAL
      public.customer_review_cycle_candidates_v1(order_row.id) candidate
    WHERE candidate.receipt_recorded_at <= now()
      AND candidate.receipt_recorded_at + interval '24 hours' > now()
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_legacy_issues issue
        WHERE issue.order_id = candidate.order_id
          AND issue.resolved_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links untimed_link
        WHERE untimed_link.order_id = candidate.order_id
          AND untimed_link.is_active = true
          AND untimed_link.expires_at IS NULL
      )
      AND (
        SELECT COUNT(*)
        FROM public.customer_order_review_links active_link
        WHERE active_link.order_id = candidate.order_id
          AND active_link.is_active = true
      ) <= 1
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links link_row
        WHERE link_row.order_id = candidate.order_id
          AND link_row.is_active = true
          AND link_row.expires_at IS NOT NULL
          AND link_row.expires_at > now()
      )
  ) missing_cycle;

  SELECT COUNT(*)::integer
  INTO v_unexplained_empty_cycle_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now()
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = link_row.id
        AND membership.membership_status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_legacy_issues issue
      WHERE issue.order_id = link_row.order_id
        AND issue.review_link_id = link_row.id
        AND issue.resolved_at IS NULL
    );

  IF v_missing_cycle_count <> 0 OR v_unexplained_empty_cycle_count <> 0 THEN
    RAISE EXCEPTION
      'Mini 4 platform verification failed: materialisable missing cycles %, unexplained empty open cycles %.',
      v_missing_cycle_count,
      v_unexplained_empty_cycle_count;
  END IF;
END;
$verify$;

COMMIT;
