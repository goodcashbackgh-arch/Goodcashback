-- Patch D: branch/country server guard.
-- Governing authority: MULTI_TENANT_ONBOARDING_ACCESS_MVP_COMPLETION_ADDENDUM_v1 section 6 / Patch D.
-- Scope: onboarding writes only. No historical data correction.

CREATE OR REPLACE FUNCTION public.internal_upsert_shipper_branch_v1(
  p_shipper_id uuid,
  p_name text,
  p_contact_email text,
  p_contact_phone text,
  p_country_id uuid,
  p_vat_treatment text DEFAULT NULL::text,
  p_vat_registration_country text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_staff_id uuid;
  v_shipper_id uuid;
  v_existing_country_id uuid;
  v_active_country_count integer := 0;
BEGIN
  SELECT id
  INTO v_staff_id
  FROM public.staff
  WHERE auth_user_id = auth.uid()
    AND active = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'not_authorised';
  END IF;

  IF NULLIF(trim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'shipper_name_required';
  END IF;

  IF p_country_id IS NULL THEN
    RAISE EXCEPTION 'country_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.countries c
    WHERE c.id = p_country_id
      AND c.active = true
  ) THEN
    RAISE EXCEPTION 'country_not_found_or_inactive';
  END IF;

  IF p_shipper_id IS NULL THEN
    INSERT INTO public.shippers (
      name,
      contact_email,
      contact_phone,
      vat_treatment,
      vat_registration_country,
      active
    )
    VALUES (
      trim(p_name),
      NULLIF(trim(COALESCE(p_contact_email, '')), ''),
      NULLIF(trim(COALESCE(p_contact_phone, '')), ''),
      NULLIF(trim(COALESCE(p_vat_treatment, '')), ''),
      NULLIF(trim(COALESCE(p_vat_registration_country, '')), ''),
      true
    )
    RETURNING id INTO v_shipper_id;

    INSERT INTO public.shipper_countries (shipper_id, country_id)
    VALUES (v_shipper_id, p_country_id);

    RETURN v_shipper_id;
  END IF;

  SELECT s.id
  INTO v_shipper_id
  FROM public.shippers s
  WHERE s.id = p_shipper_id
    AND s.active = true
  FOR UPDATE;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'shipper_not_found';
  END IF;

  SELECT
    count(DISTINCT sc.country_id)::integer,
    min(sc.country_id)
  INTO v_active_country_count, v_existing_country_id
  FROM public.shipper_countries sc
  JOIN public.countries c
    ON c.id = sc.country_id
   AND c.active = true
  WHERE sc.shipper_id = v_shipper_id;

  IF v_active_country_count <> 1 THEN
    RAISE EXCEPTION 'shipper_branch_country_not_ready';
  END IF;

  IF v_existing_country_id IS DISTINCT FROM p_country_id THEN
    RAISE EXCEPTION 'shipper_branch_country_mismatch';
  END IF;

  UPDATE public.shippers
  SET name = trim(p_name),
      contact_email = NULLIF(trim(COALESCE(p_contact_email, '')), ''),
      contact_phone = NULLIF(trim(COALESCE(p_contact_phone, '')), ''),
      vat_treatment = NULLIF(trim(COALESCE(p_vat_treatment, '')), ''),
      vat_registration_country = NULLIF(trim(COALESCE(p_vat_registration_country, '')), '')
  WHERE id = v_shipper_id;

  RETURN v_shipper_id;
END;
$function$;


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
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_staff_id uuid;
  v_importer_id uuid;
  v_resolved_country_id uuid;
  v_active_country_count integer := 0;
  v_existing_importer record;
BEGIN
  SELECT id
  INTO v_staff_id
  FROM public.staff
  WHERE auth_user_id = auth.uid()
    AND active = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'not_authorised';
  END IF;

  IF p_shipper_id IS NULL THEN
    RAISE EXCEPTION 'shipper_required';
  END IF;

  IF NULLIF(trim(COALESCE(p_company_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'company_name_required';
  END IF;

  -- Lock the selected active branch while resolving its one-country lane.
  PERFORM 1
  FROM public.shippers s
  WHERE s.id = p_shipper_id
    AND s.active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shipper_not_found';
  END IF;

  SELECT
    count(DISTINCT sc.country_id)::integer,
    min(sc.country_id)
  INTO v_active_country_count, v_resolved_country_id
  FROM public.shipper_countries sc
  JOIN public.countries c
    ON c.id = sc.country_id
   AND c.active = true
  WHERE sc.shipper_id = p_shipper_id;

  IF v_active_country_count <> 1 THEN
    RAISE EXCEPTION 'shipper_branch_country_not_ready';
  END IF;

  -- p_country_id remains in the legacy RPC signature only as a compatibility/mismatch guard.
  -- The stored importer country is always derived from the selected branch.
  IF p_country_id IS NOT NULL
     AND p_country_id IS DISTINCT FROM v_resolved_country_id THEN
    RAISE EXCEPTION 'branch_importer_country_mismatch';
  END IF;

  IF p_importer_id IS NULL THEN
    INSERT INTO public.importers (
      shipper_id,
      country_id,
      company_name,
      trading_name,
      address,
      active
    )
    VALUES (
      p_shipper_id,
      v_resolved_country_id,
      trim(p_company_name),
      NULLIF(trim(COALESCE(p_trading_name, '')), ''),
      NULLIF(trim(COALESCE(p_address, '')), ''),
      true
    )
    RETURNING id INTO v_importer_id;
  ELSE
    SELECT i.id, i.shipper_id, i.country_id
    INTO v_existing_importer
    FROM public.importers i
    WHERE i.id = p_importer_id
      AND i.active = true
    FOR UPDATE;

    IF v_existing_importer.id IS NULL THEN
      RAISE EXCEPTION 'importer_not_found';
    END IF;

    -- Do not silently repair a known historical mismatch when merely editing the same branch.
    IF v_existing_importer.shipper_id = p_shipper_id
       AND v_existing_importer.country_id IS DISTINCT FROM v_resolved_country_id THEN
      RAISE EXCEPTION 'existing_importer_country_mismatch_requires_review';
    END IF;

    UPDATE public.importers
    SET shipper_id = p_shipper_id,
        country_id = v_resolved_country_id,
        company_name = trim(p_company_name),
        trading_name = NULLIF(trim(COALESCE(p_trading_name, '')), ''),
        address = NULLIF(trim(COALESCE(p_address, '')), '')
    WHERE id = p_importer_id
    RETURNING id INTO v_importer_id;
  END IF;

  RETURN v_importer_id;
END;
$function$;
