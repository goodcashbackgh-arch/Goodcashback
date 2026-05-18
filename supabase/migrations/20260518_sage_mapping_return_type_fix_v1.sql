BEGIN;

-- Fix PL/pgSQL RETURN QUERY strict type matching.
-- PostgreSQL does not treat varchar as text in RETURN QUERY output columns.
-- Scope: exact casts only; no schema/data changes and no Sage posting.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_sage_mapping_control_v1()
RETURNS TABLE (
  mapping_code text,
  mapping_group text,
  display_name text,
  description text,
  value_kind text,
  required_for text[],
  sage_external_id text,
  sage_display_name text,
  is_active boolean,
  mapping_status text,
  blocker text,
  configured_at timestamptz,
  configured_by_staff_name text,
  notes text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage mapping control requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for Sage mapping control.';
  END IF;

  RETURN QUERY
  SELECT
    sm.mapping_code::text,
    sm.mapping_group::text,
    sm.display_name::text,
    sm.description::text,
    sm.value_kind::text,
    sm.required_for::text[],
    sm.sage_external_id::text,
    sm.sage_display_name::text,
    sm.is_active::boolean,
    CASE
      WHEN sm.is_active IS DISTINCT FROM true THEN 'disabled'
      WHEN NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NULL THEN 'missing'
      ELSE 'configured'
    END::text AS mapping_status,
    CASE
      WHEN sm.is_active IS DISTINCT FROM true THEN 'mapping_disabled'
      WHEN NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NULL THEN 'sage_external_id_missing'
      ELSE NULL::text
    END AS blocker,
    sm.configured_at::timestamptz,
    st.full_name::text AS configured_by_staff_name,
    sm.notes::text
  FROM public.sage_mapping_settings sm
  LEFT JOIN public.staff st ON st.id = sm.configured_by_staff_id
  ORDER BY
    CASE sm.mapping_group
      WHEN 'customer_sales' THEN 0
      WHEN 'supplier_goods_ap' THEN 1
      WHEN 'shipper_ap' THEN 2
      ELSE 3
    END,
    sm.display_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_sage_party_mapping_control_v1()
RETURNS TABLE (
  platform_party_type text,
  platform_party_id uuid,
  platform_party_display_name text,
  platform_context_text text,
  recommended_sage_contact_type text,
  sage_mapping_id uuid,
  sage_contact_id text,
  sage_contact_display_name text,
  sage_contact_reference text,
  sage_contact_type text,
  mapping_status text,
  blocker text,
  verified_at timestamptz,
  verified_by_staff_name text,
  notes text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage party mapping control requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for Sage party mapping control.';
  END IF;

  RETURN QUERY
  WITH parties AS (
    SELECT
      'importer_customer'::text AS platform_party_type,
      i.id AS platform_party_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), i.company_name)::text AS platform_party_display_name,
      concat_ws(' · ', 'Importer/customer', s.name, c.iso_code)::text AS platform_context_text,
      'customer'::text AS recommended_sage_contact_type
    FROM public.importers i
    LEFT JOIN public.shippers s ON s.id = i.shipper_id
    LEFT JOIN public.countries c ON c.id = i.country_id
    WHERE COALESCE(i.active, true) = true

    UNION ALL

    SELECT
      'retailer_supplier'::text AS platform_party_type,
      r.id AS platform_party_id,
      r.name::text AS platform_party_display_name,
      'Retailer/supplier for supplier goods AP'::text AS platform_context_text,
      'supplier'::text AS recommended_sage_contact_type
    FROM public.retailers r
    WHERE COALESCE(r.global_enabled, true) = true

    UNION ALL

    SELECT
      'shipper'::text AS platform_party_type,
      s.id AS platform_party_id,
      s.name::text AS platform_party_display_name,
      'Shipper/logistics AP supplier'::text AS platform_context_text,
      'supplier'::text AS recommended_sage_contact_type
    FROM public.shippers s
    WHERE COALESCE(s.active, true) = true
  )
  SELECT
    p.platform_party_type::text,
    p.platform_party_id::uuid,
    p.platform_party_display_name::text,
    p.platform_context_text::text,
    p.recommended_sage_contact_type::text,
    m.id::uuid AS sage_mapping_id,
    m.sage_contact_id::text,
    m.sage_contact_display_name::text,
    m.sage_contact_reference::text,
    m.sage_contact_type::text,
    CASE
      WHEN m.id IS NULL OR NULLIF(trim(COALESCE(m.sage_contact_id, '')), '') IS NULL THEN 'missing'
      WHEN m.active IS DISTINCT FROM true THEN 'disabled'
      ELSE 'configured'
    END::text AS mapping_status,
    CASE
      WHEN m.id IS NULL OR NULLIF(trim(COALESCE(m.sage_contact_id, '')), '') IS NULL THEN 'sage_contact_id_missing'
      WHEN m.active IS DISTINCT FROM true THEN 'mapping_disabled'
      ELSE NULL::text
    END AS blocker,
    m.verified_at::timestamptz,
    st.full_name::text AS verified_by_staff_name,
    m.notes::text
  FROM parties p
  LEFT JOIN LATERAL (
    SELECT spm.*
    FROM public.sage_party_mappings spm
    WHERE spm.platform_party_type = p.platform_party_type
      AND spm.platform_party_id = p.platform_party_id
      AND spm.active = true
    ORDER BY spm.updated_at DESC
    LIMIT 1
  ) m ON true
  LEFT JOIN public.staff st ON st.id = m.verified_by_staff_id
  ORDER BY
    CASE p.platform_party_type
      WHEN 'importer_customer' THEN 0
      WHEN 'retailer_supplier' THEN 1
      WHEN 'shipper' THEN 2
      ELSE 3
    END,
    p.platform_party_display_name;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_mapping_control_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_party_mapping_control_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_mapping_control_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_sage_party_mapping_control_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
