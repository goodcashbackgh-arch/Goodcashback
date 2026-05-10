-- =============================================================================
-- 20260510_shipper_package_receipts_no_dashboard_replace.sql
-- Multi Tenant Platform Build — shipper package receipt controls, safe variant
--
-- Purpose:
--   Add package receipt table/RPC and a receipt-specific dashboard RPC without
--   changing the return type of the existing shipper_package_dashboard_v1().
--
-- IMPORTANT:
--   Do not replace shipper_package_dashboard_v1() here. PostgreSQL does not
--   allow changing OUT return columns with CREATE OR REPLACE FUNCTION.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TABLE IF NOT EXISTS public.shipper_package_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tracking_submission_id uuid NOT NULL REFERENCES public.order_tracking_submissions(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  shipper_user_id uuid NOT NULL REFERENCES public.shipper_users(id),
  receipt_status varchar NOT NULL CHECK (receipt_status IN (
    'received_clean',
    'received_damaged',
    'held_query',
    'not_received'
  )),
  condition_note text,
  evidence_url text,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.shipper_package_receipts IS
'Package-level shipper receipt/condition history for tracking refs. Does not lock item-content allocation.';

CREATE INDEX IF NOT EXISTS idx_shipper_package_receipts_tracking_created
  ON public.shipper_package_receipts(tracking_submission_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_shipper_package_receipts_shipper_created
  ON public.shipper_package_receipts(shipper_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_shipper_package_receipts_order
  ON public.shipper_package_receipts(order_id);

ALTER TABLE public.shipper_package_receipts ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'shipper_package_receipts'
      AND policyname = 'shipper_package_receipts_shipper_select'
  ) THEN
    CREATE POLICY shipper_package_receipts_shipper_select
    ON public.shipper_package_receipts
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = shipper_package_receipts.shipper_id
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
      AND tablename = 'shipper_package_receipts'
      AND policyname = 'shipper_package_receipts_staff_all'
  ) THEN
    CREATE POLICY shipper_package_receipts_staff_all
    ON public.shipper_package_receipts
    FOR ALL
    TO authenticated
    USING (is_active_staff())
    WITH CHECK (is_active_staff());
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_record_package_receipt_v1(
  p_tracking_submission_id uuid,
  p_receipt_status text,
  p_condition_note text DEFAULT NULL,
  p_evidence_url text DEFAULT NULL
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
  v_order_id uuid;
  v_order_shipper_id uuid;
  v_receipt_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper package receipt requires auth.uid()';
  END IF;

  IF p_receipt_status NOT IN ('received_clean','received_damaged','held_query','not_received') THEN
    RAISE EXCEPTION 'Invalid package receipt status: %', p_receipt_status;
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

  SELECT ots.order_id, o.shipper_id
    INTO v_order_id, v_order_shipper_id
  FROM public.order_tracking_submissions ots
  JOIN public.orders o ON o.id = ots.order_id
  WHERE ots.id = p_tracking_submission_id
    AND ots.superseded_at IS NULL;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Tracking/package record not found or superseded.';
  END IF;

  IF v_order_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Tracking/package does not belong to this shipper.';
  END IF;

  INSERT INTO public.shipper_package_receipts (
    tracking_submission_id,
    order_id,
    shipper_id,
    shipper_user_id,
    receipt_status,
    condition_note,
    evidence_url
  ) VALUES (
    p_tracking_submission_id,
    v_order_id,
    v_shipper_id,
    v_shipper_user_id,
    p_receipt_status,
    NULLIF(BTRIM(COALESCE(p_condition_note, '')), ''),
    NULLIF(BTRIM(COALESCE(p_evidence_url, '')), '')
  )
  RETURNING id INTO v_receipt_id;

  RETURN v_receipt_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_record_package_receipt_v1(uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_record_package_receipt_v1(uuid,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_package_receipt_dashboard_v1()
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
  submitted_at timestamptz,
  is_final_delivery_yn boolean,
  tracking_evidence_url text,
  tracking_note text,
  allocated_qty numeric,
  allocated_net_value_gbp numeric,
  allocation_status_summary text,
  latest_receipt_status text,
  latest_receipt_note text,
  latest_receipt_evidence_url text,
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
    RAISE EXCEPTION 'Unauthenticated user: shipper receipt dashboard requires auth.uid()';
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
    ots.submitted_at,
    ots.is_final_delivery_yn,
    ots.tracking_screenshot_url::text AS tracking_evidence_url,
    ots.note::text AS tracking_note,
    COALESCE(alloc.allocated_qty, 0::numeric) AS allocated_qty,
    COALESCE(alloc.allocated_net_value_gbp, 0::numeric) AS allocated_net_value_gbp,
    COALESCE(alloc.status_summary, 'not_allocated')::text AS allocation_status_summary,
    latest_receipt.receipt_status::text AS latest_receipt_status,
    latest_receipt.condition_note::text AS latest_receipt_note,
    latest_receipt.evidence_url::text AS latest_receipt_evidence_url,
    latest_receipt.recorded_at AS latest_receipt_recorded_at
  FROM public.orders o
  JOIN public.shippers s ON s.id = o.shipper_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.order_tracking_submissions ots
    ON ots.order_id = o.id
   AND ots.superseded_at IS NULL
  LEFT JOIN public.couriers c ON c.id = ots.courier_id
  LEFT JOIN LATERAL (
    SELECT
      SUM(otla.qty_allocated) AS allocated_qty,
      SUM(otla.adjusted_net_value_gbp) AS allocated_net_value_gbp,
      string_agg(DISTINCT otla.allocation_status, ', ' ORDER BY otla.allocation_status) AS status_summary
    FROM public.order_tracking_line_allocations otla
    WHERE otla.order_id = o.id
      AND otla.tracking_submission_id = ots.id
  ) alloc ON ots.id IS NOT NULL
  LEFT JOIN LATERAL (
    SELECT spr.receipt_status, spr.condition_note, spr.evidence_url, spr.recorded_at
    FROM public.shipper_package_receipts spr
    WHERE spr.tracking_submission_id = ots.id
    ORDER BY spr.created_at DESC
    LIMIT 1
  ) latest_receipt ON ots.id IS NOT NULL
  WHERE o.shipper_id = v_shipper_id
  ORDER BY o.created_at DESC, ots.tracking_date DESC NULLS LAST, ots.submitted_at DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_package_receipt_dashboard_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_package_receipt_dashboard_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
