BEGIN;

-- Contract v5 Phase 3: Sage party/contact mappings.
-- Scope: DB + RPC foundation only. No Sage posting. No OCR behaviour change.
-- This separates platform party -> Sage contact mapping from GL/tax/bank mappings.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
  IF to_regclass('public.importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importers';
  END IF;
  IF to_regclass('public.retailers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.retailers';
  END IF;
  IF to_regclass('public.shippers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shippers';
  END IF;
  IF to_regclass('public.sage_connections') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_connections';
  END IF;
  IF to_regclass('public.sage_businesses') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_businesses';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.sage_party_mappings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_party_type text NOT NULL CHECK (platform_party_type IN ('importer_customer','retailer_supplier','shipper')),
  platform_party_id uuid NOT NULL,
  platform_party_display_name text NOT NULL,
  sage_connection_id uuid NOT NULL REFERENCES public.sage_connections(id) ON DELETE CASCADE,
  sage_business_row_id uuid REFERENCES public.sage_businesses(id) ON DELETE SET NULL,
  sage_business_id text,
  sage_contact_id text,
  sage_contact_display_name text,
  sage_contact_reference text,
  sage_contact_type text NOT NULL DEFAULT 'unknown' CHECK (sage_contact_type IN ('customer','supplier','customer_supplier','unknown')),
  active boolean NOT NULL DEFAULT true,
  verified_at timestamptz,
  verified_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sage_party_mappings_active_contact_check CHECK (
    active IS DISTINCT FROM true OR NULLIF(trim(COALESCE(sage_contact_id, '')), '') IS NOT NULL
  )
);

COMMENT ON TABLE public.sage_party_mappings IS
'Platform party to Sage contact mapping. Separate from GL/tax/bank mapping. OCR matches platform parties first; this table supplies Sage contact ids.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_sage_party_mappings_one_active_per_party
ON public.sage_party_mappings(platform_party_type, platform_party_id, sage_connection_id, sage_business_row_id)
WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_sage_party_mappings_party
ON public.sage_party_mappings(platform_party_type, platform_party_id, active);

CREATE INDEX IF NOT EXISTS idx_sage_party_mappings_sage_contact
ON public.sage_party_mappings(sage_contact_id)
WHERE active = true AND sage_contact_id IS NOT NULL;

ALTER TABLE public.sage_party_mappings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sage_party_mappings FROM PUBLIC, anon, authenticated;

-- v5 mapping seeds: supplier goods AP now has its own GL/tax mappings.
INSERT INTO public.sage_mapping_settings (
  mapping_code,
  mapping_group,
  display_name,
  description,
  value_kind,
  required_for
)
VALUES
  (
    'SUPPLIER_GOODS_AP_LEDGER',
    'supplier_goods_ap',
    'Supplier goods AP / COGS ledger account',
    'Sage ledger/account id/name used for retailer/supplier goods purchase invoice cost lines.',
    'ledger_account_id',
    ARRAY['supplier_goods_ap_purchase_invoice']::text[]
  ),
  (
    'SUPPLIER_GOODS_AP_TAX_RATE',
    'supplier_goods_ap',
    'Supplier goods AP tax rate',
    'Sage tax rate id/name used for retailer/supplier goods purchase invoice lines. Do not use VAT control ledger accounts here.',
    'tax_rate_id',
    ARRAY['supplier_goods_ap_purchase_invoice']::text[]
  )
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    updated_at = now();

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
    sm.mapping_code,
    sm.mapping_group,
    sm.display_name,
    sm.description,
    sm.value_kind,
    sm.required_for,
    sm.sage_external_id,
    sm.sage_display_name,
    sm.is_active,
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
    sm.configured_at,
    st.full_name AS configured_by_staff_name,
    sm.notes
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
    p.platform_party_type,
    p.platform_party_id,
    p.platform_party_display_name,
    p.platform_context_text,
    p.recommended_sage_contact_type,
    m.id AS sage_mapping_id,
    m.sage_contact_id,
    m.sage_contact_display_name,
    m.sage_contact_reference,
    m.sage_contact_type,
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
    m.verified_at,
    st.full_name AS verified_by_staff_name,
    m.notes
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

CREATE OR REPLACE FUNCTION public.internal_upsert_sage_party_mapping_v1(
  p_platform_party_type text,
  p_platform_party_id uuid,
  p_sage_contact_id text,
  p_sage_contact_display_name text DEFAULT NULL,
  p_sage_contact_reference text DEFAULT NULL,
  p_sage_contact_type text DEFAULT 'unknown',
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  platform_party_type text,
  platform_party_id uuid,
  mapping_status text,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_role text;
  v_connection_id uuid;
  v_business_row_id uuid;
  v_sage_business_id text;
  v_party_display text;
  v_contact_id text := NULLIF(trim(COALESCE(p_sage_contact_id, '')), '');
  v_contact_type text := COALESCE(NULLIF(trim(COALESCE(p_sage_contact_type, '')), ''), 'unknown');
  v_updated_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage party mapping update requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff_id, v_role
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required for Sage party mapping update.';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for Sage party mapping update.';
  END IF;

  IF p_platform_party_type NOT IN ('importer_customer','retailer_supplier','shipper') THEN
    RAISE EXCEPTION 'Unsupported Sage party type: %', p_platform_party_type;
  END IF;

  IF v_contact_type NOT IN ('customer','supplier','customer_supplier','unknown') THEN
    RAISE EXCEPTION 'Unsupported Sage contact type: %', v_contact_type;
  END IF;

  SELECT c.id
    INTO v_connection_id
  FROM public.sage_connections c
  WHERE c.status IN ('connected','token_expired','refresh_failed')
  ORDER BY
    CASE c.status WHEN 'connected' THEN 0 WHEN 'token_expired' THEN 1 ELSE 2 END,
    c.updated_at DESC,
    c.created_at DESC
  LIMIT 1;

  IF v_connection_id IS NULL THEN
    RAISE EXCEPTION 'No Sage connection available. Connect Sage before saving party mappings.';
  END IF;

  SELECT b.id, b.sage_business_id
    INTO v_business_row_id, v_sage_business_id
  FROM public.sage_businesses b
  WHERE b.connection_id = v_connection_id
    AND b.status = 'active'
  ORDER BY b.is_primary DESC, b.selected_at DESC NULLS LAST, b.created_at ASC
  LIMIT 1;

  IF v_business_row_id IS NULL THEN
    RAISE EXCEPTION 'No active Sage business available. Select/connect a Sage business before saving party mappings.';
  END IF;

  IF p_platform_party_type = 'importer_customer' THEN
    SELECT COALESCE(NULLIF(trim(i.trading_name), ''), i.company_name)::text
      INTO v_party_display
    FROM public.importers i
    WHERE i.id = p_platform_party_id
      AND COALESCE(i.active, true) = true;
  ELSIF p_platform_party_type = 'retailer_supplier' THEN
    SELECT r.name::text
      INTO v_party_display
    FROM public.retailers r
    WHERE r.id = p_platform_party_id
      AND COALESCE(r.global_enabled, true) = true;
  ELSIF p_platform_party_type = 'shipper' THEN
    SELECT s.name::text
      INTO v_party_display
    FROM public.shippers s
    WHERE s.id = p_platform_party_id
      AND COALESCE(s.active, true) = true;
  END IF;

  IF v_party_display IS NULL THEN
    RAISE EXCEPTION 'Platform party not found or inactive: % %', p_platform_party_type, p_platform_party_id;
  END IF;

  IF v_contact_id IS NULL THEN
    UPDATE public.sage_party_mappings spm
    SET active = false,
        updated_at = now(),
        notes = NULLIF(trim(COALESCE(p_notes, '')), '')
    WHERE spm.platform_party_type = p_platform_party_type
      AND spm.platform_party_id = p_platform_party_id
      AND spm.sage_connection_id = v_connection_id
      AND spm.sage_business_row_id = v_business_row_id
      AND spm.active = true;

    RETURN QUERY SELECT p_platform_party_type, p_platform_party_id, 'missing'::text, 'Party mapping cleared.'::text;
    RETURN;
  END IF;

  UPDATE public.sage_party_mappings spm
  SET platform_party_display_name = v_party_display,
      sage_contact_id = v_contact_id,
      sage_contact_display_name = NULLIF(trim(COALESCE(p_sage_contact_display_name, '')), ''),
      sage_contact_reference = NULLIF(trim(COALESCE(p_sage_contact_reference, '')), ''),
      sage_contact_type = v_contact_type,
      active = true,
      verified_at = now(),
      verified_by_staff_id = v_staff_id,
      notes = NULLIF(trim(COALESCE(p_notes, '')), ''),
      updated_at = now()
  WHERE spm.platform_party_type = p_platform_party_type
    AND spm.platform_party_id = p_platform_party_id
    AND spm.sage_connection_id = v_connection_id
    AND spm.sage_business_row_id = v_business_row_id
    AND spm.active = true;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  IF v_updated_count = 0 THEN
    INSERT INTO public.sage_party_mappings (
      platform_party_type,
      platform_party_id,
      platform_party_display_name,
      sage_connection_id,
      sage_business_row_id,
      sage_business_id,
      sage_contact_id,
      sage_contact_display_name,
      sage_contact_reference,
      sage_contact_type,
      active,
      verified_at,
      verified_by_staff_id,
      notes
    ) VALUES (
      p_platform_party_type,
      p_platform_party_id,
      v_party_display,
      v_connection_id,
      v_business_row_id,
      v_sage_business_id,
      v_contact_id,
      NULLIF(trim(COALESCE(p_sage_contact_display_name, '')), ''),
      NULLIF(trim(COALESCE(p_sage_contact_reference, '')), ''),
      v_contact_type,
      true,
      now(),
      v_staff_id,
      NULLIF(trim(COALESCE(p_notes, '')), '')
    );
  END IF;

  RETURN QUERY SELECT p_platform_party_type, p_platform_party_id, 'configured'::text, 'Party mapping saved.'::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_sage_party_mapping_configured_v1(
  p_platform_party_type text,
  p_platform_party_id uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.sage_party_mappings spm
    WHERE spm.platform_party_type = p_platform_party_type
      AND spm.platform_party_id = p_platform_party_id
      AND spm.active = true
      AND NULLIF(trim(COALESCE(spm.sage_contact_id, '')), '') IS NOT NULL
  )
$$;

REVOKE ALL ON FUNCTION public.internal_sage_mapping_control_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_party_mapping_control_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_upsert_sage_party_mapping_v1(text, uuid, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_party_mapping_configured_v1(text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.internal_sage_mapping_control_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_sage_party_mapping_control_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_upsert_sage_party_mapping_v1(text, uuid, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_sage_party_mapping_configured_v1(text, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
