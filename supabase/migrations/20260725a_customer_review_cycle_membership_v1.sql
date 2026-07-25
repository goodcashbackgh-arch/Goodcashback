BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_order_review_links');
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_pre_shipment_hold_requests');
  END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_sales_release_lines');
  END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    v_missing := array_append(v_missing, 'public.order_tracking_line_allocations');
  END IF;
  IF to_regprocedure('public.customer_active_order_review_link_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_active_order_review_link_v1(uuid)');
  END IF;
  IF to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_review_ready_line_ids_v1(uuid)');
  END IF;
  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Mini 4 prerequisites missing: %', array_to_string(v_missing, ', ');
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.customer_review_cycle_memberships (
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
  package_or_tracking_identity text NOT NULL,
  review_qty numeric(12,3) NOT NULL CHECK (review_qty > 0),
  review_value_gbp numeric(14,2) NOT NULL CHECK (review_value_gbp >= 0),
  receipt_recorded_at timestamptz NOT NULL,
  membership_status text NOT NULL DEFAULT 'active'
    CHECK (membership_status IN (
      'active',
      'held',
      'released',
      'expired',
      'closed',
      'legacy_unresolved'
    )),
  membership_fingerprint text NOT NULL,
  legacy_backfill_yn boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by_staff_id uuid NULL REFERENCES public.staff(id) ON DELETE SET NULL,
  status_updated_at timestamptz NULL,
  CONSTRAINT customer_review_cycle_memberships_link_order_unique
    UNIQUE (review_link_id, tracking_line_allocation_id),
  CONSTRAINT customer_review_cycle_memberships_fingerprint_unique
    UNIQUE (membership_fingerprint)
);

COMMENT ON TABLE public.customer_review_cycle_memberships IS
'Mini 4 immutable exact membership behind customer_order_review_links. The existing review link ID is the cycle identity and expires_at remains the sole review deadline.';

CREATE INDEX IF NOT EXISTS idx_customer_review_cycle_memberships_order
  ON public.customer_review_cycle_memberships(order_id, created_at);

CREATE INDEX IF NOT EXISTS idx_customer_review_cycle_memberships_link
  ON public.customer_review_cycle_memberships(review_link_id, membership_status);

CREATE INDEX IF NOT EXISTS idx_customer_review_cycle_memberships_allocation
  ON public.customer_review_cycle_memberships(
    tracking_line_allocation_id,
    membership_status
  );

CREATE TABLE IF NOT EXISTS public.customer_review_cycle_legacy_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_link_id uuid NULL
    REFERENCES public.customer_order_review_links(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL
    REFERENCES public.orders(id) ON DELETE RESTRICT,
  issue_code text NOT NULL,
  issue_detail text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz NULL,
  resolved_by_staff_id uuid NULL REFERENCES public.staff(id) ON DELETE SET NULL,
  resolution_note text NULL,
  CONSTRAINT customer_review_cycle_legacy_issue_once
    UNIQUE (review_link_id, issue_code)
);

COMMENT ON TABLE public.customer_review_cycle_legacy_issues IS
'Fail-closed audit for historical review links whose exact Mini 4 membership cannot be proven without guessing.';

ALTER TABLE public.customer_review_cycle_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_review_cycle_legacy_issues ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_review_cycle_memberships_staff_read_v1
  ON public.customer_review_cycle_memberships;
CREATE POLICY customer_review_cycle_memberships_staff_read_v1
  ON public.customer_review_cycle_memberships
  FOR SELECT
  TO authenticated
  USING (public.is_active_staff());

DROP POLICY IF EXISTS customer_review_cycle_legacy_issues_staff_read_v1
  ON public.customer_review_cycle_legacy_issues;
CREATE POLICY customer_review_cycle_legacy_issues_staff_read_v1
  ON public.customer_review_cycle_legacy_issues
  FOR SELECT
  TO authenticated
  USING (public.is_active_staff());

REVOKE ALL ON TABLE public.customer_review_cycle_memberships FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.customer_review_cycle_legacy_issues FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.customer_review_cycle_memberships TO authenticated;
GRANT SELECT ON TABLE public.customer_review_cycle_legacy_issues TO authenticated;
GRANT ALL ON TABLE public.customer_review_cycle_memberships TO service_role;
GRANT ALL ON TABLE public.customer_review_cycle_legacy_issues TO service_role;

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
     OR NEW.package_or_tracking_identity IS DISTINCT FROM OLD.package_or_tracking_identity
     OR NEW.review_qty IS DISTINCT FROM OLD.review_qty
     OR NEW.review_value_gbp IS DISTINCT FROM OLD.review_value_gbp
     OR NEW.receipt_recorded_at IS DISTINCT FROM OLD.receipt_recorded_at
     OR NEW.membership_fingerprint IS DISTINCT FROM OLD.membership_fingerprint
     OR NEW.legacy_backfill_yn IS DISTINCT FROM OLD.legacy_backfill_yn
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.created_by_staff_id IS DISTINCT FROM OLD.created_by_staff_id
  THEN
    RAISE EXCEPTION
      'Customer review cycle source membership is immutable; create a later review cycle for later source.';
  END IF;

  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status THEN
    IF NOT (
      (OLD.membership_status = 'active'
        AND NEW.membership_status IN ('held','released','expired','closed'))
      OR (OLD.membership_status = 'held'
        AND NEW.membership_status IN ('released','closed'))
      OR (OLD.membership_status = 'released'
        AND NEW.membership_status = 'closed')
      OR (OLD.membership_status = 'expired'
        AND NEW.membership_status = 'closed')
      OR (OLD.membership_status = 'legacy_unresolved'
        AND NEW.membership_status = 'closed')
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

DROP TRIGGER IF EXISTS trg_customer_review_cycle_membership_immutable_v1
  ON public.customer_review_cycle_memberships;
CREATE TRIGGER trg_customer_review_cycle_membership_immutable_v1
BEFORE UPDATE ON public.customer_review_cycle_memberships
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_cycle_membership_immutable_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_review_cycle_candidates_v1(
  p_order_id uuid
)
RETURNS TABLE (
  order_id uuid,
  supplier_invoice_id uuid,
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  package_or_tracking_identity text,
  review_qty numeric,
  review_value_gbp numeric,
  receipt_recorded_at timestamptz,
  expires_at timestamptz,
  membership_fingerprint text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH tracking_scope AS (
    SELECT
      ots.id AS tracking_submission_id,
      ots.order_id,
      latest_receipt.recorded_at,
      latest_receipt.recorded_at + interval '24 hours' AS expires_at
    FROM public.order_tracking_submissions ots
    JOIN LATERAL (
      SELECT spr.receipt_status, spr.recorded_at
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = ots.id
      ORDER BY spr.created_at DESC, spr.id DESC
      LIMIT 1
    ) latest_receipt ON true
    WHERE ots.order_id = p_order_id
      AND ots.superseded_at IS NULL
      AND latest_receipt.receipt_status = 'received_clean'
      AND now() >= latest_receipt.recorded_at
      AND now() < latest_receipt.recorded_at + interval '24 hours'
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages sbp
        WHERE sbp.tracking_submission_id = ots.id
          AND sbp.active = true
      )
  ),
  prior_review AS (
    SELECT
      m.tracking_line_allocation_id,
      SUM(m.review_qty)::numeric AS review_qty
    FROM public.customer_review_cycle_memberships m
    WHERE m.order_id = p_order_id
      AND m.membership_status <> 'legacy_unresolved'
    GROUP BY m.tracking_line_allocation_id
  ),
  prior_release AS (
    SELECT
      l.tracking_line_allocation_id,
      SUM(l.released_qty)::numeric AS released_qty
    FROM public.customer_sales_release_lines l
    WHERE l.order_id = p_order_id
      AND l.release_status = 'active'
    GROUP BY l.tracking_line_allocation_id
  ),
  base AS (
    SELECT
      ts.order_id,
      sil.supplier_invoice_id,
      otla.supplier_invoice_line_id,
      ts.tracking_submission_id,
      otla.id AS tracking_line_allocation_id,
      ('tracking:' || ts.tracking_submission_id::text)::text
        AS package_or_tracking_identity,
      COALESCE(otla.qty_allocated, 0)::numeric AS allocated_qty,
      COALESCE(otla.adjusted_net_value_gbp, 0)::numeric AS allocated_value_gbp,
      COALESCE(pr.review_qty, 0)::numeric AS prior_review_qty,
      COALESCE(pl.released_qty, 0)::numeric AS prior_released_qty,
      ts.recorded_at,
      ts.expires_at
    FROM tracking_scope ts
    JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = ts.order_id
     AND otla.tracking_submission_id = ts.tracking_submission_id
     AND otla.supplier_invoice_line_id IS NOT NULL
     AND COALESCE(otla.qty_allocated, 0) > 0
    JOIN public.supplier_invoice_lines sil
      ON sil.id = otla.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = ts.order_id
    LEFT JOIN prior_review pr
      ON pr.tracking_line_allocation_id = otla.id
    LEFT JOIN prior_release pl
      ON pl.tracking_line_allocation_id = otla.id
    WHERE COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, ''))
        IN ('y','yes','true','1')
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_pre_shipment_hold_requests h
        WHERE h.order_id = ts.order_id
          AND h.resolved_at IS NULL
          AND h.status IN ('requested','supervisor_approved')
          AND (
            h.requested_scope = 'order'
            OR (
              h.requested_scope = 'tracking'
              AND h.tracking_submission_id = ts.tracking_submission_id
            )
            OR (
              h.requested_scope = 'line'
              AND h.supplier_invoice_line_id = otla.supplier_invoice_line_id
            )
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.dispute_lines dl
        JOIN public.disputes d ON d.id = dl.dispute_id
        WHERE dl.supplier_invoice_line_id = otla.supplier_invoice_line_id
          AND dl.resolved_at IS NULL
          AND d.resolved_at IS NULL
      )
  ),
  remaining AS (
    SELECT
      b.*,
      GREATEST(
        b.allocated_qty - GREATEST(b.prior_review_qty, b.prior_released_qty),
        0
      )::numeric AS remaining_qty
    FROM base b
  )
  SELECT
    r.order_id,
    r.supplier_invoice_id,
    r.supplier_invoice_line_id,
    r.tracking_submission_id,
    r.tracking_line_allocation_id,
    r.package_or_tracking_identity,
    ROUND(r.remaining_qty, 3)::numeric AS review_qty,
    ROUND(
      CASE
        WHEN r.allocated_qty > 0
          THEN r.allocated_value_gbp * r.remaining_qty / r.allocated_qty
        ELSE 0
      END,
      2
    )::numeric AS review_value_gbp,
    r.recorded_at AS receipt_recorded_at,
    r.expires_at,
    md5(concat_ws(
      '|',
      'customer_review_cycle_v1',
      r.order_id,
      r.supplier_invoice_id,
      r.supplier_invoice_line_id,
      r.tracking_submission_id,
      r.tracking_line_allocation_id,
      ROUND(r.remaining_qty, 3),
      ROUND(
        CASE
          WHEN r.allocated_qty > 0
            THEN r.allocated_value_gbp * r.remaining_qty / r.allocated_qty
          ELSE 0
        END,
        2
      ),
      r.recorded_at
    ))::text AS membership_fingerprint
  FROM remaining r
  WHERE r.remaining_qty > 0;
$$;

COMMENT ON FUNCTION public.customer_review_cycle_candidates_v1(uuid) IS
'Returns only exact newly eligible received-clean allocation quantity. Prior review membership, active release membership, holds and unresolved exceptions are conservatively removed.';

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
  v_deadline timestamptz;
  v_link_id uuid;
  v_created integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtext('customer_review_cycle|' || p_order_id::text)
  );
  PERFORM 1 FROM public.orders WHERE id = p_order_id FOR UPDATE;

  UPDATE public.customer_order_review_links l
  SET is_active = false
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND l.expires_at IS NOT NULL
    AND l.expires_at <= now();

  UPDATE public.customer_review_cycle_memberships m
  SET membership_status = 'expired',
      status_updated_at = now()
  FROM public.customer_order_review_links l
  WHERE l.id = m.review_link_id
    AND l.order_id = p_order_id
    AND l.expires_at IS NOT NULL
    AND l.expires_at <= now()
    AND m.membership_status = 'active';

  IF EXISTS (
    SELECT 1
    FROM public.customer_review_cycle_legacy_issues i
    WHERE i.order_id = p_order_id
      AND i.resolved_at IS NULL
  ) THEN
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_order_review_links l
    WHERE l.order_id = p_order_id
      AND l.is_active = true
      AND l.expires_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = l.id
      )
  ) THEN
    RETURN 0;
  END IF;

  FOR v_deadline IN
    SELECT DISTINCT c.expires_at
    FROM public.customer_review_cycle_candidates_v1(p_order_id) c
    ORDER BY c.expires_at
  LOOP
    INSERT INTO public.customer_order_review_links (
      order_id,
      is_active,
      expires_at,
      created_by_staff_id
    )
    VALUES (
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
      package_or_tracking_identity,
      review_qty,
      review_value_gbp,
      receipt_recorded_at,
      membership_status,
      membership_fingerprint,
      legacy_backfill_yn,
      created_by_staff_id
    )
    SELECT
      v_link_id,
      c.order_id,
      c.supplier_invoice_id,
      c.supplier_invoice_line_id,
      c.tracking_submission_id,
      c.tracking_line_allocation_id,
      c.package_or_tracking_identity,
      c.review_qty,
      c.review_value_gbp,
      c.receipt_recorded_at,
      'active',
      md5(v_link_id::text || '|' || c.membership_fingerprint),
      false,
      p_created_by_staff_id
    FROM public.customer_review_cycle_candidates_v1(p_order_id) c
    WHERE c.expires_at = v_deadline;

    IF NOT FOUND THEN
      DELETE FROM public.customer_order_review_links
      WHERE id = v_link_id;
    ELSE
      v_created := v_created + 1;
    END IF;
  END LOOP;

  RETURN v_created;
END;
$$;

REVOKE ALL ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
  TO service_role;

DO $$
DECLARE
  r record;
  v_inserted integer;
BEGIN
  /*
   * Existing timed links are frozen conservatively from facts that existed no
   * later than the link creation timestamp. Later receipts, allocations and
   * supplier lines are never attached to the old token.
   *
   * Legacy untimed links retain their established dynamic compatibility route;
   * no retrospective 24-hour deadline or guessed membership is created.
   */
  FOR r IN
    SELECT l.*
    FROM public.customer_order_review_links l
    WHERE l.expires_at IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = l.id
      )
    ORDER BY l.order_id, l.created_at, l.id
  LOOP
    INSERT INTO public.customer_review_cycle_memberships (
      review_link_id,
      order_id,
      supplier_invoice_id,
      supplier_invoice_line_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      package_or_tracking_identity,
      review_qty,
      review_value_gbp,
      receipt_recorded_at,
      membership_status,
      membership_fingerprint,
      legacy_backfill_yn,
      created_by_staff_id
    )
    SELECT
      r.id,
      r.order_id,
      sil.supplier_invoice_id,
      otla.supplier_invoice_line_id,
      ots.id,
      otla.id,
      ('tracking:' || ots.id::text)::text,
      ROUND(COALESCE(otla.qty_allocated, 0), 3),
      ROUND(COALESCE(otla.adjusted_net_value_gbp, 0), 2),
      historical_receipt.recorded_at,
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.customer_sales_release_lines release_line
          WHERE release_line.tracking_line_allocation_id = otla.id
            AND release_line.release_status = 'active'
        ) THEN 'released'
        WHEN r.is_active = true AND r.expires_at > now() THEN 'active'
        ELSE 'expired'
      END,
      md5(concat_ws(
        '|',
        'customer_review_cycle_legacy_as_of_link_v1',
        r.id,
        r.order_id,
        sil.supplier_invoice_id,
        otla.supplier_invoice_line_id,
        ots.id,
        otla.id,
        ROUND(COALESCE(otla.qty_allocated, 0), 3),
        ROUND(COALESCE(otla.adjusted_net_value_gbp, 0), 2),
        historical_receipt.recorded_at
      )),
      true,
      r.created_by_staff_id
    FROM public.order_tracking_submissions ots
    JOIN LATERAL (
      SELECT spr.receipt_status, spr.recorded_at
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = ots.id
        AND spr.created_at <= r.created_at
        AND spr.recorded_at <= r.created_at
      ORDER BY spr.created_at DESC, spr.id DESC
      LIMIT 1
    ) historical_receipt ON true
    JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = r.order_id
     AND otla.tracking_submission_id = ots.id
     AND otla.created_at <= r.created_at
     AND COALESCE(otla.qty_allocated, 0) > 0
    JOIN public.supplier_invoice_lines sil
      ON sil.id = otla.supplier_invoice_line_id
     AND sil.created_at <= r.created_at
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = r.order_id
     AND si.uploaded_at <= r.created_at
    WHERE ots.order_id = r.order_id
      AND ots.superseded_at IS NULL
      AND historical_receipt.receipt_status = 'received_clean'
      AND historical_receipt.recorded_at <= r.created_at
      AND historical_receipt.recorded_at + interval '24 hours' >= r.created_at
      AND COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, ''))
        IN ('y','yes','true','1')
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships prior_m
        WHERE prior_m.order_id = r.order_id
          AND prior_m.tracking_line_allocation_id = otla.id
      )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
      INSERT INTO public.customer_review_cycle_legacy_issues (
        review_link_id,
        order_id,
        issue_code,
        issue_detail
      )
      VALUES (
        r.id,
        r.order_id,
        'timed_legacy_membership_unproven',
        'The pre-Mini-4 timed review link and original expires_at were preserved, but exact as-of-link source membership could not be proven without using later facts.'
      )
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  INSERT INTO public.customer_review_cycle_legacy_issues (
    review_link_id,
    order_id,
    issue_code,
    issue_detail
  )
  SELECT
    l.id,
    l.order_id,
    'multiple_active_untimed_legacy_links',
    'More than one active untimed legacy review link exists for the order; compatibility is preserved but shipment and release fail closed until staff resolve the ambiguity.'
  FROM public.customer_order_review_links l
  WHERE l.is_active = true
    AND l.expires_at IS NULL
    AND (
      SELECT COUNT(*)
      FROM public.customer_order_review_links sibling
      WHERE sibling.order_id = l.order_id
        AND sibling.is_active = true
        AND sibling.expires_at IS NULL
    ) > 1
  ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_line_has_active_hold_conflict_v1(
  p_order_id uuid,
  p_tracking_submission_id uuid,
  p_supplier_invoice_line_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = p_order_id
        AND h.status IN ('requested','supervisor_approved')
        AND (
          h.requested_scope = 'order'
          OR (
            h.requested_scope = 'tracking'
            AND h.tracking_submission_id = p_tracking_submission_id
          )
          OR (
            h.requested_scope = 'line'
            AND h.supplier_invoice_line_id = p_supplier_invoice_line_id
          )
        )
    )
    OR EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_legacy_issues issue
      WHERE issue.order_id = p_order_id
        AND issue.resolved_at IS NULL
    );
$$;

COMMENT ON FUNCTION public.customer_line_has_active_hold_conflict_v1(uuid,uuid,uuid) IS
'Existing exact hold conflict truth extended only with the Mini 4 fail-closed unresolved historical review blocker. Existing shipment candidate, direct-create and package-preview consumers remain authoritative.';

REVOKE ALL ON FUNCTION
  public.customer_line_has_active_hold_conflict_v1(uuid,uuid,uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.customer_line_has_active_hold_conflict_v1(uuid,uuid,uuid)
  TO authenticated, service_role;

DO $$
BEGIN
  IF to_regprocedure(
    'public.internal_customer_sales_release_sources_pre_mini4_v1(uuid)'
  ) IS NULL THEN
    IF to_regprocedure(
      'public.internal_customer_sales_release_sources_v1(uuid)'
    ) IS NULL THEN
      RAISE EXCEPTION
        'Mini 4 prerequisite missing: internal_customer_sales_release_sources_v1(uuid)';
    END IF;

    ALTER FUNCTION public.internal_customer_sales_release_sources_v1(uuid)
      RENAME TO internal_customer_sales_release_sources_pre_mini4_v1;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_customer_sales_release_sources_v1(
  p_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  importer_id uuid,
  importer_name text,
  shipper_id uuid,
  shipper_name text,
  commercial_parent_order_id uuid,
  source_order_id uuid,
  order_ref text,
  tracking_submission_id uuid,
  tracking_ref text,
  tracking_line_allocation_id uuid,
  supplier_invoice_id uuid,
  supplier_invoice_line_id uuid,
  item_description text,
  release_qty numeric,
  goods_amount_gbp numeric,
  delivery_share_gbp numeric,
  discount_share_gbp numeric,
  shipping_amount_gbp numeric,
  customer_charge_amount_gbp numeric,
  proposed_invoice_type text,
  sales_invoice_state text,
  membership_fingerprint text,
  blocker text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    source_row.shipment_batch_id,
    source_row.booking_ref,
    source_row.importer_id,
    source_row.importer_name,
    source_row.shipper_id,
    source_row.shipper_name,
    source_row.commercial_parent_order_id,
    source_row.source_order_id,
    source_row.order_ref,
    source_row.tracking_submission_id,
    source_row.tracking_ref,
    source_row.tracking_line_allocation_id,
    source_row.supplier_invoice_id,
    source_row.supplier_invoice_line_id,
    source_row.item_description,
    source_row.release_qty,
    source_row.goods_amount_gbp,
    source_row.delivery_share_gbp,
    source_row.discount_share_gbp,
    source_row.shipping_amount_gbp,
    source_row.customer_charge_amount_gbp,
    source_row.proposed_invoice_type,
    source_row.sales_invoice_state,
    source_row.membership_fingerprint,
    CASE
      WHEN source_row.blocker IS NOT NULL THEN source_row.blocker
      WHEN EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_legacy_issues issue
        WHERE issue.resolved_at IS NULL
          AND issue.order_id IN (
            source_row.source_order_id,
            source_row.commercial_parent_order_id
          )
      ) THEN 'customer_review_cycle_legacy_membership_unresolved'
      ELSE NULL
    END::text AS blocker
  FROM public.internal_customer_sales_release_sources_pre_mini4_v1(
    p_batch_id
  ) source_row;
$$;

REVOKE ALL ON FUNCTION
  public.internal_customer_sales_release_sources_pre_mini4_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.internal_customer_sales_release_sources_pre_mini4_v1(uuid)
  TO service_role;

REVOKE ALL ON FUNCTION
  public.internal_customer_sales_release_sources_v1(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.internal_customer_sales_release_sources_v1(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.customer_review_legacy_block_release_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.release_status = 'active'
     AND EXISTS (
       SELECT 1
       FROM public.customer_review_cycle_legacy_issues issue
       WHERE issue.resolved_at IS NULL
         AND issue.order_id IN (
           NEW.order_id,
           NEW.commercial_parent_order_id
         )
     )
  THEN
    RAISE EXCEPTION
      'Customer sales release blocked: historical customer review membership is unresolved for this order.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_review_legacy_block_release_v1
  ON public.customer_sales_release_lines;
CREATE TRIGGER trg_customer_review_legacy_block_release_v1
BEFORE INSERT OR UPDATE OF
  release_status,
  order_id,
  commercial_parent_order_id
ON public.customer_sales_release_lines
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_legacy_block_release_v1();

CREATE OR REPLACE FUNCTION public.internal_resolve_customer_review_cycle_legacy_issue_v1(
  p_issue_id uuid,
  p_resolution_note text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION
      'Active staff required to resolve historical review membership.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_resolution_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Resolution note is required.';
  END IF;

  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  UPDATE public.customer_review_cycle_legacy_issues issue
  SET resolved_at = now(),
      resolved_by_staff_id = v_staff_id,
      resolution_note = BTRIM(p_resolution_note)
  WHERE issue.id = p_issue_id
    AND issue.resolved_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Open customer review legacy issue not found: %',
      p_issue_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION
  public.internal_resolve_customer_review_cycle_legacy_issue_v1(uuid,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.internal_resolve_customer_review_cycle_legacy_issue_v1(uuid,text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_review_ready_line_ids_v1(
  p_order_id uuid
)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  tracking_submission_id uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH frozen AS (
    SELECT DISTINCT
      m.supplier_invoice_line_id,
      m.tracking_submission_id
    FROM public.customer_review_cycle_memberships m
    JOIN public.customer_order_review_links l
      ON l.id = m.review_link_id
    WHERE m.order_id = p_order_id
      AND l.is_active = true
      AND (l.expires_at IS NULL OR l.expires_at > now())
      AND m.membership_status = 'active'
  ),
  legacy_dynamic AS (
    SELECT DISTINCT
      otla.supplier_invoice_line_id,
      ots.id AS tracking_submission_id
    FROM public.customer_order_review_links l
    JOIN public.order_tracking_submissions ots
      ON ots.order_id = l.order_id
     AND ots.superseded_at IS NULL
    JOIN LATERAL (
      SELECT spr.receipt_status, spr.recorded_at
      FROM public.shipper_package_receipts spr
      WHERE spr.tracking_submission_id = ots.id
      ORDER BY spr.created_at DESC, spr.id DESC
      LIMIT 1
    ) latest_receipt ON true
    JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = ots.order_id
     AND otla.tracking_submission_id = ots.id
     AND otla.supplier_invoice_line_id IS NOT NULL
     AND COALESCE(otla.qty_allocated, 0) > 0
    JOIN public.supplier_invoice_lines sil
      ON sil.id = otla.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = ots.order_id
    WHERE l.order_id = p_order_id
      AND l.is_active = true
      AND l.expires_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = l.id
      )
      AND latest_receipt.receipt_status = 'received_clean'
      AND COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  )
  SELECT * FROM frozen
  UNION
  SELECT * FROM legacy_dynamic;
$$;

CREATE OR REPLACE FUNCTION public.customer_active_order_review_link_v1(
  p_order_id uuid
)
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

  SELECT o.importer_id
  INTO v_importer_id
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators op
    JOIN public.operator_importers oi
      ON oi.operator_id = op.id
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
      AND oi.revoked_at IS NULL
      AND oi.importer_id = v_importer_id
  ) THEN
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;

  PERFORM public.internal_materialize_customer_review_cycles_v1(
    p_order_id,
    NULL
  );

  SELECT l.secure_token
  INTO v_token
  FROM public.customer_order_review_links l
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
    AND (
      EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = l.id
          AND m.membership_status = 'active'
      )
      OR (
        l.expires_at IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM public.customer_review_cycle_memberships m
          WHERE m.review_link_id = l.id
        )
      )
    )
  ORDER BY l.expires_at ASC NULLS LAST, l.created_at ASC, l.id ASC
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

CREATE OR REPLACE FUNCTION public.internal_create_customer_order_review_link_v1(
  p_order_id uuid
)
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

  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION
      'Active staff account required to create customer review link.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.orders o WHERE o.id = p_order_id
  ) THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  PERFORM public.internal_materialize_customer_review_cycles_v1(
    p_order_id,
    v_staff_id
  );

  SELECT l.secure_token
  INTO v_token
  FROM public.customer_order_review_links l
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
    AND (
      EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = l.id
          AND m.membership_status = 'active'
      )
      OR (
        l.expires_at IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM public.customer_review_cycle_memberships m
          WHERE m.review_link_id = l.id
        )
      )
    )
  ORDER BY l.expires_at ASC NULLS LAST, l.created_at ASC, l.id ASC
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

CREATE OR REPLACE FUNCTION public.customer_pre_shipment_hold_review_v1(
  p_secure_token text
)
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
  SELECT l.id, l.order_id, l.expires_at
  INTO v_link_id, v_order_id, v_expires_at
  FROM public.customer_order_review_links l
  WHERE l.secure_token = p_secure_token
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Customer review link is invalid or expired.';
  END IF;

  UPDATE public.customer_order_review_links
  SET last_used_at = now()
  WHERE id = v_link_id;

  SELECT jsonb_build_object(
    'order', jsonb_build_object(
      'id', o.id,
      'order_ref', o.order_ref,
      'retailer_name', r.name,
      'status', o.status,
      'order_type', o.order_type,
      'total_qty_declared', o.total_qty_declared,
      'review_link_id', v_link_id,
      'review_expires_at', v_expires_at
    ),
    'tracking', '[]'::jsonb,
    'lines', COALESCE((
      WITH frozen_lines AS (
        SELECT
          m.id AS review_membership_id,
          m.supplier_invoice_line_id,
          m.tracking_submission_id,
          m.tracking_line_allocation_id,
          m.review_qty,
          m.review_value_gbp,
          m.package_or_tracking_identity
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = v_link_id
          AND m.membership_status = 'active'
      ),
      legacy_lines AS (
        SELECT
          NULL::uuid AS review_membership_id,
          rl.supplier_invoice_line_id,
          rl.tracking_submission_id,
          NULL::uuid AS tracking_line_allocation_id,
          COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS review_qty,
          COALESCE(
            sil.amount_confirmed,
            sil.amount_inc_vat_gbp,
            0
          )::numeric AS review_value_gbp,
          ('tracking:' || rl.tracking_submission_id::text)::text
            AS package_or_tracking_identity
        FROM public.customer_review_ready_line_ids_v1(o.id) rl
        JOIN public.supplier_invoice_lines sil
          ON sil.id = rl.supplier_invoice_line_id
        WHERE v_expires_at IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.customer_review_cycle_memberships m
            WHERE m.review_link_id = v_link_id
          )
      ),
      review_lines AS (
        SELECT * FROM frozen_lines
        UNION ALL
        SELECT * FROM legacy_lines
      )
      SELECT jsonb_agg(jsonb_build_object(
        'id', sil.id,
        'review_membership_id', rl.review_membership_id,
        'description', sil.description,
        'size', sil.size,
        'retailer_sku', sil.retailer_sku,
        'qty', rl.review_qty,
        'amount_inc_vat_gbp', rl.review_value_gbp,
        'tracking_submission_id', rl.tracking_submission_id,
        'tracking_line_allocation_id', rl.tracking_line_allocation_id,
        'package_or_tracking_identity', rl.package_or_tracking_identity,
        'eligible_for_invoice_yn', sil.eligible_for_invoice_yn
      ) ORDER BY sil.created_at NULLS LAST, sil.id)
      FROM review_lines rl
      JOIN public.supplier_invoice_lines sil
        ON sil.id = rl.supplier_invoice_line_id
    ), '[]'::jsonb),
    'holds', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', h.id,
        'review_link_id', h.review_link_id,
        'requested_scope', h.requested_scope,
        'tracking_submission_id', h.tracking_submission_id,
        'supplier_invoice_line_id', h.supplier_invoice_line_id,
        'narrowed_from_hold_request_id', h.narrowed_from_hold_request_id,
        'converted_dispute_id', h.converted_dispute_id,
        'status', h.status,
        'reason', h.reason,
        'created_at', h.created_at,
        'supervisor_review_note', h.supervisor_review_note
      ) ORDER BY h.created_at DESC)
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = o.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.orders o
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  WHERE o.id = v_order_id;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_dashboard_review_cards_v1()
RETURNS TABLE (
  order_id uuid,
  customer_review_path text,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_review_path text;
  v_expires_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  FOR v_order_id IN
    SELECT DISTINCT o.id
    FROM public.orders o
    JOIN public.operator_importers oi
      ON oi.importer_id = o.importer_id
     AND oi.revoked_at IS NULL
    JOIN public.operators op
      ON op.id = oi.operator_id
     AND op.auth_user_id = auth.uid()
     AND COALESCE(op.active, true) = true
  LOOP
    v_review_path := NULL;
    v_expires_at := NULL;

    SELECT active_link.customer_review_path
    INTO v_review_path
    FROM public.customer_active_order_review_link_v1(v_order_id) active_link
    LIMIT 1;

    IF v_review_path IS NULL THEN
      CONTINUE;
    END IF;

    SELECT l.expires_at
    INTO v_expires_at
    FROM public.customer_order_review_links l
    WHERE l.order_id = v_order_id
      AND l.is_active = true
      AND ('/customer/orders/' || l.secure_token || '/review') = v_review_path
    LIMIT 1;

    IF v_expires_at IS NULL OR v_expires_at <= now() THEN
      CONTINUE;
    END IF;

    order_id := v_order_id;
    customer_review_path := v_review_path;
    expires_at := v_expires_at;
    RETURN NEXT;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_close_order_review_links_for_invoice_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  /*
   * Mini 4: creating an unrelated main or supplementary document must not
   * close every active review cycle on the order. Exact membership lifecycle
   * is governed by the immutable cycle rows, holds, releases and expiry.
   */
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
  v_membership_count integer := 0;
  v_tracking_count integer := 0;
  v_tracking_id uuid;
BEGIN
  IF NEW.status <> 'requested'
     OR NEW.narrowed_from_hold_request_id IS NOT NULL
  THEN
    RETURN NEW;
  END IF;

  IF NEW.review_link_id IS NULL THEN
    RAISE EXCEPTION
      'Customer hold must retain the exact customer review link.';
  END IF;

  SELECT *
  INTO v_link
  FROM public.customer_order_review_links l
  WHERE l.id = NEW.review_link_id
    AND l.order_id = NEW.order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now());

  IF v_link.id IS NULL THEN
    RAISE EXCEPTION
      'Customer hold is outside the active review cycle.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_membership_count
  FROM public.customer_review_cycle_memberships m
  WHERE m.review_link_id = NEW.review_link_id
    AND m.membership_status = 'active';

  IF v_membership_count = 0 AND v_link.expires_at IS NOT NULL THEN
    RAISE EXCEPTION
      'Timed review membership is unresolved; hold creation fails closed.';
  END IF;

  IF v_membership_count > 0 THEN
    IF NEW.requested_scope = 'order' THEN
      NULL;
    ELSIF NEW.requested_scope = 'tracking' THEN
      IF NEW.tracking_submission_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = NEW.review_link_id
          AND m.membership_status = 'active'
          AND m.tracking_submission_id = NEW.tracking_submission_id
      ) THEN
        RAISE EXCEPTION
          'Tracking hold target is not part of this immutable review cycle.';
      END IF;
    ELSIF NEW.requested_scope = 'line' THEN
      IF NEW.supplier_invoice_line_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = NEW.review_link_id
          AND m.membership_status = 'active'
          AND m.supplier_invoice_line_id = NEW.supplier_invoice_line_id
          AND (
            NEW.tracking_submission_id IS NULL
            OR m.tracking_submission_id = NEW.tracking_submission_id
          )
      ) THEN
        RAISE EXCEPTION
          'Line hold target is not part of this immutable review cycle.';
      END IF;

      IF NEW.tracking_submission_id IS NULL THEN
        SELECT
          COUNT(DISTINCT m.tracking_submission_id)::integer,
          MIN(m.tracking_submission_id::text)::uuid
        INTO v_tracking_count, v_tracking_id
        FROM public.customer_review_cycle_memberships m
        WHERE m.review_link_id = NEW.review_link_id
          AND m.membership_status = 'active'
          AND m.supplier_invoice_line_id = NEW.supplier_invoice_line_id;

        IF v_tracking_count = 1 THEN
          NEW.tracking_submission_id := v_tracking_id;
        ELSIF v_tracking_count > 1 THEN
          RAISE EXCEPTION
            'Line appears in more than one package in this review cycle; exact tracking target is required.';
        END IF;
      END IF;
    ELSE
      RAISE EXCEPTION 'Unsupported customer hold scope: %', NEW.requested_scope;
    END IF;
  ELSE
    /*
     * Legacy untimed compatibility only. The established order-wide function
     * remains available for links that pre-date the clean-receipt deadline.
     */
    IF NEW.requested_scope = 'tracking'
       AND NOT EXISTS (
         SELECT 1
         FROM public.customer_review_ready_line_ids_v1(NEW.order_id) rl
         WHERE rl.tracking_submission_id = NEW.tracking_submission_id
       )
    THEN
      RAISE EXCEPTION 'Legacy tracking hold target is not review-ready.';
    ELSIF NEW.requested_scope = 'line'
       AND NOT EXISTS (
         SELECT 1
         FROM public.customer_review_ready_line_ids_v1(NEW.order_id) rl
         WHERE rl.supplier_invoice_line_id = NEW.supplier_invoice_line_id
       )
    THEN
      RAISE EXCEPTION 'Legacy line hold target is not review-ready.';
    END IF;
  END IF;

  IF NEW.tracking_submission_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.shipper_shipment_batch_packages sbp
       WHERE sbp.tracking_submission_id = NEW.tracking_submission_id
         AND sbp.active = true
     )
  THEN
    RAISE EXCEPTION
      'Package is already in a shipment and cannot receive a new pre-shipment hold.';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_active_order_review_link_v1(uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_active_order_review_link_v1(uuid)
  TO authenticated;

REVOKE ALL ON FUNCTION public.internal_create_customer_order_review_link_v1(uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_create_customer_order_review_link_v1(uuid)
  TO authenticated;

REVOKE ALL ON FUNCTION public.customer_pre_shipment_hold_review_v1(text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_pre_shipment_hold_review_v1(text)
  TO anon, authenticated;

REVOKE ALL ON FUNCTION public.customer_dashboard_review_cards_v1()
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_dashboard_review_cards_v1()
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
