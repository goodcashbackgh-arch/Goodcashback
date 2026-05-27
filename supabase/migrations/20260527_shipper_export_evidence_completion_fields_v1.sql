-- =============================================================================
-- 20260527_shipper_export_evidence_completion_fields_v1.sql
-- Multi Tenant Platform Build — shipper-side final shipment/COS completion fields
--
-- Purpose:
--   Store the shipper-completed shipment facts used to produce/download the
--   draft COS + EEP pack and later verify the final uploaded COS/export evidence.
--
-- Important:
--   These fields are deliberately NOT added to shipper_shipment_batches. The
--   batch header remains package/shipment truth only; final shipment/COS facts
--   live in this export-evidence lane.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TABLE IF NOT EXISTS public.shipper_export_evidence_completion_fields (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id) ON DELETE CASCADE,
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  mbl_bol_sea_waybill_ref text,
  container_number text,
  seal_number text,
  vessel_voyage text,
  port_of_loading text,
  port_of_discharge text,
  place_of_delivery text,
  export_shipment_date date,
  final_package_confirmation text,
  authorised_name text,
  signature_stamp_confirmation_yn boolean NOT NULL DEFAULT false,
  notes text,
  completion_status varchar NOT NULL DEFAULT 'completion_fields_draft'
    CHECK (completion_status IN ('completion_fields_draft','completion_fields_ready')),
  created_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  updated_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ux_shipper_export_evidence_completion_fields_batch UNIQUE (shipment_batch_id)
);

COMMENT ON TABLE public.shipper_export_evidence_completion_fields IS
'Shipper-completed COS/export shipment facts. Separate from shipper_shipment_batches so batch header remains package movement truth only.';

CREATE INDEX IF NOT EXISTS idx_shipper_export_evidence_completion_fields_shipper
  ON public.shipper_export_evidence_completion_fields(shipper_id, updated_at DESC);

ALTER TABLE public.shipper_export_evidence_completion_fields ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'shipper_export_evidence_completion_fields'
      AND policyname = 'shipper_export_evidence_completion_fields_select'
  ) THEN
    CREATE POLICY shipper_export_evidence_completion_fields_select
    ON public.shipper_export_evidence_completion_fields
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = shipper_export_evidence_completion_fields.shipper_id
      )
      OR public.is_active_staff()
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_save_export_evidence_completion_fields_v1(
  p_shipment_batch_id uuid,
  p_mbl_bol_sea_waybill_ref text DEFAULT NULL,
  p_container_number text DEFAULT NULL,
  p_seal_number text DEFAULT NULL,
  p_vessel_voyage text DEFAULT NULL,
  p_port_of_loading text DEFAULT NULL,
  p_port_of_discharge text DEFAULT NULL,
  p_place_of_delivery text DEFAULT NULL,
  p_export_shipment_date date DEFAULT NULL,
  p_final_package_confirmation text DEFAULT NULL,
  p_authorised_name text DEFAULT NULL,
  p_signature_stamp_confirmation_yn boolean DEFAULT false,
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
  v_batch_shipper_id uuid;
  v_status text;
  v_completion_status text;
  v_row_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: export evidence completion requires auth.uid()';
  END IF;

  IF p_shipment_batch_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch id is required.';
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

  SELECT b.shipper_id, b.status
    INTO v_batch_shipper_id, v_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id;

  IF v_batch_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found.';
  END IF;

  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Shipment batch does not belong to this shipper.';
  END IF;

  IF v_status IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Export evidence fields cannot be edited for shipment batch status: %', v_status;
  END IF;

  v_completion_status := CASE
    WHEN NULLIF(BTRIM(COALESCE(p_mbl_bol_sea_waybill_ref, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_container_number, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_seal_number, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_vessel_voyage, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_port_of_loading, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_port_of_discharge, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_place_of_delivery, '')), '') IS NOT NULL
     AND p_export_shipment_date IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_final_package_confirmation, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_authorised_name, '')), '') IS NOT NULL
     AND COALESCE(p_signature_stamp_confirmation_yn, false) = true
    THEN 'completion_fields_ready'
    ELSE 'completion_fields_draft'
  END;

  INSERT INTO public.shipper_export_evidence_completion_fields (
    shipment_batch_id,
    shipper_id,
    mbl_bol_sea_waybill_ref,
    container_number,
    seal_number,
    vessel_voyage,
    port_of_loading,
    port_of_discharge,
    place_of_delivery,
    export_shipment_date,
    final_package_confirmation,
    authorised_name,
    signature_stamp_confirmation_yn,
    notes,
    completion_status,
    created_by_shipper_user_id,
    updated_by_shipper_user_id
  ) VALUES (
    p_shipment_batch_id,
    v_shipper_id,
    NULLIF(BTRIM(COALESCE(p_mbl_bol_sea_waybill_ref, '')), ''),
    NULLIF(BTRIM(COALESCE(p_container_number, '')), ''),
    NULLIF(BTRIM(COALESCE(p_seal_number, '')), ''),
    NULLIF(BTRIM(COALESCE(p_vessel_voyage, '')), ''),
    NULLIF(BTRIM(COALESCE(p_port_of_loading, '')), ''),
    NULLIF(BTRIM(COALESCE(p_port_of_discharge, '')), ''),
    NULLIF(BTRIM(COALESCE(p_place_of_delivery, '')), ''),
    p_export_shipment_date,
    NULLIF(BTRIM(COALESCE(p_final_package_confirmation, '')), ''),
    NULLIF(BTRIM(COALESCE(p_authorised_name, '')), ''),
    COALESCE(p_signature_stamp_confirmation_yn, false),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    v_completion_status,
    v_shipper_user_id,
    v_shipper_user_id
  )
  ON CONFLICT (shipment_batch_id)
  DO UPDATE SET
    mbl_bol_sea_waybill_ref = EXCLUDED.mbl_bol_sea_waybill_ref,
    container_number = EXCLUDED.container_number,
    seal_number = EXCLUDED.seal_number,
    vessel_voyage = EXCLUDED.vessel_voyage,
    port_of_loading = EXCLUDED.port_of_loading,
    port_of_discharge = EXCLUDED.port_of_discharge,
    place_of_delivery = EXCLUDED.place_of_delivery,
    export_shipment_date = EXCLUDED.export_shipment_date,
    final_package_confirmation = EXCLUDED.final_package_confirmation,
    authorised_name = EXCLUDED.authorised_name,
    signature_stamp_confirmation_yn = EXCLUDED.signature_stamp_confirmation_yn,
    notes = EXCLUDED.notes,
    completion_status = EXCLUDED.completion_status,
    updated_by_shipper_user_id = v_shipper_user_id,
    updated_at = now()
  RETURNING id INTO v_row_id;

  RETURN v_row_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_shipment_export_evidence_completion_fields_v1(
  p_shipment_batch_id uuid
)
RETURNS TABLE (
  id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  shipper_id uuid,
  shipper_name text,
  mbl_bol_sea_waybill_ref text,
  container_number text,
  seal_number text,
  vessel_voyage text,
  port_of_loading text,
  port_of_discharge text,
  place_of_delivery text,
  export_shipment_date date,
  final_package_confirmation text,
  authorised_name text,
  signature_stamp_confirmation_yn boolean,
  notes text,
  completion_status text,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal export evidence completion fields require auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal export evidence completion fields.';
  END IF;

  RETURN QUERY
  SELECT
    f.id,
    b.id AS shipment_batch_id,
    b.booking_ref::text,
    b.shipper_id,
    s.name::text AS shipper_name,
    f.mbl_bol_sea_waybill_ref,
    f.container_number,
    f.seal_number,
    f.vessel_voyage,
    f.port_of_loading,
    f.port_of_discharge,
    f.place_of_delivery,
    f.export_shipment_date,
    f.final_package_confirmation,
    f.authorised_name,
    f.signature_stamp_confirmation_yn,
    f.notes,
    COALESCE(f.completion_status, 'completion_fields_draft')::text AS completion_status,
    f.updated_at
  FROM public.shipper_shipment_batches b
  JOIN public.shippers s ON s.id = b.shipper_id
  LEFT JOIN public.shipper_export_evidence_completion_fields f
    ON f.shipment_batch_id = b.id
  WHERE b.id = p_shipment_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipment_export_evidence_completion_fields_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipment_export_evidence_completion_fields_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
