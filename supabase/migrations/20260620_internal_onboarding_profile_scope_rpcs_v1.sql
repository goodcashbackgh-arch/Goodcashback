BEGIN;

CREATE OR REPLACE FUNCTION public.internal_upsert_export_evidence_profile_v1(
  p_profile_id uuid,
  p_shipper_id uuid,
  p_country_id uuid,
  p_profile_name text,
  p_exporter_name text,
  p_exporter_address text,
  p_exporter_vat_number text,
  p_default_movement_consignee_name text,
  p_default_movement_consignee_address text,
  p_default_notify_party_name text,
  p_default_notify_party_address text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_profile_id uuid;
BEGIN
  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true LIMIT 1;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not_authorised'; END IF;
  IF p_shipper_id IS NULL THEN RAISE EXCEPTION 'shipper_required'; END IF;
  IF p_country_id IS NULL THEN RAISE EXCEPTION 'country_required'; END IF;
  IF NULLIF(trim(COALESCE(p_exporter_name, '')), '') IS NULL THEN RAISE EXCEPTION 'exporter_name_required'; END IF;
  IF NULLIF(trim(COALESCE(p_exporter_address, '')), '') IS NULL THEN RAISE EXCEPTION 'exporter_address_required'; END IF;
  IF NULLIF(trim(COALESCE(p_default_movement_consignee_name, '')), '') IS NULL THEN RAISE EXCEPTION 'movement_consignee_name_required'; END IF;
  IF NULLIF(trim(COALESCE(p_default_movement_consignee_address, '')), '') IS NULL THEN RAISE EXCEPTION 'movement_consignee_address_required'; END IF;

  IF p_profile_id IS NULL THEN
    INSERT INTO public.tenant_export_evidence_profiles (shipper_id, country_id, profile_name, exporter_name, exporter_address, exporter_vat_number, default_movement_consignee_name, default_movement_consignee_address, default_notify_party_name, default_notify_party_address, active)
    VALUES (p_shipper_id, p_country_id, COALESCE(NULLIF(trim(COALESCE(p_profile_name, '')), ''), 'Default export evidence profile'), trim(p_exporter_name), trim(p_exporter_address), NULLIF(trim(COALESCE(p_exporter_vat_number, '')), ''), trim(p_default_movement_consignee_name), trim(p_default_movement_consignee_address), NULLIF(trim(COALESCE(p_default_notify_party_name, '')), ''), NULLIF(trim(COALESCE(p_default_notify_party_address, '')), ''), true)
    RETURNING id INTO v_profile_id;
  ELSE
    UPDATE public.tenant_export_evidence_profiles
    SET shipper_id = p_shipper_id,
        country_id = p_country_id,
        profile_name = COALESCE(NULLIF(trim(COALESCE(p_profile_name, '')), ''), 'Default export evidence profile'),
        exporter_name = trim(p_exporter_name),
        exporter_address = trim(p_exporter_address),
        exporter_vat_number = NULLIF(trim(COALESCE(p_exporter_vat_number, '')), ''),
        default_movement_consignee_name = trim(p_default_movement_consignee_name),
        default_movement_consignee_address = trim(p_default_movement_consignee_address),
        default_notify_party_name = NULLIF(trim(COALESCE(p_default_notify_party_name, '')), ''),
        default_notify_party_address = NULLIF(trim(COALESCE(p_default_notify_party_address, '')), ''),
        active = true,
        updated_at = now()
    WHERE id = p_profile_id
    RETURNING id INTO v_profile_id;
    IF v_profile_id IS NULL THEN RAISE EXCEPTION 'profile_not_found'; END IF;
  END IF;

  RETURN v_profile_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_set_supervisor_scope_v1(
  p_supervisor_staff_id uuid,
  p_scope_mode text,
  p_shipper_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_shipper_id uuid;
BEGIN
  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true LIMIT 1;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not_authorised'; END IF;
  IF p_scope_mode NOT IN ('all','assigned') THEN RAISE EXCEPTION 'invalid_scope_mode'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id = p_supervisor_staff_id AND role_type = 'supervisor' AND active = true) THEN RAISE EXCEPTION 'supervisor_not_found'; END IF;

  UPDATE public.supervisor_access_scopes SET active = false, updated_at = now()
  WHERE supervisor_staff_id = p_supervisor_staff_id AND active = true;

  INSERT INTO public.supervisor_access_scopes (supervisor_staff_id, scope_mode, active)
  VALUES (p_supervisor_staff_id, p_scope_mode, true);

  UPDATE public.supervisor_branch_assignments SET active = false, revoked_at = now()
  WHERE supervisor_staff_id = p_supervisor_staff_id AND active = true;

  IF p_scope_mode = 'assigned' THEN
    FOREACH v_shipper_id IN ARRAY COALESCE(p_shipper_ids, ARRAY[]::uuid[]) LOOP
      INSERT INTO public.supervisor_branch_assignments (supervisor_staff_id, shipper_id, active)
      VALUES (p_supervisor_staff_id, v_shipper_id, true)
      ON CONFLICT (supervisor_staff_id, shipper_id) WHERE active = true DO NOTHING;
    END LOOP;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_link_operator_importer_v1(
  p_operator_id uuid,
  p_importer_id uuid,
  p_relationship_type text,
  p_role_code text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_auth_user_id uuid;
BEGIN
  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true LIMIT 1;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not_authorised'; END IF;
  IF p_relationship_type NOT IN ('sole_owner','authorised_user') THEN RAISE EXCEPTION 'invalid_relationship_type'; END IF;
  IF p_role_code NOT IN ('customer','importer') THEN RAISE EXCEPTION 'invalid_role_code'; END IF;

  SELECT auth_user_id INTO v_auth_user_id FROM public.operators WHERE id = p_operator_id AND active = true;
  IF v_auth_user_id IS NULL THEN RAISE EXCEPTION 'operator_has_no_auth_user_id'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.importers WHERE id = p_importer_id AND active = true) THEN RAISE EXCEPTION 'importer_not_found'; END IF;

  INSERT INTO public.operator_importers (operator_id, importer_id, relationship_type)
  SELECT p_operator_id, p_importer_id, p_relationship_type
  WHERE NOT EXISTS (
    SELECT 1 FROM public.operator_importers
    WHERE operator_id = p_operator_id AND importer_id = p_importer_id AND revoked_at IS NULL
  );

  INSERT INTO public.platform_user_memberships (auth_user_id, role_code, importer_id, active)
  SELECT v_auth_user_id, p_role_code, p_importer_id, true
  WHERE NOT EXISTS (
    SELECT 1 FROM public.platform_user_memberships
    WHERE auth_user_id = v_auth_user_id AND role_code = p_role_code AND importer_id = p_importer_id AND active = true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_upsert_export_evidence_profile_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_set_supervisor_scope_v1(uuid,text,uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_link_operator_importer_v1(uuid,uuid,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
