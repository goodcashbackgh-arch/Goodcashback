BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Groupage Movement Control foundation.
-- Contract: docs/governing-pack/ui/GROUPAGE_MOVEMENT_CONTROL_CONTRACT_v1.md
-- Design rule: groupage is a sidecar/control layer. Shipment batches remain the operational source of truth.

CREATE TABLE IF NOT EXISTS public.tenant_export_evidence_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  shipper_id uuid REFERENCES public.shippers(id),
  country_id uuid,
  profile_name text NOT NULL DEFAULT 'Default export evidence profile',
  exporter_name text,
  exporter_address text,
  exporter_vat_number text,
  default_movement_consignee_name text,
  default_movement_consignee_address text,
  default_notify_party_name text,
  default_notify_party_address text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tenant_export_evidence_profiles_shipper_active
  ON public.tenant_export_evidence_profiles(shipper_id, active, updated_at DESC);

ALTER TABLE public.tenant_export_evidence_profiles ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'tenant_export_evidence_profiles'
      AND policyname = 'tenant_export_evidence_profiles_select'
  ) THEN
    CREATE POLICY tenant_export_evidence_profiles_select
    ON public.tenant_export_evidence_profiles
    FOR SELECT TO authenticated
    USING (
      public.is_active_staff()
      OR EXISTS (
        SELECT 1
        FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND (tenant_export_evidence_profiles.shipper_id IS NULL OR su.shipper_id = tenant_export_evidence_profiles.shipper_id)
      )
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.importer_export_delivery_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  importer_id uuid NOT NULL REFERENCES public.importers(id) ON DELETE CASCADE,
  country_id uuid,
  final_recipient_name text,
  final_recipient_address_line_1 text,
  final_recipient_address_line_2 text,
  final_recipient_city text,
  final_recipient_region text,
  final_recipient_country text,
  final_recipient_phone text,
  final_recipient_email text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_importer_export_delivery_profiles_importer_active
  ON public.importer_export_delivery_profiles(importer_id, active, updated_at DESC);

ALTER TABLE public.importer_export_delivery_profiles ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'importer_export_delivery_profiles'
      AND policyname = 'importer_export_delivery_profiles_select'
  ) THEN
    CREATE POLICY importer_export_delivery_profiles_select
    ON public.importer_export_delivery_profiles
    FOR SELECT TO authenticated
    USING (
      public.is_active_staff()
      OR EXISTS (
        SELECT 1
        FROM public.shipper_users su
        JOIN public.shipper_shipment_batches b ON b.shipper_id = su.shipper_id
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND b.importer_id = importer_export_delivery_profiles.importer_id
      )
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.shipper_groupage_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  destination_country_id uuid,
  currency_code text,
  groupage_movement_ref text NOT NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN (
    'draft',
    'movement_facts_incomplete',
    'movement_facts_ready',
    'signed_export_pack_submitted',
    'signed_export_pack_part_accepted',
    'signed_export_pack_fully_accepted',
    'pod_part_submitted',
    'pod_part_accepted',
    'pod_fully_accepted',
    'complete',
    'voided'
  )),
  mbl_bol_sea_waybill_ref text,
  container_number text,
  seal_number text,
  vessel_voyage text,
  port_of_loading text,
  port_of_discharge text,
  place_of_delivery text,
  export_shipment_date date,
  weight_text text,
  exporter_name_snapshot text,
  exporter_address_snapshot text,
  exporter_vat_number_snapshot text,
  shipper_name_snapshot text,
  shipper_address_snapshot text,
  movement_consignee_name_snapshot text,
  movement_consignee_address_snapshot text,
  notify_party_name_snapshot text,
  notify_party_address_snapshot text,
  authorised_name text,
  signature_stamp_confirmation_yn boolean NOT NULL DEFAULT false,
  created_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  updated_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ux_shipper_groupage_movements_shipper_ref UNIQUE (shipper_id, groupage_movement_ref)
);

CREATE INDEX IF NOT EXISTS idx_shipper_groupage_movements_shipper_status
  ON public.shipper_groupage_movements(shipper_id, status, created_at DESC);

ALTER TABLE public.shipper_groupage_movements ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'shipper_groupage_movements'
      AND policyname = 'shipper_groupage_movements_select'
  ) THEN
    CREATE POLICY shipper_groupage_movements_select
    ON public.shipper_groupage_movements
    FOR SELECT TO authenticated
    USING (
      public.is_active_staff()
      OR EXISTS (
        SELECT 1
        FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = shipper_groupage_movements.shipper_id
      )
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.shipper_groupage_movement_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  groupage_movement_id uuid NOT NULL REFERENCES public.shipper_groupage_movements(id) ON DELETE CASCADE,
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id) ON DELETE CASCADE,
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  importer_id_snapshot uuid,
  importer_name_snapshot text,
  booking_ref_snapshot text,
  final_recipient_name_snapshot text,
  final_recipient_address_snapshot text,
  active boolean NOT NULL DEFAULT true,
  added_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_shipper_groupage_movement_batches_active_batch
  ON public.shipper_groupage_movement_batches(shipment_batch_id)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_shipper_groupage_movement_batches_movement
  ON public.shipper_groupage_movement_batches(groupage_movement_id, active, added_at);

ALTER TABLE public.shipper_groupage_movement_batches ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'shipper_groupage_movement_batches'
      AND policyname = 'shipper_groupage_movement_batches_select'
  ) THEN
    CREATE POLICY shipper_groupage_movement_batches_select
    ON public.shipper_groupage_movement_batches
    FOR SELECT TO authenticated
    USING (
      public.is_active_staff()
      OR EXISTS (
        SELECT 1
        FROM public.shipper_users su
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = shipper_groupage_movement_batches.shipper_id
      )
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.shipper_groupage_movement_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  groupage_movement_id uuid NOT NULL REFERENCES public.shipper_groupage_movements(id) ON DELETE CASCADE,
  document_kind text NOT NULL CHECK (document_kind IN ('signed_export_pack','pod_delivery_evidence','other_groupage_evidence')),
  document_ref text,
  file_url text NOT NULL,
  notes text,
  created_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shipper_groupage_movement_documents_movement
  ON public.shipper_groupage_movement_documents(groupage_movement_id, document_kind, created_at DESC);

ALTER TABLE public.shipper_groupage_movement_documents ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'shipper_groupage_movement_documents'
      AND policyname = 'shipper_groupage_movement_documents_select'
  ) THEN
    CREATE POLICY shipper_groupage_movement_documents_select
    ON public.shipper_groupage_movement_documents
    FOR SELECT TO authenticated
    USING (
      public.is_active_staff()
      OR EXISTS (
        SELECT 1
        FROM public.shipper_users su
        JOIN public.shipper_groupage_movements gm ON gm.id = shipper_groupage_movement_documents.groupage_movement_id
        WHERE su.auth_user_id = auth.uid()
          AND su.active = true
          AND su.shipper_id = gm.shipper_id
      )
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_groupage_candidate_batches_v1()
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  importer_id uuid,
  importer_name text,
  final_recipient_name text,
  final_recipient_address text,
  box_count integer,
  package_count bigint,
  item_qty numeric,
  invoice_value_gbp numeric,
  export_evidence_status text,
  pod_status text,
  existing_groupage_movement_id uuid,
  existing_groupage_movement_ref text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: groupage candidates require auth.uid()';
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

  RETURN QUERY
  WITH package_totals AS (
    SELECT p.shipment_batch_id, COUNT(*)::bigint AS package_count
    FROM public.shipper_shipment_batch_packages p
    WHERE p.active = true
    GROUP BY p.shipment_batch_id
  ), doc_status AS (
    SELECT
      d.shipment_batch_id,
      CASE
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'accepted_current') THEN 'accepted_current'
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') THEN 'submitted_for_review'
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') THEN 'rejected_resubmit_required'
        ELSE 'not_started'
      END AS export_evidence_status,
      CASE
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'accepted_current') THEN 'accepted_current'
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') THEN 'submitted_for_review'
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') THEN 'rejected_resubmit_required'
        ELSE 'not_started'
      END AS pod_status
    FROM public.shipper_final_export_evidence_documents d
    WHERE d.shipper_id = v_shipper_id
    GROUP BY d.shipment_batch_id
  )
  SELECT
    b.id,
    b.booking_ref::text,
    b.importer_id,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text AS importer_name,
    COALESCE(NULLIF(dp.final_recipient_name, ''), NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text AS final_recipient_name,
    NULLIF(CONCAT_WS(', ', dp.final_recipient_address_line_1, dp.final_recipient_address_line_2, dp.final_recipient_city, dp.final_recipient_region, dp.final_recipient_country), '')::text AS final_recipient_address,
    b.box_count,
    COALESCE(pt.package_count, 0)::bigint,
    COALESCE(pack.item_qty, 0)::numeric,
    COALESCE(pack.invoice_value_gbp, 0)::numeric,
    COALESCE(ds.export_evidence_status, 'not_started')::text,
    COALESCE(ds.pod_status, 'not_started')::text,
    gm.id,
    gm.groupage_movement_ref::text
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
  LEFT JOIN package_totals pt ON pt.shipment_batch_id = b.id
  LEFT JOIN LATERAL (
    SELECT SUM(pr.qty_allocated)::numeric AS item_qty, SUM(pr.total_export_value_gbp)::numeric AS invoice_value_gbp
    FROM public.shipper_export_evidence_pack_preview_v1(b.id) pr
  ) pack ON true
  LEFT JOIN doc_status ds ON ds.shipment_batch_id = b.id
  LEFT JOIN public.shipper_groupage_movement_batches gmb ON gmb.shipment_batch_id = b.id AND gmb.active = true
  LEFT JOIN public.shipper_groupage_movements gm ON gm.id = gmb.groupage_movement_id AND gm.status <> 'voided'
  WHERE b.shipper_id = v_shipper_id
    AND b.status <> 'voided'
  ORDER BY b.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_groupage_candidate_batches_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_groupage_movements_v1()
RETURNS TABLE (
  groupage_movement_id uuid,
  groupage_movement_ref text,
  status text,
  shipper_id uuid,
  shipper_name text,
  batch_count bigint,
  signed_export_pack_count bigint,
  pod_document_count bigint,
  accepted_export_pack_count bigint,
  accepted_pod_count bigint,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: groupage movements require auth.uid()';
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

  RETURN QUERY
  SELECT
    gm.id,
    gm.groupage_movement_ref::text,
    gm.status::text,
    gm.shipper_id,
    s.name::text,
    COUNT(DISTINCT gmb.shipment_batch_id)::bigint AS batch_count,
    COUNT(DISTINCT gd.id) FILTER (WHERE gd.document_kind = 'signed_export_pack')::bigint AS signed_export_pack_count,
    COUNT(DISTINCT gd.id) FILTER (WHERE gd.document_kind = 'pod_delivery_evidence')::bigint AS pod_document_count,
    COUNT(DISTINCT d.id) FILTER (WHERE d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'accepted_current')::bigint AS accepted_export_pack_count,
    COUNT(DISTINCT d.id) FILTER (WHERE d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'accepted_current')::bigint AS accepted_pod_count,
    gm.created_at,
    gm.updated_at
  FROM public.shipper_groupage_movements gm
  JOIN public.shippers s ON s.id = gm.shipper_id
  LEFT JOIN public.shipper_groupage_movement_batches gmb ON gmb.groupage_movement_id = gm.id AND gmb.active = true
  LEFT JOIN public.shipper_groupage_movement_documents gd ON gd.groupage_movement_id = gm.id
  LEFT JOIN public.shipper_final_export_evidence_documents d ON d.shipment_batch_id = gmb.shipment_batch_id AND d.document_ref = gm.groupage_movement_ref
  WHERE gm.shipper_id = v_shipper_id
    AND gm.status <> 'voided'
  GROUP BY gm.id, gm.groupage_movement_ref, gm.status, gm.shipper_id, s.name, gm.created_at, gm.updated_at
  ORDER BY gm.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_groupage_movements_v1() TO authenticated;

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
  v_profile record;
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

  SELECT p.* INTO v_profile
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
    v_profile.exporter_name,
    v_profile.exporter_address,
    v_profile.exporter_vat_number,
    v_shipper_name,
    v_profile.default_movement_consignee_name,
    v_profile.default_movement_consignee_address,
    v_profile.default_notify_party_name,
    v_profile.default_notify_party_address,
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

CREATE OR REPLACE FUNCTION public.shipper_save_groupage_movement_facts_v1(
  p_groupage_movement_id uuid,
  p_mbl_bol_sea_waybill_ref text DEFAULT NULL,
  p_container_number text DEFAULT NULL,
  p_seal_number text DEFAULT NULL,
  p_vessel_voyage text DEFAULT NULL,
  p_port_of_loading text DEFAULT NULL,
  p_port_of_discharge text DEFAULT NULL,
  p_place_of_delivery text DEFAULT NULL,
  p_export_shipment_date date DEFAULT NULL,
  p_weight_text text DEFAULT NULL,
  p_movement_consignee_name text DEFAULT NULL,
  p_movement_consignee_address text DEFAULT NULL,
  p_notify_party_name text DEFAULT NULL,
  p_notify_party_address text DEFAULT NULL,
  p_authorised_name text DEFAULT NULL,
  p_signature_stamp_confirmation_yn boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_movement record;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: save groupage movement facts requires auth.uid()';
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

  SELECT * INTO v_movement
  FROM public.shipper_groupage_movements gm
  WHERE gm.id = p_groupage_movement_id
    AND gm.shipper_id = v_shipper_id
    AND gm.status <> 'voided';

  IF v_movement.id IS NULL THEN
    RAISE EXCEPTION 'Groupage Movement not found for this shipper.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movement_batches gmb
    JOIN public.shipper_shipment_batches b ON b.id = gmb.shipment_batch_id
    WHERE gmb.groupage_movement_id = p_groupage_movement_id
      AND gmb.active = true
      AND b.status IS DISTINCT FROM 'created'
  ) THEN
    RAISE EXCEPTION 'Groupage movement facts can only be applied while included batches are still editable/created.';
  END IF;

  v_status := CASE
    WHEN NULLIF(BTRIM(COALESCE(p_mbl_bol_sea_waybill_ref, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_container_number, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_seal_number, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_vessel_voyage, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_port_of_loading, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_port_of_discharge, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_place_of_delivery, '')), '') IS NOT NULL
     AND p_export_shipment_date IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_authorised_name, '')), '') IS NOT NULL
     AND COALESCE(p_signature_stamp_confirmation_yn, false) = true
    THEN 'movement_facts_ready'
    ELSE 'movement_facts_incomplete'
  END;

  UPDATE public.shipper_groupage_movements gm
  SET mbl_bol_sea_waybill_ref = NULLIF(BTRIM(COALESCE(p_mbl_bol_sea_waybill_ref, '')), ''),
      container_number = NULLIF(BTRIM(COALESCE(p_container_number, '')), ''),
      seal_number = NULLIF(BTRIM(COALESCE(p_seal_number, '')), ''),
      vessel_voyage = NULLIF(BTRIM(COALESCE(p_vessel_voyage, '')), ''),
      port_of_loading = NULLIF(BTRIM(COALESCE(p_port_of_loading, '')), ''),
      port_of_discharge = NULLIF(BTRIM(COALESCE(p_port_of_discharge, '')), ''),
      place_of_delivery = NULLIF(BTRIM(COALESCE(p_place_of_delivery, '')), ''),
      export_shipment_date = p_export_shipment_date,
      weight_text = NULLIF(BTRIM(COALESCE(p_weight_text, '')), ''),
      movement_consignee_name_snapshot = COALESCE(NULLIF(BTRIM(COALESCE(p_movement_consignee_name, '')), ''), gm.movement_consignee_name_snapshot),
      movement_consignee_address_snapshot = COALESCE(NULLIF(BTRIM(COALESCE(p_movement_consignee_address, '')), ''), gm.movement_consignee_address_snapshot),
      notify_party_name_snapshot = COALESCE(NULLIF(BTRIM(COALESCE(p_notify_party_name, '')), ''), gm.notify_party_name_snapshot),
      notify_party_address_snapshot = COALESCE(NULLIF(BTRIM(COALESCE(p_notify_party_address, '')), ''), gm.notify_party_address_snapshot),
      authorised_name = NULLIF(BTRIM(COALESCE(p_authorised_name, '')), ''),
      signature_stamp_confirmation_yn = COALESCE(p_signature_stamp_confirmation_yn, false),
      status = v_status,
      updated_by_shipper_user_id = v_shipper_user_id,
      updated_at = now()
  WHERE gm.id = p_groupage_movement_id;

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
  )
  SELECT
    b.id,
    b.shipper_id,
    NULLIF(BTRIM(COALESCE(p_mbl_bol_sea_waybill_ref, '')), ''),
    NULLIF(BTRIM(COALESCE(p_container_number, '')), ''),
    NULLIF(BTRIM(COALESCE(p_seal_number, '')), ''),
    NULLIF(BTRIM(COALESCE(p_vessel_voyage, '')), ''),
    NULLIF(BTRIM(COALESCE(p_port_of_loading, '')), ''),
    NULLIF(BTRIM(COALESCE(p_port_of_discharge, '')), ''),
    NULLIF(BTRIM(COALESCE(p_place_of_delivery, '')), ''),
    p_export_shipment_date,
    COALESCE(NULLIF(BTRIM(COALESCE(b.box_count::text, '')), '') || ' boxes/packages', 'Groupage movement packages'),
    NULLIF(BTRIM(COALESCE(p_authorised_name, '')), ''),
    COALESCE(p_signature_stamp_confirmation_yn, false),
    'Applied from Groupage Movement ' || v_movement.groupage_movement_ref,
    CASE WHEN v_status = 'movement_facts_ready' THEN 'completion_fields_ready' ELSE 'completion_fields_draft' END,
    v_shipper_user_id,
    v_shipper_user_id
  FROM public.shipper_groupage_movement_batches gmb
  JOIN public.shipper_shipment_batches b ON b.id = gmb.shipment_batch_id
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true
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
    updated_at = now();

  RETURN p_groupage_movement_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_save_groupage_movement_facts_v1(uuid,text,text,text,text,text,text,text,date,text,text,text,text,text,text,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_groupage_movement_detail_v1(p_groupage_movement_id uuid)
RETURNS TABLE (
  groupage_movement_id uuid,
  groupage_movement_ref text,
  groupage_status text,
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
  weight_text text,
  exporter_name_snapshot text,
  exporter_address_snapshot text,
  exporter_vat_number_snapshot text,
  movement_consignee_name_snapshot text,
  movement_consignee_address_snapshot text,
  notify_party_name_snapshot text,
  notify_party_address_snapshot text,
  authorised_name text,
  signature_stamp_confirmation_yn boolean,
  shipment_batch_id uuid,
  booking_ref text,
  importer_id uuid,
  importer_name text,
  final_recipient_name text,
  final_recipient_address text,
  box_count integer,
  package_count bigint,
  item_qty numeric,
  invoice_value_gbp numeric,
  export_evidence_status text,
  pod_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
  v_is_staff boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: groupage movement detail requires auth.uid()';
  END IF;

  v_is_staff := public.is_active_staff();

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF NOT v_is_staff AND v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account or active staff required.';
  END IF;

  RETURN QUERY
  WITH package_totals AS (
    SELECT p.shipment_batch_id, COUNT(*)::bigint AS package_count
    FROM public.shipper_shipment_batch_packages p
    WHERE p.active = true
    GROUP BY p.shipment_batch_id
  ), doc_status AS (
    SELECT
      d.shipment_batch_id,
      CASE
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'accepted_current') THEN 'accepted_current'
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') THEN 'submitted_for_review'
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') THEN 'rejected_resubmit_required'
        ELSE 'not_started'
      END AS export_evidence_status,
      CASE
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'accepted_current') THEN 'accepted_current'
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') THEN 'submitted_for_review'
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') THEN 'rejected_resubmit_required'
        ELSE 'not_started'
      END AS pod_status
    FROM public.shipper_final_export_evidence_documents d
    GROUP BY d.shipment_batch_id
  )
  SELECT
    gm.id,
    gm.groupage_movement_ref::text,
    gm.status::text,
    gm.shipper_id,
    COALESCE(gm.shipper_name_snapshot, s.name)::text,
    gm.mbl_bol_sea_waybill_ref,
    gm.container_number,
    gm.seal_number,
    gm.vessel_voyage,
    gm.port_of_loading,
    gm.port_of_discharge,
    gm.place_of_delivery,
    gm.export_shipment_date,
    gm.weight_text,
    gm.exporter_name_snapshot,
    gm.exporter_address_snapshot,
    gm.exporter_vat_number_snapshot,
    gm.movement_consignee_name_snapshot,
    gm.movement_consignee_address_snapshot,
    gm.notify_party_name_snapshot,
    gm.notify_party_address_snapshot,
    gm.authorised_name,
    gm.signature_stamp_confirmation_yn,
    b.id,
    b.booking_ref::text,
    b.importer_id,
    gmb.importer_name_snapshot,
    gmb.final_recipient_name_snapshot,
    gmb.final_recipient_address_snapshot,
    b.box_count,
    COALESCE(pt.package_count, 0)::bigint,
    COALESCE(pack.item_qty, 0)::numeric,
    COALESCE(pack.invoice_value_gbp, 0)::numeric,
    COALESCE(ds.export_evidence_status, 'not_started')::text,
    COALESCE(ds.pod_status, 'not_started')::text
  FROM public.shipper_groupage_movements gm
  JOIN public.shippers s ON s.id = gm.shipper_id
  JOIN public.shipper_groupage_movement_batches gmb ON gmb.groupage_movement_id = gm.id AND gmb.active = true
  JOIN public.shipper_shipment_batches b ON b.id = gmb.shipment_batch_id
  LEFT JOIN package_totals pt ON pt.shipment_batch_id = b.id
  LEFT JOIN LATERAL (
    SELECT SUM(pr.qty_allocated)::numeric AS item_qty, SUM(pr.total_export_value_gbp)::numeric AS invoice_value_gbp
    FROM public.shipper_export_evidence_pack_preview_v1(b.id) pr
  ) pack ON true
  LEFT JOIN doc_status ds ON ds.shipment_batch_id = b.id
  WHERE gm.id = p_groupage_movement_id
    AND gm.status <> 'voided'
    AND (v_is_staff OR gm.shipper_id = v_shipper_id)
  ORDER BY b.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_groupage_movement_detail_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_groupage_export_pack_preview_v1(p_groupage_movement_id uuid)
RETURNS TABLE (
  groupage_movement_id uuid,
  groupage_movement_ref text,
  groupage_status text,
  exporter_name text,
  exporter_address text,
  exporter_vat_number text,
  shipper_name text,
  movement_consignee_name text,
  movement_consignee_address text,
  notify_party_name text,
  notify_party_address text,
  weight_text text,
  shipment_batch_id uuid,
  booking_ref text,
  importer_name text,
  final_recipient_name text,
  final_recipient_address text,
  eep_ref text,
  package_box_ref text,
  total_boxes integer,
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
  completion_status text,
  order_id uuid,
  order_ref text,
  sales_invoice_ref text,
  supplier_invoice_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  unit_export_value_gbp numeric,
  total_export_value_gbp numeric,
  destination text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
  v_is_staff boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: groupage export pack preview requires auth.uid()';
  END IF;

  v_is_staff := public.is_active_staff();
  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF NOT v_is_staff AND v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account or active staff required.';
  END IF;

  RETURN QUERY
  SELECT
    gm.id,
    gm.groupage_movement_ref::text,
    gm.status::text,
    gm.exporter_name_snapshot,
    gm.exporter_address_snapshot,
    gm.exporter_vat_number_snapshot,
    COALESCE(gm.shipper_name_snapshot, pr.shipper_name)::text,
    gm.movement_consignee_name_snapshot,
    gm.movement_consignee_address_snapshot,
    gm.notify_party_name_snapshot,
    gm.notify_party_address_snapshot,
    gm.weight_text,
    pr.shipment_batch_id,
    pr.booking_ref,
    gmb.importer_name_snapshot,
    gmb.final_recipient_name_snapshot,
    gmb.final_recipient_address_snapshot,
    pr.eep_ref,
    pr.package_box_ref,
    pr.total_boxes,
    COALESCE(gm.mbl_bol_sea_waybill_ref, pr.mbl_bol_sea_waybill_ref)::text,
    COALESCE(gm.container_number, pr.container_number)::text,
    COALESCE(gm.seal_number, pr.seal_number)::text,
    COALESCE(gm.vessel_voyage, pr.vessel_voyage)::text,
    COALESCE(gm.port_of_loading, pr.port_of_loading)::text,
    COALESCE(gm.port_of_discharge, pr.port_of_discharge)::text,
    COALESCE(gm.place_of_delivery, pr.place_of_delivery)::text,
    COALESCE(gm.export_shipment_date, pr.export_shipment_date),
    pr.final_package_confirmation,
    COALESCE(gm.authorised_name, pr.authorised_name)::text,
    pr.completion_status,
    pr.order_id,
    pr.order_ref,
    pr.sales_invoice_ref,
    pr.supplier_invoice_ref,
    pr.supplier_invoice_line_id,
    pr.item_description,
    pr.qty_allocated,
    pr.unit_export_value_gbp,
    pr.total_export_value_gbp,
    pr.destination
  FROM public.shipper_groupage_movements gm
  JOIN public.shipper_groupage_movement_batches gmb ON gmb.groupage_movement_id = gm.id AND gmb.active = true
  JOIN LATERAL public.shipper_export_evidence_pack_preview_v1(gmb.shipment_batch_id) pr ON true
  WHERE gm.id = p_groupage_movement_id
    AND gm.status <> 'voided'
    AND (v_is_staff OR gm.shipper_id = v_shipper_id)
  ORDER BY gmb.booking_ref_snapshot, pr.customer_name, pr.order_ref NULLS LAST, pr.item_description NULLS LAST;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_groupage_export_pack_preview_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_submit_groupage_signed_export_pack_v1(
  p_groupage_movement_id uuid,
  p_file_url text,
  p_document_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_movement record;
  v_doc_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: submit groupage signed export pack requires auth.uid()';
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

  SELECT * INTO v_movement
  FROM public.shipper_groupage_movements gm
  WHERE gm.id = p_groupage_movement_id
    AND gm.shipper_id = v_shipper_id
    AND gm.status <> 'voided';

  IF v_movement.id IS NULL THEN
    RAISE EXCEPTION 'Groupage Movement not found for this shipper.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_file_url, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Signed export pack file URL is required.';
  END IF;

  IF v_movement.status <> 'movement_facts_ready' THEN
    RAISE EXCEPTION 'Complete and save Groupage Movement facts before uploading the signed export pack.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(v_movement.exporter_name_snapshot, '')), '') IS NULL
     OR NULLIF(BTRIM(COALESCE(v_movement.movement_consignee_name_snapshot, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Exporter and movement consignee profile details are required before final upload.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movement_batches gmb
    LEFT JOIN public.shipper_export_evidence_completion_fields f ON f.shipment_batch_id = gmb.shipment_batch_id
    WHERE gmb.groupage_movement_id = p_groupage_movement_id
      AND gmb.active = true
      AND COALESCE(f.completion_status, 'completion_fields_draft') <> 'completion_fields_ready'
  ) THEN
    RAISE EXCEPTION 'One or more included batches are missing ready export evidence completion fields.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movement_batches gmb
    WHERE gmb.groupage_movement_id = p_groupage_movement_id
      AND gmb.active = true
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_export_evidence_pack_preview_v1(gmb.shipment_batch_id) pr
      )
  ) THEN
    RAISE EXCEPTION 'One or more included batches have no export pack preview rows.';
  END IF;

  INSERT INTO public.shipper_groupage_movement_documents (
    groupage_movement_id, document_kind, document_ref, file_url, notes, created_by_shipper_user_id
  ) VALUES (
    p_groupage_movement_id,
    'signed_export_pack',
    COALESCE(NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), v_movement.groupage_movement_ref),
    BTRIM(p_file_url),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    v_shipper_user_id
  ) RETURNING id INTO v_doc_id;

  INSERT INTO public.shipper_final_export_evidence_documents (
    shipment_batch_id, shipper_id, document_kind, document_ref, file_url, notes, review_status, created_by_shipper_user_id
  )
  SELECT
    gmb.shipment_batch_id,
    v_shipper_id,
    'completed_cos',
    COALESCE(NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), v_movement.groupage_movement_ref),
    BTRIM(p_file_url),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    'submitted_for_review',
    v_shipper_user_id
  FROM public.shipper_groupage_movement_batches gmb
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true;

  UPDATE public.shipper_groupage_movements
  SET status = 'signed_export_pack_submitted',
      updated_by_shipper_user_id = v_shipper_user_id,
      updated_at = now()
  WHERE id = p_groupage_movement_id;

  RETURN v_doc_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_submit_groupage_signed_export_pack_v1(uuid,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_submit_groupage_pod_v1(
  p_groupage_movement_id uuid,
  p_shipment_batch_ids uuid[],
  p_file_url text,
  p_document_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_movement record;
  v_selected_count integer;
  v_valid_count integer;
  v_doc_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: submit groupage POD requires auth.uid()';
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

  SELECT * INTO v_movement
  FROM public.shipper_groupage_movements gm
  WHERE gm.id = p_groupage_movement_id
    AND gm.shipper_id = v_shipper_id
    AND gm.status <> 'voided';

  IF v_movement.id IS NULL THEN
    RAISE EXCEPTION 'Groupage Movement not found for this shipper.';
  END IF;

  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one booking reference covered by the POD.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_file_url, '')), '') IS NULL THEN
    RAISE EXCEPTION 'POD file URL is required.';
  END IF;

  SELECT COUNT(DISTINCT x)::integer INTO v_selected_count FROM unnest(p_shipment_batch_ids) AS x;
  SELECT COUNT(DISTINCT gmb.shipment_batch_id)::integer INTO v_valid_count
  FROM public.shipper_groupage_movement_batches gmb
  JOIN public.shipper_shipment_batches b ON b.id = gmb.shipment_batch_id
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true
    AND gmb.shipment_batch_id = ANY(p_shipment_batch_ids)
    AND gmb.shipper_id = v_shipper_id
    AND b.status <> 'voided';

  IF v_valid_count <> v_selected_count THEN
    RAISE EXCEPTION 'Selected POD booking references must belong to this active Groupage Movement.';
  END IF;

  INSERT INTO public.shipper_groupage_movement_documents (
    groupage_movement_id, document_kind, document_ref, file_url, notes, created_by_shipper_user_id
  ) VALUES (
    p_groupage_movement_id,
    'pod_delivery_evidence',
    COALESCE(NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), v_movement.groupage_movement_ref),
    BTRIM(p_file_url),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    v_shipper_user_id
  ) RETURNING id INTO v_doc_id;

  INSERT INTO public.shipper_final_export_evidence_documents (
    shipment_batch_id, shipper_id, document_kind, document_ref, file_url, notes, review_status, created_by_shipper_user_id
  )
  SELECT
    gmb.shipment_batch_id,
    v_shipper_id,
    'pod_delivery_evidence',
    COALESCE(NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), v_movement.groupage_movement_ref),
    BTRIM(p_file_url),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    'submitted_for_review',
    v_shipper_user_id
  FROM public.shipper_groupage_movement_batches gmb
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true
    AND gmb.shipment_batch_id = ANY(p_shipment_batch_ids);

  UPDATE public.shipper_groupage_movements
  SET status = CASE WHEN status = 'complete' THEN status ELSE 'pod_part_submitted' END,
      updated_by_shipper_user_id = v_shipper_user_id,
      updated_at = now()
  WHERE id = p_groupage_movement_id;

  RETURN v_doc_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_submit_groupage_pod_v1(uuid,uuid[],text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_shipping_control_v2()
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  batch_status text,
  shipment_cutoff_at timestamptz,
  dispatched_at timestamptz,
  box_count integer,
  created_at timestamptz,
  package_count bigint,
  order_count bigint,
  allocated_package_count bigint,
  unallocated_package_count bigint,
  item_qty numeric,
  receipt_issue_count bigint,
  package_refs_preview text,
  order_refs_preview text,
  receipt_status_summary text,
  allocation_status_summary text,
  shipper_invoice_status text,
  export_evidence_status text,
  master_shipment_status text,
  sage_readiness_status text,
  next_action text,
  groupage_movement_id uuid,
  groupage_movement_ref text,
  groupage_status text,
  groupage_export_pack_status text,
  groupage_pod_status text,
  grouped_yn boolean,
  groupage_batch_count bigint,
  groupage_completed_batch_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipping control v2 requires auth.uid()';
  END IF;
  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for internal shipping control v2.';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT * FROM public.internal_shipping_control_v1()
  ), membership AS (
    SELECT
      gmb.shipment_batch_id,
      gm.id AS groupage_movement_id,
      gm.groupage_movement_ref,
      gm.status AS groupage_status
    FROM public.shipper_groupage_movement_batches gmb
    JOIN public.shipper_groupage_movements gm ON gm.id = gmb.groupage_movement_id
    WHERE gmb.active = true
      AND gm.status <> 'voided'
  ), doc AS (
    SELECT
      d.shipment_batch_id,
      CASE
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'accepted_current') THEN 'accepted_current'
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') THEN 'submitted_for_review'
        WHEN bool_or(d.document_kind <> 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') THEN 'rejected_resubmit_required'
        ELSE 'not_started'
      END AS groupage_export_pack_status,
      CASE
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'accepted_current') THEN 'accepted_current'
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'submitted_for_review') THEN 'submitted_for_review'
        WHEN bool_or(d.document_kind = 'pod_delivery_evidence' AND d.review_status = 'rejected_resubmit_required') THEN 'rejected_resubmit_required'
        ELSE 'not_started'
      END AS groupage_pod_status
    FROM public.shipper_final_export_evidence_documents d
    GROUP BY d.shipment_batch_id
  ), movement_counts AS (
    SELECT
      gm.id AS groupage_movement_id,
      COUNT(DISTINCT gmb.shipment_batch_id)::bigint AS batch_count,
      COUNT(DISTINCT gmb.shipment_batch_id) FILTER (
        WHERE EXISTS (
          SELECT 1 FROM public.shipper_final_export_evidence_documents de
          WHERE de.shipment_batch_id = gmb.shipment_batch_id
            AND de.document_kind <> 'pod_delivery_evidence'
            AND de.review_status = 'accepted_current'
        )
        AND EXISTS (
          SELECT 1 FROM public.shipper_final_export_evidence_documents dp
          WHERE dp.shipment_batch_id = gmb.shipment_batch_id
            AND dp.document_kind = 'pod_delivery_evidence'
            AND dp.review_status = 'accepted_current'
        )
      )::bigint AS completed_batch_count
    FROM public.shipper_groupage_movements gm
    JOIN public.shipper_groupage_movement_batches gmb ON gmb.groupage_movement_id = gm.id AND gmb.active = true
    WHERE gm.status <> 'voided'
    GROUP BY gm.id
  )
  SELECT
    b.shipment_batch_id,
    b.booking_ref,
    b.shipper_id,
    b.shipper_name,
    b.importer_id,
    b.importer_name,
    b.batch_status,
    b.shipment_cutoff_at,
    b.dispatched_at,
    b.box_count,
    b.created_at,
    b.package_count,
    b.order_count,
    b.allocated_package_count,
    b.unallocated_package_count,
    b.item_qty,
    b.receipt_issue_count,
    b.package_refs_preview,
    b.order_refs_preview,
    b.receipt_status_summary,
    b.allocation_status_summary,
    b.shipper_invoice_status,
    b.export_evidence_status,
    COALESCE(m.groupage_status, b.master_shipment_status)::text AS master_shipment_status,
    b.sage_readiness_status,
    b.next_action,
    m.groupage_movement_id,
    m.groupage_movement_ref::text,
    m.groupage_status::text,
    COALESCE(doc.groupage_export_pack_status, 'not_grouped')::text,
    COALESCE(doc.groupage_pod_status, 'not_grouped')::text,
    (m.groupage_movement_id IS NOT NULL) AS grouped_yn,
    COALESCE(mc.batch_count, 0)::bigint,
    COALESCE(mc.completed_batch_count, 0)::bigint
  FROM base b
  LEFT JOIN membership m ON m.shipment_batch_id = b.shipment_batch_id
  LEFT JOIN doc ON doc.shipment_batch_id = b.shipment_batch_id
  LEFT JOIN movement_counts mc ON mc.groupage_movement_id = m.groupage_movement_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.internal_shipping_control_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
