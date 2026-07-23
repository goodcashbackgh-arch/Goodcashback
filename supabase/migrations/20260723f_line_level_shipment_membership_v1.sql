BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shipper_shipment_batch_packages') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.customer_pre_shipment_hold_requests') IS NULL
  THEN
    RAISE EXCEPTION 'Line-level shipment membership prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.customer_line_has_active_hold_conflict_v1(uuid,uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite function missing: customer_line_has_active_hold_conflict_v1(uuid,uuid,uuid)';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.shipper_shipment_batch_line_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id) ON DELETE CASCADE,
  shipment_batch_package_id uuid NOT NULL REFERENCES public.shipper_shipment_batch_packages(id) ON DELETE CASCADE,
  tracking_submission_id uuid NOT NULL REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  tracking_line_allocation_id uuid NOT NULL REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  qty_in_shipment numeric(12,3) NOT NULL CHECK (qty_in_shipment > 0),
  adjusted_net_value_gbp numeric(14,2) NOT NULL DEFAULT 0 CHECK (adjusted_net_value_gbp >= 0),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shipper_batch_line_membership_identity_uq UNIQUE (
    shipment_batch_id,
    tracking_line_allocation_id
  )
);

COMMENT ON TABLE public.shipper_shipment_batch_line_memberships IS
'Immutable exact allocation-line membership for shipment batches. New batches snapshot only lines eligible at creation; legacy batches without rows use package-allocation compatibility fallback.';

CREATE INDEX IF NOT EXISTS idx_ssblm_batch_active
  ON public.shipper_shipment_batch_line_memberships(shipment_batch_id)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_ssblm_tracking_active
  ON public.shipper_shipment_batch_line_memberships(tracking_submission_id)
  WHERE active = true;

ALTER TABLE public.shipper_shipment_batch_line_memberships ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shipper_shipment_batch_line_memberships_select ON public.shipper_shipment_batch_line_memberships;
CREATE POLICY shipper_shipment_batch_line_memberships_select
ON public.shipper_shipment_batch_line_memberships
FOR SELECT TO authenticated
USING (
  public.is_active_staff()
  OR EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batches b
    JOIN public.shipper_users su ON su.shipper_id = b.shipper_id
    WHERE b.id = shipper_shipment_batch_line_memberships.shipment_batch_id
      AND su.auth_user_id = auth.uid()
      AND su.active = true
  )
);

REVOKE ALL ON public.shipper_shipment_batch_line_memberships FROM PUBLIC;
GRANT SELECT ON public.shipper_shipment_batch_line_memberships TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.shipper_shipment_batch_line_memberships TO service_role;

CREATE OR REPLACE FUNCTION public.shipper_block_shipment_line_membership_mutation_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Shipment line membership is immutable; deactivate the package membership or void the batch instead.';
  END IF;

  IF (to_jsonb(NEW) - 'active') IS DISTINCT FROM (to_jsonb(OLD) - 'active') THEN
    RAISE EXCEPTION 'Shipment line membership identity and values are immutable.';
  END IF;

  IF OLD.active = false AND NEW.active = true THEN
    RAISE EXCEPTION 'Inactive shipment line membership cannot be reactivated.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shipper_block_shipment_line_membership_mutation_v1
  ON public.shipper_shipment_batch_line_memberships;
CREATE TRIGGER trg_shipper_block_shipment_line_membership_mutation_v1
BEFORE UPDATE OR DELETE ON public.shipper_shipment_batch_line_memberships
FOR EACH ROW EXECUTE FUNCTION public.shipper_block_shipment_line_membership_mutation_v1();

-- Authoritative line scope for downstream shipment readers.
-- New batches use the immutable snapshot. Legacy batches with no snapshot rows
-- retain their former package-allocation behaviour.
CREATE OR REPLACE FUNCTION public.shipper_shipment_batch_effective_lines_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  shipment_batch_id uuid,
  shipment_batch_package_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  order_id uuid,
  supplier_invoice_line_id uuid,
  qty_in_shipment numeric,
  adjusted_net_value_gbp numeric,
  source_mode text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH snapshot_exists AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.shipment_batch_id = p_shipment_batch_id
    ) AS yes
  ), snapshot_lines AS (
    SELECT
      m.shipment_batch_id,
      m.shipment_batch_package_id,
      m.tracking_submission_id,
      m.tracking_line_allocation_id,
      m.order_id,
      m.supplier_invoice_line_id,
      m.qty_in_shipment,
      m.adjusted_net_value_gbp,
      'immutable_snapshot'::text AS source_mode
    FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = p_shipment_batch_id
      AND m.active = true
  ), legacy_lines AS (
    SELECT
      p.shipment_batch_id,
      p.id AS shipment_batch_package_id,
      p.tracking_submission_id,
      a.id AS tracking_line_allocation_id,
      a.order_id,
      a.supplier_invoice_line_id,
      COALESCE(a.qty_allocated, 0)::numeric AS qty_in_shipment,
      COALESCE(a.adjusted_net_value_gbp, 0)::numeric AS adjusted_net_value_gbp,
      'legacy_package_fallback'::text AS source_mode
    FROM public.shipper_shipment_batch_packages p
    JOIN public.order_tracking_line_allocations a
      ON a.tracking_submission_id = p.tracking_submission_id
     AND a.order_id = p.order_id
    CROSS JOIN snapshot_exists se
    WHERE p.shipment_batch_id = p_shipment_batch_id
      AND p.active = true
      AND se.yes = false
      AND COALESCE(a.qty_allocated, 0) > 0
  )
  SELECT * FROM snapshot_lines
  UNION ALL
  SELECT * FROM legacy_lines;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_effective_lines_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_effective_lines_v1(uuid) TO authenticated;

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
    RAISE EXCEPTION 'Unauthenticated user: shipment batch candidates require auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    v_shipper_user_id,
    s.id,
    s.name::text,
    o.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text,
    o.id,
    o.order_ref::text,
    r.name::text,
    ots.id,
    c.name::text,
    ots.tracking_ref::text,
    ots.tracking_date::text,
    eligible.allocated_qty,
    eligible.allocated_net_value_gbp,
    latest_receipt.receipt_status::text,
    latest_receipt.recorded_at
  FROM public.orders o
  JOIN public.shippers s ON s.id = o.shipper_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  JOIN public.order_tracking_submissions ots
    ON ots.order_id = o.id
   AND ots.superseded_at IS NULL
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  JOIN LATERAL (
    SELECT
      SUM(COALESCE(a.qty_allocated, 0))::numeric AS allocated_qty,
      SUM(COALESCE(a.adjusted_net_value_gbp, 0))::numeric AS allocated_net_value_gbp
    FROM public.order_tracking_line_allocations a
    WHERE a.order_id = o.id
      AND a.tracking_submission_id = ots.id
      AND COALESCE(a.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        a.order_id,
        a.tracking_submission_id,
        a.supplier_invoice_line_id
      ) IS DISTINCT FROM true
  ) eligible ON COALESCE(eligible.allocated_qty, 0) > 0
  JOIN LATERAL (
    SELECT spr.receipt_status, spr.recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = ots.id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1
  ) latest_receipt ON true
  LEFT JOIN public.shipper_shipment_batch_packages existing_link
    ON existing_link.tracking_submission_id = ots.id
   AND existing_link.active = true
  WHERE o.shipper_id = v_shipper_id
    AND latest_receipt.receipt_status = 'received_clean'
    AND now() >= latest_receipt.recorded_at + interval '24 hours'
    AND existing_link.id IS NULL
  ORDER BY i.company_name NULLS LAST, o.created_at DESC, ots.tracking_date DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_shipment_batch_candidates_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_shipment_batch_candidates_v1() TO authenticated;

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
  v_eligible_count integer;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: create shipment batch requires auth.uid()';
  END IF;
  IF p_importer_id IS NULL THEN
    RAISE EXCEPTION 'Importer is required.';
  END IF;
  IF p_tracking_submission_ids IS NULL OR array_length(p_tracking_submission_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one received-clean package.';
  END IF;
  IF NULLIF(btrim(COALESCE(p_booking_ref, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Booking reference is required.';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  INSERT INTO public.shipper_shipment_batches (
    shipper_id, importer_id, created_by_shipper_user_id, booking_ref,
    shipment_cutoff_at, dispatched_at, box_count, container_ref, bol_ref, notes
  ) VALUES (
    v_shipper_id, p_importer_id, v_shipper_user_id, btrim(p_booking_ref),
    p_shipment_cutoff_at, p_dispatched_at, p_box_count,
    NULLIF(btrim(COALESCE(p_container_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_bol_ref, '')), ''),
    NULLIF(btrim(COALESCE(p_notes, '')), '')
  ) RETURNING id INTO v_batch_id;

  FOREACH v_tracking_id IN ARRAY p_tracking_submission_ids LOOP
    SELECT ots.order_id, o.shipper_id, o.importer_id
      INTO v_order_id, v_order_shipper_id, v_order_importer_id
    FROM public.order_tracking_submissions ots
    JOIN public.orders o ON o.id = ots.order_id
    WHERE ots.id = v_tracking_id
      AND ots.superseded_at IS NULL;

    IF v_order_id IS NULL THEN
      RAISE EXCEPTION 'Tracking/package not found: %', v_tracking_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(v_order_id::text));
    PERFORM pg_advisory_xact_lock(hashtext(v_tracking_id::text));

    IF v_order_shipper_id IS DISTINCT FROM v_shipper_id THEN
      RAISE EXCEPTION 'Tracking/package does not belong to this shipper: %', v_tracking_id;
    END IF;
    IF v_order_importer_id IS DISTINCT FROM p_importer_id THEN
      RAISE EXCEPTION 'All selected packages must belong to the selected importer.';
    END IF;

    SELECT spr.receipt_status, spr.recorded_at
      INTO v_latest_receipt_status, v_latest_receipt_recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = v_tracking_id
    ORDER BY spr.created_at DESC, spr.id DESC
    LIMIT 1;

    IF v_latest_receipt_status IS DISTINCT FROM 'received_clean' THEN
      RAISE EXCEPTION 'Only latest received-clean packages can be selected for shipment batch.';
    END IF;
    IF now() < v_latest_receipt_recorded_at + interval '24 hours' THEN
      RAISE EXCEPTION 'This package is inside the 24-hour customer review window and cannot yet be added to a shipment.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_packages p
      WHERE p.tracking_submission_id = v_tracking_id AND p.active = true
    ) THEN
      RAISE EXCEPTION 'This package is already in an active shipment batch.';
    END IF;

    SELECT COUNT(*)::integer
      INTO v_eligible_count
    FROM public.order_tracking_line_allocations a
    WHERE a.order_id = v_order_id
      AND a.tracking_submission_id = v_tracking_id
      AND COALESCE(a.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        a.order_id,
        a.tracking_submission_id,
        a.supplier_invoice_line_id
      ) IS DISTINCT FROM true;

    IF COALESCE(v_eligible_count, 0) = 0 THEN
      RAISE EXCEPTION 'This package has no shipment-eligible lines after active customer holds are applied.';
    END IF;

    INSERT INTO public.shipper_shipment_batch_packages (
      shipment_batch_id, tracking_submission_id, order_id, shipper_id,
      importer_id, selected_by_shipper_user_id
    ) VALUES (
      v_batch_id, v_tracking_id, v_order_id, v_shipper_id,
      p_importer_id, v_shipper_user_id
    ) RETURNING id INTO v_package_id;

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
      a.tracking_submission_id,
      a.id,
      a.order_id,
      a.supplier_invoice_line_id,
      a.qty_allocated,
      COALESCE(a.adjusted_net_value_gbp, 0)
    FROM public.order_tracking_line_allocations a
    WHERE a.order_id = v_order_id
      AND a.tracking_submission_id = v_tracking_id
      AND COALESCE(a.qty_allocated, 0) > 0
      AND public.customer_line_has_active_hold_conflict_v1(
        a.order_id,
        a.tracking_submission_id,
        a.supplier_invoice_line_id
      ) IS DISTINCT FROM true;
  END LOOP;

  RETURN v_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) TO authenticated;

-- Shipper preview follows the same scope before batching and the immutable
-- snapshot after batching. This makes held lines disappear while remaining
-- lines continue to show under the original received-clean tracking identity.
CREATE OR REPLACE FUNCTION public.shipper_package_contents_preview_v1(
  p_tracking_submission_id uuid DEFAULT NULL
)
RETURNS TABLE (
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  allocation_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: package contents preview requires auth.uid()';
  END IF;

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  WITH active_package AS (
    SELECT DISTINCT ON (p.tracking_submission_id)
      p.id AS package_id,
      p.shipment_batch_id,
      p.tracking_submission_id
    FROM public.shipper_shipment_batch_packages p
    JOIN public.shipper_shipment_batches b ON b.id = p.shipment_batch_id
    WHERE p.active = true AND b.status <> 'voided'
    ORDER BY p.tracking_submission_id, p.created_at DESC
  ), scoped AS (
    SELECT
      a.tracking_submission_id,
      a.order_id,
      a.supplier_invoice_line_id,
      a.qty_allocated,
      a.allocation_status::text,
      ap.package_id,
      ap.shipment_batch_id,
      EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_line_memberships x
        WHERE x.shipment_batch_id = ap.shipment_batch_id
      ) AS has_snapshot
    FROM public.order_tracking_line_allocations a
    LEFT JOIN active_package ap ON ap.tracking_submission_id = a.tracking_submission_id
    WHERE COALESCE(a.qty_allocated, 0) > 0
      AND (
        ap.package_id IS NULL
        AND public.customer_line_has_active_hold_conflict_v1(
          a.order_id, a.tracking_submission_id, a.supplier_invoice_line_id
        ) IS DISTINCT FROM true
        OR ap.package_id IS NOT NULL
        AND (
          NOT EXISTS (
            SELECT 1 FROM public.shipper_shipment_batch_line_memberships any_m
            WHERE any_m.shipment_batch_id = ap.shipment_batch_id
          )
          OR EXISTS (
            SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
            WHERE m.shipment_batch_id = ap.shipment_batch_id
              AND m.tracking_line_allocation_id = a.id
              AND m.active = true
          )
        )
      )
  )
  SELECT
    ots.id,
    o.id,
    o.order_ref::text,
    r.name::text,
    c.name::text,
    ots.tracking_ref::text,
    sil.id,
    COALESCE(NULLIF(btrim(sil.description), ''), 'Unlabelled item')::text,
    s.qty_allocated,
    s.allocation_status
  FROM scoped s
  JOIN public.order_tracking_submissions ots ON ots.id = s.tracking_submission_id
  JOIN public.orders o ON o.id = s.order_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  JOIN public.supplier_invoice_lines sil ON sil.id = s.supplier_invoice_line_id
  WHERE o.shipper_id = v_shipper_id
    AND ots.superseded_at IS NULL
    AND (p_tracking_submission_id IS NULL OR ots.id = p_tracking_submission_id)
  ORDER BY o.order_ref NULLS LAST, ots.tracking_date NULLS LAST, sil.line_order NULLS LAST, sil.description;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_package_contents_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_package_contents_preview_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
