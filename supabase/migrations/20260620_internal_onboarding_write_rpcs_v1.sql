BEGIN;

CREATE OR REPLACE FUNCTION public.internal_upsert_shipper_branch_v1(
  p_shipper_id uuid,
  p_name text,
  p_contact_email text,
  p_contact_phone text,
  p_country_id uuid,
  p_vat_treatment text DEFAULT NULL,
  p_vat_registration_country text DEFAULT NULL
)
RETURNS uuid
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
  IF NULLIF(trim(COALESCE(p_name, '')), '') IS NULL THEN RAISE EXCEPTION 'shipper_name_required'; END IF;
  IF p_country_id IS NULL THEN RAISE EXCEPTION 'country_required'; END IF;

  IF p_shipper_id IS NULL THEN
    INSERT INTO public.shippers (name, contact_email, contact_phone, vat_treatment, vat_registration_country, active)
    VALUES (trim(p_name), NULLIF(trim(COALESCE(p_contact_email, '')), ''), NULLIF(trim(COALESCE(p_contact_phone, '')), ''), NULLIF(trim(COALESCE(p_vat_treatment, '')), ''), NULLIF(trim(COALESCE(p_vat_registration_country, '')), ''), true)
    RETURNING id INTO v_shipper_id;
  ELSE
    UPDATE public.shippers
    SET name = trim(p_name),
        contact_email = NULLIF(trim(COALESCE(p_contact_email, '')), ''),
        contact_phone = NULLIF(trim(COALESCE(p_contact_phone, '')), ''),
        vat_treatment = NULLIF(trim(COALESCE(p_vat_treatment, '')), ''),
        vat_registration_country = NULLIF(trim(COALESCE(p_vat_registration_country, '')), '')
    WHERE id = p_shipper_id AND active = true
    RETURNING id INTO v_shipper_id;
    IF v_shipper_id IS NULL THEN RAISE EXCEPTION 'shipper_not_found'; END IF;
  END IF;

  INSERT INTO public.shipper_countries (shipper_id, country_id)
  VALUES (v_shipper_id, p_country_id)
  ON CONFLICT (shipper_id, country_id) DO NOTHING;

  RETURN v_shipper_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_upsert_importer_branch_v1(
  p_importer_id uuid,
  p_shipper_id uuid,
  p_country_id uuid,
  p_company_name text,
  p_trading_name text,
  p_address text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_importer_id uuid;
BEGIN
  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true LIMIT 1;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not_authorised'; END IF;
  IF p_shipper_id IS NULL THEN RAISE EXCEPTION 'shipper_required'; END IF;
  IF p_country_id IS NULL THEN RAISE EXCEPTION 'country_required'; END IF;
  IF NULLIF(trim(COALESCE(p_company_name, '')), '') IS NULL THEN RAISE EXCEPTION 'company_name_required'; END IF;

  IF p_importer_id IS NULL THEN
    INSERT INTO public.importers (shipper_id, country_id, company_name, trading_name, address, active)
    VALUES (p_shipper_id, p_country_id, trim(p_company_name), NULLIF(trim(COALESCE(p_trading_name, '')), ''), NULLIF(trim(COALESCE(p_address, '')), ''), true)
    RETURNING id INTO v_importer_id;
  ELSE
    UPDATE public.importers
    SET shipper_id = p_shipper_id,
        country_id = p_country_id,
        company_name = trim(p_company_name),
        trading_name = NULLIF(trim(COALESCE(p_trading_name, '')), ''),
        address = NULLIF(trim(COALESCE(p_address, '')), '')
    WHERE id = p_importer_id AND active = true
    RETURNING id INTO v_importer_id;
    IF v_importer_id IS NULL THEN RAISE EXCEPTION 'importer_not_found'; END IF;
  END IF;

  RETURN v_importer_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_upsert_importer_delivery_profile_v1(
  p_importer_id uuid,
  p_final_recipient_name text,
  p_final_recipient_address_line_1 text,
  p_final_recipient_address_line_2 text,
  p_final_recipient_city text,
  p_final_recipient_region text,
  p_final_recipient_country text,
  p_final_recipient_phone text,
  p_final_recipient_email text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_profile_id uuid;
  v_country_id uuid;
BEGIN
  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true LIMIT 1;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not_authorised'; END IF;
  SELECT country_id INTO v_country_id FROM public.importers WHERE id = p_importer_id AND active = true;
  IF v_country_id IS NULL THEN RAISE EXCEPTION 'importer_not_found'; END IF;
  IF NULLIF(trim(COALESCE(p_final_recipient_name, '')), '') IS NULL THEN RAISE EXCEPTION 'recipient_name_required'; END IF;
  IF NULLIF(trim(COALESCE(p_final_recipient_address_line_1, '')), '') IS NULL THEN RAISE EXCEPTION 'address_line_1_required'; END IF;
  IF NULLIF(trim(COALESCE(p_final_recipient_country, '')), '') IS NULL THEN RAISE EXCEPTION 'recipient_country_required'; END IF;

  UPDATE public.importer_export_delivery_profiles SET active = false, updated_at = now()
  WHERE importer_id = p_importer_id AND active = true;

  INSERT INTO public.importer_export_delivery_profiles (importer_id, country_id, final_recipient_name, final_recipient_address_line_1, final_recipient_address_line_2, final_recipient_city, final_recipient_region, final_recipient_country, final_recipient_phone, final_recipient_email, active)
  VALUES (p_importer_id, v_country_id, trim(p_final_recipient_name), trim(p_final_recipient_address_line_1), NULLIF(trim(COALESCE(p_final_recipient_address_line_2, '')), ''), NULLIF(trim(COALESCE(p_final_recipient_city, '')), ''), NULLIF(trim(COALESCE(p_final_recipient_region, '')), ''), trim(p_final_recipient_country), NULLIF(trim(COALESCE(p_final_recipient_phone, '')), ''), NULLIF(trim(COALESCE(p_final_recipient_email, '')), ''), true)
  RETURNING id INTO v_profile_id;

  RETURN v_profile_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_upsert_shipper_branch_v1(uuid,text,text,text,uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_upsert_importer_branch_v1(uuid,uuid,uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_upsert_importer_delivery_profile_v1(uuid,text,text,text,text,text,text,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
