BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Safety fix for 20260619_groupage_movement_control_v1.
-- Avoid reading fields from an unassigned PL/pgSQL record when no export evidence profile exists yet.

CREATE OR REPLACE FUNCTION public.shipper_create_groupage_movement_v1(
  p_shipment_batch_ids uuid[],
  p_groupage_movement_ref text,
  p_profile_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_movement_id uuid;
  v_selected_count integer;
  v_batch_count integer;
  v_distinct_shipper_count integer;
  v_voided_count integer;
  v_missing_booking_count integer;
  v_grouped_count integer;
  v_exporter_name text;
  v_exporter_address text;
  v_exporter_vat_number text;
  v_default_consignee_name text;
  v_default_consignee_address text;
  v_default_notify_party_name text;
  v_default_notify_party_address text;
  v_shipper_name text;
  v_distinct_country_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: create groupage movement requires auth.uid()';
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

  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one shipment batch.';
  END IF;

  SELECT COUNT(DISTINCT x)::integer INTO v_selected_count FROM unnest(p_shipment_batch_ids) AS x;

  SELECT
    COUNT(DISTINCT b.id)::integer,
    COUNT(DISTINCT b.shipper_id)::integer,
    COUNT(*) FILTER (WHERE b.status = 'voided')::integer,
    COUNT(*) FILTER (WHERE NULLIF(BTRIM(COALESCE(b.booking_ref, '')), '') IS NULL)::integer,
    COUNT(*) FILTER (WHERE gmb.id IS NOT NULL)::integer
  INTO v_batch_count, v_distinct_shipper_count, v_voided_count, v_missing_booking_count, v_grouped_count
  FROM unnest(p_shipment_batch_ids) AS selected(batch_id)
  LEFT JOIN public.shipper_shipment_batches b ON b.id = selected.batch_id
  LEFT JOIN public.shipper_groupage_movement_batches gmb ON gmb.shipment_batch_id = b.id AND gmb.active = true;

  IF v_batch_count <> v_selected_count THEN
    RAISE EXCEPTION 'One or more selected shipment batches were not found.';
  END IF;
  IF v_distinct_shipper_count <> 1 THEN
    RAISE EXCEPTION 'Selected shipment batches must belong to one shipper.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.shipper_shipment_batches b
    WHERE b.id = ANY(p_shipment_batch_ids)
      AND b.shipper_id IS DISTINCT FROM v_shipper_id
  ) THEN
    RAISE EXCEPTION 'Selected shipment batches do not belong to this shipper.';
  END IF;
  IF v_voided_count > 0 THEN
    RAISE EXCEPTION 'Voided shipment batches cannot be grouped.';
  END IF;
  IF v_missing_booking_count > 0 THEN
    RAISE EXCEPTION 'Every selected batch must have a real booking reference.';
  END IF;
  IF v_grouped_count > 0 THEN
    RAISE EXCEPTION 'One or more selected batches are already in an active Groupage Movement.';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_groupage_movement_ref, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Groupage movement reference is required.';
  END IF;

  SELECT COUNT(DISTINCT dp.country_id)::integer INTO v_distinct_country_count
  FROM public.shipper_shipment_batches b
  JOIN unnest(p_shipment_batch_ids) selected(batch_id) ON selected.batch_id = b.id
  LEFT JOIN LATERAL (
    SELECT dp0.country_id
    FROM public.importer_export_delivery_profiles dp0
    WHERE dp0.importer_id = b.importer_id
      AND dp0.active = true
    ORDER BY dp0.updated_at DESC, dp0.created_at DESC
    LIMIT 1
  ) dp ON true
  WHERE dp.country_id IS NOT NULL;

  IF COALESCE(v_distinct_country_count, 0) > 1 THEN
    RAISE EXCEPTION 'Selected shipment batches must belong to one destination jurisdiction.';
  END IF;

  SELECT
    p.exporter_name,
    p.exporter_address,
    p.exporter_vat_number,
    p.default_movement_consignee_name,
    p.default_movement_consignee_address,
    p.default_notify_party_name,
    p.default_notify_party_address
  INTO
    v_exporter_name,
    v_exporter_address,
    v_exporter_vat_number,
    v_default_consignee_name,
    v_default_consignee_address,
    v_default_notify_party_name,
    v_default_notify_party_address
  FROM public.tenant_export_evidence_profiles p
  WHERE p.active = true
    AND (p_profile_id IS NULL OR p.id = p_profile_id)
    AND (p.shipper_id IS NULL OR p.shipper_id = v_shipper_id)
  ORDER BY CASE WHEN p.id = p_profile_id THEN 0 WHEN p.shipper_id = v_shipper_id THEN 1 ELSE 2 END, p.updated_at DESC, p.created_at DESC
  LIMIT 1;

  SELECT s.name::text INTO v_shipper_name FROM public.shippers s WHERE s.id = v_shipper_id;

  INSERT INTO public.shipper_groupage_movements (
    shipper_id,
    destination_country_id,
    groupage_movement_ref,
    status,
    exporter_name_snapshot,
    exporter_address_snapshot,
    exporter_vat_number_snapshot,
    shipper_name_snapshot,
    movement_consignee_name_snapshot,
    movement_consignee_address_snapshot,
    notify_party_name_snapshot,
    notify_party_address_snapshot,
    created_by_shipper_user_id,
    updated_by_shipper_user_id
  ) VALUES (
    v_shipper_id,
    (
      SELECT dp.country_id
      FROM public.shipper_shipment_batches b
      JOIN unnest(p_shipment_batch_ids) selected(batch_id) ON selected.batch_id = b.id
      LEFT JOIN LATERAL (
        SELECT dp0.country_id
        FROM public.importer_export_delivery_profiles dp0
        WHERE dp0.importer_id = b.importer_id
          AND dp0.active = true
        ORDER BY dp0.updated_at DESC, dp0.created_at DESC
        LIMIT 1
      ) dp ON true
      WHERE dp.country_id IS NOT NULL
      LIMIT 1
    ),
    BTRIM(p_groupage_movement_ref),
    'draft',
    v_exporter_name,
    v_exporter_address,
    v_exporter_vat_number,
    v_shipper_name,
    v_default_consignee_name,
    v_default_consignee_address,
    v_default_notify_party_name,
    v_default_notify_party_address,
    v_shipper_user_id,
    v_shipper_user_id
  ) RETURNING id INTO v_movement_id;

  INSERT INTO public.shipper_groupage_movement_batches (
    groupage_movement_id,
    shipment_batch_id,
    shipper_id,
    importer_id_snapshot,
    importer_name_snapshot,
    booking_ref_snapshot,
    final_recipient_name_snapshot,
    final_recipient_address_snapshot
  )
  SELECT
    v_movement_id,
    b.id,
    b.shipper_id,
    b.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text,
    b.booking_ref::text,
    COALESCE(NULLIF(dp.final_recipient_name, ''), NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text,
    NULLIF(CONCAT_WS(', ', dp.final_recipient_address_line_1, dp.final_recipient_address_line_2, dp.final_recipient_city, dp.final_recipient_region, dp.final_recipient_country), '')::text
  FROM public.shipper_shipment_batches b
  LEFT JOIN public.importers i ON i.id = b.importer_id
  LEFT JOIN LATERAL (
    SELECT dp0.*
    FROM public.importer_export_delivery_profiles dp0
    WHERE dp0.importer_id = b.importer_id
      AND dp0.active = true
    ORDER BY dp0.updated_at DESC, dp0.created_at DESC
    LIMIT 1
  ) dp ON true
  WHERE b.id = ANY(p_shipment_batch_ids);

  RETURN v_movement_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_create_groupage_movement_v1(uuid[], text, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
