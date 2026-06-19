BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Contract-aligned profile source setup for Groupage Movement Control.
-- The Groupage Movement must pull exporter/consignee/recipient facts from DB profile tables,
-- then snapshot those facts into the movement. The movement page is a consumer of these source records.

CREATE OR REPLACE FUNCTION public.shipper_export_evidence_profiles_v1()
RETURNS TABLE (
  profile_id uuid,
  profile_name text,
  exporter_name text,
  exporter_address text,
  exporter_vat_number text,
  default_movement_consignee_name text,
  default_movement_consignee_address text,
  default_notify_party_name text,
  default_notify_party_address text,
  active boolean,
  updated_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH me AS (
    SELECT su.shipper_id
    FROM public.shipper_users su
    WHERE su.auth_user_id = auth.uid()
      AND su.active = true
    ORDER BY su.created_at DESC
    LIMIT 1
  )
  SELECT
    p.id,
    p.profile_name,
    p.exporter_name,
    p.exporter_address,
    p.exporter_vat_number,
    p.default_movement_consignee_name,
    p.default_movement_consignee_address,
    p.default_notify_party_name,
    p.default_notify_party_address,
    p.active,
    p.updated_at
  FROM public.tenant_export_evidence_profiles p
  JOIN me ON p.shipper_id = me.shipper_id
  WHERE p.active = true
  ORDER BY p.updated_at DESC, p.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_export_evidence_profiles_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_upsert_export_evidence_profile_v1(
  p_profile_id uuid DEFAULT NULL,
  p_profile_name text DEFAULT 'Default export evidence profile',
  p_exporter_name text DEFAULT NULL,
  p_exporter_address text DEFAULT NULL,
  p_exporter_vat_number text DEFAULT NULL,
  p_default_movement_consignee_name text DEFAULT NULL,
  p_default_movement_consignee_address text DEFAULT NULL,
  p_default_notify_party_name text DEFAULT NULL,
  p_default_notify_party_address text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
  v_profile_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: export evidence profile update requires auth.uid()';
  END IF;

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_exporter_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Exporter name is required.';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_exporter_address, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Exporter address is required.';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_default_movement_consignee_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Movement consignee name is required.';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_default_movement_consignee_address, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Movement consignee address is required.';
  END IF;

  IF p_profile_id IS NOT NULL THEN
    UPDATE public.tenant_export_evidence_profiles p
    SET profile_name = COALESCE(NULLIF(BTRIM(COALESCE(p_profile_name, '')), ''), 'Default export evidence profile'),
        exporter_name = NULLIF(BTRIM(COALESCE(p_exporter_name, '')), ''),
        exporter_address = NULLIF(BTRIM(COALESCE(p_exporter_address, '')), ''),
        exporter_vat_number = NULLIF(BTRIM(COALESCE(p_exporter_vat_number, '')), ''),
        default_movement_consignee_name = NULLIF(BTRIM(COALESCE(p_default_movement_consignee_name, '')), ''),
        default_movement_consignee_address = NULLIF(BTRIM(COALESCE(p_default_movement_consignee_address, '')), ''),
        default_notify_party_name = NULLIF(BTRIM(COALESCE(p_default_notify_party_name, '')), ''),
        default_notify_party_address = NULLIF(BTRIM(COALESCE(p_default_notify_party_address, '')), ''),
        active = true,
        updated_at = now()
    WHERE p.id = p_profile_id
      AND p.shipper_id = v_shipper_id
    RETURNING p.id INTO v_profile_id;

    IF v_profile_id IS NULL THEN
      RAISE EXCEPTION 'Export evidence profile not found for this shipper.';
    END IF;
  ELSE
    INSERT INTO public.tenant_export_evidence_profiles (
      shipper_id,
      profile_name,
      exporter_name,
      exporter_address,
      exporter_vat_number,
      default_movement_consignee_name,
      default_movement_consignee_address,
      default_notify_party_name,
      default_notify_party_address,
      active
    ) VALUES (
      v_shipper_id,
      COALESCE(NULLIF(BTRIM(COALESCE(p_profile_name, '')), ''), 'Default export evidence profile'),
      NULLIF(BTRIM(COALESCE(p_exporter_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_exporter_address, '')), ''),
      NULLIF(BTRIM(COALESCE(p_exporter_vat_number, '')), ''),
      NULLIF(BTRIM(COALESCE(p_default_movement_consignee_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_default_movement_consignee_address, '')), ''),
      NULLIF(BTRIM(COALESCE(p_default_notify_party_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_default_notify_party_address, '')), ''),
      true
    ) RETURNING id INTO v_profile_id;
  END IF;

  RETURN v_profile_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_upsert_export_evidence_profile_v1(uuid,text,text,text,text,text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_importer_delivery_profiles_v1()
RETURNS TABLE (
  importer_id uuid,
  importer_name text,
  profile_id uuid,
  final_recipient_name text,
  final_recipient_address_line_1 text,
  final_recipient_address_line_2 text,
  final_recipient_city text,
  final_recipient_region text,
  final_recipient_country text,
  final_recipient_phone text,
  final_recipient_email text,
  active boolean,
  updated_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH me AS (
    SELECT su.shipper_id
    FROM public.shipper_users su
    WHERE su.auth_user_id = auth.uid()
      AND su.active = true
    ORDER BY su.created_at DESC
    LIMIT 1
  ), scoped_importers AS (
    SELECT DISTINCT b.importer_id
    FROM public.shipper_shipment_batches b
    JOIN me ON me.shipper_id = b.shipper_id
    WHERE b.status <> 'voided'
  )
  SELECT
    i.id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text AS importer_name,
    dp.id,
    dp.final_recipient_name,
    dp.final_recipient_address_line_1,
    dp.final_recipient_address_line_2,
    dp.final_recipient_city,
    dp.final_recipient_region,
    dp.final_recipient_country,
    dp.final_recipient_phone,
    dp.final_recipient_email,
    dp.active,
    dp.updated_at
  FROM scoped_importers si
  JOIN public.importers i ON i.id = si.importer_id
  LEFT JOIN LATERAL (
    SELECT dp0.*
    FROM public.importer_export_delivery_profiles dp0
    WHERE dp0.importer_id = i.id
      AND dp0.active = true
    ORDER BY dp0.updated_at DESC, dp0.created_at DESC
    LIMIT 1
  ) dp ON true
  ORDER BY importer_name;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_importer_delivery_profiles_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_upsert_importer_export_delivery_profile_v1(
  p_importer_id uuid,
  p_final_recipient_name text DEFAULT NULL,
  p_final_recipient_address_line_1 text DEFAULT NULL,
  p_final_recipient_address_line_2 text DEFAULT NULL,
  p_final_recipient_city text DEFAULT NULL,
  p_final_recipient_region text DEFAULT NULL,
  p_final_recipient_country text DEFAULT NULL,
  p_final_recipient_phone text DEFAULT NULL,
  p_final_recipient_email text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
  v_profile_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: importer delivery profile update requires auth.uid()';
  END IF;

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batches b
    WHERE b.shipper_id = v_shipper_id
      AND b.importer_id = p_importer_id
      AND b.status <> 'voided'
  ) THEN
    RAISE EXCEPTION 'Importer is not available to this shipper.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_final_recipient_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Final recipient name is required.';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_final_recipient_address_line_1, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Final recipient address line 1 is required.';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_final_recipient_country, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Final recipient country is required.';
  END IF;

  SELECT dp.id INTO v_profile_id
  FROM public.importer_export_delivery_profiles dp
  WHERE dp.importer_id = p_importer_id
    AND dp.active = true
  ORDER BY dp.updated_at DESC, dp.created_at DESC
  LIMIT 1;

  IF v_profile_id IS NULL THEN
    INSERT INTO public.importer_export_delivery_profiles (
      importer_id,
      final_recipient_name,
      final_recipient_address_line_1,
      final_recipient_address_line_2,
      final_recipient_city,
      final_recipient_region,
      final_recipient_country,
      final_recipient_phone,
      final_recipient_email,
      active
    ) VALUES (
      p_importer_id,
      NULLIF(BTRIM(COALESCE(p_final_recipient_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_final_recipient_address_line_1, '')), ''),
      NULLIF(BTRIM(COALESCE(p_final_recipient_address_line_2, '')), ''),
      NULLIF(BTRIM(COALESCE(p_final_recipient_city, '')), ''),
      NULLIF(BTRIM(COALESCE(p_final_recipient_region, '')), ''),
      NULLIF(BTRIM(COALESCE(p_final_recipient_country, '')), ''),
      NULLIF(BTRIM(COALESCE(p_final_recipient_phone, '')), ''),
      NULLIF(BTRIM(COALESCE(p_final_recipient_email, '')), ''),
      true
    ) RETURNING id INTO v_profile_id;
  ELSE
    UPDATE public.importer_export_delivery_profiles dp
    SET final_recipient_name = NULLIF(BTRIM(COALESCE(p_final_recipient_name, '')), ''),
        final_recipient_address_line_1 = NULLIF(BTRIM(COALESCE(p_final_recipient_address_line_1, '')), ''),
        final_recipient_address_line_2 = NULLIF(BTRIM(COALESCE(p_final_recipient_address_line_2, '')), ''),
        final_recipient_city = NULLIF(BTRIM(COALESCE(p_final_recipient_city, '')), ''),
        final_recipient_region = NULLIF(BTRIM(COALESCE(p_final_recipient_region, '')), ''),
        final_recipient_country = NULLIF(BTRIM(COALESCE(p_final_recipient_country, '')), ''),
        final_recipient_phone = NULLIF(BTRIM(COALESCE(p_final_recipient_phone, '')), ''),
        final_recipient_email = NULLIF(BTRIM(COALESCE(p_final_recipient_email, '')), ''),
        active = true,
        updated_at = now()
    WHERE dp.id = v_profile_id;
  END IF;

  RETURN v_profile_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_upsert_importer_export_delivery_profile_v1(uuid,text,text,text,text,text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_refresh_groupage_movement_snapshots_v1(p_groupage_movement_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_profile record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: refresh groupage snapshots requires auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movements gm
    WHERE gm.id = p_groupage_movement_id
      AND gm.shipper_id = v_shipper_id
      AND gm.status IN ('draft', 'movement_facts_incomplete', 'movement_facts_ready')
  ) THEN
    RAISE EXCEPTION 'Groupage Movement not found, not owned by this shipper, or no longer editable.';
  END IF;

  SELECT * INTO v_profile
  FROM public.tenant_export_evidence_profiles p
  WHERE p.active = true
    AND p.shipper_id = v_shipper_id
  ORDER BY p.updated_at DESC, p.created_at DESC
  LIMIT 1;

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Export evidence profile is missing. Complete the shipper export evidence profile first.';
  END IF;

  UPDATE public.shipper_groupage_movements gm
  SET exporter_name_snapshot = v_profile.exporter_name,
      exporter_address_snapshot = v_profile.exporter_address,
      exporter_vat_number_snapshot = v_profile.exporter_vat_number,
      movement_consignee_name_snapshot = v_profile.default_movement_consignee_name,
      movement_consignee_address_snapshot = v_profile.default_movement_consignee_address,
      notify_party_name_snapshot = v_profile.default_notify_party_name,
      notify_party_address_snapshot = v_profile.default_notify_party_address,
      updated_by_shipper_user_id = v_shipper_user_id,
      updated_at = now()
  WHERE gm.id = p_groupage_movement_id;

  UPDATE public.shipper_groupage_movement_batches gmb
  SET final_recipient_name_snapshot = COALESCE(NULLIF(dp.final_recipient_name, ''), gmb.final_recipient_name_snapshot),
      final_recipient_address_snapshot = COALESCE(
        NULLIF(CONCAT_WS(', ', dp.final_recipient_address_line_1, dp.final_recipient_address_line_2, dp.final_recipient_city, dp.final_recipient_region, dp.final_recipient_country), ''),
        gmb.final_recipient_address_snapshot
      )
  FROM public.importer_export_delivery_profiles dp
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true
    AND gmb.importer_id_snapshot = dp.importer_id
    AND dp.active = true
    AND dp.id = (
      SELECT dp2.id
      FROM public.importer_export_delivery_profiles dp2
      WHERE dp2.importer_id = gmb.importer_id_snapshot
        AND dp2.active = true
      ORDER BY dp2.updated_at DESC, dp2.created_at DESC
      LIMIT 1
    );

  IF EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movement_batches gmb
    WHERE gmb.groupage_movement_id = p_groupage_movement_id
      AND gmb.active = true
      AND NULLIF(BTRIM(COALESCE(gmb.final_recipient_address_snapshot, '')), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'One or more importer export delivery profiles are still missing final recipient address details.';
  END IF;

  RETURN p_groupage_movement_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_refresh_groupage_movement_snapshots_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
