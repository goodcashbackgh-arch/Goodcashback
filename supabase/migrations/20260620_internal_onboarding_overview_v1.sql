BEGIN;

CREATE OR REPLACE FUNCTION public.internal_onboarding_overview_v1()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  SELECT id INTO v_staff_id
  FROM public.staff
  WHERE auth_user_id = auth.uid()
    AND active = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RETURN jsonb_build_object('error', 'not_staff');
  END IF;

  RETURN jsonb_build_object(
    'countries', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb)
      FROM (
        SELECT c.id, c.name, c.iso_code, c.currency_id, cur.code AS currency_code
        FROM public.countries c
        JOIN public.currencies cur ON cur.id = c.currency_id
        WHERE c.active = true
      ) x
    ),
    'shippers', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb)
      FROM (
        SELECT
          sh.id,
          sh.name,
          sh.contact_email,
          sh.contact_phone,
          sh.vat_treatment,
          sh.vat_registration_country,
          sh.active,
          count(sc.country_id)::int AS country_count,
          COALESCE(jsonb_agg(jsonb_build_object('country_id', c.id, 'country_name', c.name, 'currency_code', cur.code) ORDER BY c.name) FILTER (WHERE c.id IS NOT NULL), '[]'::jsonb) AS countries
        FROM public.shippers sh
        LEFT JOIN public.shipper_countries sc ON sc.shipper_id = sh.id
        LEFT JOIN public.countries c ON c.id = sc.country_id
        LEFT JOIN public.currencies cur ON cur.id = c.currency_id
        WHERE sh.active = true
        GROUP BY sh.id, sh.name, sh.contact_email, sh.contact_phone, sh.vat_treatment, sh.vat_registration_country, sh.active
      ) x
    ),
    'importers', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.importer_name), '[]'::jsonb)
      FROM (
        SELECT
          i.id,
          i.shipper_id,
          sh.name AS shipper_name,
          i.country_id,
          c.name AS country_name,
          cur.code AS currency_code,
          i.company_name,
          i.trading_name,
          COALESCE(NULLIF(i.trading_name, ''), i.company_name, i.id::text) AS importer_name,
          i.address,
          i.active,
          CASE WHEN dp.id IS NULL THEN NULL ELSE jsonb_build_object('id', dp.id, 'final_recipient_name', dp.final_recipient_name, 'final_recipient_address_line_1', dp.final_recipient_address_line_1, 'final_recipient_country', dp.final_recipient_country, 'final_recipient_phone', dp.final_recipient_phone, 'final_recipient_email', dp.final_recipient_email) END AS delivery_profile
        FROM public.importers i
        JOIN public.shippers sh ON sh.id = i.shipper_id
        JOIN public.countries c ON c.id = i.country_id
        JOIN public.currencies cur ON cur.id = c.currency_id
        LEFT JOIN LATERAL (
          SELECT dp0.*
          FROM public.importer_export_delivery_profiles dp0
          WHERE dp0.importer_id = i.id AND dp0.active = true
          ORDER BY dp0.updated_at DESC, dp0.created_at DESC
          LIMIT 1
        ) dp ON true
        WHERE i.active = true
      ) x
    ),
    'operators', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.full_name), '[]'::jsonb)
      FROM (
        SELECT o.id, o.auth_user_id, o.email, o.phone, o.full_name, o.active
        FROM public.operators o
        WHERE o.active = true
      ) x
    ),
    'export_profiles', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.profile_name), '[]'::jsonb)
      FROM (
        SELECT p.*, sh.name AS shipper_name, c.name AS country_name
        FROM public.tenant_export_evidence_profiles p
        LEFT JOIN public.shippers sh ON sh.id = p.shipper_id
        LEFT JOIN public.countries c ON c.id = p.country_id
        WHERE p.active = true
      ) x
    ),
    'supervisors', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.full_name), '[]'::jsonb)
      FROM (
        SELECT s.id, s.full_name, s.email, COALESCE(sas.scope_mode, 'all') AS scope_mode
        FROM public.staff s
        LEFT JOIN public.supervisor_access_scopes sas ON sas.supervisor_staff_id = s.id AND sas.active = true
        WHERE s.active = true AND s.role_type = 'supervisor'
      ) x
    ),
    'blockers', jsonb_build_object(
      'importers_missing_delivery_profile', (
        SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.importer_name), '[]'::jsonb)
        FROM (
          SELECT i.id AS importer_id, COALESCE(NULLIF(i.trading_name, ''), i.company_name) AS importer_name, sh.name AS shipper_name
          FROM public.importers i
          JOIN public.shippers sh ON sh.id = i.shipper_id
          LEFT JOIN LATERAL (
            SELECT dp0.* FROM public.importer_export_delivery_profiles dp0
            WHERE dp0.importer_id = i.id AND dp0.active = true
            ORDER BY dp0.updated_at DESC, dp0.created_at DESC
            LIMIT 1
          ) dp ON true
          WHERE i.active = true
            AND (dp.id IS NULL OR NULLIF(trim(COALESCE(dp.final_recipient_name, '')), '') IS NULL OR NULLIF(trim(COALESCE(dp.final_recipient_address_line_1, '')), '') IS NULL OR NULLIF(trim(COALESCE(dp.final_recipient_country, '')), '') IS NULL)
        ) x
      ),
      'shipper_branches_missing_export_profile', (
        SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.shipper_name), '[]'::jsonb)
        FROM (
          SELECT sh.id AS shipper_id, sh.name AS shipper_name, c.id AS country_id, c.name AS country_name
          FROM public.shippers sh
          JOIN public.shipper_countries sc ON sc.shipper_id = sh.id
          JOIN public.countries c ON c.id = sc.country_id
          LEFT JOIN public.tenant_export_evidence_profiles p ON p.shipper_id = sh.id AND p.country_id = c.id AND p.active = true
          WHERE sh.active = true AND p.id IS NULL
        ) x
      )
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_onboarding_overview_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
