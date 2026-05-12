BEGIN;

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
    END::text AS blocker,
    sm.configured_at::timestamptz,
    st.full_name::text AS configured_by_staff_name,
    sm.notes::text
  FROM public.sage_mapping_settings sm
  LEFT JOIN public.staff st ON st.id = sm.configured_by_staff_id
  ORDER BY
    CASE sm.mapping_group
      WHEN 'customer_sales' THEN 0
      WHEN 'shipper_ap' THEN 1
      ELSE 2
    END,
    sm.display_name;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_mapping_control_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_mapping_control_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
