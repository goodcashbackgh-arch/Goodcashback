BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final Mini 4 scope alignment.
-- This migration changes only Mini 4 review-cycle and hold-provenance helpers.
-- It does not replace any cash, invoice, credit-note, Sage, VAT or funding route.

DO $prerequisites$
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regclass('public.customer_hold_review_memberships') IS NULL
     OR to_regprocedure(
       'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.customer_materialize_hold_review_memberships_v1(uuid)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Mini 4 final alignment prerequisites are missing.';
  END IF;
END
$prerequisites$;

-- These are private server-side helpers. Existing SECURITY DEFINER customer and
-- shipper routes continue to call them as their owner; arbitrary authenticated
-- callers must not query candidate provenance or deadlines directly.
REVOKE ALL ON FUNCTION public.customer_review_cycle_candidates_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_review_cycle_candidates_v1(uuid)
  TO service_role;

REVOKE ALL ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  TO service_role;

-- The cumulative guard runs first and takes an exclusive allocation-row lock.
-- This second insert guard proves the frozen value components and creates a
-- deterministic fingerprint using the cumulative quantity already reviewed.
CREATE OR REPLACE FUNCTION public.customer_review_cycle_component_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_allocation public.order_tracking_line_allocations%ROWTYPE;
  v_existing_review_qty numeric;
  v_ratio numeric;
  v_expected_goods numeric;
  v_expected_delivery numeric;
  v_expected_discount numeric;
BEGIN
  SELECT allocation.*
  INTO v_allocation
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id = NEW.tracking_line_allocation_id;

  IF v_allocation.id IS NULL
     OR COALESCE(v_allocation.qty_allocated, 0) <= 0
  THEN
    RAISE EXCEPTION
      'Exact tracking allocation is missing for customer review membership.';
  END IF;

  v_ratio := NEW.review_qty / v_allocation.qty_allocated;
  v_expected_goods := ROUND(
    COALESCE(v_allocation.base_value_gbp, 0)::numeric * v_ratio,
    2
  );
  v_expected_delivery := ROUND(
    COALESCE(v_allocation.retailer_delivery_share_gbp, 0)::numeric * v_ratio,
    2
  );
  v_expected_discount := ROUND(
    COALESCE(v_allocation.discount_share_gbp, 0)::numeric * v_ratio,
    2
  );

  IF ABS(NEW.goods_amount_gbp - v_expected_goods) > 0.01
     OR ABS(NEW.delivery_share_gbp - v_expected_delivery) > 0.01
     OR ABS(NEW.discount_share_gbp - v_expected_discount) > 0.01
  THEN
    RAISE EXCEPTION
      'Customer review membership value components do not match the exact allocation and quantity.';
  END IF;

  SELECT COALESCE(SUM(membership.review_qty), 0)
  INTO v_existing_review_qty
  FROM public.customer_review_cycle_memberships membership
  WHERE membership.tracking_line_allocation_id =
        NEW.tracking_line_allocation_id;

  NEW.membership_fingerprint := md5(concat_ws(
    '|',
    'customer_review_membership_v2',
    NEW.review_link_id,
    NEW.order_id,
    NEW.supplier_invoice_id,
    NEW.supplier_invoice_line_id,
    NEW.tracking_submission_id,
    NEW.tracking_line_allocation_id,
    ROUND(v_existing_review_qty, 3),
    ROUND(NEW.review_qty, 3),
    NEW.goods_amount_gbp,
    NEW.delivery_share_gbp,
    NEW.discount_share_gbp,
    NEW.receipt_recorded_at
  ));

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_review_cycle_01_component_guard_v1
BEFORE INSERT ON public.customer_review_cycle_memberships
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_cycle_component_guard_v1();

-- Preserve the existing function signature. The only lifecycle correction is
-- that additional exact membership may join an already-open cycle while now()
-- is before its stored deadline; it does not also need a separate receipt+24h
-- window. New cycles still require a currently open first-source window.
CREATE OR REPLACE FUNCTION public.internal_materialize_customer_review_cycles_v1(
  p_order_id uuid,
  p_created_by_staff_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
      order_id, issue_code, issue_detail
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
      order_id, issue_code, issue_detail
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
      order_id, issue_code, issue_detail
    ) VALUES (
      p_order_id,
      'multiple_active_timed_review_links',
      'More than one active timed review link exists. No membership is guessed and cycle materialisation fails closed.'
    )
    ON CONFLICT (order_id, issue_code) DO NOTHING;
    RETURN 0;
  END IF;

  SELECT link_row.id, link_row.expires_at
  INTO v_link_id, v_deadline
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
        order_id, review_link_id, issue_code, issue_detail
      ) VALUES (
        p_order_id,
        v_link_id,
        'pre_mini4_timed_membership_unproven',
        'The existing timed link and stored deadline were preserved, but exact historical membership cannot be proven without guessing.'
      )
      ON CONFLICT (order_id, issue_code) DO NOTHING;
      RETURN 0;
    END IF;

    -- Open-cycle join is governed only by the already stored deadline.
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
      candidate.source_fingerprint,
      false,
      p_created_by_staff_id
    FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
    WHERE candidate.receipt_recorded_at < v_deadline
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted;
  END IF;

  SELECT MIN(candidate.receipt_recorded_at)
  INTO v_anchor_receipt
  FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
  WHERE candidate.receipt_recorded_at + interval '24 hours' > now();

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
    v_deadline,
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
    candidate.source_fingerprint,
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

  RETURN v_total_inserted;
END;
$$;

REVOKE ALL ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
  TO service_role;

-- Freeze hold provenance at row insertion. Later updates may close or validate
-- existing provenance, but they must never absorb membership added afterwards.
CREATE OR REPLACE FUNCTION public.customer_hold_review_membership_sync_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_expires_at timestamptz;
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.customer_materialize_hold_review_memberships_v1(NEW.id);
    RETURN NEW;
  END IF;

  IF NEW.status IN ('rejected','resolved','superseded') THEN
    UPDATE public.customer_hold_review_memberships hold_membership
    SET membership_status = 'closed',
        status_updated_at = COALESCE(hold_membership.status_updated_at, now())
    WHERE hold_membership.hold_request_id = NEW.id
      AND hold_membership.membership_status = 'active';
    RETURN NEW;
  END IF;

  SELECT link_row.expires_at
  INTO v_link_expires_at
  FROM public.customer_order_review_links link_row
  WHERE link_row.id = NEW.review_link_id
    AND link_row.order_id = NEW.order_id;

  IF v_link_expires_at IS NOT NULL
     AND NEW.status IN ('requested','supervisor_approved')
     AND NOT EXISTS (
       SELECT 1
       FROM public.customer_hold_review_memberships hold_membership
       WHERE hold_membership.hold_request_id = NEW.id
     )
  THEN
    RAISE EXCEPTION
      'Timed hold % has no frozen review membership.',
      NEW.id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_hold_review_memberships hold_membership
    JOIN public.customer_review_cycle_memberships review_membership
      ON review_membership.id = hold_membership.review_membership_id
    WHERE hold_membership.hold_request_id = NEW.id
      AND NOT (
        NEW.requested_scope = 'order'
        OR (
          NEW.requested_scope = 'tracking'
          AND NEW.tracking_submission_id =
                review_membership.tracking_submission_id
        )
        OR (
          NEW.requested_scope = 'line'
          AND NEW.supplier_invoice_line_id =
                review_membership.supplier_invoice_line_id
          AND (
            NEW.tracking_submission_id IS NULL
            OR NEW.tracking_submission_id =
                  review_membership.tracking_submission_id
          )
        )
      )
  ) THEN
    RAISE EXCEPTION
      'Customer hold target cannot move outside its frozen review membership.';
  END IF;

  RETURN NEW;
END;
$$;

DO $proof$
DECLARE
  v_definition text;
BEGIN
  IF has_function_privilege(
       'authenticated',
       'public.customer_review_cycle_candidates_v1(uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)',
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'Mini 4 private helper execution leaked to authenticated.';
  END IF;

  IF NOT has_function_privilege(
       'service_role',
       'public.customer_review_cycle_candidates_v1(uuid)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role',
       'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)',
       'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'Mini 4 private helper execution is missing for service_role.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_review_cycle_memberships'::regclass
      AND trigger_row.tgname =
        'trg_customer_review_cycle_01_component_guard_v1'
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'Review membership component guard is missing or disabled.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure
  ) INTO v_definition;
  IF position('Open-cycle join is governed only by the already stored deadline' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Open-cycle membership join rule is not installed.';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_hold_review_membership_sync_v1()'::regprocedure
  ) INTO v_definition;
  IF position('TG_OP = ''INSERT''' IN v_definition) = 0
     OR position('cannot move outside its frozen review membership' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'Hold membership is not frozen at insertion.';
  END IF;
END
$proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
