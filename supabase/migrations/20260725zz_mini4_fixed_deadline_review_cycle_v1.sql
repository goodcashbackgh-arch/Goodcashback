BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Mini-build 4: fixed-deadline customer review cycles.
-- Scope is limited to review-cycle membership, review-link selection/payload,
-- the existing review-link close side effect, and the two existing shipment
-- deadline consumers. No accounting, cash, credit-note or Sage function is
-- replaced by this migration.

DO $prerequisites$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_definition text;
BEGIN
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_order_review_links');
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_pre_shipment_hold_requests');
  END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_sales_release_lines');
  END IF;
  IF to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_shipment_batch_line_memberships');
  END IF;
  IF to_regprocedure('public.customer_active_order_review_link_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_active_order_review_link_v1(uuid)');
  END IF;
  IF to_regprocedure('public.customer_pre_shipment_hold_review_v1(text)') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_pre_shipment_hold_review_v1(text)');
  END IF;
  IF to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_shipment_batch_candidates_v1()');
  END IF;
  IF to_regprocedure('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_create_shipment_batch_v1(...)');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Mini 4 prerequisites missing: %', array_to_string(v_missing, ', ');
  END IF;

  SELECT pg_get_functiondef('public.customer_active_order_review_link_v1(uuid)'::regprocedure)
    INTO v_definition;
  IF position('MAX(' IN v_definition) = 0
     OR position('SET expires_at = v_deadline' IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'Current customer_active_order_review_link_v1 definition does not match the audited pre-Mini-4 deadline-extension implementation.';
  END IF;

  SELECT pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure)
    INTO v_definition;
  IF position('recorded_at + interval ''24 hours''' IN v_definition) = 0
     AND position('recorded_at + ''24:00:00''::interval' IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'Current shipper candidate definition no longer matches the audited receipt-plus-24-hours gate.';
  END IF;
END
$prerequisites$;

CREATE TABLE public.customer_review_cycle_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_link_id uuid NOT NULL
    REFERENCES public.customer_order_review_links(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL
    REFERENCES public.orders(id) ON DELETE RESTRICT,
  supplier_invoice_id uuid NOT NULL
    REFERENCES public.supplier_invoices(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL
    REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  tracking_submission_id uuid NOT NULL
    REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  tracking_line_allocation_id uuid NOT NULL
    REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  review_qty numeric(12,3) NOT NULL CHECK (review_qty > 0),
  goods_amount_gbp numeric(14,2) NOT NULL CHECK (goods_amount_gbp >= 0),
  delivery_share_gbp numeric(14,2) NOT NULL DEFAULT 0 CHECK (delivery_share_gbp >= 0),
  discount_share_gbp numeric(14,2) NOT NULL DEFAULT 0 CHECK (discount_share_gbp >= 0),
  receipt_recorded_at timestamptz NOT NULL,
  membership_status text NOT NULL DEFAULT 'active'
    CHECK (membership_status IN ('active','expired','released','closed')),
  membership_fingerprint text NOT NULL UNIQUE,
  legacy_backfill_yn boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  status_updated_at timestamptz
);

COMMENT ON TABLE public.customer_review_cycle_memberships IS
'Immutable exact source quantity and value components behind the existing customer review link. customer_order_review_links.id remains the cycle identity and expires_at remains the sole deadline.';

CREATE INDEX idx_customer_review_cycle_memberships_order
  ON public.customer_review_cycle_memberships(order_id, created_at);
CREATE INDEX idx_customer_review_cycle_memberships_link
  ON public.customer_review_cycle_memberships(review_link_id, membership_status);
CREATE INDEX idx_customer_review_cycle_memberships_tracking
  ON public.customer_review_cycle_memberships(tracking_submission_id, membership_status);
CREATE INDEX idx_customer_review_cycle_memberships_allocation
  ON public.customer_review_cycle_memberships(
    review_link_id,
    tracking_line_allocation_id
  );

CREATE TABLE public.customer_review_cycle_legacy_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  review_link_id uuid REFERENCES public.customer_order_review_links(id) ON DELETE RESTRICT,
  issue_code text NOT NULL,
  issue_detail text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolved_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  resolution_note text,
  CONSTRAINT customer_review_cycle_legacy_issue_uq UNIQUE (order_id, issue_code)
);

COMMENT ON TABLE public.customer_review_cycle_legacy_issues IS
'Fail-closed audit for pre-Mini-4 review links whose exact historical membership cannot be proven without guessing.';

ALTER TABLE public.customer_review_cycle_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_review_cycle_legacy_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY customer_review_cycle_memberships_staff_read_v1
ON public.customer_review_cycle_memberships
FOR SELECT TO authenticated
USING (public.is_active_staff());

CREATE POLICY customer_review_cycle_legacy_issues_staff_read_v1
ON public.customer_review_cycle_legacy_issues
FOR SELECT TO authenticated
USING (public.is_active_staff());

REVOKE ALL ON public.customer_review_cycle_memberships FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.customer_review_cycle_legacy_issues FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.customer_review_cycle_memberships TO authenticated;
GRANT SELECT ON public.customer_review_cycle_legacy_issues TO authenticated;
GRANT ALL ON public.customer_review_cycle_memberships TO service_role;
GRANT ALL ON public.customer_review_cycle_legacy_issues TO service_role;

CREATE OR REPLACE FUNCTION public.customer_review_cycle_membership_immutable_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.review_link_id IS DISTINCT FROM OLD.review_link_id
     OR NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.supplier_invoice_id IS DISTINCT FROM OLD.supplier_invoice_id
     OR NEW.supplier_invoice_line_id IS DISTINCT FROM OLD.supplier_invoice_line_id
     OR NEW.tracking_submission_id IS DISTINCT FROM OLD.tracking_submission_id
     OR NEW.tracking_line_allocation_id IS DISTINCT FROM OLD.tracking_line_allocation_id
     OR NEW.review_qty IS DISTINCT FROM OLD.review_qty
     OR NEW.goods_amount_gbp IS DISTINCT FROM OLD.goods_amount_gbp
     OR NEW.delivery_share_gbp IS DISTINCT FROM OLD.delivery_share_gbp
     OR NEW.discount_share_gbp IS DISTINCT FROM OLD.discount_share_gbp
     OR NEW.receipt_recorded_at IS DISTINCT FROM OLD.receipt_recorded_at
     OR NEW.membership_fingerprint IS DISTINCT FROM OLD.membership_fingerprint
     OR NEW.legacy_backfill_yn IS DISTINCT FROM OLD.legacy_backfill_yn
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.created_by_staff_id IS DISTINCT FROM OLD.created_by_staff_id
  THEN
    RAISE EXCEPTION
      'Customer review source membership is immutable; later source must use a later cycle.';
  END IF;

  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status THEN
    IF NOT (
      (OLD.membership_status = 'active'
        AND NEW.membership_status IN ('expired','released','closed'))
      OR (OLD.membership_status = 'expired' AND NEW.membership_status = 'closed')
      OR (OLD.membership_status = 'released' AND NEW.membership_status = 'closed')
    ) THEN
      RAISE EXCEPTION
        'Invalid customer review membership status transition: % -> %',
        OLD.membership_status,
        NEW.membership_status;
    END IF;
    NEW.status_updated_at := COALESCE(NEW.status_updated_at, now());
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_review_cycle_membership_immutable_v1
BEFORE UPDATE ON public.customer_review_cycle_memberships
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_cycle_membership_immutable_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_review_cycle_candidates_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  supplier_invoice_id uuid,
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  review_qty numeric,
  goods_amount_gbp numeric,
  delivery_share_gbp numeric,
  discount_share_gbp numeric,
  receipt_recorded_at timestamptz,
  source_fingerprint text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH latest_clean_receipt AS (
    SELECT
      ots.id AS tracking_submission_id,
      ots.order_id,
      receipt.recorded_at
    FROM public.order_tracking_submissions ots
    JOIN LATERAL (
      SELECT spr.receipt_status, spr.recorded_at
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = ots.id
      ORDER BY spr.created_at DESC, spr.id DESC
      LIMIT 1
    ) receipt ON true
    WHERE ots.order_id = p_order_id
      AND ots.superseded_at IS NULL
      AND receipt.receipt_status = 'received_clean'
      AND receipt.recorded_at <= now()
  ),
  prior_review AS (
    SELECT
      m.tracking_line_allocation_id,
      SUM(m.review_qty)::numeric AS review_qty
    FROM public.customer_review_cycle_memberships m
    WHERE m.order_id = p_order_id
    GROUP BY m.tracking_line_allocation_id
  ),
  prior_release AS (
    SELECT
      r.tracking_line_allocation_id,
      SUM(r.released_qty)::numeric AS released_qty
    FROM public.customer_sales_release_lines r
    WHERE r.order_id = p_order_id
      AND r.release_status = 'active'
    GROUP BY r.tracking_line_allocation_id
  ),
  source_rows AS (
    SELECT
      receipt.order_id,
      sil.supplier_invoice_id,
      allocation.supplier_invoice_line_id,
      receipt.tracking_submission_id,
      allocation.id AS tracking_line_allocation_id,
      COALESCE(allocation.qty_allocated, 0)::numeric AS allocated_qty,
      COALESCE(allocation.base_value_gbp, 0)::numeric AS allocated_goods,
      COALESCE(allocation.retailer_delivery_share_gbp, 0)::numeric AS allocated_delivery,
      COALESCE(allocation.discount_share_gbp, 0)::numeric AS allocated_discount,
      COALESCE(pr.review_qty, 0)::numeric AS prior_review_qty,
      COALESCE(rel.released_qty, 0)::numeric AS prior_released_qty,
      receipt.recorded_at
    FROM latest_clean_receipt receipt
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.order_id = receipt.order_id
     AND allocation.tracking_submission_id = receipt.tracking_submission_id
     AND allocation.supplier_invoice_line_id IS NOT NULL
     AND COALESCE(allocation.qty_allocated, 0) > 0
    JOIN public.supplier_invoice_lines sil
      ON sil.id = allocation.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = receipt.order_id
    LEFT JOIN prior_review pr
      ON pr.tracking_line_allocation_id = allocation.id
    LEFT JOIN prior_release rel
      ON rel.tracking_line_allocation_id = allocation.id
    WHERE COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, ''))
        IN ('y','yes','true','1')
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_pre_shipment_hold_requests hold_row
        WHERE hold_row.order_id = receipt.order_id
          AND hold_row.resolved_at IS NULL
          AND hold_row.status IN ('requested','supervisor_approved')
          AND (
            hold_row.requested_scope = 'order'
            OR (
              hold_row.requested_scope = 'tracking'
              AND hold_row.tracking_submission_id = receipt.tracking_submission_id
            )
            OR (
              hold_row.requested_scope = 'line'
              AND hold_row.supplier_invoice_line_id = allocation.supplier_invoice_line_id
            )
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.dispute_lines dispute_line
        JOIN public.disputes dispute_row
          ON dispute_row.id = dispute_line.dispute_id
        WHERE dispute_line.supplier_invoice_line_id = allocation.supplier_invoice_line_id
          AND dispute_line.resolved_at IS NULL
          AND dispute_row.resolved_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.dispute_lines terminal_line
        JOIN public.disputes terminal_dispute
          ON terminal_dispute.id = terminal_line.dispute_id
        WHERE terminal_line.supplier_invoice_line_id = allocation.supplier_invoice_line_id
          AND terminal_dispute.desired_outcome = 'refund'
          AND terminal_dispute.status = 'refunded'
          AND terminal_dispute.resolved_at IS NOT NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batches shipment_batch
        JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(shipment_batch.id) shipment_line
          ON shipment_line.tracking_line_allocation_id = allocation.id
        WHERE shipment_batch.status <> 'voided'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links legacy_timed_link
        WHERE legacy_timed_link.order_id = receipt.order_id
          AND legacy_timed_link.expires_at IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.customer_review_cycle_memberships proven_membership
            WHERE proven_membership.review_link_id = legacy_timed_link.id
          )
          AND receipt.recorded_at < legacy_timed_link.expires_at
      )
  ),
  remaining AS (
    SELECT
      source_row.*,
      GREATEST(
        source_row.allocated_qty
          - GREATEST(source_row.prior_review_qty, source_row.prior_released_qty),
        0
      )::numeric AS remaining_qty
    FROM source_rows source_row
  )
  SELECT
    remaining.order_id,
    remaining.supplier_invoice_id,
    remaining.supplier_invoice_line_id,
    remaining.tracking_submission_id,
    remaining.tracking_line_allocation_id,
    ROUND(remaining.remaining_qty, 3)::numeric,
    ROUND(
      CASE WHEN remaining.allocated_qty > 0
        THEN remaining.allocated_goods * remaining.remaining_qty / remaining.allocated_qty
        ELSE 0
      END,
      2
    )::numeric,
    ROUND(
      CASE WHEN remaining.allocated_qty > 0
        THEN remaining.allocated_delivery * remaining.remaining_qty / remaining.allocated_qty
        ELSE 0
      END,
      2
    )::numeric,
    ROUND(
      CASE WHEN remaining.allocated_qty > 0
        THEN remaining.allocated_discount * remaining.remaining_qty / remaining.allocated_qty
        ELSE 0
      END,
      2
    )::numeric,
    remaining.recorded_at,
    md5(concat_ws(
      '|',
      'customer_review_source_v1',
      remaining.order_id,
      remaining.supplier_invoice_id,
      remaining.supplier_invoice_line_id,
      remaining.tracking_submission_id,
      remaining.tracking_line_allocation_id,
      ROUND(remaining.remaining_qty, 3),
      ROUND(
        CASE WHEN remaining.allocated_qty > 0
          THEN remaining.allocated_goods * remaining.remaining_qty / remaining.allocated_qty
          ELSE 0
        END,
        2
      ),
      ROUND(
        CASE WHEN remaining.allocated_qty > 0
          THEN remaining.allocated_delivery * remaining.remaining_qty / remaining.allocated_qty
          ELSE 0
        END,
        2
      ),
      ROUND(
        CASE WHEN remaining.allocated_qty > 0
          THEN remaining.allocated_discount * remaining.remaining_qty / remaining.allocated_qty
          ELSE 0
        END,
        2
      ),
      remaining.recorded_at
    ))::text
  FROM remaining
  WHERE remaining.remaining_qty > 0;
$$;

REVOKE ALL ON FUNCTION public.customer_review_cycle_candidates_v1(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_review_cycle_candidates_v1(uuid)
  TO authenticated, service_role;

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

  RETURN v_total_inserted;
END;
$$;

REVOKE ALL ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
  TO service_role;

-- Existing timed links pre-date immutable membership. Preserve them and fail
-- closed rather than attaching current facts retrospectively.
INSERT INTO public.customer_review_cycle_legacy_issues (
  order_id, review_link_id, issue_code, issue_detail
)
SELECT
  link_row.order_id,
  link_row.id,
  'pre_mini4_timed_membership_unproven',
  'The existing timed link and stored deadline were preserved, but exact historical membership cannot be proven without guessing.'
FROM public.customer_order_review_links link_row
WHERE link_row.expires_at IS NOT NULL
  AND link_row.is_active = true
  AND link_row.expires_at > now()
  AND NOT EXISTS (
    SELECT 1
    FROM public.customer_review_cycle_memberships membership
    WHERE membership.review_link_id = link_row.id
  )
ON CONFLICT (order_id, issue_code) DO NOTHING;

CREATE OR REPLACE FUNCTION public.customer_review_receipt_materialize_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
BEGIN
  IF NEW.receipt_status IS DISTINCT FROM 'received_clean' THEN
    RETURN NEW;
  END IF;

  SELECT tracking_row.order_id
  INTO v_order_id
  FROM public.order_tracking_submissions tracking_row
  WHERE tracking_row.id = NEW.tracking_submission_id
    AND tracking_row.superseded_at IS NULL;

  IF v_order_id IS NOT NULL THEN
    PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_review_receipt_materialize_v1
AFTER INSERT OR UPDATE OF receipt_status, recorded_at
ON public.shipper_package_receipts
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_receipt_materialize_v1();

CREATE OR REPLACE FUNCTION public.customer_review_ready_line_ids_v1(p_order_id uuid)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH timed_membership AS (
    SELECT DISTINCT
      membership.supplier_invoice_line_id,
      membership.tracking_submission_id
    FROM public.customer_review_cycle_memberships membership
    JOIN public.customer_order_review_links link_row
      ON link_row.id = membership.review_link_id
    WHERE membership.order_id = p_order_id
      AND membership.membership_status = 'active'
      AND link_row.is_active = true
      AND link_row.expires_at IS NOT NULL
      AND link_row.expires_at > now()
  ),
  legacy_dynamic AS (
    SELECT DISTINCT
      allocation.supplier_invoice_line_id,
      tracking_row.id AS tracking_submission_id
    FROM public.customer_order_review_links link_row
    JOIN public.order_tracking_submissions tracking_row
      ON tracking_row.order_id = link_row.order_id
     AND tracking_row.superseded_at IS NULL
    JOIN LATERAL (
      SELECT receipt.receipt_status, receipt.recorded_at
      FROM public.shipper_package_receipts receipt
      WHERE receipt.tracking_submission_id = tracking_row.id
      ORDER BY receipt.created_at DESC, receipt.id DESC
      LIMIT 1
    ) latest_receipt ON true
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.order_id = tracking_row.order_id
     AND allocation.tracking_submission_id = tracking_row.id
     AND allocation.supplier_invoice_line_id IS NOT NULL
     AND COALESCE(allocation.qty_allocated, 0) > 0
    JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = allocation.supplier_invoice_line_id
    JOIN public.supplier_invoices supplier_invoice
      ON supplier_invoice.id = supplier_line.supplier_invoice_id
     AND supplier_invoice.order_id = tracking_row.order_id
    WHERE link_row.order_id = p_order_id
      AND link_row.is_active = true
      AND link_row.expires_at IS NULL
      AND latest_receipt.receipt_status = 'received_clean'
      AND COALESCE(supplier_invoice.review_status, '') NOT IN (
        'rejected_resubmit_required','duplicate_blocked','superseded'
      )
  )
  SELECT * FROM timed_membership
  UNION
  SELECT * FROM legacy_dynamic;
$$;

REVOKE ALL ON FUNCTION public.customer_review_ready_line_ids_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_review_ready_line_ids_v1(uuid)
  TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.customer_order_has_review_ready_lines_v1(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customer_review_ready_line_ids_v1(p_order_id)
  );
$$;

REVOKE ALL ON FUNCTION public.customer_order_has_review_ready_lines_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_order_has_review_ready_lines_v1(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_active_order_review_link_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  customer_review_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_importer_id uuid;
  v_token text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT order_row.importer_id
  INTO v_importer_id
  FROM public.orders order_row
  WHERE order_row.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators operator_row
    JOIN public.operator_importers access_row
      ON access_row.operator_id = operator_row.id
    WHERE operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
      AND access_row.revoked_at IS NULL
      AND access_row.importer_id = v_importer_id
  ) THEN
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;

  PERFORM public.internal_materialize_customer_review_cycles_v1(p_order_id, NULL);

  SELECT link_row.secure_token
  INTO v_token
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_legacy_issues issue
      WHERE issue.order_id = p_order_id
        AND issue.resolved_at IS NULL
    )
    AND (
      (
        link_row.expires_at IS NOT NULL
        AND link_row.expires_at > now()
        AND EXISTS (
          SELECT 1
          FROM public.customer_review_cycle_memberships membership
          WHERE membership.review_link_id = link_row.id
            AND membership.membership_status = 'active'
        )
      )
      OR (
        link_row.expires_at IS NULL
        AND public.customer_order_has_review_ready_lines_v1(p_order_id)
      )
    )
  ORDER BY
    CASE WHEN link_row.expires_at IS NULL THEN 0 ELSE 1 END,
    link_row.created_at,
    link_row.id
  LIMIT 1;

  IF v_token IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    p_order_id,
    ('/customer/orders/' || v_token || '/review')::text;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_active_order_review_link_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_active_order_review_link_v1(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_create_customer_order_review_link_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  secure_token text,
  customer_review_path text,
  customer_review_url text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_token text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION
      'Unauthenticated user: customer order review link requires auth.uid()';
  END IF;

  SELECT staff_row.id
  INTO v_staff_id
  FROM public.staff staff_row
  WHERE staff_row.auth_user_id = auth.uid()
    AND COALESCE(staff_row.active, true) = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION
      'Active staff account required to create customer review link.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.orders order_row WHERE order_row.id = p_order_id
  ) THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  PERFORM public.internal_materialize_customer_review_cycles_v1(
    p_order_id,
    v_staff_id
  );

  SELECT link_row.secure_token
  INTO v_token
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_legacy_issues issue
      WHERE issue.order_id = p_order_id
        AND issue.resolved_at IS NULL
    )
    AND (
      (
        link_row.expires_at IS NOT NULL
        AND link_row.expires_at > now()
        AND EXISTS (
          SELECT 1
          FROM public.customer_review_cycle_memberships membership
          WHERE membership.review_link_id = link_row.id
            AND membership.membership_status = 'active'
        )
      )
      OR (
        link_row.expires_at IS NULL
        AND public.customer_order_has_review_ready_lines_v1(p_order_id)
      )
    )
  ORDER BY
    CASE WHEN link_row.expires_at IS NULL THEN 0 ELSE 1 END,
    link_row.created_at,
    link_row.id
  LIMIT 1;

  IF v_token IS NULL THEN
    RAISE EXCEPTION
      'No exact newly eligible customer review membership exists for order %.',
      p_order_id;
  END IF;

  RETURN QUERY
  SELECT
    p_order_id,
    v_token,
    ('/customer/orders/' || v_token || '/review')::text,
    ('/customer/orders/' || v_token || '/review')::text;
END;
$$;

REVOKE ALL ON FUNCTION
  public.internal_create_customer_order_review_link_v1(uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.internal_create_customer_order_review_link_v1(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_pre_shipment_hold_review_v1(p_secure_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_id uuid;
  v_order_id uuid;
  v_expires_at timestamptz;
  v_result jsonb;
BEGIN
  SELECT link_row.id, link_row.order_id, link_row.expires_at
  INTO v_link_id, v_order_id, v_expires_at
  FROM public.customer_order_review_links link_row
  WHERE link_row.secure_token = p_secure_token
    AND link_row.is_active = true
    AND (link_row.expires_at IS NULL OR link_row.expires_at > now())
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Customer review link is invalid or expired.';
  END IF;

  UPDATE public.customer_order_review_links
  SET last_used_at = now()
  WHERE id = v_link_id;

  SELECT jsonb_build_object(
    'order', jsonb_build_object(
      'id', order_row.id,
      'order_ref', order_row.order_ref,
      'retailer_name', retailer_row.name,
      'status', order_row.status,
      'order_type', order_row.order_type,
      'total_qty_declared', order_row.total_qty_declared
    ),
    'tracking', '[]'::jsonb,
    'lines', COALESCE((
      WITH timed_lines AS (
        SELECT
          membership.supplier_invoice_line_id,
          membership.tracking_submission_id,
          SUM(membership.review_qty)::numeric AS qty,
          SUM(
            membership.goods_amount_gbp
            + membership.delivery_share_gbp
            - membership.discount_share_gbp
          )::numeric AS amount_inc_vat_gbp
        FROM public.customer_review_cycle_memberships membership
        WHERE membership.review_link_id = v_link_id
          AND membership.membership_status = 'active'
          AND v_expires_at IS NOT NULL
        GROUP BY
          membership.supplier_invoice_line_id,
          membership.tracking_submission_id
      ),
      legacy_lines AS (
        SELECT
          ready_line.supplier_invoice_line_id,
          ready_line.tracking_submission_id,
          COALESCE(supplier_line.qty_confirmed, supplier_line.qty, 0)::numeric AS qty,
          COALESCE(
            supplier_line.amount_confirmed,
            supplier_line.amount_inc_vat_gbp,
            0
          )::numeric AS amount_inc_vat_gbp
        FROM public.customer_review_ready_line_ids_v1(v_order_id) ready_line
        JOIN public.supplier_invoice_lines supplier_line
          ON supplier_line.id = ready_line.supplier_invoice_line_id
        WHERE v_expires_at IS NULL
      ),
      review_lines AS (
        SELECT * FROM timed_lines
        UNION ALL
        SELECT * FROM legacy_lines
      )
      SELECT jsonb_agg(jsonb_build_object(
        'id', supplier_line.id,
        'description', supplier_line.description,
        'size', supplier_line.size,
        'retailer_sku', supplier_line.retailer_sku,
        'qty', review_line.qty,
        'amount_inc_vat_gbp', review_line.amount_inc_vat_gbp,
        'tracking_submission_id', review_line.tracking_submission_id,
        'eligible_for_invoice_yn', supplier_line.eligible_for_invoice_yn
      ) ORDER BY supplier_line.created_at NULLS LAST, supplier_line.id)
      FROM review_lines review_line
      JOIN public.supplier_invoice_lines supplier_line
        ON supplier_line.id = review_line.supplier_invoice_line_id
    ), '[]'::jsonb),
    'holds', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', hold_row.id,
        'requested_scope', hold_row.requested_scope,
        'tracking_submission_id', hold_row.tracking_submission_id,
        'supplier_invoice_line_id', hold_row.supplier_invoice_line_id,
        'narrowed_from_hold_request_id', hold_row.narrowed_from_hold_request_id,
        'converted_dispute_id', hold_row.converted_dispute_id,
        'status', hold_row.status,
        'reason', hold_row.reason,
        'created_at', hold_row.created_at,
        'supervisor_review_note', hold_row.supervisor_review_note
      ) ORDER BY hold_row.created_at DESC)
      FROM public.customer_pre_shipment_hold_requests hold_row
      WHERE hold_row.order_id = order_row.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.orders order_row
  LEFT JOIN public.retailers retailer_row
    ON retailer_row.id = order_row.retailer_id
  WHERE order_row.id = v_order_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_pre_shipment_hold_review_v1(text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_pre_shipment_hold_review_v1(text)
  TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.customer_close_order_review_links_for_invoice_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.invoice_type::text, '') IN ('main','supplementary')
     AND COALESCE(NEW.sage_status::text, '') IN ('draft','posted')
  THEN
    -- Preserve the established close behaviour for legacy untimed links only.
    -- Timed Mini 4 cycles close through their fixed deadline and exact membership.
    UPDATE public.customer_order_review_links link_row
    SET is_active = false
    WHERE link_row.order_id = NEW.order_id
      AND link_row.is_active = true
      AND link_row.expires_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_hold_enforce_open_review_window_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link public.customer_order_review_links%ROWTYPE;
  v_tracking_id uuid;
  v_tracking_count integer;
BEGIN
  IF NEW.status <> 'requested'
     OR NEW.narrowed_from_hold_request_id IS NOT NULL
  THEN
    RETURN NEW;
  END IF;

  IF NEW.review_link_id IS NULL THEN
    RAISE EXCEPTION 'Customer hold must retain the exact customer review link.';
  END IF;

  SELECT *
  INTO v_link
  FROM public.customer_order_review_links link_row
  WHERE link_row.id = NEW.review_link_id
    AND link_row.order_id = NEW.order_id
    AND link_row.is_active = true
    AND (link_row.expires_at IS NULL OR link_row.expires_at > now());

  IF v_link.id IS NULL THEN
    RAISE EXCEPTION 'Customer review link is invalid or expired.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.order_id::text));

  IF v_link.expires_at IS NOT NULL THEN
    IF NEW.requested_scope = 'order' THEN
      IF NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships membership
        WHERE membership.review_link_id = NEW.review_link_id
          AND membership.membership_status = 'active'
      ) THEN
        RAISE EXCEPTION 'Timed review membership is unresolved.';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.requested_scope = 'tracking' THEN
      IF NEW.tracking_submission_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships membership
        WHERE membership.review_link_id = NEW.review_link_id
          AND membership.membership_status = 'active'
          AND membership.tracking_submission_id = NEW.tracking_submission_id
      ) THEN
        RAISE EXCEPTION
          'Tracking/package is not part of this customer review cycle.';
      END IF;
      PERFORM pg_advisory_xact_lock(hashtext(NEW.tracking_submission_id::text));
      RETURN NEW;
    END IF;

    IF NEW.requested_scope = 'line' THEN
      SELECT
        MIN(membership.tracking_submission_id::text)::uuid,
        COUNT(DISTINCT membership.tracking_submission_id)::integer
      INTO v_tracking_id, v_tracking_count
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = NEW.review_link_id
        AND membership.membership_status = 'active'
        AND membership.supplier_invoice_line_id = NEW.supplier_invoice_line_id
        AND (
          NEW.tracking_submission_id IS NULL
          OR membership.tracking_submission_id = NEW.tracking_submission_id
        );

      IF COALESCE(v_tracking_count, 0) = 0 THEN
        RAISE EXCEPTION
          'Invoice line is not part of this customer review cycle.';
      END IF;

      IF NEW.tracking_submission_id IS NULL AND v_tracking_count > 1 THEN
        RAISE EXCEPTION
          'This item is in more than one package in this review cycle. Select the package.';
      END IF;

      NEW.tracking_submission_id := COALESCE(
        NEW.tracking_submission_id,
        v_tracking_id
      );
      PERFORM pg_advisory_xact_lock(hashtext(NEW.tracking_submission_id::text));
      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Unsupported customer hold scope: %', NEW.requested_scope;
  END IF;

  -- Legacy untimed compatibility keeps the existing dynamic target check.
  IF NEW.requested_scope = 'order' THEN
    IF NOT public.customer_order_has_review_ready_lines_v1(NEW.order_id) THEN
      RAISE EXCEPTION 'No review-ready lines remain for this order.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.requested_scope = 'tracking' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.customer_review_ready_line_ids_v1(NEW.order_id) ready_line
      WHERE ready_line.tracking_submission_id = NEW.tracking_submission_id
    ) THEN
      RAISE EXCEPTION 'Tracking/package is not review-ready.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.requested_scope = 'line' THEN
    SELECT
      MIN(ready_line.tracking_submission_id),
      COUNT(DISTINCT ready_line.tracking_submission_id)::integer
    INTO v_tracking_id, v_tracking_count
    FROM public.customer_review_ready_line_ids_v1(NEW.order_id) ready_line
    WHERE ready_line.supplier_invoice_line_id = NEW.supplier_invoice_line_id
      AND (
        NEW.tracking_submission_id IS NULL
        OR ready_line.tracking_submission_id = NEW.tracking_submission_id
      );

    IF COALESCE(v_tracking_count, 0) = 0 THEN
      RAISE EXCEPTION 'Invoice line is not review-ready.';
    END IF;

    IF NEW.tracking_submission_id IS NULL AND v_tracking_count > 1 THEN
      RAISE EXCEPTION
        'This item is allocated across more than one package. Select the package.';
    END IF;

    NEW.tracking_submission_id := COALESCE(
      NEW.tracking_submission_id,
      v_tracking_id
    );
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

-- Keep the existing trigger identity. Only its function body is replaced.
DO $trigger_guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_pre_shipment_hold_requests'::regclass
      AND trigger_row.tgname = 'trg_customer_hold_enforce_open_review_window_v1'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION
      'Existing open-review-window hold trigger is missing or disabled.';
  END IF;
END
$trigger_guard$;

CREATE OR REPLACE FUNCTION public.customer_tracking_review_deadline_v1(
  p_order_id uuid,
  p_tracking_submission_id uuid,
  p_receipt_recorded_at timestamptz
)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT MAX(link_row.expires_at)
      FROM public.customer_review_cycle_memberships membership
      JOIN public.customer_order_review_links link_row
        ON link_row.id = membership.review_link_id
      WHERE membership.order_id = p_order_id
        AND membership.tracking_submission_id = p_tracking_submission_id
        AND link_row.expires_at IS NOT NULL
    ),
    p_receipt_recorded_at + interval '24 hours'
  );
$$;

REVOKE ALL ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_candidates_v1()
RETURNS TABLE (
  shipper_user_id uuid,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  order_id uuid,
  order_ref text,
  retailer_name text,
  tracking_submission_id uuid,
  courier_name text,
  tracking_ref text,
  tracking_date text,
  allocated_qty numeric,
  allocated_net_value_gbp numeric,
  latest_receipt_status text,
  latest_receipt_recorded_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION
      'Unauthenticated user: shipment batch candidates require auth.uid()';
  END IF;

  SELECT shipper_user.id, shipper_user.shipper_id
  INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users shipper_user
  WHERE shipper_user.auth_user_id = v_auth_uid
    AND shipper_user.active = true
  ORDER BY shipper_user.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    v_shipper_user_id,
    shipper_row.id,
    shipper_row.name::text,
    order_row.importer_id,
    COALESCE(
      NULLIF(importer_row.trading_name, ''),
      importer_row.company_name
    )::text,
    order_row.id,
    order_row.order_ref::text,
    retailer_row.name::text,
    tracking_row.id,
    courier_row.name::text,
    tracking_row.tracking_ref::text,
    tracking_row.tracking_date::text,
    eligible.allocated_qty,
    eligible.allocated_net_value_gbp,
    latest_receipt.receipt_status::text,
    latest_receipt.recorded_at
  FROM public.orders order_row
  JOIN public.shippers shipper_row
    ON shipper_row.id = order_row.shipper_id
  LEFT JOIN public.importers importer_row
    ON importer_row.id = order_row.importer_id
  LEFT JOIN public.retailers retailer_row
    ON retailer_row.id = order_row.retailer_id
  JOIN public.order_tracking_submissions tracking_row
    ON tracking_row.order_id = order_row.id
   AND tracking_row.superseded_at IS NULL
  LEFT JOIN public.couriers courier_row
    ON courier_row.id = tracking_row.courier_id
  JOIN LATERAL (
    SELECT
      SUM(COALESCE(allocation.qty_allocated, 0))::numeric AS allocated_qty,
      SUM(COALESCE(allocation.adjusted_net_value_gbp, 0))::numeric
        AS allocated_net_value_gbp
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = order_row.id
      AND allocation.tracking_submission_id = tracking_row.id
      AND COALESCE(allocation.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        allocation.order_id,
        allocation.tracking_submission_id,
        allocation.supplier_invoice_line_id
      ) IS DISTINCT FROM true
  ) eligible ON COALESCE(eligible.allocated_qty, 0) > 0
  JOIN LATERAL (
    SELECT receipt.receipt_status, receipt.recorded_at
    FROM public.shipper_package_receipts receipt
    WHERE receipt.tracking_submission_id = tracking_row.id
    ORDER BY receipt.created_at DESC, receipt.id DESC
    LIMIT 1
  ) latest_receipt ON true
  LEFT JOIN public.shipper_shipment_batch_packages existing_link
    ON existing_link.tracking_submission_id = tracking_row.id
   AND existing_link.active = true
  WHERE order_row.shipper_id = v_shipper_id
    AND latest_receipt.receipt_status = 'received_clean'
    AND now() >= public.customer_tracking_review_deadline_v1(
      order_row.id,
      tracking_row.id,
      latest_receipt.recorded_at
    )
    AND existing_link.id IS NULL
  ORDER BY
    importer_row.company_name NULLS LAST,
    order_row.created_at DESC,
    tracking_row.tracking_date DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_candidates_v1()
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_candidates_v1()
  TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_create_shipment_batch_v1(
  p_importer_id uuid,
  p_tracking_submission_ids uuid[],
  p_booking_ref text,
  p_shipment_cutoff_at timestamptz DEFAULT NULL,
  p_dispatched_at timestamptz DEFAULT NULL,
  p_box_count integer DEFAULT NULL,
  p_container_ref text DEFAULT NULL,
  p_bol_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch_id uuid;
  v_package_id uuid;
  v_tracking_id uuid;
  v_order_id uuid;
  v_order_shipper_id uuid;
  v_order_importer_id uuid;
  v_latest_receipt_status text;
  v_latest_receipt_recorded_at timestamptz;
  v_review_deadline timestamptz;
  v_eligible_count integer;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION
      'Unauthenticated user: create shipment batch requires auth.uid()';
  END IF;
  IF p_importer_id IS NULL THEN
    RAISE EXCEPTION 'Importer is required.';
  END IF;
  IF p_tracking_submission_ids IS NULL
     OR array_length(p_tracking_submission_ids, 1) IS NULL
  THEN
    RAISE EXCEPTION 'Select at least one received-clean package.';
  END IF;
  IF NULLIF(btrim(COALESCE(p_booking_ref, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Booking reference is required.';
  END IF;

  SELECT shipper_user.id, shipper_user.shipper_id
  INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users shipper_user
  WHERE shipper_user.auth_user_id = v_auth_uid
    AND shipper_user.active = true
  ORDER BY shipper_user.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  INSERT INTO public.shipper_shipment_batches (
    shipper_id,
    importer_id,
    created_by_shipper_user_id,
    booking_ref,
    shipment_cutoff_at,
    dispatched_at,
    box_count,
    container_ref,
    bol_ref,
    notes
  ) VALUES (
    v_shipper_id,
    p_importer_id,
    v_shipper_user_id,
    btrim(p_booking_ref),
    p_shipment_cutoff_at,
    p_dispatched_at,
    p_box_count,
    NULLIF(btrim(COALESCE(p_container_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_bol_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_notes, '')), '')
  )
  RETURNING id INTO v_batch_id;

  FOREACH v_tracking_id IN ARRAY p_tracking_submission_ids LOOP
    SELECT
      tracking_row.order_id,
      order_row.shipper_id,
      order_row.importer_id
    INTO
      v_order_id,
      v_order_shipper_id,
      v_order_importer_id
    FROM public.order_tracking_submissions tracking_row
    JOIN public.orders order_row
      ON order_row.id = tracking_row.order_id
    WHERE tracking_row.id = v_tracking_id
      AND tracking_row.superseded_at IS NULL;

    IF v_order_id IS NULL THEN
      RAISE EXCEPTION 'Tracking/package not found: %', v_tracking_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(v_order_id::text));
    PERFORM pg_advisory_xact_lock(hashtext(v_tracking_id::text));

    IF v_order_shipper_id IS DISTINCT FROM v_shipper_id THEN
      RAISE EXCEPTION
        'Tracking/package does not belong to this shipper: %',
        v_tracking_id;
    END IF;
    IF v_order_importer_id IS DISTINCT FROM p_importer_id THEN
      RAISE EXCEPTION
        'All selected packages must belong to the selected importer.';
    END IF;

    SELECT receipt.receipt_status, receipt.recorded_at
    INTO v_latest_receipt_status, v_latest_receipt_recorded_at
    FROM public.shipper_package_receipts receipt
    WHERE receipt.tracking_submission_id = v_tracking_id
    ORDER BY receipt.created_at DESC, receipt.id DESC
    LIMIT 1;

    IF v_latest_receipt_status IS DISTINCT FROM 'received_clean' THEN
      RAISE EXCEPTION
        'Only latest received-clean packages can be selected for shipment batch.';
    END IF;

    v_review_deadline := public.customer_tracking_review_deadline_v1(
      v_order_id,
      v_tracking_id,
      v_latest_receipt_recorded_at
    );

    IF now() < v_review_deadline THEN
      RAISE EXCEPTION
        'This package is inside the customer review window and cannot yet be added to a shipment.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_packages package_row
      WHERE package_row.tracking_submission_id = v_tracking_id
        AND package_row.active = true
    ) THEN
      RAISE EXCEPTION
        'This package is already in an active shipment batch.';
    END IF;

    SELECT COUNT(*)::integer
    INTO v_eligible_count
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = v_order_id
      AND allocation.tracking_submission_id = v_tracking_id
      AND COALESCE(allocation.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        allocation.order_id,
        allocation.tracking_submission_id,
        allocation.supplier_invoice_line_id
      ) IS DISTINCT FROM true;

    IF COALESCE(v_eligible_count, 0) = 0 THEN
      RAISE EXCEPTION
        'This package has no shipment-eligible lines after active customer holds are applied.';
    END IF;

    INSERT INTO public.shipper_shipment_batch_packages (
      shipment_batch_id,
      tracking_submission_id,
      order_id,
      shipper_id,
      importer_id,
      selected_by_shipper_user_id
    ) VALUES (
      v_batch_id,
      v_tracking_id,
      v_order_id,
      v_shipper_id,
      p_importer_id,
      v_shipper_user_id
    )
    RETURNING id INTO v_package_id;

    INSERT INTO public.shipper_shipment_batch_line_memberships (
      shipment_batch_id,
      shipment_batch_package_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      order_id,
      supplier_invoice_line_id,
      qty_in_shipment,
      adjusted_net_value_gbp
    )
    SELECT
      v_batch_id,
      v_package_id,
      allocation.tracking_submission_id,
      allocation.id,
      allocation.order_id,
      allocation.supplier_invoice_line_id,
      allocation.qty_allocated,
      COALESCE(allocation.adjusted_net_value_gbp, 0)
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = v_order_id
      AND allocation.tracking_submission_id = v_tracking_id
      AND COALESCE(allocation.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        allocation.order_id,
        allocation.tracking_submission_id,
        allocation.supplier_invoice_line_id
      ) IS DISTINCT FROM true;
  END LOOP;

  RETURN v_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION
  public.shipper_create_shipment_batch_v1(
    uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text
  )
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.shipper_create_shipment_batch_v1(
    uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text
  )
  TO authenticated;

-- Materialise only currently open, exact eligibility after all replacements are
-- installed. Historical expired sources are not reopened or backfilled.
DO $materialize_open$
DECLARE
  v_order_id uuid;
BEGIN
  FOR v_order_id IN
    SELECT DISTINCT tracking_row.order_id
    FROM public.order_tracking_submissions tracking_row
    JOIN LATERAL (
      SELECT receipt.receipt_status, receipt.recorded_at
      FROM public.shipper_package_receipts receipt
      WHERE receipt.tracking_submission_id = tracking_row.id
      ORDER BY receipt.created_at DESC, receipt.id DESC
      LIMIT 1
    ) latest_receipt ON true
    WHERE tracking_row.superseded_at IS NULL
      AND latest_receipt.receipt_status = 'received_clean'
      AND latest_receipt.recorded_at + interval '24 hours' > now()
  LOOP
    PERFORM public.internal_materialize_customer_review_cycles_v1(
      v_order_id,
      NULL
    );
  END LOOP;
END
$materialize_open$;

NOTIFY pgrst, 'reload schema';

COMMIT;
