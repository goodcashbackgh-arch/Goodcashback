-- =============================================================================
-- 20260510_shipper_shipment_batches_v1.sql
-- Multi Tenant Platform Build — shipper shipment batch selection
--
-- Purpose:
--   Let shipper users group received-clean tracking refs/packages into an
--   importer-level shipment batch using booking ref, dispatch date, box count
--   and optional container/BOL references.
--
-- Scope:
--   Package/shipment truth only. No COS generation, no Sage, no VAT clearance,
--   no shipping apportionment, and no item-content lock.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TABLE IF NOT EXISTS public.shipper_shipment_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  importer_id uuid NOT NULL REFERENCES public.importers(id),
  created_by_shipper_user_id uuid NOT NULL REFERENCES public.shipper_users(id),
  booking_ref varchar NOT NULL,
  shipment_cutoff_at timestamptz,
  dispatched_at timestamptz,
  box_count integer,
  container_ref varchar,
  bol_ref varchar,
  notes text,
  status varchar NOT NULL DEFAULT 'created' CHECK (status IN ('created','voided')),
  created_at timestamptz NOT NULL DEFAULT now(),
  voided_at timestamptz,
  voided_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  void_reason text
);

COMMENT ON TABLE public.shipper_shipment_batches IS
'Importer-level package shipment batch selected by shipper from received-clean tracking refs. Does not create COS/Sage/VAT effects.';

CREATE INDEX IF NOT EXISTS idx_shipper_shipment_batches_shipper_created
  ON public.shipper_shipment_batches(shipper_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_shipper_shipment_batches_importer_created
  ON public.shipper_shipment_batches(importer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.shipper_shipment_batch_packages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id) ON DELETE CASCADE,
  tracking_submission_id uuid NOT NULL REFERENCES public.order_tracking_submissions(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  importer_id uuid NOT NULL REFERENCES public.importers(id),
  selected_by_shipper_user_id uuid NOT NULL REFERENCES public.shipper_users(id),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  removed_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  remove_reason text
);

COMMENT ON TABLE public.shipper_shipment_batch_packages IS
'Package/tracking refs included in a shipper shipment batch. Package-level logistics truth only.';

CREATE INDEX IF NOT EXISTS idx_shipper_shipment_batch_packages_batch
  ON public.shipper_shipment_batch_packages(shipment_batch_id);

CREATE INDEX IF NOT EXISTS idx_shipper_shipment_batch_packages_tracking
  ON public.shipper_shipment_batch_packages(tracking_submission_id);

CREATE UNIQUE INDEX IF NOT EXISTS ux_shipper_shipment_batch_packages_active_tracking
  ON public.shipper_shipment_batch_packages(tracking_submission_id)
  WHERE active = true;

ALTER TABLE public.shipper_shipment_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipper_shipment_batch_packages ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'shipper_shipment_batches'
      AND policyname = 'shipper_shipment_batches_shipper_select'
  ) THEN
    CREATE POLICY shipper_shipment_batches_shipper_select
    ON public.shipper_shipment_batches
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = shipper_shipment_batches.shipper_id
      )
      OR is_active_staff()
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'shipper_shipment_batch_packages'
      AND policyname = 'shipper_shipment_batch_packages_shipper_select'
  ) THEN
    CREATE POLICY shipper_shipment_batch_packages_shipper_select
    ON public.shipper_shipment_batch_packages
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = shipper_shipment_batch_packages.shipper_id
      )
      OR is_active_staff()
    );
  END IF;
END $$;

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
    v_shipper_user_id AS shipper_user_id,
    s.id AS shipper_id,
    s.name::text AS shipper_name,
    o.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text AS importer_name,
    o.id AS order_id,
    o.order_ref::text AS order_ref,
    r.name::text AS retailer_name,
    ots.id AS tracking_submission_id,
    c.name::text AS courier_name,
    ots.tracking_ref::text AS tracking_ref,
    ots.tracking_date::text AS tracking_date,
    COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
    COALESCE(alloc.allocated_net_value_gbp, 0::numeric) AS allocated_net_value_gbp,
    latest_receipt.receipt_status::text AS latest_receipt_status,
    latest_receipt.recorded_at AS latest_receipt_recorded_at
  FROM public.orders o
  JOIN public.shippers s ON s.id = o.shipper_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  JOIN public.order_tracking_submissions ots
    ON ots.order_id = o.id
   AND ots.superseded_at IS NULL
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  LEFT JOIN LATERAL (
    SELECT SUM(otla.qty_allocated) AS allocated_qty,
           SUM(otla.adjusted_net_value_gbp) AS allocated_net_value_gbp
    FROM public.order_tracking_line_allocations otla
    WHERE otla.order_id = o.id
      AND otla.tracking_submission_id = ots.id
  ) alloc ON true
  LEFT JOIN LATERAL (
    SELECT spr.receipt_status, spr.recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = ots.id
    ORDER BY spr.created_at DESC
    LIMIT 1
  ) latest_receipt ON true
  LEFT JOIN public.shipper_shipment_batch_packages existing_link
    ON existing_link.tracking_submission_id = ots.id
   AND existing_link.active = true
  WHERE o.shipper_id = v_shipper_id
    AND latest_receipt.receipt_status = 'received_clean'
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
  v_tracking_id uuid;
  v_order_id uuid;
  v_order_shipper_id uuid;
  v_order_importer_id uuid;
  v_latest_receipt_status text;
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

  IF NULLIF(BTRIM(COALESCE(p_booking_ref, '')), '') IS NULL THEN
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
    BTRIM(p_booking_ref),
    p_shipment_cutoff_at,
    p_dispatched_at,
    p_box_count,
    NULLIF(BTRIM(COALESCE(p_container_ref, '')), ''),
    NULLIF(BTRIM(COALESCE(p_bol_ref, '')), ''),
    NULLIF(BTRIM(COALESCE(p_notes, '')), '')
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

    IF v_order_shipper_id IS DISTINCT FROM v_shipper_id THEN
      RAISE EXCEPTION 'Tracking/package does not belong to this shipper: %', v_tracking_id;
    END IF;

    IF v_order_importer_id IS DISTINCT FROM p_importer_id THEN
      RAISE EXCEPTION 'All selected packages must belong to the selected importer.';
    END IF;

    SELECT spr.receipt_status
      INTO v_latest_receipt_status
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = v_tracking_id
    ORDER BY spr.created_at DESC
    LIMIT 1;

    IF v_latest_receipt_status IS DISTINCT FROM 'received_clean' THEN
      RAISE EXCEPTION 'Only latest received-clean packages can be selected for shipment batch.';
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
    );
  END LOOP;

  RETURN v_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
